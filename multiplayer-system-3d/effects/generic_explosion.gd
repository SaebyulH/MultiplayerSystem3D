extends Node3D
class_name GenericExplosion

## Generic explosion visual effect that drives an exported list of
## GPUParticles3D nodes.
##
## Spawned on-demand by ExplosionComponent; auto-frees when all particle
## systems finish so explosions don't linger on idle projectiles.
##
## Usage:
##   1. Create a new scene with a Node3D root and this script (or a subclass)
##      attached.
##   2. Add GPUParticles3D children and assign them to [member particles].
##   3. Set [member effect_color] to tint all particle materials.
##   4. Override [method _apply_scale_to_particle] for per-particle tweaks.
##   5. Call [method start_effect] to fire the explosion.
##
## Colour customisation:
##   [member effect_color] is multiplied with each particle material's
##   albedo / emission shader parameters at runtime.  Set it to a non-white
##   colour to create ice (blue), poison (green), void (purple), etc.
##   explosions without duplicating textures.

signal all_particles_finished

## GPUParticles3D nodes managed by this explosion.
## Assign child particle nodes here — either in the editor or via _ready().
@export var particles: Array[GPUParticles3D] = []

## Default colour tint applied to all particle materials.
## Multiplied with each material's albedo / emission shader parameters.
## White (default) = no tint.
@export var effect_color: Color = Color.WHITE

var _finished_count := 0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func start_effect(scale: float, color_override: Color = Color(1.0, 1.0, 1.0, 0.0)) -> void:
	_finished_count = 0

	# Use the override colour if explicitly provided (non-transparent),
	# otherwise fall back to the exported effect_color.
	var color: Color = effect_color
	if color_override.a > 0.0:
		color = color_override

	for p in particles:
		if p == null:
			_track_finished()
			continue

		var mat := p.process_material
		if mat == null or not mat is ParticleProcessMaterial:
			_track_finished()
			continue

		# Shallow copy — curve / texture sub-resources stay shared.
		mat = mat.duplicate(false)

		mat.scale_min *= scale
		mat.scale_max *= scale
		mat.emission_shape_scale *= scale

		p.process_material = mat

		# Per-particle scale hook (e.g. debris velocity).
		_apply_scale_to_particle(p, scale)

		# Colour tint.
		_apply_color_to_particle(p, color)

		# Connect finished signal (one-shot, fires when all particles expire).
		if not p.finished.is_connected(_on_particle_finished):
			p.finished.connect(_on_particle_finished, CONNECT_ONE_SHOT)

		p.restart()


# ---------------------------------------------------------------------------
# Extension points — override in subclasses
# ---------------------------------------------------------------------------

## Called for each particle after generic scale application.
## Override to apply per-particle scale tweaks (e.g. reduced velocity for
## debris so it doesn't fly out too far).
func _apply_scale_to_particle(_p: GPUParticles3D, _scale: float) -> void:
	pass


## Applies [color] tint to [p]'s material override.
## Override for custom colour-mapping behaviour.
func _apply_color_to_particle(p: GPUParticles3D, color: Color) -> void:
	var material: Material = p.material_override
	if material == null:
		return

	if material is ShaderMaterial:
		material = material.duplicate()
		p.material_override = material
		# Tint albedo (present on virtually all our particle shaders).
		if _shader_has_param(material, "albedo"):
			var original: Color = material.get_shader_parameter("albedo")
			material.set_shader_parameter("albedo", original * color)
		# Tint emission (present on shaders that glow, e.g. Boom, Cloud).
		if _shader_has_param(material, "emission"):
			var original: Color = material.get_shader_parameter("emission")
			material.set_shader_parameter("emission", original * color)
	elif material is StandardMaterial3D:
		material = material.duplicate()
		p.material_override = material
		material.albedo_color = material.albedo_color * color


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Returns true if [param_name] is declared as a uniform in [mat]'s shader.
func _shader_has_param(mat: ShaderMaterial, param_name: String) -> bool:
	if mat.shader == null:
		return false
	# Crude but effective: the shader source is GLSL text, so a substring
	# check tells us whether the uniform is declared.  False positives are
	# unlikely for these specific parameter names ("albedo", "emission").
	return param_name in mat.shader.code


# ---------------------------------------------------------------------------
# Lifetime management
# ---------------------------------------------------------------------------

func _on_particle_finished() -> void:
	_track_finished()


func _track_finished() -> void:
	_finished_count += 1
	if _finished_count >= particles.size():
		all_particles_finished.emit()
		queue_free()


func _exit_tree() -> void:
	# Safety: if the explosion is freed mid-effect, don't let stale
	# finished signals call methods on a freed node.
	for p in particles:
		if p and p.finished.is_connected(_on_particle_finished):
			p.finished.disconnect(_on_particle_finished)
