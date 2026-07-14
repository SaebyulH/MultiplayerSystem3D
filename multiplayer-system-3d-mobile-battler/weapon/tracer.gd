class_name Tracer extends MeshInstance3D

@export_group("Appearance")
## Color of the tracer. Default is a warm orange-yellow to simulate a bullet tracer round.
@export var color: Color = Color(1.26, 0.765, 0.0, 1.0)
## Radius of the tracer cylinder in meters. Keep this very small for realism.
@export var radius: float = 0.01

@export_group("Speed")
## Scales how fast the tracer travels. Lower = faster. Formula: distance * multiplier = duration.
## At 0.005, a 100-unit shot takes 0.5s before clamping.
@export var speed_multiplier: float = 0.01
## Minimum time in seconds the tracer travel animation will last, regardless of distance.
## Prevents point-blank shots from being invisible.
@export var min_duration: float = 0.03
## Maximum time in seconds the tracer travel animation will last, regardless of distance.
## Prevents very long-range shots from having a tracer that lingers too long.
@export var max_duration: float = 0.15

func fire(start: Vector3, end: Vector3) -> void:
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
	cylinder.radial_segments = 3

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cylinder.material = mat

	mesh = cylinder
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	global_transform.basis = Basis.looking_at(forward, Vector3.UP) * Basis(Vector3.RIGHT, PI / 2.0)

	# KEY FIX: center offset This will ensure that it "feels" fast
	global_position = start + forward * (distance * 0.5)

	var duration: float = clamp(distance * speed_multiplier, min_duration, max_duration)
	var tween := get_tree().create_tween()
	tween.tween_property(self, "global_position", end, duration)
	tween.finished.connect(queue_free)
