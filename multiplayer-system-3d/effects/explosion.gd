extends GenericExplosion

## Standard explosion — six-particle fireball.
##
## Populates the base-class [member particles] array from named children
## and applies debris-specific velocity scaling so debris doesn't fly out
## too far relative to the visual core.

func _apply_scale_to_particle(p: GPUParticles3D, scale: float) -> void:
	if p == $Debris:
		var mat := p.process_material as ParticleProcessMaterial
		if mat:
			mat.initial_velocity_min *= scale * 0.4
			mat.initial_velocity_max *= scale * 0.4
