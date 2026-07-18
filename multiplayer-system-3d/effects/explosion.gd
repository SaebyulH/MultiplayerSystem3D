extends Node3D

## Explosion visual effect — drives six child GPUParticles3D nodes.
##
## Spawned on-demand by ExplosionComponent; auto-frees when all particle
## systems finish, so explosions don't linger on idle projectiles.
##
## Optimisations:
##   • ParticleProcessMaterial is shallow-duplicated — curves & textures
##     stay shared; only numeric properties (scale, velocity) are copied.
##   • restart() runs synchronously — no per-particle frame-delay.

signal all_particles_finished

@onready var _particles: Array[GPUParticles3D] = [
	$Debris,
	$Cloud,
	$Smoke,
	$Boom,
	$Ring,
	$SmokeRings,
]

var _finished_count := 0


func start_effect(scale: float) -> void:
	_finished_count = 0

	for p in _particles:
		if p == null:
			_track_finished()
			continue

		var mat := p.process_material
		if mat == null or not mat is ParticleProcessMaterial:
			_track_finished()
			continue

		# Shallow copy — curve sub-resources are shared across instances.
		mat = mat.duplicate(false)

		mat.scale_min *= scale
		mat.scale_max *= scale

		if p == $Debris:
			mat.initial_velocity_min *= scale * 0.4
			mat.initial_velocity_max *= scale * 0.4

		mat.emission_shape_scale *= scale

		p.process_material = mat

		# Connect finished signal (one-shot, fires when all particles expire).
		if not p.finished.is_connected(_on_particle_finished):
			p.finished.connect(_on_particle_finished, CONNECT_ONE_SHOT)

		p.restart()


func _on_particle_finished() -> void:
	_track_finished()


func _track_finished() -> void:
	_finished_count += 1
	if _finished_count >= _particles.size():
		all_particles_finished.emit()
		queue_free()


func _exit_tree() -> void:
	# Safety: if the explosion is freed mid-effect, don't let stale
	# finished signals call methods on a freed node.
	for p in _particles:
		if p and p.finished.is_connected(_on_particle_finished):
			p.finished.disconnect(_on_particle_finished)
