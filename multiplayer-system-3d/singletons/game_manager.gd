extends Node

var spawn_parent: Node3D
var game_mode_component: GameModeComponent

func find_player(id: String) -> Player:
	for child in spawn_parent.get_children():
		if child.name == id and child is Player:
			return child as Player
	return null

func get_despawn_position() -> Vector3:
	for node in spawn_parent.get_children():
		if node is Map:
			return node.get_despawn_position()
	return Vector3.ZERO
