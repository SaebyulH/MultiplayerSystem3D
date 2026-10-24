extends Node3D

@export var player_scene: PackedScene
@onready var loadout_menu: LoadoutMenuUI = %LoadoutMenu
@onready var game_menu: Control = $GameMenu

const DEV_MENU_SCRIPT := preload("res://world/dev_menu.gd")
var dev_menu

## The global kill feed.  Kept as a member so the dev-menu "hide other HUD"
## toggle can hide it; it is a local CanvasLayer, not a replicated node.
var _kill_feed: KillFeed


#@export var player_ui: Control
var class_selected := false
var map_path

func _ready() -> void:
	GameManager.spawn_parent = %SpawnParent
	# Projectiles live under the world, not under the Player that fired them: the
	# Player is hidden on death and freed on disconnect, either of which would take
	# its in-flight projectiles with it.  Set before SpawnManager is added below, so
	# no Player can fire before this exists.  Runs on host and client alike.
	GameManager.projectile_parent = %ProjectilesParent

	# Global kill feed — one per peer, cleaned up with the scene.
	_kill_feed = KillFeed.new()
	add_child(_kill_feed)
	
	
	
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	if NetworkManager.is_hosting_game:

		
		var map = load(map_path).instantiate()
		map.name = "Map"
		GameManager.spawn_parent.add_child(map)
		if OS.is_debug_build(): print("MAP ADDED" + map_path)
		
		
		
		var spawn_manager_scene = load("res://world/spawn_manager.tscn")
		var spawn_manager = spawn_manager_scene.instantiate()
		spawn_manager.player_scene = player_scene
		#spawn_manager.spawn_locations = map.spawn_locations
		add_child(spawn_manager)

		var sm := spawn_manager as SpawnManager
		if sm:
			GameManager.spawn_manager = sm
			# Manual bots that followed the host back from a match.
			for entry in GameManager.lobby_bots:
				sm.add_bot_with_loadout(entry)

	# Dev hacks menu.  Created for every peer (the General tab is self-service);
	# parented to the world, never to SpawnParent, so it is not replicated.
	dev_menu = DEV_MENU_SCRIPT.new()
	add_child(dev_menu)
	dev_menu.setup(loadout_menu)

	# GameManager outlives this scene, so a world rebuilt after return_to_lobby
	# must re-apply its persisted dev display flag to the fresh HUD nodes.
	apply_dev_world_hud_visibility()


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
