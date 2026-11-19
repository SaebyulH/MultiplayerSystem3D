extends Node
## Builds `trenchbroom/maps/water_volume_test.map` and checks the `water` brush entity
## comes out usable: non-colliding, visible, concretely bounded, and carrying the animated
## water material.
##
## What is under test is the whole authoring chain: the entity definition, the material
## lookup by texture stem (`Material-LIB/Nature/Water/Water[swim]` →
## `trenchbroom/textures/.../Water[swim].tres`), the generated convex shapes the
## [WaterVolume] cache reads, and its registration with the [Map].
##
## The map still has to be rebuilt and saved by hand for a shipped map to gain water; that
## serialization half is not testable outside the editor, same as the brush-entity harness.
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/verify_water_volume.tscn
##
## Expect the same `Attempting to initialize the wrong RID` noise as
## `verify_brush_entities` — the dummy renderer has no mesh storage.  The exit code is the
## thing to read: 0 means every assertion passed.

const MAP_SETTINGS_PATH := "res://trenchbroom/multiplayer_system_3d_map_settings.tres"
const FIXTURE_PATH := "res://trenchbroom/maps/water_volume_test.map"
const WATER_SHADER_SUFFIX := "water_surface.gdshader"

var _failures := 0


func _ready() -> void:
	var settings := load(MAP_SETTINGS_PATH) as FuncGodotMapSettings
	if settings == null:
		printerr("FAIL: could not load %s" % MAP_SETTINGS_PATH)
		get_tree().quit(1)
		return

	# A real Map root, not a bare Node: the volume registers with its ancestor map, and
	# that registration is one of the things under test.  The camera and the mode
	# component exist because Map's `_enter_tree`/`_ready` reach for them.
	var map := Map.new()
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	map.add_child(camera)
	# A real mode component: `Map._enter_tree()` assigns `$GameModeComponent` to the
	# statically typed `GameManager.game_mode_component`, so a bare Node errors out of
	# `_enter_tree` before the water registry is cleared or the build can register.
	var gmc := GameModeComponent.new()
	gmc.name = "GameModeComponent"
	map.add_child(gmc)
	add_child(map)

	var fgd := FuncGodotMap.new()
	fgd.map_settings = settings
	fgd.local_map_file = FIXTURE_PATH
	map.add_child(fgd)

	var verify_err := fgd.verify()
	if verify_err != OK:
		printerr("FAIL: could not open %s (error %d)" % [FIXTURE_PATH, verify_err])
		get_tree().quit(1)
		return

	fgd.build()
	# Entity assembly is deferred; one idle frame plus one to spare, as in the
	# brush-entity harness.
	await get_tree().process_frame
	await get_tree().process_frame

	# Typed as Area3D, not WaterVolume: a newly added `class_name` is not in the
	# global class cache until the editor rescans, and a cold headless run would
	# fail to parse before it could test anything.  The method calls below go
	# through `has_method`/`call` for the same reason.
	var volume: Area3D = _sole(map, "WaterVolume") as Area3D
	if volume == null:
		_report()
		return

	# 1. The entity became a non-colliding Area3D.  If any of these is wrong, the pool is
	#    a wall the player cannot swim through.
	_check_equal("collision_layer", volume.collision_layer, 0)
	_check_equal("collision_mask", volume.collision_mask, 0)
	if not volume.monitoring:
		print("ok   area: monitoring is off")
	else:
		_fail("monitoring is on — the volume detects bodies nobody reads")

	# 2. Convex shapes exist.  They are the geometry `contains_point()` caches; no shape
	#    means every query is false and the water is dry.
	var shape_nodes: Array[Node] = volume.find_children("*", "CollisionShape3D", true, false)
	if shape_nodes.is_empty():
		_fail("no CollisionShape3D — the volume has no extent")
		_report()
		return
	var first_convex: ConvexPolygonShape3D = null
	for node in shape_nodes:
		var shape := (node as CollisionShape3D).shape as ConvexPolygonShape3D
		if shape == null or shape.points.is_empty():
			_fail("%s is not a non-empty ConvexPolygonShape3D" % node.name)
			continue
		if first_convex == null:
			first_convex = shape
	if first_convex == null:
		_report()
		return
	print("ok   collision: %d convex shape(s)" % shape_nodes.size())

	# 3. Visible, and wearing the animated water material.  `build_visuals = true` is what
	#    makes the brush render at all, and the surface material is resolved by the texture
	#    stem — the exact mechanism a mapper relies on.
	var mesh_instance := _first_mesh(volume)
	if mesh_instance == null or mesh_instance.mesh == null \
			or mesh_instance.mesh.get_surface_count() == 0:
		_fail("no rendered mesh — build_visuals = true was ignored")
	else:
		print("ok   visual: mesh with %d surface(s)" % mesh_instance.mesh.get_surface_count())
		var material := mesh_instance.mesh.surface_get_material(0)
		if material is ShaderMaterial:
			print("ok   material: ShaderMaterial")
			var shader_material := material as ShaderMaterial
			if shader_material.shader == null:
				_fail("the water ShaderMaterial has no shader")
			elif shader_material.shader.resource_path.ends_with(WATER_SHADER_SUFFIX):
				print("ok   shader: %s" % shader_material.shader.resource_path)
			else:
				_fail("shader is %s, expected %s"
					% [shader_material.shader.resource_path, WATER_SHADER_SUFFIX])
			var alpha: float = float(shader_material.get_shader_parameter("alpha"))
			if alpha < 1.0:
				print("ok   transparent: alpha = %s" % alpha)
			else:
				_fail("alpha is %s — the water surface would be opaque" % alpha)
		else:
			_fail("surface material is %s, expected the ShaderMaterial from Water[swim].tres"
				% (material.get_class() if material else "<none>"))

	# 4. Containment and the map query agree, inside and far outside.  The point is derived
	#    from the built shape, not from a number copied out of the .map, so a unit-conversion
	#    mistake cannot make both sides wrong together.
	var shape_node := shape_nodes[0] as CollisionShape3D
	var xf := shape_node.global_transform
	var box := AABB(xf * first_convex.points[0], Vector3.ZERO)
	for point in first_convex.points:
		box = box.expand(xf * point)
	var centre := box.get_center()
	var outside := centre + Vector3(1000.0, 0.0, 0.0)

	if not volume.has_method("contains_point"):
		_fail("the built entity has no contains_point() — the wrong script was attached")
	elif bool(volume.call("contains_point", centre)):
		print("ok   volume: centre %s is inside" % centre)
	else:
		_fail("centre %s is reported outside its own bounds %s" % [centre, box])
	if volume.has_method("contains_point") and not bool(volume.call("contains_point", outside)):
		print("ok   volume: %s is outside" % outside)
	elif volume.has_method("contains_point"):
		_fail("%s is reported inside the volume" % outside)

	# 5. Registration and the map-level query.
	if map.water_volumes.has(volume):
		print("ok   registry: the volume registered with Map")
	else:
		_fail("the volume did not register with Map — every swim query would be false")
	if map.is_point_in_water(centre):
		print("ok   map: is_point_in_water(centre) is true")
	else:
		_fail("Map.is_point_in_water(centre) is false")
	if not map.is_point_in_water(outside):
		print("ok   map: is_point_in_water(outside) is false")
	else:
		_fail("Map.is_point_in_water(outside) is true")

	_report()


## The first MeshInstance3D under the built entity, if any.
func _first_mesh(root: Node) -> MeshInstance3D:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		return node as MeshInstance3D
	return null


## The single node of the given script class under the built map.
func _sole(root: Node, script_class: String) -> Node:
	var found: Array[Node] = []
	for node in root.find_children("*", "", true, false):
		if node.get_script() != null and node.get_script().get_global_name() == script_class:
			found.append(node)
	if found.size() != 1:
		_fail("expected exactly one %s, found %d" % [script_class, found.size()])
		return null
	return found[0]


func _check_equal(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("ok   %s: %s" % [label, actual])
	else:
		_fail("%s is %s, expected %s" % [label, actual, expected])


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL: %s" % message)


func _report() -> void:
	print("---")
	if _failures == 0:
		print("PASS: water volume built, registered and materialised")
	else:
		printerr("FAIL: %d assertion(s) failed" % _failures)
	get_tree().quit(_failures)
