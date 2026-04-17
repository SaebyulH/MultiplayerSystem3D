extends Node
class_name SpawnManager
#ONLY THE HOST HAS A SPAWN MANAGER!


@onready var spawn_parent : Node3D = get_tree().current_scene.get_node("%SpawnParent")

var player_scene: PackedScene

func _ready() -> void:
	get_tree().get_multiplayer().peer_connected.connect(_peer_connected)
	get_tree().get_multiplayer().peer_disconnected.connect(_peer_disconnected)
	_add_player_to_game(1)
	
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
	spawn_parent.add_child(player_to_add)
	player_to_add.global_position = Vector3(0, 12, 0)
	#TODO Fix
	get_parent().leaderboard_component.request_add_player(str(network_id))
