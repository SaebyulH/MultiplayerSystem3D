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

func fire(start: Vector3, end: Vector3, flash_color: Color = color) -> void:
	var dir: Vector3 = end - start
	var distance: float = dir.length()
	if distance < 0.001:
		queue_free()
		return

	var forward := dir.normalized()

	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = distance
	cylinder.radial_segments = 6

	var mat := StandardMaterial3D.new()
	# Additive blending — adds the tracer's colour on top of the background,
	# which reads as a natural "glow" even without post-processing bloom.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Depth-test against walls but don't write depth (standard transparent pass).
	mat.no_depth_test = false
	# Emission feeds the WorldEnvironment glow post-process for the bloom halo.
	mat.emission_enabled = true
	mat.emission = flash_color
	mat.emission_energy_multiplier = 5.0
	# Reduce alpha so the additive blend actually adds to the background
	# rather than fully replacing it (α=1 would be opaque, not a glow).
	var glow_color := flash_color
	glow_color.a = 0.3
	mat.albedo_color = glow_color
	cylinder.material = mat

	mesh = cylinder
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Orient the cylinder so its local Y axis (the height) aligns with the shot
	# direction.  CylinderMesh height extends along local Y.
	global_transform.basis = Basis.looking_at(forward, Vector3.UP) * Basis(Vector3.RIGHT, PI / 2.0)
	global_position = start + forward * (distance * 0.5)

	# Animate the tracer shrinking into the hit point.  We tween both the
	# cylinder height and the node position together so the far end stays
	# locked at 'end' -- it never extends past the wall.
	#   t=0:  height = distance,  center = midpoint  -> spans [start, end]
	#   t=1:  height = 0,         center = end       -> pinched at the hit point
	var duration: float = clamp(distance * speed_multiplier, min_duration, max_duration)
	var tween := get_tree().create_tween()
	tween.tween_method(
		func(t: float): _shrink_toward_end(t, forward, distance, end, cylinder),
		0.0, 1.0, duration
	)
	tween.finished.connect(queue_free)

func _shrink_toward_end(t: float, forward: Vector3, distance: float, end: Vector3, cylinder: CylinderMesh) -> void:
	var current_height: float = distance * (1.0 - t)
	cylinder.height = maxf(current_height, 0.001)
	# Keep the far end of the cylinder exactly at 'end'.
	# CylinderMesh extends along local Y, so the tip in +Y direction is
	# at: global_position + forward * (height * 0.5).
	# We want that tip to stay at 'end', so:
	#   global_position = end - forward * (height * 0.5)
	global_position = end - forward * (current_height * 0.5)
