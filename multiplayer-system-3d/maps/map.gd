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

## Bakes this map's payload route and its railroad track into the scene, so both are saved and
## visible in the editor rather than compiled at runtime.
##
## [b]You usually do not need this button[/b] — [method _notification] runs the same bake on
## every save. Press it only to see the result before saving, which also avoids the one extra
## save the hook costs: adding nodes during a save marks the scene dirty again, so the save you
## pressed it before is the only one.
##
## Writes two nodes under this map root, never under the `FuncGodotMap`: [PayloadPath] (the
## route, a shell — its zone table and glowing line are rebuilt on every peer) and the track
## container [constant PayloadTrackBuilder.CONTAINER_NAME].  See [PayloadPathBuilder.bake_path]
## and [PayloadTrackBuilder.bake].
@export_tool_button("Bake Payload Route & Track") var bake_payload_route: Callable = bake_payload_route_and_track

## Standardises this map for navigation-mesh baking: adds the map root to
## [constant NavmeshGenerator.NAV_GROUP], creates or reuses a direct-child
## [NavigationRegion3D], and applies the agent/cell settings from [NavmeshGenerator].
##
## Safe to press repeatedly — it never adds a second region.  It does not bake by default; use
## the region's "Bake NavigationMesh" inspector button, or set
## [constant NavmeshGenerator.BAKE_AFTER_SETUP].
@export_tool_button("Setup Navigation") var setup_navigation: Callable = _setup_navigation

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


# ─────────────────────────────────────────────
#  NAVIGATION
# ─────────────────────────────────────────────

## Backing the "Setup Navigation" button — see [member setup_navigation].
func _setup_navigation() -> void:
	NavmeshGenerator.setup(self)


# ─────────────────────────────────────────────
#  PAYLOAD BAKE
# ─────────────────────────────────────────────

## Backing the "Bake Payload Route & Track" button — see [member bake_payload_route].
##
## Editor-only in effect: it writes generated nodes into the scene, which is authoring work a
## running game has no business doing. Bakes the route first, because the track is swept along
## it, then reports what happened in the Output panel.
func bake_payload_route_and_track() -> void:
	if not Engine.is_editor_hint():
		push_warning("Map: the payload bake is editor-only.")
		return

	# Not `owner`: this script is on a `Node`, which already has an `owner` property, and
	# shadowing it is a warning rather than the scene root this actually is.
	var scene_root := _editable_owner()
	if scene_root == null:
		return

	var path := PayloadPathBuilder.bake_path(self, scene_root)
	var track := PayloadTrackBuilder.bake(self, scene_root)

	if path != null:
		print("Map: baked payload route — %d point(s)." % path.curve.point_count)
	if not String(track["warning"]).is_empty():
		push_warning("Map: payload track — %s." % track["warning"])
	elif bool(track["changed"]):
		print("Map: baked payload track — %d tie(s), %d vertex(es)."
			% [track["ties"], track["vertices"]])
	else:
		print("Map: payload track is already up to date.")


## The bake [method bake_payload_route_and_track] runs on every save, so a route edited in
## TrenchBroom is re-baked the moment it is saved — no button press.
##
## Silent on a map with no payload route (the lobby, an ordinary gameplay map): this fires for
## *every* map save, and warning about the absence of a feature is noise.
func _auto_bake_payload() -> void:
	if not Engine.is_editor_hint():
		return
	if not _has_payload_route():
		return

	var scene_root := _editable_owner()
	if scene_root == null:
		return

	PayloadPathBuilder.bake_path(self, scene_root)
	PayloadTrackBuilder.bake(self, scene_root)


## Whether anything here should ever be baked.  True when the map already carries a route — a
## baked [PayloadPath] or a hand-authored one — or has the path points to build one from.
func _has_payload_route() -> bool:
	if PayloadTrackBuilder.find_route(self) != null:
		return true
	return PayloadPathBuilder.find_path_points(self).size() >= 2


## The node the generated route and track must be owned by to serialize, or `null` when baking
## would write into the wrong file.
##
## [method Node.add_child] does not propagate `owner`, so without this the nodes would exist
## only in the editor session and vanish on reload.  The owner is the *edited scene root*, not
## [member owner] — this script is on that root, so its own `owner` is `null`.  When the map is
## instanced inside another scene instead (the thumbnail generator, a test scene) the two
## differ, and baking then would serialize the generated nodes into the enclosing file.
func _editable_owner() -> Node:
	if not is_inside_tree():
		return null
	var root := get_tree().edited_scene_root
	if root != self:
		push_warning(
			"Map: not baking — this map is instanced inside another scene, so the generated "
			+ "route and track would serialize into that scene's file instead of this map's.")
		return null
	return root


## Drops the baked route's derived half — the zone table and the tube mesh — so neither reaches
## the `.tscn`.
func _strip_derived_route() -> void:
	for node in find_children("*", "", true, false):
		var path := node as PayloadPath
		if path != null:
			path.strip_derived()
