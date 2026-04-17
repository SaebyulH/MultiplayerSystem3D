extends Node3D

@export var player_scene: PackedScene
@export var leaderboard: ItemList
@export var leaderboard_component: LeaderboardComponent
@export var spawn_points: Array[Node3D] = []
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
	# pick random spawn
	if spawn_points.size() > 0:
		var index = randi() % spawn_points.size()
		var spawn_point = spawn_points[index]
		return spawn_point.global_position
	else:
		return Vector3(0, 12, 0)
