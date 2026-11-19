@tool
extends Area3D
class_name WaterVolume

## A brush you can swim in. Ported to TrenchBroom as the `water` entity — see
## `trenchbroom/entities/water.tres`. The volume is the brush you draw; each brush in the
## entity becomes one convex collision shape.
##
## [b]An [Area3D] never blocks a body[/b], which is the whole point: water faces are drawn
## but players walk and swim straight through them, unlike the world brushes around them.
## The generated collision shapes are used as geometry, not for physics queries — they give
## the entity's extent for free.
##
## [b]Containment is geometric and is meant to be read from the rollback tick.[/b]
## [method contains_point] tests cached axis-aligned boxes, so it is deterministic on every
## peer as long as the map is the same on every peer (it is: the map replicates). Do not
## replace this with an `Area3D` body-tracking list — signals do not replay during
## re-simulation, so a swimmer's movement would disagree between the server and a predicting
## client. See `docs/02-netcode.md`.
##
## The box is exact for an axis-aligned brush, which is the intended authoring shape. A
## rotated brush's axes-aligned bounds are conservative and leak water outside the brush
## (`docs/05-known-issues.md`).

## One world-space AABB per generated brush shape, built once on first runtime load.
var _bounds: Array[AABB] = []
var _bounds_ready: bool = false


func _ready() -> void:
	# The editor owns the authored scene; nothing here is meaningful there (the collision
	# shapes only exist after a build, and there is no map registry to join).
	if Engine.is_editor_hint():
		return
	# Geometry only. This entity detects nothing itself — `Map.is_point_in_water()` is the
	# only consumer of these shapes.
	collision_layer = 0
	collision_mask = 0
	monitoring = false
	monitorable = false
	_ensure_bounds()
	var map := find_map()
	if map != null:
		map.register_water_volume(self)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var map := find_map()
	if map != null:
		map.unregister_water_volume(self)


## True when [param world_point] lies inside any brush of this volume.
#
# Lazy so the editor's built scene (where `_ready` returned early) still answers if asked,
# and so a map built at runtime by a verification harness works without `_ready` ordering.
func contains_point(world_point: Vector3) -> bool:
	_ensure_bounds()
	for box in _bounds:
		if box.has_point(world_point):
			return true
	return false


## The nearest ancestor `Map`, or null when this entity is not inside a map (the headless
## build harness, preview scenes). No group scan, no `GameManager` dependency.
func find_map() -> Map:
	var node: Node = get_parent()
	while node != null:
		if node is Map:
			return node as Map
		node = node.get_parent()
	return null


## Cache one world-space AABB per generated collision shape. The assembler builds one
## `ConvexPolygonShape3D` per brush; its `points` are the brush's corners, so a box brush
## yields an exact box.
func _ensure_bounds() -> void:
	if _bounds_ready:
		return
	_bounds_ready = true
	_bounds.clear()
	for child in find_children("*", "CollisionShape3D", true, false):
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null:
			continue
		var convex := shape_node.shape as ConvexPolygonShape3D
		if convex == null or convex.points.is_empty():
			continue
		var xf := shape_node.global_transform
		var box := AABB(xf * convex.points[0], Vector3.ZERO)
		for point in convex.points:
			box = box.expand(xf * point)
		_bounds.append(box)
