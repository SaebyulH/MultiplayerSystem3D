extends Node
## Checks the payload route from both ends: the chain compiler, and the TrenchBroom
## entities that feed it.
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/verify_payload_path.tscn
##
## Expect a wall of `Attempting to initialize the wrong RID` / `mesh_set_blend_shape_mode`
## errors out of the second half.  They are the dummy renderer — `--headless` has no mesh
## storage, so anything that builds visuals trips it.  Printed, not fatal; the exit code is
## what to read.
##
## Exits with the number of failed assertions, so 0 means a route authored in TrenchBroom
## compiles into the path a cart actually rides.
##
## Deliberately small.  The project has no test suite by design, and this covers the two
## things about this feature that a running map will not tell you:
##
##   * [b]the chain walk[/b], which is pure logic — a route that compiles in the wrong order,
##     or a checkpoint that projects to the wrong offset, looks exactly like a correct one
##     until someone plays the map for ten minutes;
##   * [b]the entity definitions[/b], where a property whose name does not match a real
##     `@export` is dropped by `entity_assembler.gd:250-262`'s `if property in node` with no
##     error at all, and a vector authored in TrenchBroom's axes silently moves the thing
##     sideways (known-issues #70 and #74).  That half builds
##     `trenchbroom/maps/payload_path_test.map` through the real `FuncGodotMap`, the same
##     way `tools/verify_brush_entities.gd` does.

const MAP_SCRIPT := preload("res://maps/map.gd")
const PATH_POINT_SCENE := preload("res://world/payload/payload_path_point.tscn")
const CHECKPOINT_SCENE := preload("res://world/payload_checkpoint_visual.tscn")
## Forces the payload itself to parse; the fixture build below instantiates it for real.
const PAYLOAD_SCRIPT := preload("res://world/payload/payload.gd")

const MAP_SETTINGS_PATH := "res://trenchbroom/multiplayer_system_3d_map_settings.tres"
const FIXTURE_PATH := "res://trenchbroom/maps/payload_path_test.map"

## A real level with a payload route in it, opened **read-only** by the linker checks.  It
## exists to prove the `.map` parser copes with a file this harness did not author.
const REAL_MAP_PATH := "res://trenchbroom/maps/test.map"

## Waypoints on a straight line along +X, so every expected offset is arithmetic.
##
## Four rather than three, because the last stretch of a route starts at ratio 1.0 and so is
## only reachable at the very end.  The "no flags at all" case needs a stretch with room in
## it, which means a waypoint in the middle carrying neither.
const WAYPOINTS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(10.0, 0.0, 0.0),
	Vector3(20.0, 0.0, 0.0),
	Vector3(30.0, 0.0, 0.0),
]

## Deliberately three units off the route, beside the second waypoint.
const CHECKPOINT_POSITION := Vector3(10.0, 0.0, 3.0)

## Where that waypoint falls along a 30-unit straight route.
const CHECKPOINT_RATIO: float = 1.0 / 3.0

## How far a projection or a unit conversion may drift.  Every check here is on a straight
## run or an exact conversion, so this only absorbs float noise.
const TOLERANCE: float = 0.02

## `FuncGodotMapSettings.inverse_scale_factor`, the divisor a build applies to lengths.
const MAP_UNITS_PER_GODOT_UNIT := 32.0

## The payload's authored `vertical_offset` in the fixture, in TrenchBroom map units along
## up, and the Godot vector it has to arrive as.
const FIXTURE_VERTICAL_OFFSET_TB := "0 0 128"
const FIXTURE_VERTICAL_OFFSET_GODOT := Vector3(0.0, 4.0, 0.0)

var _failures: int = 0


func _ready() -> void:
	_check_grounded(PATH_POINT_SCENE, "PayloadPathPoint")
	_check_grounded(CHECKPOINT_SCENE, "PayloadCheckpoint")
	_check_linker()
	await _check_chain_compiler()
	await _check_entity_build()
	_finish()


# ─────────────────────────────────────────────
#  HALF 0b — the linker that writes the links
# ─────────────────────────────────────────────

## [PayloadPathLinker] rewrites a `.map`, which is the one thing in this feature that can
## damage a level.  Everything below is about the two properties that make that safe: it
## changes only the lines it has to, and running it twice changes nothing.
func _check_linker() -> void:
	_check_linker_fills_gaps()
	_check_linker_keeps_decisions()
	_check_linker_is_idempotent()
	_check_linker_preserves_bytes()
	_check_linker_needs_two_points()
	_check_linker_on_real_map()


## Unnamed, unlinked points get `path_1…path_N` in placement order and chain forwards.
func _check_linker_fills_gaps() -> void:
	var lines := [
		"// entity 0", "{", "\"classname\" \"worldspawn\"", "}",
		"// entity 1", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 0 0\"", "}",
		"// entity 2", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 320 0\"", "}",
		"// entity 3", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 640 0\"", "}",
	]
	var result := PayloadPathLinker.link_map_text(_map_text(lines))

	_check("linker names all three", result["named"], 3)
	_check("linker links two of them", result["linked"], 2)

	var linked: String = result["text"]
	_check_contains(linked, "\"targetname\" \"path_1\"", "first point is named path_1")
	_check_contains(linked, "\"target\" \"path_2\"", "first point targets path_2")
	_check_contains(linked, "\"targetname\" \"path_3\"", "third point is named path_3")

	# Three points, so two links and no third: the last point has nothing after it and must
	# not be given a dangling or empty target.
	_check("linker writes exactly two target lines", _count(linked, "\"target\" "), 2)
	_check_contains(linked, "\"target\" \"path_3\"", "the second point targets the third")


## Existing names and existing targets are the mapper's decisions, not gaps — they survive,
## and a generated name never collides with a name already used anywhere in the map.
func _check_linker_keeps_decisions() -> void:
	var lines := [
		"// entity 0", "{", "\"classname\" \"worldspawn\"", "}",
		# `path_1` is taken by a trigger, so the first generated name must be path_2.
		"// entity 1", "{", "\"classname\" \"trigger\"", "\"targetname\" \"path_1\"", "}",
		"// entity 2", "{", "\"classname\" \"PayloadPathPoint\"", "\"targetname\" \"entrance\"", "}",
		"// entity 3", "{", "\"classname\" \"PayloadPathPoint\"", "}",
		"// entity 4", "{", "\"classname\" \"PayloadPathPoint\"", "}",
	]
	var result := PayloadPathLinker.link_map_text(_map_text(lines))
	var linked: String = result["text"]

	_check("linker names only the unnamed", result["named"], 2)
	_check_contains(linked, "\"targetname\" \"entrance\"", "the hand-written name survives")
	_check("linker skips a name taken elsewhere", _count(linked, "\"targetname\" \"path_1\""), 1)
	_check_contains(linked, "\"targetname\" \"path_2\"", "numbering resumes past the taken name")
	_check_contains(linked, "\"target\" \"path_2\"", "the named head links into the new chain")


## Running it on an already-linked map is a no-op.  This is the property the whole design
## rests on: the button can be pressed at any time without reviewing what it might change.
func _check_linker_is_idempotent() -> void:
	var lines := [
		"// entity 0", "{", "\"classname\" \"worldspawn\"", "}",
		"// entity 1", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 0 0\"", "}",
		"// entity 2", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 320 0\"", "}",
	]
	var first := PayloadPathLinker.link_map_text(_map_text(lines))
	var second := PayloadPathLinker.link_map_text(first["text"])

	if second["text"] == first["text"]:
		_ok("linker: a second pass changes nothing")
	else:
		_fail("a second pass rewrote the map")
	_check("linker second pass names nothing", second["named"], 0)
	_check("linker second pass links nothing", second["linked"], 0)


## CRLF survives, brush blocks are not mistaken for properties, and every line the linker did
## not need to change comes through byte-identical.
func _check_linker_preserves_bytes() -> void:
	var lines := [
		"// Game: MultiplayerSystem3D",
		"// entity 0",
		"{",
		"\"classname\" \"worldspawn\"",
		"// brush 0",
		"{",
		"( 0 0 0 ) ( 0 1 0 ) ( 0 0 1 ) tex [ 1 0 0 0 ] [ 0 1 0 0 ] 0 1 1",
		"}",
		"}",
		"",
		"// entity 1",
		"{",
		"\"classname\" \"PayloadPathPoint\"",
		"\"origin\" \"0 0 0\"",
		"}",
		"// entity 2",
		"{",
		"\"classname\" \"PayloadPathPoint\"",
		"\"origin\" \"0 320 0\"",
		"}",
	]
	var original := _map_text(lines)
	var result := PayloadPathLinker.link_map_text(original)
	var linked: String = result["text"]

	if linked == original:
		_fail("the linker changed nothing on a map with a route to link")
		return
	_ok("linker: produced new text")

	if _strip_generated(linked) == original:
		_ok("linker: every untouched line survives byte-for-byte")
	else:
		_fail("the linker altered lines it had no business touching")

	if linked.contains("\r\n") and not linked.replace("\r\n", "").contains("\n"):
		_ok("linker: CRLF line endings preserved throughout")
	else:
		_fail("the linker introduced bare LF into a CRLF map")

	# The brush's face line is not a property; a parser that lost the brace depth would read
	# it as one and mis-attribute everything after it.
	if _count(linked, "\"targetname\" \"path_") == 2:
		_ok("linker: only the two path points were named")
	else:
		_fail("the linker named %d points, expected 2"
			% _count(linked, "\"targetname\" \"path_"))


## A route of one point is not a route; the map must come back untouched.
func _check_linker_needs_two_points() -> void:
	var lines := [
		"// entity 0", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 0 0\"", "}",
	]
	var original := _map_text(lines)
	var result := PayloadPathLinker.link_map_text(original)

	if result["text"] == original and result["named"] == 0:
		_ok("linker: a single point is left alone")
	else:
		_fail("the linker rewrote a map it could not build a route for")


## The same thing against a real level, read-only.
##
## `trenchbroom/maps/test.map` is a full map with brushes, movers, triggers and a payload
## route whose points were named by hand.  It is the proof that the parser copes with a file
## it did not author — and, since that route is already fully linked, that the no-op path
## really is a no-op rather than a rewrite that happens to be equivalent.
func _check_linker_on_real_map() -> void:
	if not FileAccess.file_exists(REAL_MAP_PATH):
		_fail("could not read %s" % REAL_MAP_PATH)
		return

	var original := FileAccess.get_file_as_string(REAL_MAP_PATH)
	var result := PayloadPathLinker.link_map_text(original)

	if result["text"] == original:
		_ok("linker: an already-linked real map comes back byte-identical")
	else:
		_fail("the linker rewrote %s, which is already linked" % REAL_MAP_PATH)

	if result["named"] == 0 and result["linked"] == 0:
		_ok("linker: nothing to do on an already-linked real map")
	else:
		_fail("the linker found %d gaps in an already-linked map"
			% (result["named"] + result["linked"]))


# ─────────────────────────────────────────────
#  HALF 0 — the entities sit on the floor
# ─────────────────────────────────────────────

## Every mesh in [param scene] must have its lowest point at the node's origin.
##
## This is a placement contract, not cosmetics. TrenchBroom positions a newly placed point
## entity from its bounding box, so an entity whose art is centred on its origin — rather
## than standing on it — ends up that half-height above whatever surface it was dropped on.
## For a path point that is the route itself, which then runs above the floor and takes the
## cart's geometry with it; the mapper sees a route that does not line up with the level art
## and has no way to correct for it short of eyeballing an offset.
##
## Checked against the transformed mesh AABB rather than a hand-written number, so moving a
## mesh without moving the node fails here.
##
## The scene is put in the tree before measuring: `Node3D.get_global_transform()` is refused
## on a node outside the tree and quietly answers identity, which makes every mesh look like
## it sits at its own local origin. Run this before the map half, so nothing is on the map
## for the entities' own `_ready` to find.
func _check_grounded(scene: PackedScene, label: String) -> void:
	var root := scene.instantiate() as Node3D
	if root == null:
		_fail("%s does not instantiate to a Node3D" % label)
		return
	add_child(root)

	var lowest := INF
	var meshes := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		meshes += 1
		var to_root: Transform3D = root.global_transform.affine_inverse() \
			* mesh_instance.global_transform
		lowest = minf(lowest, (to_root * mesh_instance.mesh.get_aabb()).position.y)

	if meshes == 0:
		_fail("%s has no meshes to stand on the floor" % label)
	elif absf(lowest) < TOLERANCE:
		_ok("grounded: %s's bottom is at y=0" % label)
	else:
		_fail("%s's lowest mesh is at y=%.4f, not 0 — placing it on the floor would leave "
			% [label, lowest] + "the entity that far off it")
	root.queue_free()


# ─────────────────────────────────────────────
#  HALF 1 — the chain compiler, built by hand
# ─────────────────────────────────────────────

func _check_chain_compiler() -> void:
	var map := _build_map()

	# A frame for the deferred `ensure_path` the path points fire from their own `_ready`
	# — the harness is exercising the real load path, not a shortcut.
	var checkpoint := CHECKPOINT_SCENE.instantiate() as PayloadCheckpointVisual
	checkpoint.position = CHECKPOINT_POSITION
	map.add_child(checkpoint)
	await get_tree().process_frame

	var path := PayloadPathBuilder.ensure_path(checkpoint)
	if path == null:
		_fail("ensure_path returned null")
		return

	_check_curve(path)
	_check_idempotent(map, path)
	_check_checkpoint(checkpoint, path)
	_check_zones(path)
	_check_explicit_chain()
	_check_line(path)


## A `Map`, because that is what [method PayloadPathBuilder.map_root] keys on — the harness
## has to build the same shape a real map has, not a convenient stand-in.
##
## That shape is a `Node3D` carrying `map.gd`, not a `Node`: the script declares
## `extends Node`, but every map scene attaches it to a spatial node, and the route builder
## needs a transform.  Alongside it go the two children `map.gd` reaches for in
## `_enter_tree` — a `Camera3D` and a `GameModeComponent` — the latter left in `MAIN_MENU`,
## which is the mode whose `_ready` returns before the phase machine starts.
func _build_map() -> Node:
	var map := Node3D.new()
	map.name = "Map"
	map.set_script(MAP_SCRIPT)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	map.add_child(camera)

	var gmc := GameModeComponent.new()
	gmc.name = "GameModeComponent"
	gmc.game_mode = GameModeComponent.GameMode.MAIN_MENU
	map.add_child(gmc)

	add_child(map)

	var previous: PayloadPathPoint = null
	for i in WAYPOINTS.size():
		var point := PATH_POINT_SCENE.instantiate() as PayloadPathPoint
		point.name = "TrackPoint%d" % i
		point.position = WAYPOINTS[i]
		point.targetname = "p%d" % i
		if previous != null:
			previous.target = point.targetname
		map.add_child(point)
		previous = point

	# Point 0 starts a rollback stretch; point 1 starts a rollforward one; points 2 and 3
	# carry neither, which is the all-flags-off case the ratchet relies on.
	var first := map.get_node("TrackPoint0") as PayloadPathPoint
	first.rollback_zone = true
	var second := map.get_node("TrackPoint1") as PayloadPathPoint
	second.rollforward_zone = true

	return map


## The route is one curve point per waypoint, in chain order, in the map's own space.
func _check_curve(path: PayloadPath) -> void:
	if path.curve == null:
		_fail("the generated path has no curve")
		return

	if path.curve.point_count == WAYPOINTS.size():
		_ok("curve: %d points for %d waypoints" % [path.curve.point_count, WAYPOINTS.size()])
	else:
		_fail("curve has %d points, expected %d" % [path.curve.point_count, WAYPOINTS.size()])

	for i in mini(path.curve.point_count, WAYPOINTS.size()):
		var actual: Vector3 = path.curve.get_point_position(i)
		if actual.distance_to(WAYPOINTS[i]) < TOLERANCE:
			_ok("curve: point %d is waypoint %d" % [i, i])
		else:
			_fail("curve point %d is %s, expected %s" % [i, actual, WAYPOINTS[i]])

	if path.path_points.size() == WAYPOINTS.size():
		_ok("chain: all %d waypoints are on the route" % WAYPOINTS.size())
	else:
		_fail("chain has %d points, expected %d" % [path.path_points.size(), WAYPOINTS.size()])


## Every path point and the payload call `ensure_path`, so the second caller finding the
## first caller's route is the property the whole build depends on.
func _check_idempotent(map: Node, first_build: PayloadPath) -> void:
	var again := PayloadPathBuilder.ensure_path(map)
	if again == first_build:
		_ok("idempotent: a second ensure_path returns the same route")
	else:
		_fail("ensure_path built a second route instead of returning the existing one")

	var group_count := 0
	for candidate in get_tree().get_nodes_in_group(PayloadPath.GROUP):
		if PayloadPathBuilder.map_root(candidate) == map:
			group_count += 1
	if group_count == 1:
		_ok("idempotent: exactly one path in the group belongs to this map")
	else:
		_fail("%d paths in the group belong to this map, expected 1" % group_count)


## The whole point of the entity: a checkpoint placed roughly lands squarely on the route.
func _check_checkpoint(checkpoint: PayloadCheckpointVisual, path: PayloadPath) -> void:
	# The helper is a child of the route, not a new parent of the checkpoint — the marker
	# stays where the map put it in the tree and takes the helper's transform instead.
	var helper := path.get_node_or_null("CheckpointFollower") as PathFollow3D
	if helper == null:
		_fail("no CheckpointFollower helper was added to the route")
		return
	_ok("checkpoint: dropped a PathFollow3D helper onto the route")

	if checkpoint.get_parent() == path.get_parent():
		_ok("checkpoint: left where the map placed it in the tree")
	else:
		_fail("checkpoint was re-parented to %s" % checkpoint.get_parent().get_class())

	# It was authored 3 units off the route; it has to have moved onto it.
	var off_route: float = absf(path.to_local(checkpoint.global_position).z)
	if off_route < TOLERANCE:
		_ok("checkpoint: snapped onto the route from 3 units away")
	else:
		_fail("checkpoint is still %.3f units off the route" % off_route)

	var ratio := checkpoint.get_path_ratio()
	if absf(ratio - CHECKPOINT_RATIO) < TOLERANCE:
		_ok("checkpoint: projects to %.3f along the route" % ratio)
	else:
		_fail("checkpoint projected to %.3f, expected %.3f"
			% [ratio, CHECKPOINT_RATIO])


## A flag applies from its own point to the next one, and a stretch with no flag at all
## reads as "no rollback, no rollforward" — the ratchet the design settled on.
func _check_zones(path: PayloadPath) -> void:
	if path.zones.size() != WAYPOINTS.size():
		_fail("zone table has %d entries, expected %d" % [path.zones.size(), WAYPOINTS.size()])
		return
	_ok("zones: one stretch per waypoint")

	_expect_zone(path, 0.1, true, false, "stretch 1 is rollback only")
	_expect_zone(path, 0.5, false, true, "stretch 2 is rollforward only")
	_expect_zone(path, 0.8, false, false, "stretch 3 carries no flags")


func _expect_zone(path: PayloadPath, ratio: float, rollback: bool, rollforward: bool,
		label: String) -> void:
	var zone := path.zone_at(ratio)
	var got_rollback: bool = bool(zone.get("rollback", false))
	var got_rollforward: bool = bool(zone.get("rollforward", false))
	if got_rollback == rollback and got_rollforward == rollforward:
		_ok("zones: at %.1f — %s" % [ratio, label])
	else:
		_fail("zones at %.1f: rollback=%s rollforward=%s, expected %s/%s"
			% [ratio, got_rollback, got_rollforward, rollback, rollforward])


## The other half of the chaining rule: once any point sets `target`, the route comes from
## the links and placement order is ignored entirely.
##
## The array is deliberately in a different order from the chain it describes. If the two
## modes were ever confused for one another — or if `build_chain` fell back to array order
## the moment a link dangled — this is the assertion that notices.
func _check_explicit_chain() -> void:
	var a := _bare_point("ExplicitA", "a")
	var b := _bare_point("ExplicitB", "b")
	var c := _bare_point("ExplicitC", "c")
	var d := _bare_point("ExplicitD", "d")

	# a -> c -> d -> b, from an array laid out a, b, c, d.
	a.target = "c"
	c.target = "d"
	d.target = "b"

	var chain := PayloadPathBuilder.build_chain([a, b, c, d])
	var names := PackedStringArray()
	for point in chain:
		names.append(point.targetname)

	if Array(names) == ["a", "c", "d", "b"]:
		_ok("explicit chain: follows 'target', not array order (%s)" % ", ".join(names))
	else:
		_fail("explicit chain came out as [%s], expected [a, c, d, b]"
			% ", ".join(names))

	# A loop has no head, and chasing one must terminate rather than hang the load.
	#
	# Only the two looped points go in — a third point that nothing names would itself be a
	# head, and the walk would correctly start there and never reach the loop at all.
	a.target = "b"
	b.target = "a"
	var looped := PayloadPathBuilder.build_chain([a, b])
	if looped.size() == 2:
		_ok("explicit chain: a closed loop terminates after %d points" % looped.size())
	else:
		_fail("a closed loop produced %d points, expected it to stop at 2" % looped.size())

	for point in [a, b, c, d]:
		point.free()


## A path point with no position and no place in a map — enough for the chain walk, which
## only ever reads `target` and `targetname`.
func _bare_point(node_name: String, targetname: String) -> PayloadPathPoint:
	var point := PATH_POINT_SCENE.instantiate() as PayloadPathPoint
	point.name = node_name
	point.targetname = targetname
	return point


## A route nothing draws is a route nobody can find; the tube has to exist, and the shader
## that erases the part behind the cart has to have parsed.
##
## The uniform list is the one piece of the shader this can reach: `--headless` has no
## renderer, so nothing here proves the line *looks* right — only that
## `payload_path_line.gdshader` is valid and still declares the three things
## [method PayloadPathLine.set_progress] and `_shader_material()` write to.
func _check_line(path: PayloadPath) -> void:
	if path.line.mesh == null:
		_fail("the glowing route mesh is empty")
		return

	# `mesh != null` on its own would pass on a zero-vertex `ArrayMesh`, which is what a
	# mis-signed `sample_baked_with_rotation` or a bad ring stride produces.
	var vertices: int = path.line.mesh.surface_get_array_len(0)
	if vertices >= PayloadPathLine.SIDES * 2:
		_ok("line: the glowing route mesh has %d vertices" % vertices)
	else:
		_fail("the route mesh has %d vertices — the tube did not generate"
			% vertices)
		return

	var material := path.line.mesh.surface_get_material(0) as ShaderMaterial
	if material == null:
		_fail("the route mesh carries no shader material")
		return

	var declared: Array[String] = []
	for uniform in material.shader.get_shader_uniform_list():
		declared.append(str(uniform["name"]))

	for expected in ["line_color", "emission_strength", "progress"]:
		if expected in declared:
			_ok("line: the shader declares '%s'" % expected)
		else:
			_fail("payload_path_line.gdshader does not declare '%s' — it did not parse, "
				% expected + "or the uniform was renamed")


# ─────────────────────────────────────────────
#  HALF 2 — the same thing, out of a real TrenchBroom build
# ─────────────────────────────────────────────

## Builds the fixture map and checks that what a mapper typed is what the game gets.
##
## Everything asserted here is a *literal* — the Godot-space vectors are hardcoded rather
## than computed through `BrushEntityUtil`, because a test that derives its expectation the
## way the code under test does cannot detect that code being wrong.
func _check_entity_build() -> void:
	var settings := load(MAP_SETTINGS_PATH) as FuncGodotMapSettings
	if settings == null:
		_fail("could not load %s" % MAP_SETTINGS_PATH)
		return

	# A `Map` above the `FuncGodotMap`, because that is the shape a real map scene has and
	# what `PayloadPathBuilder.map_root` walks up to.
	var map := Node3D.new()
	map.name = "FixtureMap"
	map.set_script(MAP_SCRIPT)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	map.add_child(camera)

	var gmc := GameModeComponent.new()
	gmc.name = "GameModeComponent"
	gmc.game_mode = GameModeComponent.GameMode.MAIN_MENU
	map.add_child(gmc)
	add_child(map)

	var func_map := FuncGodotMap.new()
	func_map.map_settings = settings
	func_map.local_map_file = FIXTURE_PATH
	map.add_child(func_map)

	var verify_err := func_map.verify()
	if verify_err != OK:
		_fail("could not open %s (error %d)" % [FIXTURE_PATH, verify_err])
		return

	func_map.build()
	# Entity `_ready` runs as the build adds each node, and the route compiles from a
	# `call_deferred`, so the path does not exist until the deferred queue has run.
	await get_tree().process_frame
	await get_tree().process_frame

	var points := _all(func_map, "PayloadPathPoint")
	if points.size() != WAYPOINTS.size():
		_fail("the build produced %d path points, expected %d"
			% [points.size(), WAYPOINTS.size()])
		return
	_ok("build: %d PayloadPathPoint entities" % points.size())

	_check_applied_chain(points)
	_check_built_route(func_map, points)

	var payload := _sole(func_map, "PayloadNode") as PayloadNode
	if payload == null:
		_fail("the build produced no PayloadNode")
		return
	_ok("build: the Payload entity resolved to payload.tscn")
	_check_applied_payload(payload)

	if payload.path_follower == null:
		_fail("the built payload has no path_follower — the route did not resolve")
		return
	_ok("build: the payload found the generated route")

	if payload.checkpoints.size() == 1:
		_ok("build: the payload discovered 1 checkpoint")
	else:
		_fail("the payload discovered %d checkpoints, expected 1" % payload.checkpoints.size())

	_check_button(map, func_map)


## The `Auto Setup Payload Path` button, end to end: resolving the `.map` from the scene, the
## read, the write, and the round trip back out.
##
## [b]Everything here points at a throwaway file in `user://`.[/b] The button rewrites a real
## level's source, so the harness must never be able to reach one — `local_map_file` is
## repointed for the duration, which nothing reads again because the build has already run.
func _check_button(map: Node, func_map: FuncGodotMap) -> void:
	if map.call("_find_func_godot_map") != func_map:
		_fail("the button could not find this scene's FuncGodotMap")
		return
	_ok("button: found the FuncGodotMap")

	var temp_path := "user://payload_path_button_test.map"
	var source := _map_text([
		"// entity 0", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 0 0\"", "}",
		"// entity 1", "{", "\"classname\" \"PayloadPathPoint\"", "\"origin\" \"0 320 0\"", "}",
	])
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		_fail("could not create %s" % temp_path)
		return
	file.store_string(source)
	file.close()

	func_map.local_map_file = temp_path
	map.call("_auto_setup_payload_path")

	var written := FileAccess.get_file_as_string(temp_path)
	if written == source:
		_fail("the button did not write to the map — nothing was linked")
		return
	_ok("button: wrote the linked map back to disk")

	if written.contains("\"targetname\" \"path_1\"") \
			and written.contains("\"target\" \"path_2\""):
		_ok("button: the file on disk carries the links")
	else:
		_fail("the written map is missing the links")

	# Pressing it again must be a no-op, which is what makes it safe to use on a real map
	# without reviewing what it might change.
	map.call("_auto_setup_payload_path")
	if FileAccess.get_file_as_string(temp_path) == written:
		_ok("button: a second press leaves the file untouched")
	else:
		_fail("a second press rewrote an already-linked map")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))


## The class properties reached the nodes.
##
## `entity_assembler.gd:250-262` only assigns a property that is already on the node, and
## only when the types match — so a name that drifted from the script's `@export` keeps its
## default in silence, and the FGD export cannot see it either because the FGD is built
## from the same definition.
## The class properties reached the nodes, and none of them linked anything.
##
## `target` being empty on every point is the precondition for the placement-order test: one
## non-empty `target` anywhere switches the map to an explicit chain, and `_check_built_route`
## would then be proving the wrong mode.  The scrambled `targetname` values are asserted for
## the same reason — if the build had reordered or renamed anything, placement order and name
## order would be hard to tell apart.
func _check_applied_chain(points: Array[Node]) -> void:
	var expected := ["p2", "p0", "p3", "p1"]

	for i in points.size():
		var point := points[i] as PayloadPathPoint
		_check("point %d name" % i, point.targetname, expected[i])
		_check("point %d target" % i, point.target, "")

	var first := points[0] as PayloadPathPoint
	_check("point 0.rollback_zone", first.rollback_zone, true)
	_check("point 0.rollforward_zone", first.rollforward_zone, false)
	var second := points[1] as PayloadPathPoint
	_check("point 1.rollforward_zone", second.rollforward_zone, true)
	_check("point 1.rollback_zone", second.rollback_zone, false)


func _check_applied_payload(payload: PayloadNode) -> void:
	_check("Payload.attacking_team", payload.attacking_team, Player.Team.SCI)
	_check("Payload.push_speed_base", payload.push_speed_base, 0.07)
	_check("Payload.return_delay", payload.return_delay, 3.0)
	# Axes first, then units: TrenchBroom's up is "0 0 128", which is Godot's +Y, and 128 map
	# units is 4 Godot units.  Getting the swap wrong moves the cart sideways; getting the
	# divisor wrong puts it 32x too high.
	_check_vector("Payload.vertical_offset", payload.vertical_offset,
		FIXTURE_VERTICAL_OFFSET_GODOT)


## The route the *build* produced — same assertions as the hand-built half, so a difference
## between the two is a difference between the entity definitions and the code.
func _check_built_route(func_map: Node, points: Array[Node]) -> void:
	var checkpoint := _sole(func_map, "PayloadCheckpointVisual") as PayloadCheckpointVisual
	if checkpoint == null:
		_fail("the build produced no PayloadCheckpointVisual")
		return

	var path := PayloadPathBuilder.ensure_path(points[0])
	if path == null:
		_fail("no route was compiled from the built path points")
		return
	_ok("build: the path points compiled into a route")

	if path.curve != null and path.curve.point_count == WAYPOINTS.size():
		_ok("build: the route has %d curve points" % path.curve.point_count)
	else:
		_fail("the built route has %d curve points, expected %d"
			% [path.curve.point_count if path.curve else -1, WAYPOINTS.size()])

	for i in mini(path.curve.point_count, WAYPOINTS.size()):
		var actual: Vector3 = path.curve.get_point_position(i)
		if actual.distance_to(WAYPOINTS[i]) < TOLERANCE:
			_ok("build: curve point %d is Godot waypoint %d" % [i, i])
		else:
			_fail("built curve point %d is %s, expected %s — the map-unit or axis "
				% [i, actual, WAYPOINTS[i]] + "conversion is wrong")

	_expect_zone(path, 0.1, true, false, "built stretch 1 is rollback only")
	_expect_zone(path, 0.5, false, true, "built stretch 2 is rollforward only")
	_expect_zone(path, 0.8, false, false, "built stretch 3 carries no flags")

	# The checkpoint was authored 3 units off the route in the fixture.
	var off_route: float = absf(path.to_local(checkpoint.global_position).z)
	if off_route < TOLERANCE:
		_ok("build: the checkpoint snapped onto the route")
	else:
		_fail("the built checkpoint is %.3f units off the route" % off_route)


# ─────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────

## Every node under [param root] whose `class_name` is [param classname].
##
## `is_class` alone does not find a `class_name` script class — it answers for native
## classes — so the global name off the attached script is the half that actually matches
## `PayloadPathPoint` and friends.
func _all(root: Node, classname: String) -> Array[Node]:
	var out: Array[Node] = []
	for node in root.find_children("*", "", true, false):
		if node.is_class(classname):
			out.append(node)
			continue
		# `get_script()` answers a Variant, so the type has to be explicit — `:=` here is a
		# warning-as-error in this project, not a style preference.
		var script: Script = node.get_script()
		if script != null and script.get_global_name() == classname:
			out.append(node)
	return out


func _sole(root: Node, classname: String) -> Node:
	var found := _all(root, classname)
	return found[0] if found.size() == 1 else null


## A `.map` built from [param lines], CRLF-terminated like TrenchBroom's own output.
##
## Built from an array rather than written as one multi-line literal so the line endings are
## explicit — a `.map` written with bare LF would make the CRLF assertions vacuous.
func _map_text(lines: Array, eol: String = "\r\n") -> String:
	return eol.join(PackedStringArray(lines)) + eol


## [param text] with every generated `targetname`/`target` line removed.
##
## Comparing this against the original is the byte-exact check: everything the linker was not
## asked to change has to survive untouched, and comparing whole strings would only prove the
## output contains the input's lines somewhere.
func _strip_generated(text: String) -> String:
	var kept := PackedStringArray()
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("\"targetname\" \"path_") \
				or trimmed.begins_with("\"target\" \"path_"):
			continue
		kept.append(line)
	return "\n".join(kept)


func _count(text: String, needle: String) -> int:
	return text.count(needle)


func _check_contains(text: String, needle: String, label: String) -> void:
	if text.contains(needle):
		_ok("linker: %s" % label)
	else:
		_fail("linker: %s — expected to find %s" % [label, needle])


func _check(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_ok("applied: %s = %s" % [label, actual])
	else:
		_fail("%s is %s, expected %s — the entity property did not reach the built node"
			% [label, actual, expected])


func _check_vector(label: String, actual: Vector3, expected: Vector3) -> void:
	if actual.is_equal_approx(expected):
		_ok("applied: %s = %s" % [label, actual])
	else:
		_fail("%s is %s, expected %s" % [label, actual, expected])


func _ok(message: String) -> void:
	print("ok   %s" % message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL: %s" % message)


func _finish() -> void:
	print("---")
	if _failures == 0:
		print("PASS: payload path compiler and entities")
	else:
		printerr("FAIL: %d assertion(s) failed" % _failures)
	get_tree().quit(_failures)
