extends Node3D

@export var player_scene: PackedScene
@onready var loadout_menu: Control = %LoadoutMenu
@onready var game_menu: Control = $GameMenu


#@export var player_ui: Control
var class_selected := false
var map_path

func _ready() -> void:
	GameManager.spawn_parent = %SpawnParent

	# Global kill feed — one per peer, cleaned up with the scene.
	var kill_feed := KillFeed.new()
	add_child(kill_feed)
	
	
	
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

func _on_main_menu_pressed() -> void:
	NetworkManager.return_to_lobby()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_pressed("leaderboard"):
		game_menu.show_leaderboard()
	else:
		game_menu.hide_leaderboard()
		
	if Input.is_action_just_pressed("class_select"):
		if class_selected == false:
			return
		loadout_menu.visible = not loadout_menu.visible
		PlayerInput.ui_open = loadout_menu.visible
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if loadout_menu.visible else Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel") and loadout_menu.visible:
		# ESC closes the loadout menu without applying any changes.  Only after
		# an initial loadout is confirmed (mirrors the H-toggle guard above).
		if class_selected:
			loadout_menu.visible = false
			PlayerInput.ui_open = false
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
