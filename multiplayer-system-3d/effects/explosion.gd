extends Node3D

var duration: float = 10.0

@onready var particles := [
	$Debris,
	#$GlowingDebris,
	$Cloud,
	$Smoke,
	#$SmokeDark,
	
	$Boom,
	$Ring,
	$SmokeRings
]
func start_effect(scale: float) -> void:
	for p in particles:
		if p == null:
			continue

		var mat = p.process_material
		if mat is ParticleProcessMaterial:
			mat = mat.duplicate(true)

			mat.scale_min *= scale
			mat.scale_max *= scale
			
			if p == $Debris:
				mat.initial_velocity_min *= scale*0.4
				mat.initial_velocity_max *= scale*0.4

			mat.emission_shape_scale *= scale

			p.process_material = mat

		p.emitting = false
		p.restart()
		p.emitting = true
