class_name Tracer extends MeshInstance3D

@export_group("Appearance")
## Default color of the tracer. Warm orange-yellow for a bullet tracer round.
@export var color: Color = Color(1.7, 0.765, 0.0, 1.0)
## Radius of the tracer cylinder in meters.
@export var radius: float = 0.02

## Blue muzzle-flash / tracer color for team SCI.
const SCI_COLOR := Color(0.546, 0.979, 2.853, 1.0)

@export_group("Timing")
## Scales how fast the tracer shrinks. Lower = faster. Formula: distance * multiplier = lifetime.
@export var speed_multiplier: float = 0.017
## Minimum time in seconds the tracer is visible, regardless of distance.
@export var min_duration: float = 0.05
## Maximum time in seconds the tracer is visible, regardless of distance.
@export var max_duration: float = 0.30

## Reusable node pool so automatic fire doesn't allocate a tracer node + mesh +
## material + tween per shot (see #4 in docs/05-known-issues.md).  The mesh and
## material are built once per node in `_ready` and reused; the tween is replaced
## by a cheap `_process` shrink.
const MAX_POOL: int = 64
static var _pool: Array[Tracer] = []

var _cylinder: CylinderMesh
var _material: StandardMaterial3D

# Per-shot shrink state (drives the animation in `_process`).
var _forward: Vector3
var _distance: float
var _end: Vector3
var _duration: float
var _elapsed: float


## Pop a recycled tracer from the pool, or null if none is available (the caller
## instantiates a fresh scene in that case).
static func acquire() -> Tracer:
	while not _pool.is_empty():
		var t: Tracer = _pool.pop_back()
		if is_instance_valid(t):
			return t
	return null


func _ready() -> void:
	_cylinder = CylinderMesh.new()
	_cylinder.top_radius = radius
	_cylinder.bottom_radius = radius
	_cylinder.radial_segments = 6

	_material = StandardMaterial3D.new()
	# Additive blending — adds the tracer's colour on top of the background,
	# which reads as a natural "glow" even without post-processing bloom.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Depth-test against walls but don't write depth (standard transparent pass).
	_material.no_depth_test = false
	# Emission feeds the WorldEnvironment glow post-process for the bloom halo.
	_material.emission_enabled = true
	_material.emission_energy_multiplier = 5.0

	mesh = _cylinder
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_process(false)


func fire(start: Vector3, end: Vector3, flash_color: Color = color) -> void:
	var dir: Vector3 = end - start
	_distance = dir.length()
	if _distance < 0.001:
		_release()
		return

	_forward = dir.normalized()

	_cylinder.height = _distance

	# Configure the shared material's per-shot colour.
	_material.emission = flash_color
	# Reduce alpha so the additive blend actually adds to the background
	# rather than fully replacing it (α=1 would be opaque, not a glow).
	var glow_color := flash_color
	glow_color.a = 0.3
	_material.albedo_color = glow_color
	_cylinder.material = _material

	# Orient the cylinder so its local Y axis (the height) aligns with the shot
	# direction.  CylinderMesh height extends along local Y.
	global_transform.basis = Basis.looking_at(_forward, Vector3.UP) * Basis(Vector3.RIGHT, PI / 2.0)
	global_position = start + _forward * (_distance * 0.5)

	# Animate the tracer shrinking into the hit point.  We shrink both the
	# cylinder height and the node position together so the far end stays
	# locked at 'end' -- it never extends past the wall.
	#   t=0:  height = distance,  center = midpoint  -> spans [start, end]
	#   t=1:  height = 0,         center = end       -> pinched at the hit point
	_end = end
	_duration = clampf(_distance * speed_multiplier, min_duration, max_duration)
	_elapsed = 0.0
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	var t: float = minf(_elapsed / _duration, 1.0)
	_shrink_toward_end(t)
	if t >= 1.0:
		_release()


func _shrink_toward_end(t: float) -> void:
	var current_height: float = _distance * (1.0 - t)
	_cylinder.height = maxf(current_height, 0.001)
	# Keep the far end of the cylinder exactly at 'end'.
	# CylinderMesh extends along local Y, so the tip in +Y direction is
	# at: global_position + forward * (height * 0.5).
	# We want that tip to stay at 'end', so:
	#   global_position = end - forward * (height * 0.5)
	global_position = _end - _forward * (current_height * 0.5)


func _release() -> void:
	set_process(false)
	var parent := get_parent()
	if parent != null:
		parent.remove_child(self)
	if _pool.size() < MAX_POOL:
		_pool.append(self)
	else:
		queue_free()
