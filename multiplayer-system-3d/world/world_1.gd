extends Node3D

@export var player_scene: PackedScene
@export var leaderboard: ItemList
@onready var class_select: Control = %ClassSelect


#@export var player_ui: Control
var class_selected := false
#@export var leaderboard_component: LeaderboardComponent
#@export var spawn_parent: Node3D
var map_path

func _ready() -> void:
	GameManager.spawn_parent = %SpawnParent
	
	
	
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	if NetworkManager.is_hosting_game:

		
		var map = load(map_path).instantiate()
		map.name = "Map"
		GameManager.spawn_parent.add_child(map)
		print("MAP ADDED" + map_path)
		
		
		
		var spawn_manager_scene = load("res://world/spawn_manager.tscn")
		var spawn_manager = spawn_manager_scene.instantiate()
		spawn_manager.player_scene = player_scene
		#spawn_manager.spawn_locations = map.spawn_locations
		add_child(spawn_manager)

func _on_main_menu_pressed() -> void:
	NetworkManager.terminate_connection_load_main_menu()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_pressed("leaderboard"):
		leaderboard.show()
		
	else:
		leaderboard.hide()
		
	if Input.is_action_just_pressed("class_select"):
		if class_selected == false:
			return
		class_select.visible = not class_select.visible
		PlayerInput.ui_open = class_select.visible
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if class_select.visible else Input.MOUSE_MODE_CAPTURED)
