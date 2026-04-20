extends Node
class_name SpawnManager

@onready var spawn_parent: Node3D = get_parent().get_node("%SpawnParent")

@export var spawn_locations: Array[Marker3D]

var player_scene: PackedScene

func _ready() -> void:
	get_tree().get_multiplayer().peer_connected.connect(_peer_connected)
	get_tree().get_multiplayer().peer_disconnected.connect(_peer_disconnected)
	_add_player_to_game(1)
	randomize()
	
func _peer_connected(network_id):
	print("Peer connected: Network ID: %s" %network_id)
	_add_player_to_game(network_id)

func _peer_disconnected(network_id):
	print("Peer disconnected: Network ID: %s" %network_id)
	var player_to_remove = spawn_parent.find_child(str(network_id), false, false)
	if player_to_remove:
		player_to_remove.queue_free()
		
func _add_player_to_game(network_id: int):
	var player_to_add = player_scene.instantiate()
	player_to_add.name = str(network_id)
	player_to_add.set_multiplayer_authority(1)
	player_to_add.spawn_manager = self
	spawn_parent.add_child(player_to_add)
	player_to_add.global_position = Vector3(0, 100, 0)
	player_to_add.global_position = get_random_spawn_location()
	

	Leaderboard.request_add_player(str(network_id))
	
func get_random_spawn_location() -> Vector3:

	if spawn_locations.size() > 0:
		var index = randi() % spawn_locations.size()
		return spawn_locations[index].global_position

	return Vector3(0, 12, 0)
	
func respawn_player(player_name):
	var path = NodePath(str(player_name))
	if not spawn_parent.has_node(path):
		push_error("Player not found: " + str(player_name))
		return
	
	var player = spawn_parent.get_node(path)
	player.global_position = get_random_spawn_location()
	player.reset()
