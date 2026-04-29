extends Node


var spawn_parent: Node3D
var game_mode_component: GameModeComponent  # ← add this

func find_player(id: String) -> Node:
	var node := spawn_parent
	while node != null:
		for child in node.get_children():
			if child.name == id:
				return child
		node = node.get_parent()
		if node == get_tree().root:
			break
	return null



func get_despawn_position() -> Vector3:
	for node in spawn_parent.get_children():
		if node is Map:
			return node.get_despawn_position()
	return Vector3.ZERO
