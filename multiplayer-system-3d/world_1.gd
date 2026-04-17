extends Node3D

@export var player_scene: PackedScene
@export var leaderboard: ItemList
@export var leaderboard_component: LeaderboardComponent



func _ready() -> void:
	if NetworkManager.is_hosting_game:
		var spawn_manager_scene = load("res://spawn_manager.tscn")
		var spawn_manager = spawn_manager_scene.instantiate()
		spawn_manager.player_scene = player_scene
		add_child(spawn_manager)

func _on_main_menu_pressed() -> void:
	NetworkManager.terminate_connection_load_main_menu()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_pressed("leaderboard"):
		leaderboard.show()
	else:
		leaderboard.hide()

func get_random_spawn_location() -> Vector3:
	var map = get_node_or_null("Map")
	if map == null:
		return Vector3(0, 12, 0)

	var spawn_points: Array[Node3D] = []

	for child in map.get_children():
		if child is Node3D and child.name.begins_with("SpawnLocation"):
			spawn_points.append(child)

	if spawn_points.size() > 0:
		var index = randi() % spawn_points.size()
		return spawn_points[index].global_position

	return Vector3(0, 12, 0)
