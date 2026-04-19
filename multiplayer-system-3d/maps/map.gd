extends Node

@export var spawn_locations: Array[Marker3D] = []

func _ready() -> void:
	spawn_locations.clear()
	
	for child in get_children():
		if child is Marker3D and child.name.begins_with("Spawn Location"):
			spawn_locations.append(child)
