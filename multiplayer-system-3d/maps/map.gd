@tool
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

## Fills in the `target`/`targetname` links of this map's payload route and saves them to the
## `.map` it is built from.
##
## A route chains by placement order by default, which needs nothing typed but breaks when a
## point is inserted into the middle of an existing one — the new point is created last, so it
## appends to the end of the chain rather than slotting in. Pressing this once makes the links
## explicit, after which insertion cannot reorder anything. Points that already have a name or
## a `target` are left alone, so it is safe to press repeatedly. See [PayloadPathLinker].
@export_tool_button("Auto Setup Payload Path") var auto_setup_payload_path: Callable = _auto_setup_payload_path

func _enter_tree() -> void:
	# `@tool` is here for the button above, and nothing else on this node has any business
	# running while the editor has a map scene open — the spawn pools and the global below
	# are read at runtime only.
	if Engine.is_editor_hint():
		return

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


# ─────────────────────────────────────────────
#  EDITOR TOOLS
# ─────────────────────────────────────────────

## Backing the "Auto Setup Payload Path" button — see [member auto_setup_payload_path].
##
## Editor-only in effect: it rewrites the `.map` this scene is built from, which is a source
## file a running game has no business touching.
##
## [b]Run it with the map closed in TrenchBroom, or reload it there straight afterwards.[/b]
## TrenchBroom holds the open map in memory and does not re-read the file underneath itself,
## so saving from it later would write the pre-link contents back over this.
func _auto_setup_payload_path() -> void:
	var func_map := _find_func_godot_map()
	if func_map == null:
		push_warning(
			"Map: no FuncGodotMap under this node, so there is no .map to link — this map was "
			+ "authored in the editor rather than in TrenchBroom.")
		return

	var map_path: String = func_map.local_map_file
	if map_path.is_empty():
		push_warning("Map: the FuncGodotMap has no local_map_file set, so there is no .map to link.")
		return
	if not FileAccess.file_exists(map_path):
		push_warning("Map: %s does not exist." % map_path)
		return

	var original := FileAccess.get_file_as_string(map_path)
	if original.is_empty():
		push_warning("Map: %s is empty or could not be read." % map_path)
		return

	var result := PayloadPathLinker.link_map_text(original)
	for message in result["messages"]:
		print("Payload path: %s" % message)

	# An unchanged result means there was nothing to fill in — writing anyway would rewrite
	# the file's bytes for no reason, and any diff noise is a real cost on a source file.
	if result["text"] == original:
		return

	var file := FileAccess.open(map_path, FileAccess.WRITE)
	if file == null:
		push_error("Map: could not open %s for writing (error %d)."
			% [map_path, FileAccess.get_open_error()])
		return
	file.store_string(result["text"])
	file.close()

	print("Payload path: wrote %s. Rebuild the map, and reload it in TrenchBroom to see the "
		% map_path + "links.")


## The [FuncGodotMap] this scene is built from, or `null` when it is not a TrenchBroom map.
##
## `find_children` is filtered by `is FuncGodotMap` rather than by a type string: the addon's
## class is a `class_name`, and `find_children`'s type filter only answers for native classes.
func _find_func_godot_map() -> FuncGodotMap:
	for node in find_children("*", "", true, false):
		if node is FuncGodotMap:
			return node as FuncGodotMap
	return null
