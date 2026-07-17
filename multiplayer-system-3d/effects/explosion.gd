extends Node3D

var duration: float = 10.0

@onready var particles := [
	$Debris,
	$Cloud,
	$Smoke,
	$Boom,
	$Ring,
	$SmokeRings
]
func start_effect(scale: float) -> void:
	for p in particles:
		if p == null:
			continue

		var mat = p.process_material
		if mat == null:
			continue

		if mat is ParticleProcessMaterial:
			mat = mat.duplicate(true)

			mat.scale_min *= scale
			mat.scale_max *= scale

			if p == $Debris:
				mat.initial_velocity_min *= scale * 0.4
				mat.initial_velocity_max *= scale * 0.4

			mat.emission_shape_scale *= scale

			p.process_material = mat

		p.emitting = false
		# Defer the restart by one frame so GPU resources are ready.
		await get_tree().process_frame
		if not is_instance_valid(p):
			continue
		p.restart()
		p.emitting = true
