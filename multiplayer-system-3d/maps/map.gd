extends Node
class_name Map

@export var spawn_locations: Array[Marker3D] = []
@export var despawn_point: Marker3D

func _ready() -> void:
	spawn_locations.clear()
	
	for child in get_children():
		if child is Marker3D and child.name.begins_with("Spawn Location"):
			spawn_locations.append(child)

func get_random_spawn_location() -> Vector3:

	if spawn_locations.size() > 0:
		var index = randi() % spawn_locations.size()
		return spawn_locations[index].global_position

	return Vector3(0, 12, 0)


func get_despawned_position() -> Vector3:
	return despawn_point.global_position
