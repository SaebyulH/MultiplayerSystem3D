extends Node
class_name Map

#@export var spawn_locations: Array[Marker3D] = []
@export var spi_spawn_locations: Array[Marker3D] = []
@export var sci_spawn_locations: Array[Marker3D] = []




@export var despawn_location: Marker3D
var camera: Camera3D

#func _ready() -> void:
	#GameManager.game_mode_component = $GameModeComponent
	#spawn_locations.clear()
	#
	#for child in get_children():
		#if child is Marker3D and child.name.begins_with("Spawn Location"):
			#spawn_locations.append(child)
			
func _enter_tree() -> void:
	GameManager.game_mode_component = $GameModeComponent
	GameManager.spawn_parent.get_parent().get_node("GameMenu/CanvasLayer").setup_gmc()
	
	
	sci_spawn_locations.clear()
	spi_spawn_locations.clear()
	
	
	for child in get_children():
		if child is Marker3D and child.name.begins_with("SPI Spawn Location"):
			spi_spawn_locations.append(child)
		if child is Marker3D and child.name.begins_with("SCI Spawn Location"):
			sci_spawn_locations.append(child)

func get_random_spawn_location(team: Player.Team) -> Vector3:
	
	if team == Player.Team.SPI:
		if spi_spawn_locations.size() > 0:
			var index = randi() % spi_spawn_locations.size()
			return spi_spawn_locations[index].global_position
	
	elif team == Player.Team.SCI:
		if sci_spawn_locations.size() > 0:
			var index = randi() % sci_spawn_locations.size()
			return sci_spawn_locations[index].global_position
	else:
		if spi_spawn_locations.size() > 0 or sci_spawn_locations.size() > 0:
			var index = randi() % spi_spawn_locations.size() + sci_spawn_locations.size()
			var spawns = sci_spawn_locations + spi_spawn_locations
			return spawns[index].global_position
	
	

	return Vector3(0, 12, 0)

func get_despawn_position() -> Vector3:
	return despawn_location.global_position
