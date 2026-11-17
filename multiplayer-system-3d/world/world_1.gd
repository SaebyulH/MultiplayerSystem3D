extends Node3D

@export var player_scene: PackedScene
@onready var loadout_menu: LoadoutMenuUI = %LoadoutMenu
@onready var game_menu: Control = $GameMenu

const DEV_MENU_SCRIPT := preload("res://world/dev_menu.gd")
const SPECTATOR_CONTROLLER_SCRIPT := preload("res://world/spectator_controller.gd")
const TITLE_SCREEN_SCRIPT := preload("res://world/title_screen.gd")
const STAGING_ROOM_SCRIPT := preload("res://world/staging_room.gd")
const PAUSE_MENU_SCRIPT := preload("res://world/pause_menu.gd")
const POST_MATCH_SCRIPT := preload("res://world/post_match.gd")
const LoadoutProfileScript := preload("res://player/loadout_profile.gd")
const Protocol := preload("res://network/session_protocol.gd")
## Preloaded rather than referenced through `class_name` (load-order race).
const MatchManifestScript := preload("res://network/match_manifest.gd")
var dev_menu
var spectator_controller
var title_screen: CanvasLayer
var staging_room: CanvasLayer
var pause_menu: CanvasLayer
var post_match: CanvasLayer
var _flow_timer: Timer
var _staging_open := false
var _results_open := false
var _flow_started := false
var _auto_join_sent := false

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
	# Defensive reset: GameManager outlives the scene, so a world swapped out
	# while the staging overlay was open must not leave the new HUD suppressed.
	GameManager.suppress_gameplay_hud = false
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

		# New local flow overlays.  All are local CanvasLayers: never replicated
		# and never parented to SpawnParent.
		title_screen = TITLE_SCREEN_SCRIPT.new()
		add_child(title_screen)
		title_screen.visible = false
		title_screen.start_requested.connect(_on_title_start)

		staging_room = STAGING_ROOM_SCRIPT.new()
		add_child(staging_room)
		pause_menu = PAUSE_MENU_SCRIPT.new()
		add_child(pause_menu)
		post_match = POST_MATCH_SCRIPT.new()
		add_child(post_match)

		_flow_timer = Timer.new()
		_flow_timer.wait_time = 0.25
		_flow_timer.one_shot = false
		_flow_timer.timeout.connect(_sync_flow_ui)
		add_child(_flow_timer)
		_flow_timer.start()

		if not MatchSession.phase_changed.is_connected(_on_flow_phase_changed):
			MatchSession.phase_changed.connect(_on_flow_phase_changed)
		if not MatchSession.welcomed.is_connected(_on_flow_welcomed):
			MatchSession.welcomed.connect(_on_flow_welcomed)

		_setup_flow.call_deferred()

	if multiplayer.is_server():
		_wire_match_end.call_deferred()

	if "--test-leaderboard" in OS.get_cmdline_user_args():
		_show_test_leaderboard.call_deferred()


## Test hook: hold the leaderboard open after the roster exists so a headless /
## movie run can inspect it.  Never reaches normal gameplay.
func _show_test_leaderboard() -> void:
	await get_tree().create_timer(1.0).timeout
	# Re-assert: any unhandled input event with Tab not held calls
	# hide_leaderboard(), and the Movie Maker still forwards OS mouse events.
	while is_inside_tree():
		if is_instance_valid(game_menu):
			game_menu.show_leaderboard()
		await get_tree().create_timer(1.0).timeout


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
	if MatchSession.phase == Protocol.Phase.LOADING:
		MatchSession.notify_map_ready.call_deferred()


func _on_session_phase_changed(_new_phase: int, new_path: String, _new_hash: String) -> void:
	if new_path == "" or new_path == _session_map_path:
		return
	_install_session_map(new_path)


## Dev-menu "hide other HUD": the mode HUD and kill feed.
## Menus — GameMenu's loadout/leaderboard and the dev menu — are untouched.
func apply_dev_world_hud_visibility() -> void:
	var hide := GameManager.dev_hide_world_hud or GameManager.suppress_gameplay_hud
	# Toggle the whole CanvasLayer, never HUDController._root: the 10 Hz HUD tick
	# rewrites _root.visible and would immediately undo it.
	var hud := game_menu.get_node_or_null("CanvasLayer") as CanvasLayer
	if hud:
		hud.visible = not hide
	if is_instance_valid(_kill_feed):
		_kill_feed.visible = not hide

# ─────────────────────────────────────────────
#  Local flow: title, stored build, staging, pause, results
# ─────────────────────────────────────────────

func _new_flow_eligible() -> bool:
	if NetworkManager.is_dedicated_server():
		return false
	if NetworkManager.role == NetworkManager.Role.OFFLINE:
		return true
	if NetworkManager.role in [NetworkManager.Role.LISTEN_SERVER, NetworkManager.Role.CLIENT]:
		return MatchSession.role != MatchSession.Role.NONE
	return false


func _setup_flow() -> void:
	if not _new_flow_eligible():
		return
	_flow_started = true
	loadout_menu.visible = false
	_wire_match_end()
	# Test hook: let an idle staging run have a target map without going through
	# the Match Menu, so the mode-dependent team columns can be exercised.
	var test_staging_map := _arg_value("--test-staging-map=")
	if test_staging_map != "" and GameManager.pending_match_map == "":
		GameManager.pending_match_map = test_staging_map
	if multiplayer.is_server() and MatchSession.role == MatchSession.Role.SERVER \
			and GameManager.pending_match_map != "":
		MatchSession.set_staging_map(GameManager.pending_match_map)

	if "--test-staging-start" in OS.get_cmdline_user_args() \
			and multiplayer.is_server() and MatchSession.role == MatchSession.Role.SERVER:
		var test_map := _arg_value("--test-staging-map=")
		if test_map == "":
			test_map = MatchSession.target_map_path
		if test_map == "" and not ConnectionUtils.scan_map_data().is_empty():
			test_map = ConnectionUtils.scan_map_data()[0].map_scene_path
		if test_map != "":
			MatchSession.set_staging_map(test_map)
			NetworkManager.start_staging_match.call_deferred(test_map)

	if NetworkManager.role == NetworkManager.Role.OFFLINE and not GameManager.title_seen:
		_show_title()
		if "--test-title-start" in OS.get_cmdline_user_args():
			_on_title_start.call_deferred()
		return

	var spawn_now := NetworkManager.role == NetworkManager.Role.OFFLINE \
		or (NetworkManager.role == NetworkManager.Role.LISTEN_SERVER
			and MatchSession.phase == Protocol.Phase.ACTIVE)
	await _apply_local_build(spawn_now)
	if NetworkManager.role == NetworkManager.Role.CLIENT \
			and MatchSession.phase == Protocol.Phase.ACTIVE \
			and "--auto-loadout" in OS.get_cmdline_user_args():
		await get_tree().process_frame
		if MatchSession.local_player_id > 0:
			MatchSession.request_join_in_progress.rpc_id(1, MatchSession.local_player_id)
	_sync_flow_ui()
	if "--test-end-match" in OS.get_cmdline_user_args() and multiplayer.is_server():
		await get_tree().create_timer(6.0).timeout
		NetworkManager.end_match("TEST RESULTS")


func _show_title() -> void:
	title_screen.visible = true
	loadout_menu.visible = false
	class_selected = false
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _on_title_start() -> void:
	GameManager.title_seen = true
	if title_screen:
		title_screen.visible = false
	await _apply_local_build(true)
	_sync_flow_ui()


func _apply_local_build(spawn_now: bool) -> void:
	var local_id := MatchSession.local_id_string()
	var player: Player = null
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		# The stable id arrives with `welcome`, after the client starts waiting.
		local_id = MatchSession.local_id_string()
		player = GameManager.find_player(local_id)
		if player != null:
			break
		await get_tree().process_frame
	if player == null:
		return
	var build := GameManager.get_or_create_local_loadout()
	if not LoadoutProfileScript.is_valid(build):
		return
	if not GameManager.local_loadout.is_empty():
		build = GameManager.local_loadout
	var pp := str(build.get("primary_path", ""))
	var sp := str(build.get("secondary_path", ""))
	var mp := str(build.get("melee_path", ""))
	var cp := str(build.get("character_path", ""))
	var class_path := str(build.get("class_path", ""))
	var rand_on_death := bool(build.get("randomize_on_death", false))
	if multiplayer.is_server():
		loadout_menu._request_loadout(local_id, pp, sp, mp, Player.Team.FFA,
			cp, class_path, rand_on_death, false)
	else:
		loadout_menu._request_loadout.rpc_id(1, local_id, pp, sp, mp, Player.Team.FFA,
			cp, class_path, rand_on_death, false)
	class_selected = true
	loadout_menu.visible = false
	if spawn_now and multiplayer.is_server():
		var spawn_tf := player._get_spawn_transform()
		if multiplayer.get_peers().is_empty():
			player.rpc_spawn_now(spawn_tf)
		else:
			player.rpc_spawn_now.rpc(spawn_tf)
		PlayerInput.ui_open = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func on_match_map_loaded() -> void:
	_wire_match_end()


func _wire_match_end() -> void:
	var gmc := GameManager.game_mode_component
	if gmc == null or not multiplayer.is_server():
		return
	if not gmc.match_won.is_connected(_on_gmc_match_won):
		gmc.match_won.connect(_on_gmc_match_won)


func _on_gmc_match_won(winner: Player.Team) -> void:
	var text := "Match over"
	match winner:
		Player.Team.SPI: text = "TEAM SPI wins"
		Player.Team.SCI: text = "TEAM SCI wins"
		Player.Team.FFA: text = "Match over"
	NetworkManager.end_match(text)


func _on_flow_phase_changed(_phase: int, _map_path: String, _map_hash: String) -> void:
	_sync_flow_ui.call_deferred()


func _on_flow_welcomed(_info: Dictionary) -> void:
	_sync_flow_ui.call_deferred()


func _sync_flow_ui() -> void:
	if not _flow_started or not is_instance_valid(staging_room):
		return
	if title_screen and is_instance_valid(title_screen) and title_screen.visible:
		return
	var player := GameManager.find_player(MatchSession.local_id_string())
	var staging := false
	var join_mode := false
	if MatchSession.role != MatchSession.Role.NONE:
		if MatchSession.phase in [
			Protocol.Phase.STAGING,
			Protocol.Phase.COUNTDOWN,
			Protocol.Phase.LOADING,
		]:
			staging = true
		elif MatchSession.phase == Protocol.Phase.ACTIVE \
				and NetworkManager.role == NetworkManager.Role.CLIENT \
				and player != null and not player.spawned:
			staging = true
			join_mode = true

	if staging:
		if not _staging_open:
			staging_room.open(self, join_mode)
			_staging_open = true
		else:
			staging_room.world = self
			if not PlayerInput.ui_open and not loadout_menu.visible:
				PlayerInput.ui_open = true
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if join_mode and not _auto_join_sent \
				and "--auto-loadout" in OS.get_cmdline_user_args() \
				and MatchSession.local_player_id > 0:
			_auto_join_sent = true
			MatchSession.request_join_in_progress.rpc_id(1, MatchSession.local_player_id)
		return
	if _staging_open:
		staging_room.close()
		_staging_open = false

	if MatchSession.role != MatchSession.Role.NONE \
			and MatchSession.phase == Protocol.Phase.RESULTS:
		if not _results_open:
			_results_open = true
			post_match.open(MatchSession.result_text)
		return

	if _results_open:
		_results_open = false
		post_match.visible = false

	if _can_pause() and PlayerInput.ui_open and not loadout_menu.visible \
			and not (pause_menu and pause_menu.visible) \
			and not (dev_menu and dev_menu.is_open()):
		# A staging overlay, the title or the dev menu owns input; don't add
		# another.  Without the dev-menu guard this 0.25 s tick reclaimed input
		# 250 ms after pressing 0, leaving the menu visible with a captured mouse.
		if not (_staging_open or (title_screen and title_screen.visible)):
			PlayerInput.ui_open = false
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _can_pause() -> bool:
	if MatchSession.role == MatchSession.Role.NONE:
		return false
	var player := GameManager.find_player(MatchSession.local_id_string())
	if player == null or not player.spawned:
		return false
	if MatchSession.phase != Protocol.Phase.ACTIVE:
		return false
	return not _staging_open and not _results_open


func should_loadout_respawn() -> bool:
	if MatchSession.role == MatchSession.Role.NONE:
		return true
	if _staging_open or _results_open:
		return false
	return MatchSession.phase == Protocol.Phase.ACTIVE


## Send a loadout build through the existing loadout RPCs.  Used by staging
## agent select and anywhere that needs the same path as the Loadout screen
## without duplicating the server/client branch.
func apply_local_loadout(build: Dictionary, respawn := false) -> bool:
	if not LoadoutProfileScript.is_valid(build):
		return false
	var local_id := MatchSession.local_id_string()
	var pp := str(build.get("primary_path", ""))
	var sp := str(build.get("secondary_path", ""))
	var mp := str(build.get("melee_path", ""))
	var cp := str(build.get("character_path", ""))
	var class_path := str(build.get("class_path", ""))
	var rand_on_death := bool(build.get("randomize_on_death", false))
	GameManager.local_loadout = build.duplicate(true)
	if multiplayer.is_server():
		loadout_menu._request_loadout(local_id, pp, sp, mp, Player.Team.FFA,
			cp, class_path, rand_on_death, respawn)
	else:
		loadout_menu._request_loadout.rpc_id(1, local_id, pp, sp, mp, Player.Team.FFA,
			cp, class_path, rand_on_death, respawn)
	return true


## Open the Loadout screen.  `from_staging` raises it above the staging CanvasLayer
## (layer 5) and makes confirm return to staging instead of capturing the mouse.
func open_loadout(from_staging := false) -> void:
	if loadout_menu:
		loadout_menu.set_staging_mode(from_staging)
		loadout_menu.visible = true
		PlayerInput.ui_open = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


func _on_main_menu_pressed() -> void:
	NetworkManager.return_to_lobby()

func _unhandled_input(event: InputEvent) -> void:
	# Pause owns Esc while open.
	if pause_menu and pause_menu.visible:
		if event.is_action_pressed("ui_cancel"):
			pause_menu.close()
			get_viewport().set_input_as_handled()
		return

	if title_screen and is_instance_valid(title_screen) and title_screen.visible:
		return

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
	elif event.is_action_pressed("ui_cancel") and _can_pause() \
			and not PlayerInput.ui_open:
		pause_menu.open(self)
		get_viewport().set_input_as_handled()
