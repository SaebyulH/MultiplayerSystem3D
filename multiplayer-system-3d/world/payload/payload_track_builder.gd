extends RefCounted
class_name PayloadTrackBuilder

## Sweeps a railroad track along a payload route and bakes it into the map scene.
##
## The track used to be placed by hand in TrenchBroom as a chain of `PayloadTrackStraight`
## entities — one rigid 2 m straight segment each, rotated to follow the route.  Rotating rigid
## copies through a bend leaves a wedge gap on the outside and bunches the ties on the inside,
## which is exactly what this replaces: the geometry is swept along the route's own curve, so
## the rails follow it exactly and the tie spacing stays right through a turn.
##
## [b]Every dimension comes from the prop[/b] (`payload_track_straight.tscn`) — the rail
## cross-section, the gauge, the tie box and the tie spacing are read off its meshes at bake
## time, so the prop stays the source of truth.  Literal fallbacks exist only for the case where
## the prop cannot be read at all.
##
## [b]Why the gauge survives a bend.[/b]  A rail's cross-section is laid out in the curve
## frame's *own* lateral/up plane, and consecutive rings are connected corner to corner.  On a
## bend of radius R a corner at lateral +g therefore travels ds·(R+g)/R per step while the one at
## -g travels ds·(R-g)/R — the inner rail's quads come out genuinely shorter, and the gauge is
## constant because every ring is rebuilt from the same local lateral.  Offsetting the centreline
## in *world* space instead is the bug this avoids: it pinches the track as it turns.
##
## Stateless and static, like [PayloadPathBuilder] and [BrushEntityUtil] — not an autoload.
##
## [b]Editor-only.[/b]  Nothing here runs in a game; [Map] calls [method bake] from its tool
## button and from `NOTIFICATION_EDITOR_PRE_SAVE`.  The generated node is saved into the map
## scene, and it is deliberately parented to the `Map` root rather than under the `FuncGodotMap`
## — a rebuild of the TrenchBroom world clears that subtree and would take the track with it.

## The prop the geometry is derived from.  Read, never edited.
const PROP_PATH: String = "res://assets/props/payload_track/payload_track_straight.tscn"

## The generated node, a direct child of the Map root.
const CONTAINER_NAME: String = "PayloadTrack"
const MESH_NAME: String = "TrackMesh"

## Arc length between rail rings, in Godot units.
##
## Deliberately *not* the curve's own `bake_interval`: that is 1.0 on a generated route but 5.0
## on the hand-authored legacy curves, and sampling at 5.0 visibly facets the rails through a
## bend.  Half a metre is a chord sagitta of ~3 mm on a 10 m radius turn — invisible.
const RAIL_STEP: float = 0.5

## Upper bound on rail rings, so a pathologically long route cannot explode the vertex count.
const MAX_RAIL_STEPS: int = 2048

## Upper bound on ties, for the same reason.
const TIE_LIMIT: int = 4096

## Where the serialized-bake fingerprint lives on the container.  Node metadata is serialized,
## which is what lets the check survive a reload.
const SIGNATURE_META: String = "bake_signature"

## Literal dimensions, used only when the prop cannot be read.  They mirror
## `payload_track_straight.tscn` exactly; see [method read_prop] for how each is derived.
const FALLBACK_REST_OFFSET: float = 0.029541
const FALLBACK_RAILS: Array = [
	{"lateral": -0.6738281, "height": 0.082, "half": Vector2(0.053589, 0.038527)},
	{"lateral": 0.674, "height": 0.082, "half": Vector2(0.053589, 0.038527)},
]
const FALLBACK_TIE_SIZE: Vector3 = Vector3(1.648438, 0.059082, 0.090698)
const FALLBACK_TIE_SPACING: float = 0.25
const FALLBACK_RAIL_TEXTURE: String = \
	"res://backup/trenchbroom/textures/Material-LIB/MetalCracked/MetalCracked[Silver].png"
const FALLBACK_TIE_TEXTURE: String = \
	"res://trenchbroom/textures/FreeStylized/wood_planks_22_1k/wood_planks_22_basecolor_1k.png"


# ─────────────────────────────────────────────
#  PROP INTROSPECTION
# ─────────────────────────────────────────────

## Everything the sweep needs, read out of `payload_track_straight.tscn`.
##
## Returns:
## [codeblock]
## {
##   "ok": bool,                                  # false when the fallbacks are in use
##   "rest_offset": float,                        # lift that puts the tie underside on the curve
##   "rails": Array[Dictionary],                  # {lateral, height, half: Vector2}
##   "tie_mesh": Mesh,                            # the tie BoxMesh, stamped per tie
##   "tie_local": Transform3D,                    # the tie's shape offset inside the prop
##   "tie_size": Vector3,
##   "tie_spacing": float,
##   "rail_material": Material,
##   "tie_material": Material,
## }
## [/codeblock]
##
## Pure: no scene, no tree, so the verify harness drives it directly.
static func read_prop() -> Dictionary:
	var packed := load(PROP_PATH) as PackedScene
	if packed == null:
		push_warning("PayloadTrackBuilder: could not load %s — using fallback dimensions." % PROP_PATH)
		return _fallback_prop()

	var root := packed.instantiate() as Node3D
	if root == null:
		push_warning("PayloadTrackBuilder: %s is not a Node3D — using fallback dimensions." % PROP_PATH)
		return _fallback_prop()

	# Classify by the mesh resource the children share, not by node name: they are generically
	# named `MeshInstance3D`..`MeshInstance3D10`, and there is no `MeshInstance3D1` at all.
	var groups: Dictionary = {}   # Mesh -> Array[MeshInstance3D]
	for child in root.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if not groups.has(mi.mesh):
			groups[mi.mesh] = []
		groups[mi.mesh].append(mi)

	var rail_mesh: Mesh = null
	var tie_mesh: Mesh = null
	for mesh in groups:
		var members: Array = groups[mesh]
		if rail_mesh == null or mesh.get_aabb().size.z > rail_mesh.get_aabb().size.z:
			rail_mesh = mesh
		if tie_mesh == null or members.size() > (groups[tie_mesh] as Array).size():
			tie_mesh = mesh

	if rail_mesh == null or tie_mesh == null or rail_mesh == tie_mesh:
		push_warning("PayloadTrackBuilder: could not tell the rails from the ties in %s "
			% PROP_PATH + "— using fallback dimensions.")
		root.free()
		return _fallback_prop()

	# Rails: each carries its own lateral/height.  They are *not* perfectly symmetric in the
	# prop, so `±gauge/2` is an assumption worth not making.
	var rails: Array = []
	for node in groups[rail_mesh]:
		var mi := node as MeshInstance3D
		var scale := mi.transform.basis.get_scale().abs()
		var size := rail_mesh.get_aabb().size
		rails.append({
			"lateral": mi.transform.origin.x,
			"height": mi.transform.origin.y,
			"half": Vector2(size.x * scale.x, size.y * scale.y) * 0.5,
		})

	# Ties: the smallest positive step between them along the prop's local Z.
	var tie_nodes: Array = groups[tie_mesh]
	var tie_zs: Array[float] = []
	for node in tie_nodes:
		tie_zs.append((node as MeshInstance3D).transform.origin.z)
	tie_zs.sort()
	var spacing := 0.0
	for i in range(1, tie_zs.size()):
		var delta: float = tie_zs[i] - tie_zs[i - 1]
		if delta > 0.0001 and (spacing == 0.0 or delta < spacing):
			spacing = delta

	var tie_transform := (tie_nodes[0] as MeshInstance3D).transform
	var tie_scale := tie_transform.basis.get_scale().abs()

	# The lift that rests the prop on the curve: the negated lowest point of its whole geometry,
	# which is the tie underside.
	var lowest := INF
	for mesh in groups:
		for node in groups[mesh]:
			var box: AABB = (node as MeshInstance3D).transform * mesh.get_aabb()
			lowest = minf(lowest, box.position.y)

	var prop := {
		"ok": true,
		"rest_offset": -lowest,
		"rails": rails,
		# The tie's shape inside the prop, with its along-track placement removed — the sweep
		# supplies its own position, and the prop's asymmetric 8-tie phase is not reproduced.
		"tie_mesh": tie_mesh,
		"tie_local": Transform3D(tie_transform.basis, Vector3(
			tie_transform.origin.x, tie_transform.origin.y, 0.0)),
		"tie_size": tie_mesh.get_aabb().size * tie_scale,
		"tie_spacing": spacing,
		"rail_material": _node_material(groups[rail_mesh][0] as MeshInstance3D, rail_mesh),
		"tie_material": _node_material(tie_nodes[0] as MeshInstance3D, tie_mesh),
	}
	root.free()

	if prop["tie_spacing"] <= 0.0001:
		push_warning("PayloadTrackBuilder: the prop's ties are not evenly spaced — "
			+ "using the fallback spacing.")
		prop["tie_spacing"] = FALLBACK_TIE_SPACING

	return prop


## The visible material a prop mesh wears, in the order the prop itself would resolve it.
static func _node_material(mi: MeshInstance3D, mesh: Mesh) -> Material:
	if mi.get_surface_override_material(0) != null:
		return mi.get_surface_override_material(0)
	if mi.material_override != null:
		return mi.material_override
	if mesh.get_surface_count() > 0:
		return mesh.surface_get_material(0)
	return null


## The hardcoded profile, shaped exactly like [method read_prop]'s success case.
static func _fallback_prop() -> Dictionary:
	var tie := BoxMesh.new()
	tie.size = FALLBACK_TIE_SIZE
	return {
		"ok": false,
		"rest_offset": FALLBACK_REST_OFFSET,
		"rails": FALLBACK_RAILS.duplicate(true),
		"tie_mesh": tie,
		"tie_local": Transform3D.IDENTITY,
		"tie_size": FALLBACK_TIE_SIZE,
		"tie_spacing": FALLBACK_TIE_SPACING,
		"rail_material": _texture_material(FALLBACK_RAIL_TEXTURE),
		"tie_material": _texture_material(FALLBACK_TIE_TEXTURE),
	}


static func _texture_material(path: String) -> Material:
	var texture := load(path) as Texture2D
	if texture == null:
		return null
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	return material


# ─────────────────────────────────────────────
#  ROUTE DISCOVERY
# ─────────────────────────────────────────────

## The [Path3D] this map's cart rides, or `null` when the map has no payload route.
##
## Prefers the baked [PayloadPath]; falls back to a hand-authored `Path3D` — which is the shape
## the three legacy maps use — but only one that actually carries a [PathFollow3D], so ordinary
## decoration paths are not mistaken for the route.
static func find_route(root: Node) -> Path3D:
	var baked := PayloadPathBuilder.find_path(root)
	if baked != null:
		return baked

	for node in root.find_children("*", "Path3D", true, false):
		var path := node as Path3D
		if path == null or path.curve == null or path.curve.point_count < 2:
			continue
		if not path.find_children("*", "PathFollow3D", true, false).is_empty():
			return path
	return null


## Whether [param path] is the hand-authored route shape the legacy maps use, rather than a
## [PayloadPath] this builder can safely replace.
static func is_legacy_route(path: Path3D) -> bool:
	return path != null and not (path is PayloadPath)


# ─────────────────────────────────────────────
#  THE SWEEP
# ─────────────────────────────────────────────

## The track as one [ArrayMesh]: surface 0 the two metal rails, surface 1 the wooden ties.
##
## Returns `null` when the route has no usable curve.
static func build_mesh(route: Path3D, prop: Dictionary) -> ArrayMesh:
	if route == null or route.curve == null:
		return null
	var curve := route.curve
	var length := curve.get_baked_length()
	if length <= 0.0001:
		return null

	var rest: float = prop["rest_offset"]
	var steps := clampi(int(ceil(length / RAIL_STEP)), 1, MAX_RAIL_STEPS)
	var ds := length / float(steps)

	var rings: Array[Transform3D] = []
	for i in steps + 1:
		rings.append(_frame(curve, float(i) * ds, rest))

	var rail_tool := SurfaceTool.new()
	rail_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for rail in prop["rails"]:
		_sweep_rail(rail_tool, rings, rail, ds)

	var tie_tool := SurfaceTool.new()
	tie_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tie_mesh: Mesh = prop["tie_mesh"]
	var tie_local: Transform3D = prop["tie_local"]
	var spacing: float = prop["tie_spacing"]
	if tie_mesh != null and spacing > 0.0001:
		var offset := 0.0
		var placed := 0
		while offset <= length and placed < TIE_LIMIT:
			tie_tool.append_from(tie_mesh, 0, _frame(curve, offset, rest) * tie_local)
			placed += 1
			offset += spacing

	var merged := ArrayMesh.new()
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rail_tool.commit_to_arrays())
	merged.surface_set_material(0, prop["rail_material"])
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, tie_tool.commit_to_arrays())
	merged.surface_set_material(1, prop["tie_material"])
	return merged


## The prop's frame at arc-length [param offset]: origin raised by the resting offset so the tie
## underside sits on the curve.
##
## `cubic = true` matches [PathFollow3D]'s default, so the centreline the track is swept along is
## the same polyline the cart rides rather than a chorded approximation of it.
##
## The frame's forward sign is left as the curve gives it.  Every piece here is a symmetric box,
## so flipping it is cosmetic (it only mirrors the metal/wood grain); if a straight run ever
## reads backwards, a `* Basis(Vector3.UP, PI)` belongs here.
static func _frame(curve: Curve3D, offset: float, rest_offset: float) -> Transform3D:
	var raw := curve.sample_baked_with_rotation(offset, true, false)
	var basis := raw.basis.orthonormalized()
	return Transform3D(basis, raw.origin + basis.y * rest_offset)


## One rail as a continuous strip of quads between consecutive rings.
##
## The cross-section is defined in the ring's own lateral/up plane, which is what keeps the gauge
## constant through a bend and makes the inner rail's quads shorter than the outer one's.
static func _sweep_rail(tool: SurfaceTool, rings: Array[Transform3D], rail: Dictionary, ds: float) -> void:
	var lateral: float = rail["lateral"]
	var height: float = rail["height"]
	var half: Vector2 = rail["half"]

	# Corners counter-clockwise in the local lateral (x) / up (y) plane.
	var corners := PackedVector2Array([
		Vector2(lateral - half.x, height - half.y),
		Vector2(lateral + half.x, height - half.y),
		Vector2(lateral + half.x, height + half.y),
		Vector2(lateral - half.x, height + half.y),
	])

	# One ring of four points per step, plus the rail's own centre line, which the outward
	# normal is measured against.
	var count := rings.size()
	var ring_pts: Array[PackedVector3Array] = []
	var centres := PackedVector3Array()
	for i in count:
		var pts := PackedVector3Array()
		for corner in corners:
			pts.append(rings[i] * Vector3(corner.x, corner.y, 0.0))
		ring_pts.append(pts)
		centres.append(rings[i] * Vector3(lateral, height, 0.0))

	for i in range(count - 1):
		var v0: float = (float(i) * ds) / 2.0
		var v1: float = (float(i + 1) * ds) / 2.0
		var centre := (centres[i] + centres[i + 1]) * 0.5
		for j in 4:
			var jn := (j + 1) % 4
			var u0 := float(j) / 4.0
			var u1 := float(j + 1) / 4.0
			_add_quad(tool,
				ring_pts[i][j], ring_pts[i][jn], ring_pts[i + 1][jn], ring_pts[i + 1][j],
				Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1),
				centre)

	# Cap both ends so the rail is not an open tube.
	_add_cap(tool, ring_pts[0], -(rings[0].basis.z.normalized()))
	_add_cap(tool, ring_pts[count - 1], rings[count - 1].basis.z.normalized())


## Emits one quad as two triangles, wound so the normal points away from [param centre].
##
## Points and uvs are in perimeter order: p0 → p1 → p2 → p3.
static func _add_quad(tool: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		uv0: Vector2, uv1: Vector2, uv2: Vector2, uv3: Vector2, centre: Vector3) -> void:
	var normal := (p1 - p0).cross(p2 - p0)
	if normal.length_squared() < 1e-14:
		return
	normal = normal.normalized()
	# Outward is whichever side of the quad faces away from the rail's own axis.  Computing it
	# rather than assuming winding keeps this correct wherever the curve's forward sign lands.
	if normal.dot((p0 + p1 + p2 + p3) * 0.25 - centre) < 0.0:
		_emit_tri(tool, p0, p3, p2, uv0, uv3, uv2, -normal)
		_emit_tri(tool, p0, p2, p1, uv0, uv2, uv1, -normal)
	else:
		_emit_tri(tool, p0, p1, p2, uv0, uv1, uv2, normal)
		_emit_tri(tool, p0, p2, p3, uv0, uv2, uv3, normal)


## Closes a rail end with a quad facing [param normal].
static func _add_cap(tool: SurfaceTool, corners: PackedVector3Array, normal: Vector3) -> void:
	var a := corners[0]
	var b := corners[1]
	var c := corners[2]
	var d := corners[3]
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	if (b - a).cross(c - a).dot(normal) >= 0.0:
		_emit_tri(tool, a, b, c, uvs[0], uvs[1], uvs[2], normal)
		_emit_tri(tool, a, c, d, uvs[0], uvs[2], uvs[3], normal)
	else:
		_emit_tri(tool, a, c, b, uvs[0], uvs[2], uvs[1], normal)
		_emit_tri(tool, a, d, c, uvs[0], uvs[3], uvs[2], normal)


static func _emit_tri(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		uv_a: Vector2, uv_b: Vector2, uv_c: Vector2, normal: Vector3) -> void:
	tool.set_normal(normal)
	tool.set_uv(uv_a)
	tool.add_vertex(a)
	tool.set_normal(normal)
	tool.set_uv(uv_b)
	tool.add_vertex(b)
	tool.set_normal(normal)
	tool.set_uv(uv_c)
	tool.add_vertex(c)


## How many ties the sweep will place on [param route].
static func tie_count(route: Path3D, prop: Dictionary) -> int:
	if route == null or route.curve == null:
		return 0
	var spacing: float = prop["tie_spacing"]
	if spacing <= 0.0001:
		return 0
	var length := route.curve.get_baked_length()
	return mini(int(floor(length / spacing)) + 1, TIE_LIMIT)


## Total vertices across every surface of [param mesh].
static func vertex_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for surface in mesh.get_surface_count():
		total += mesh.surface_get_array_len(surface)
	return total


# ─────────────────────────────────────────────
#  BAKE
# ─────────────────────────────────────────────

## A fingerprint of everything [method bake] derives from, so a repeat bake can be a no-op.
##
## The point is the save hook: adding nodes re-dirties the scene, so the second save after a
## route change would otherwise rebuild the same geometry and dirty the scene all over again.
static func signature(route: Path3D, prop: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append(PROP_PATH)
	parts.append("s%.4f" % float(prop["tie_spacing"]))
	if route != null:
		parts.append(str(route.get_path()))
		parts.append(str(route.global_transform))
		var curve := route.curve
		if curve != null:
			parts.append("n%d" % curve.point_count)
			parts.append("b%.4f" % curve.bake_interval)
			for i in curve.point_count:
				var point := curve.get_point_position(i)
				parts.append("%.4f,%.4f,%.4f" % [point.x, point.y, point.z])
	return "|".join(parts)


## Builds — or refreshes — the map's [constant CONTAINER_NAME] container under [param root].
##
## Idempotent: an existing container whose fingerprint still matches is left completely alone, so
## saving a map whose route has not changed does not dirty the scene.
##
## [param owner] is the scene root the generated nodes must be owned by to serialize; pass `null`
## in a headless harness, where nothing is saved.
##
## Returns `{ "container", "changed", "ties", "vertices", "warning" }`.
static func bake(root: Node, owner: Node) -> Dictionary:
	var out := {"container": null, "changed": false, "ties": 0, "vertices": 0, "warning": ""}

	var route := find_route(root)
	if route == null:
		# A route that went away takes its track with it, so a map that lost its payload points
		# does not keep a stale railroad.
		out["changed"] = remove(root)
		out["warning"] = "no payload route in this map"
		return out

	var prop := read_prop()
	if not bool(prop["ok"]):
		out["warning"] = "the track prop could not be read; fallback dimensions were used"

	var fingerprint := signature(route, prop)
	var existing := root.get_node_or_null(CONTAINER_NAME) as Node3D
	if existing != null:
		var existing_mesh := existing.get_node_or_null(MESH_NAME) as MeshInstance3D
		if existing_mesh != null and existing_mesh.mesh != null \
				and String(existing.get_meta(SIGNATURE_META, "")) == fingerprint:
			out["container"] = existing
			out["ties"] = tie_count(route, prop)
			out["vertices"] = vertex_count(existing_mesh.mesh)
			return out
		remove(root)

	var mesh := build_mesh(route, prop)
	if mesh == null or mesh.get_surface_count() == 0:
		out["warning"] = "the route has no usable curve"
		return out

	var container := Node3D.new()
	container.name = CONTAINER_NAME
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = MESH_NAME
	mesh_instance.mesh = mesh
	container.add_child(mesh_instance)
	root.add_child(container)
	container.set_meta(SIGNATURE_META, fingerprint)

	if owner != null:
		_own(container, owner)

	out["container"] = container
	out["changed"] = true
	out["ties"] = tie_count(route, prop)
	out["vertices"] = vertex_count(mesh)
	return out


## Frees the container [method bake] would have written, if one exists.  Returns whether there
## was anything to remove.
static func remove(root: Node) -> bool:
	var existing := root.get_node_or_null(CONTAINER_NAME)
	if existing == null:
		return false
	# `free`, not `queue_free`: this runs during `NOTIFICATION_EDITOR_PRE_SAVE`, and a deferred
	# free would still be in the tree when the scene is packed.
	root.remove_child(existing)
	existing.free()
	return true


## Gives every node in [param node]'s subtree an owner, so it serializes into the saved scene.
## `add_child` does not propagate ownership, so each node needs it set explicitly.
static func _own(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.find_children("*", "", true, false):
		child.owner = owner
