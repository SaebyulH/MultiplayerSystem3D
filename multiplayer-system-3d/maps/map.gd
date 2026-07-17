extends Node
class_name Map

@export var spi_spawn_locations: Array[Marker3D] = []
@export var sci_spawn_locations: Array[Marker3D] = []



@export var despawn_location: Marker3D
var camera: Camera3D

func _enter_tree() -> void:
	GameManager.game_mode_component = $GameModeComponent
	GameManager.spawn_parent.get_parent().get_node("GameMenu/CanvasLayer").setup_gmc()

	sci_spawn_locations.clear()
	spi_spawn_locations.clear()

	for child in get_children():
		if child is Marker3D and "spawn" in child.name.to_lower() and not "despawn" in child.name.to_lower():
			if "spi" in child.name.to_lower():
				spi_spawn_locations.append(child)
			elif "sci" in child.name.to_lower():
				sci_spawn_locations.append(child)
			else:
				# Unlabeled spawn — add to both pools for FFA fallback.
				spi_spawn_locations.append(child)
				sci_spawn_locations.append(child)

func get_random_spawn_location(team: Player.Team) -> Vector3:
	if team == Player.Team.SPI:
		if spi_spawn_locations.size() > 0:
			return spi_spawn_locations[randi() % spi_spawn_locations.size()].global_position
	elif team == Player.Team.SCI:
		if sci_spawn_locations.size() > 0:
			return sci_spawn_locations[randi() % sci_spawn_locations.size()].global_position
	else:
		# FFA / any team: pick from all available spawns.
		var all_spawns: Array[Marker3D] = []
		all_spawns.append_array(sci_spawn_locations)
		all_spawns.append_array(spi_spawn_locations)
		if all_spawns.size() > 0:
			return all_spawns[randi() % all_spawns.size()].global_position

	# Absolute fallback.
	return Vector3(0, 12, 0)

func get_despawn_position() -> Vector3:
	return despawn_location.global_position
