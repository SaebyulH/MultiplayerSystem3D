extends Node3D

@export var player_scene: PackedScene
@export var leaderboard: ItemList
@export var player_ui: Control

#@export var leaderboard_component: LeaderboardComponent
@export var spawn_parent: Node3D
var map_path

func _ready() -> void:
	if NetworkManager.is_hosting_game:

		
		var map = load(map_path).instantiate()
		map.name = "Map"
		spawn_parent.add_child(map)
		print("MAP ADDED" + map_path)
		
		var spawn_manager_scene = load("res://world/spawn_manager.tscn")
		var spawn_manager = spawn_manager_scene.instantiate()
		spawn_manager.player_scene = player_scene
		spawn_manager.spawn_locations = map.spawn_locations
		add_child(spawn_manager)

func _on_main_menu_pressed() -> void:
	NetworkManager.terminate_connection_load_main_menu()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_pressed("leaderboard"):
		leaderboard.show()
		
	else:
		leaderboard.hide()
