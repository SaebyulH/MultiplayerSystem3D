extends Node
class_name Map

## Populated by `_enter_tree()` from this node's **direct** `Marker3D` children, and by
## nothing else — see the rules there.  Deliberately NOT `@export`: an inspector slot
## would look authoritative, accept assignments, and then have every one of them wiped on
## load, so a renamed marker would silently change spawning while the Inspector still read
## correctly.  The names are the source of truth.
var spi_spawn_locations: Array[Marker3D] = []
var sci_spawn_locations: Array[Marker3D] = []



@export var despawn_location: Marker3D
@onready var camera: Camera3D = $Camera3D

func _enter_tree() -> void:
	GameManager.game_mode_component = $GameModeComponent

	var spawn_parent := GameManager.spawn_parent
	if spawn_parent != null and spawn_parent.get_parent() != null:
		var hud := spawn_parent.get_parent().get_node_or_null("GameMenu/CanvasLayer")
		if hud != null and hud.has_method("setup_gmc"):
			hud.setup_gmc()

	# Spawn discovery.  This is the ONLY thing that decides where players spawn, so the
	# rules are worth stating exactly — a spawn that stops qualifying silently drops out
	# of the pool and the map falls back to Vector3(0, 12, 0) rather than erroring.
	#
	#   - a spawn is a `PlayerSpawn` node, and ONLY that.  The pool comes from its `team`
	#     property; the node's NAME is never consulted.  Renaming a spawn therefore cannot
	#     move it between pools, and a stray `Marker3D` that merely has "spawn" in its
	#     name is ignored instead of being picked up as one.
	#   - recursive, because func_godot parents every entity it builds under its
	#     `FuncGodotMap` node: a spawn placed through TrenchBroom is one level deeper than
	#     a hand-placed one, and a direct-children scan found none of them.
	sci_spawn_locations.clear()
	spi_spawn_locations.clear()

	for node in find_children("*", "Marker3D", true, false):
		var spawn := node as PlayerSpawn
		if spawn == null:
			continue

		match spawn.team:
			PlayerSpawn.Team.SPI:
				spi_spawn_locations.append(spawn)
			PlayerSpawn.Team.SCI:
				sci_spawn_locations.append(spawn)
			_:
				# ANY — a spawn either team may use.  Also what an unset `team` gives,
				# since that is the property's default.
				spi_spawn_locations.append(spawn)
				sci_spawn_locations.append(spawn)


## A random spawn for `team`: where to stand **and** which way to face.
##
## The basis is built from the marker's yaw alone — not its `global_transform` — so a
## marker scaled in TrenchBroom cannot leak scale onto the player.  Yaw is the whole
## facing a first-person body has, so pitch/roll on a marker are ignored.
func get_random_spawn_transform(team: Player.Team) -> Transform3D:
	var picked: Marker3D = null
	if team == Player.Team.SPI and not spi_spawn_locations.is_empty():
		picked = spi_spawn_locations[randi() % spi_spawn_locations.size()]
	elif team == Player.Team.SCI and not sci_spawn_locations.is_empty():
		picked = sci_spawn_locations[randi() % sci_spawn_locations.size()]
	elif team != Player.Team.SPI and team != Player.Team.SCI:
		# FFA / any team: pick from all available spawns.
		var all_spawns: Array[Marker3D] = []
		all_spawns.append_array(sci_spawn_locations)
		all_spawns.append_array(spi_spawn_locations)
		if not all_spawns.is_empty():
			picked = all_spawns[randi() % all_spawns.size()]

	# Absolute fallback.
	if picked == null:
		return Transform3D(Basis.IDENTITY, Vector3(0, 12, 0))

	return Transform3D(Basis(Vector3.UP, picked.global_rotation.y), picked.global_position)

func get_despawn_position() -> Vector3:
	return despawn_location.global_position
