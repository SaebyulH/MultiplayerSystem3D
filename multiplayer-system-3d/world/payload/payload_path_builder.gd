extends RefCounted
class_name PayloadPathBuilder

## Turns a chain of [PayloadPathPoint]s into the [PayloadPath] a cart rides.
##
## Stateless and static, like [BrushEntityUtil] — not an autoload.  The whole compile
## happens once, at map load, on every peer.
##
## [b]The build is idempotent and that is load-bearing.[/b] Every path point calls
## [method ensure_path] (deferred, from its `_ready`) and so does the payload, and the order
## those land in is just the order the mapper's entities happen to sit in the scene.  Making
## the first caller build and every later caller find the result is what removes that
## ordering dependency entirely.
##
## [b]Two halves: a baked shell and a derived fill.[/b]  [method bake_path] writes the route
## into the map scene at editor time — the `Path3D` and its `Curve3D`, and nothing else — so it
## is visible in the Godot editor and saved with the map.  The parts derived from the curve
## (the zones, the `PathLine` tube, the follower's settings) are *stripped* before the save and
## rebuilt on every peer by [method ensure_path] calling [method PayloadPath.configure], exactly
## as the whole route used to be built.  Keeping the derived half out of the file is the same
## trade [ToonMaterialConverter] makes; it also means the route stays map furniture every peer
## derives, rather than state that replicates.
##
## [b]The runtime build is still the fallback.[/b]  A map that was never baked — the three
## legacy maps, or a scene opened before anyone pressed the button — still gets a transient
## route compiled from its chain on load, unchanged from before.

const PATH_SCENE: PackedScene = preload("res://world/payload/payload_path.tscn")

## Curve bake resolution for a generated route, in Godot units.
##
## Well below [method Curve3D.get_closest_offset]'s default of 5.0 on purpose: checkpoint
## placement is a projection onto the baked polyline, so this is what decides how far off a
## checkpoint can land.  One unit is far finer than anyone places a waypoint.
const BAKE_INTERVAL: float = 1.0


## The [PayloadPath] for the map [param anchor] belongs to, building it if it does not
## exist yet.  Returns `null` when the map has no usable chain.
static func ensure_path(anchor: Node) -> PayloadPath:
	var root := map_root(anchor)
	if root == null:
		return null

	var existing := find_path(root)
	if existing != null:
		# A baked route is a shell: its curve came from the scene, but everything derived from
		# that curve was stripped before the save.  Rebuild it here — `path_points` is the flag,
		# since it is the first thing `configure` writes and it is never serialized.
		if existing.path_points.is_empty():
			var chain := build_chain(find_path_points(root))
			if chain.size() >= 2:
				existing.configure(chain)
		return existing

	return _build(root)


## The already-built route under [param root], or `null`.
##
## Cheap on purpose — this is the early return every path point takes after the first one
## has done the work.  Group membership is maintained by Godot itself, so a route whose map
## has been freed cannot be found here.
static func find_path(root: Node) -> PayloadPath:
	if root.get_tree() == null:
		return null
	for candidate in root.get_tree().get_nodes_in_group(PayloadPath.GROUP):
		var path := candidate as PayloadPath
		# A payload in `main_menu_world.tscn` and one in a match map could both be alive
		# across a map swap; only this map's route is ours.
		if path != null and map_root(path) == root:
			return path
	return null


## The `Map` node [param node] sits inside, or `null` when it is not in one.
##
## Walks ancestors rather than reading `GameManager.spawn_parent`, because this runs during
## map load — `Map._enter_tree()` sets the global, but a map built by the thumbnail
## generator has no peer and no spawn parent at all.
##
## [b]Returns [Node], not [Node3D], and that is not an oversight.[/b] `maps/map.gd` declares
## `extends Node`, so that is all the `Map` type guarantees — every map scene in practice
## attaches it to a `Node3D` (Godot permits a script whose base is an ancestor of the node's
## class), but the type system does not know that. Callers that need a transform have to
## cast; see [method _spatial_root].
static func map_root(node: Node) -> Node:
	var current := node
	while current != null:
		if current is Map:
			return current
		current = current.get_parent()
	return null


## Every path point in the map, in tree order.
##
## Recursive (`owned = false`) for the same reason `Map._enter_tree()` is: func_godot
## parents every entity it builds under its `FuncGodotMap` node, so a path point placed in
## TrenchBroom is one level below the map root, not a direct child of it.
static func find_path_points(root: Node) -> Array[PayloadPathPoint]:
	var out: Array[PayloadPathPoint] = []
	for node in root.find_children("*", "", true, false):
		var point := node as PayloadPathPoint
		if point != null:
			out.append(point)
	return out


## Orders [param points] into the route a cart rides.
##
## [b]By default the route is the points in the order they were placed[/b] — no names, no
## links, nothing to fill in. That order is simply how they sit under the `FuncGodotMap`,
## because func_godot builds entities in the order the `.map` lists them and TrenchBroom
## lists them in the order they were created; `find_path_points` returns them that way
## already. Draw the waypoints front to back and they connect themselves, which is how
## every spline tool works and what a mapper expects.
##
## [b]Setting `target` on any point switches the map to an explicit chain[/b] — the escape
## hatch, and the older behaviour. It is what a route needs when its points were not placed
## in order, when a leg has to run somewhere other than the next point, or when a loop is
## wanted. In that mode `targetname` and `target` do the work and placement order is ignored.
##
## The two modes never mix. One `target` anywhere means the whole map is read the old way,
## because a half-explicit, half-implied chain has no answer a mapper could predict.
##
## Neither mode fails: every way this can go wrong is a warning plus the best route that
## could be built from what the mapper drew, because a broken route should still leave a map
## playable rather than taking the whole thing down at load.
static func build_chain(points: Array[PayloadPathPoint]) -> Array[PayloadPathPoint]:
	if points.is_empty():
		return points

	for point in points:
		if not point.target.is_empty():
			return _build_explicit_chain(points)

	# Placement order. `find_path_points` is a tree walk and func_godot builds entities in
	# `.map` order, so this array is already the route — see the note on the two modes above.
	return points


## Orders [param points] by following `target` from the head, which is the one point no
## other point names.
static func _build_explicit_chain(points: Array[PayloadPathPoint]) -> Array[PayloadPathPoint]:
	var chain: Array[PayloadPathPoint] = []

	var by_name: Dictionary = {}
	for point in points:
		if point.targetname.is_empty():
			continue
		if by_name.has(point.targetname):
			push_warning(
				"PayloadPathPoint: two points are both named '%s' — the second is unreachable."
				% point.targetname)
			continue
		by_name[point.targetname] = point

	# A point with no name can never be named, so it is always a head.
	var named: Dictionary = {}
	for point in points:
		if not point.target.is_empty():
			named[point.target] = true

	var heads: Array[PayloadPathPoint] = []
	for point in points:
		if point.targetname.is_empty() or not named.has(point.targetname):
			heads.append(point)

	if heads.is_empty():
		# Every point is named by another — a closed loop with no way in.  Starting anywhere
		# at least yields a curve, and the walk below truncates it at the cycle.
		push_warning(
			"PayloadPathPoint: the chain is a closed loop — no head to start from. "
			+ "Starting at the first point found.")
		heads.append(points[0])
	elif heads.size() > 1:
		# Either a fork or two unrelated routes in one map.  Only one can be built.
		push_warning(
			"PayloadPathPoint: %d points start a chain but a map has room for one route. "
			% heads.size()
			+ "Building from '%s'; the rest are unreachable."
			% (heads[0].name))

	var seen: Dictionary = {}
	var current: PayloadPathPoint = heads[0]
	while current != null:
		if seen.has(current):
			push_warning(
				"PayloadPathPoint: the chain loops back to '%s' — truncating there."
				% current.name)
			break
		seen[current] = true
		chain.append(current)

		if current.target.is_empty():
			break
		if not by_name.has(current.target):
			push_warning(
				"PayloadPathPoint: '%s' targets '%s', which no path point is named. "
				% [current.name, current.target]
				+ "The route ends there.")
			break
		current = by_name[current.target] as PayloadPathPoint

	if chain.size() < points.size():
		push_warning(
			"PayloadPathPoint: %d of %d path points are not on the chain and will be ignored. "
			% [points.size() - chain.size(), points.size()]
			+ "This map sets 'target' somewhere, so the route is being read as an explicit "
			+ "chain. Delete every 'target' to go back to chaining in placement order "
			+ "instead, which needs no names at all.")

	return chain


static func _build(root: Node) -> PayloadPath:
	var chain := build_chain(find_path_points(root))

	# One waypoint is a position, not a route: a Curve3D needs two points before it has a
	# direction, and a cart with no direction has nothing to ride.
	if chain.size() < 2:
		push_warning(
			"PayloadPathPoint: a route needs at least 2 chained points, found %d. "
			% chain.size()
			+ "No payload path was built for this map.")
		return null

	# Every map scene attaches `map.gd` to a `Node3D`, but `Map` only declares `Node` — so
	# the cast is required to reach a transform at all. A map root that somehow is not
	# spatial has nowhere to put a curve, and is not a map this can help.
	var spatial := root as Node3D
	if spatial == null:
		push_warning(
			"PayloadPathPoint: the Map root is a %s, which has no transform — "
			% root.get_class()
			+ "a payload route needs a Node3D root. No path was built.")
		return null

	var path := PATH_SCENE.instantiate() as PayloadPath
	root.add_child(path)
	path.curve = build_curve(spatial, chain)
	path.configure(chain)
	return path


## The [Curve3D] the chain describes, in [param spatial]'s own space.
##
## Shared by the runtime build and the editor bake, so a baked route's curve and a transient
## one's are the same object down to the bake resolution.
##
## The curve is in the map root's space and the path sits at its origin, so the two conversions
## agree — `PayloadPath.to_local()` answers the same thing later on.
static func build_curve(spatial: Node3D, chain: Array[PayloadPathPoint]) -> Curve3D:
	var curve := Curve3D.new()
	curve.bake_interval = BAKE_INTERVAL
	for point in chain:
		curve.add_point(spatial.to_local(point.global_position))
	return curve


## Editor only.  Writes — or refreshes — the route this map's chain describes into the scene,
## so it is saved and visible rather than compiled afresh on every load.
##
## The node is a **shell**: the curve is the only thing it owns.  [method
## PayloadPath.strip_derived] drops the zones and the line tube before the save, and
## [method ensure_path] rebuilds them on every peer at load.
##
## [param owner] is the scene root the node must be owned by to serialize; pass `null` in a
## headless harness, where nothing is saved.
##
## Returns the baked path, or `null` when there is nothing to bake.
static func bake_path(root: Node, owner: Node) -> PayloadPath:
	var spatial := root as Node3D
	if spatial == null:
		push_warning("PayloadPath: the Map root is a %s, which has no transform — "
			% root.get_class() + "a payload route needs a Node3D root. Nothing was baked.")
		return null

	var existing := find_path(root)
	var chain := build_chain(find_path_points(root))

	# Nothing to bake, and no route to conflict with: either an ordinary map with no payload, or
	# a legacy map that hand-authors its route.  Both are the normal case, and this runs on
	# every save — so it is silent.
	if existing == null and chain.size() < 2:
		return null

	# [b]Refuse to add a second route beside a hand-authored one.[/b]  The legacy maps carry a
	# plain `Path3D` their cart is wired to by NodePath.  Baking a `PayloadPath` beside it would
	# give the map two routes: the cart would keep riding the old one while every "the route"
	# lookup returned the new one, silently.  Better to say so and do nothing.  Only reachable
	# when path points were *added* to such a map, since the empty case returned above.
	if existing == null:
		var legacy := _legacy_route(root)
		if legacy != null:
			push_warning(
				"PayloadPath: this map hand-authors its route at '%s', so the bake will not add "
				% String(legacy.get_path())
				+ "a second one. Delete that Path3D if the path points should own the route.")
			return null

	if chain.size() < 2:
		push_warning(
			"PayloadPathPoint: a route needs at least 2 chained points, found %d. "
			% chain.size() + "Nothing was baked for this map.")
		return null

	var path := existing
	if path == null:
		path = PATH_SCENE.instantiate() as PayloadPath
		# The group rides with the scene (`payload_path.tscn` sets it), so it survives the save
		# and `find_path` can find this route on the next load.
		root.add_child(path)
		if owner != null:
			_own(path, owner)

	# Generated, not placeable: the curve is stored in map-root space and `_rebuild_zones`
	# projects through `to_local`, so a moved path would misplace every offset.
	#
	# [b]Both writes are guarded on having actually changed.[/b]  This runs on *every* save
	# (the Map's `NOTIFICATION_EDITOR_PRE_SAVE` hook), and `curve` and `transform` are stored
	# properties — assigning them marks the scene dirty even when the value is identical, which
	# would turn "the save after a route change costs one extra save" into "every save is
	# dirty, for ever".
	if path.transform != Transform3D.IDENTITY:
		path.transform = Transform3D.IDENTITY
	if not _curve_matches(path.curve, spatial, chain):
		path.curve = build_curve(spatial, chain)

	path.strip_derived()
	return path


## Whether [param curve] already describes [param chain] in [param spatial]'s space, so the bake
## can leave a scene that has not changed completely alone.
static func _curve_matches(curve: Curve3D, spatial: Node3D, chain: Array[PayloadPathPoint]) -> bool:
	if curve == null or curve.point_count != chain.size():
		return false
	if not is_equal_approx(curve.bake_interval, BAKE_INTERVAL):
		return false
	for i in chain.size():
		var placed: Vector3 = spatial.to_local(chain[i].global_position)
		if not curve.get_point_position(i).is_equal_approx(placed):
			return false
	return true


## A hand-authored route — a plain `Path3D` carrying a [PathFollow3D] — under [param root], or
## `null`.  This is the shape the three maps that predate the path points use.
static func _legacy_route(root: Node) -> Path3D:
	for node in root.find_children("*", "Path3D", true, false):
		var path := node as Path3D
		if path == null or path is PayloadPath:
			continue
		if not path.find_children("*", "PathFollow3D", true, false).is_empty():
			return path
	return null


## Gives [param node]'s whole subtree an owner, so it serializes into the saved scene.
## `add_child` does not propagate ownership, so each node needs it set explicitly.
static func _own(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.find_children("*", "", true, false):
		child.owner = owner
