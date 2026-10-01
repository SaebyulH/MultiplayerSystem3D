extends MeshInstance3D
class_name PayloadPathLine

## The glowing red line that draws a payload route in gameplay.
##
## Lives under [PayloadPath] and is built **once**, on map load, into a static tube that
## follows the curve.  Nothing is rebuilt afterwards: "show only the part still ahead of
## the cart" is done entirely in the shader
## (`assets/materials/payload_path_line.gdshader`), which discards every fragment whose
## `UV.x` — the normalised distance along the curve, written per-vertex here — is behind
## the payload's progress.  So advancing the cart costs one float per sync rather than a
## mesh rebuild, and a route of any length costs the same on the CPU.
##
## The tube is unshaded and emissive; every map in `maps/` already sets `glow_enabled` on
## its `Environment`, which is what turns that emission into the bloom the line reads as.

## Radius of the tube in Godot units.  The route is decoration, so this is a cosmetic
## value, not a collision one.
@export var line_radius: float = 0.07

@export var line_color: Color = Color(1.0, 0.1, 0.1)

@export var emission_strength: float = 5.0

## Tube cross-section.  Eight is the point of diminishing returns for a 7 cm pipe.
const SIDES: int = 8

## Upper bound on tube samples.  A pathologically long or finely-baked curve should cost
## more than a few thousand vertices.
const MAX_STEPS: int = 512

var _material: ShaderMaterial


## Builds the tube from [param path]'s curve.  Safe to call again — the mesh is replaced.
##
## Called by [PayloadPath.configure] once the curve has been filled in, never per frame.
func rebuild(path: Path3D) -> void:
	mesh = null
	if path == null or path.curve == null:
		return

	var curve: Curve3D = path.curve
	var baked_length: float = curve.get_baked_length()
	if baked_length <= 0.0:
		return

	# Sample at the curve's own bake resolution: sampling finer than the baked polyline
	# adds no detail, it just duplicates points.  `bake_interval` is a minimum of 0.1 to
	# keep a curve someone authored with a tiny interval from exploding the vertex count.
	var steps: int = clampi(
		int(ceil(baked_length / maxf(curve.bake_interval, 0.1))), 1, MAX_STEPS)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# One ring per sample.  The frame comes from the curve itself, so the tube is square to
	# the path everywhere including round bends; the ring is swept in the frame's own X/Y
	# plane, which is perpendicular to the tangent by construction.
	for i in steps + 1:
		var ratio: float = float(i) / float(steps)
		var frame: Transform3D = curve.sample_baked_with_rotation(ratio * baked_length, true)
		var origin: Vector3 = frame.origin
		var side: Vector3 = frame.basis.x
		var up: Vector3 = frame.basis.y

		for s in SIDES:
			var angle: float = TAU * float(s) / float(SIDES)
			var offset: Vector3 = side * cos(angle) + up * sin(angle)
			vertices.append(origin + offset * line_radius)
			normals.append(offset)
			# `UV.x` is what the shader cuts on, so it has to be the arc-length fraction
			# and not the sample index — those differ wherever the curve bends.
			uvs.append(Vector2(ratio, float(s) / float(SIDES)))

	# Two triangles per quad between consecutive rings.  Wound so both faces are visible,
	# since the material is `cull_disabled` anyway.
	for i in steps:
		for s in SIDES:
			var next: int = (s + 1) % SIDES
			var a: int = i * SIDES + s
			var b: int = i * SIDES + next
			var c: int = (i + 1) * SIDES + s
			var d: int = (i + 1) * SIDES + next
			indices.append_array([a, c, b, b, c, d])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var built := ArrayMesh.new()
	built.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	built.surface_set_material(0, _shader_material())
	mesh = built
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## How much of the route is behind the cart, as a fraction.  The only per-frame-ish write
## this node ever takes; it is a uniform, not geometry.
func set_progress(ratio: float) -> void:
	if _material != null:
		_material.set_shader_parameter("progress", clampf(ratio, 0.0, 1.0))


func _shader_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = preload("res://assets/materials/payload_path_line.gdshader")
	_material.set_shader_parameter("line_color", line_color)
	_material.set_shader_parameter("emission_strength", emission_strength)
	return _material
