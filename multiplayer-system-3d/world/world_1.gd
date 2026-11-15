extends Node3D

@export var player_scene: PackedScene
@onready var loadout_menu: LoadoutMenuUI = %LoadoutMenu
@onready var game_menu: Control = $GameMenu

const DEV_MENU_SCRIPT := preload("res://world/dev_menu.gd")
const SPECTATOR_CONTROLLER_SCRIPT := preload("res://world/spectator_controller.gd")
## Preloaded rather than referenced through `class_name` (load-order race).
const MatchManifestScript := preload("res://network/match_manifest.gd")
var dev_menu
var spectator_controller

## The global kill feed.  Kept as a member so the dev-menu "hide other HUD"
## toggle can hide it; it is a local CanvasLayer, not a replicated node.
var _kill_feed: KillFeed


#@export var player_ui: Control
var class_selected := false
var map_path
## Map currently built by this peer in a match session (client-side).
var _session_map_path: String = ""

func _ready() -> void:
	GameManager.spawn_parent = %SpawnParent
	# Projectiles live under the world, not under the Player that fired them: the
	# Player is hidden on death and freed on disconnect, either of which would take
	# its in-flight projectiles with it.  Set before SpawnManager is added below, so
	# no Player can fire before this exists.  Runs on host and client alike.
	GameManager.projectile_parent = %ProjectilesParent

	# Match sessions load maps from local files on every peer.  The spawner is
	# reduced to the player scene so it cannot also replicate a 46 MB map, and a
	# client builds the staging map before it sends `hello`.
	var session_role := MatchSession.role
	if session_role == MatchSession.Role.SERVER or session_role == MatchSession.Role.CLIENT:
		_restrict_world_spawner_to_players()
	if session_role == MatchSession.Role.CLIENT:
		_install_client_session_map()
		if not MatchSession.phase_changed.is_connected(_on_session_phase_changed):
			MatchSession.phase_changed.connect(_on_session_phase_changed)

	# A dedicated match server has no local player, camera or UI.  Peer 1 is the
	# authority but is not a participant; SpawnManager adds only joining peers.
	var dedicated := NetworkManager.is_dedicated_server()

	if not dedicated:
		# Global kill feed — one per peer, cleaned up with the scene.
		_kill_feed = KillFeed.new()
		add_child(_kill_feed)

		PlayerInput.ui_open = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		# The nodes still exist in world1.tscn; hide them so no HUD or menu
		# allocates/ticks per frame on the server.
		game_menu.visible = false
		loadout_menu.visible = false

	if NetworkManager.is_hosting_game:


		var map = load(map_path).instantiate()
		map.name = "Map"
		GameManager.spawn_parent.add_child(map)
		if OS.is_debug_build(): print("MAP ADDED" + map_path)
		if MatchSession.role == MatchSession.Role.SERVER:
			# The handshake announces this hash; clients verify it before loading
			# the same local file.
			MatchSession.map_hash = MatchManifestScript.hash_map(map_path)



		var spawn_manager_scene = load("res://world/spawn_manager.tscn")
		var spawn_manager = spawn_manager_scene.instantiate()
		spawn_manager.player_scene = player_scene
		# A dedicated server has no peer-1 player; only a listen/legacy host does.
		spawn_manager.spawn_local_player = not dedicated
		#spawn_manager.spawn_locations = map.spawn_locations
		add_child(spawn_manager)

		var sm := spawn_manager as SpawnManager
		if sm:
			GameManager.spawn_manager = sm
			# Manual bots that followed the host back from a match.
			for entry in GameManager.lobby_bots:
				sm.add_bot_with_loadout(entry)
			# Apply the host menu's pre-host choices (team, autofill) now that
			# the listen server has a SpawnManager and player 1.
			if MatchSession.role == MatchSession.Role.SERVER:
				_apply_pending_host_setup(sm)
			# Only now can the match session accept hellos: the spawn manager is
			# what adds the joining Player once the client's world exists.
			if MatchSession.role == MatchSession.Role.SERVER:
				MatchSession.mark_server_world_ready(sm)

	if not dedicated:
		# Dev hacks menu.  Created for every peer (the General tab is self-service);
		# parented to the world, never to SpawnParent, so it is not replicated.
		dev_menu = DEV_MENU_SCRIPT.new()
		add_child(dev_menu)
		dev_menu.setup(loadout_menu)

		# Spectator camera + target cycling.  Local-only, like the dev menu — a
		# sibling of SpawnParent, so neither it nor its camera is replicated.
		spectator_controller = SPECTATOR_CONTROLLER_SCRIPT.new()
		add_child(spectator_controller)

		# GameManager outlives this scene, so a world rebuilt after return_to_lobby
		# must re-apply its persisted dev display flag to the fresh HUD nodes.
		apply_dev_world_hud_visibility()


## Apply the host menu's choices captured in the local shell to the new listen
## server.  Manual bots are already re-added from `GameManager.lobby_bots`
## (the menu updates their team there before the transition).
func _apply_pending_host_setup(sm: SpawnManager) -> void:
	var setup := GameManager.pending_host_setup
	if setup.is_empty():
		return
	GameManager.pending_host_setup = {}
	var host := GameManager.find_player("1")
	if host != null:
		host.team = int(setup.get("host_team", Player.Team.FFA))
	if not bool(setup.get("autofill", false)):
		return
	if bool(setup.get("ffa", false)):
		var target := int(setup.get("ffa_target", 0))
		var count := _count_team_players(Player.Team.FFA)
		for _i in range(count, target):
			sm.add_autofill_bot(Player.Team.FFA)
	else:
		var team_size := int(setup.get("team_size", 0))
		for team in [Player.Team.SPI, Player.Team.SCI]:
			var count := _count_team_players(team)
			for _i in range(count, team_size):
				sm.add_autofill_bot(team)


func _count_team_players(team: Player.Team) -> int:
	var count := 0
	if not is_instance_valid(GameManager.spawn_parent):
		return 0
	for child in GameManager.spawn_parent.get_children():
		if child is Player and (child as Player).team == team:
			count += 1
	return count


## Match sessions carry maps as local assets, not spawner traffic.  The world
## spawner keeps only the player scene; the projectile spawner is separate and
## untouched.
func _restrict_world_spawner_to_players() -> void:
	var spawner := get_node_or_null("MultiplayerSpawner") as MultiplayerSpawner
	if spawner == null or player_scene == null:
		return
	spawner._spawnable_scenes = PackedStringArray([player_scene.resource_path])


## Client side of the match-session map model: build the staging map from disk
## and verify it against the server's hash before use.
func _install_client_session_map() -> void:
	var path: String = MatchSession.map_path
	if path == "":
		path = NetworkManager.LOBBY_MAP_PATH
	_install_session_map(path)


func _install_session_map(path: String) -> void:
	if MatchSession.map_hash != "" and not MatchManifestScript.verify_map(path, MatchSession.map_hash):
		push_error("MAP_MISMATCH: %s does not match the server hash" % path)
		return
	var old_map := GameManager.spawn_parent.get_node_or_null("Map")
	if old_map != null:
		# Remove before queue_free.  A queued node keeps its name until the end of
		# the frame, so adding the new map while the old one is still a child
		# auto-renames the new node ("Map2") and every `Map/...` path breaks.
		GameManager.spawn_parent.remove_child(old_map)
		old_map.queue_free()
	var map = load(path).instantiate()
	map.name = "Map"
	GameManager.spawn_parent.add_child(map)
	_session_map_path = path
	if OS.is_debug_build(): print("CLIENT MAP ADDED " + path)


func _on_session_phase_changed(_new_phase: int, new_path: String, _new_hash: String) -> void:
	if new_path == "" or new_path == _session_map_path:
		return
	_install_session_map(new_path)


## Dev-menu "hide other HUD": the mode HUD and kill feed.
## Menus — GameMenu's loadout/leaderboard and the dev menu — are untouched.
func apply_dev_world_hud_visibility() -> void:
	var hide := GameManager.dev_hide_world_hud
	# Toggle the whole CanvasLayer, never HUDController._root: the 10 Hz HUD tick
	# rewrites _root.visible and would immediately undo it.
	var hud := game_menu.get_node_or_null("CanvasLayer") as CanvasLayer
	if hud:
		hud.visible = not hide
	if is_instance_valid(_kill_feed):
		_kill_feed.visible = not hide

func _on_main_menu_pressed() -> void:
	NetworkManager.return_to_lobby()

func _unhandled_input(event: InputEvent) -> void:
	# Dev menu owns input while it is logically open — including while its
	# canvas is hidden during a bot-loadout edit.
	if event.is_action_pressed("dev_menu"):
		if OS.is_debug_build():
			dev_menu.toggle()
			get_viewport().set_input_as_handled()
		return

	if dev_menu and dev_menu.is_open():
		if event.is_action_pressed("ui_cancel"):
			dev_menu.close()
			get_viewport().set_input_as_handled()
		return

	if Input.is_action_pressed("leaderboard"):
		game_menu.show_leaderboard()
	else:
		game_menu.hide_leaderboard()

	if event.is_action_pressed("class_select"):
		if class_selected == false:
			return
		if loadout_menu.bot_edit_mode:
			# Cancel the bot editor; the dev menu reopens on its Bots tab.
			loadout_menu.visible = false
			return
		loadout_menu.visible = not loadout_menu.visible
		PlayerInput.ui_open = loadout_menu.visible
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if loadout_menu.visible else Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel") and loadout_menu.visible:
		# ESC closes the loadout menu without applying any changes.  Only after
		# an initial loadout is confirmed (mirrors the H-toggle guard above), or
		# while editing a bot from the dev menu.
		if loadout_menu.bot_edit_mode:
			# Hiding finishes bot-edit mode, which reopens the dev menu; that
			# path restores ui_open and the mouse mode itself.
			loadout_menu.visible = false
		elif class_selected:
			loadout_menu.visible = false
			PlayerInput.ui_open = false
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
