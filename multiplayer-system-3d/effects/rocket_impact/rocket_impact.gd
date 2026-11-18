extends Node3D
## One-shot, visual-only rocket impact. Call play() after adding the scene to the tree.

signal finished

enum Shape { RING, SMOKE, FIRE, STREAK, SHARD, FLASH, GLOW }
enum Motion { DRIFT, BOUNCE }

const ALPHA_SHADER = preload("rocket_impact.gdshader")
const ADD_SHADER = preload("rocket_impact_add.gdshader")
const CAPACITY := 192
const WARM := Color("#ff7a20")
const GOLD := Color("#ffdc6f")
const SMOKE := Color("#524e50")
const CLAY := Color("#6a5857")

@export_range(0.05, 20.0, 0.01, "or_greater") var effect_scale := 1.0
@export var auto_free := true
## Multiplied with every particle colour, so one scene covers fire (white),
## heal (green), poison (purple), etc.  Set before calling play().
@export var tint := Color.WHITE

class Particle:
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var gravity := 0.0
	var drag := 0.0
	var birth := 0.0
	var lifetime := 1.0
	var radius := 1.0
	var angle := 0.0
	var spin := 0.0
	var seed := 0.0
	var opacity := 1.0
	var color := Color.WHITE
	var end_color := Color.WHITE
	var shape := Shape.SMOKE
	var motion := Motion.DRIFT
	var additive := false
	var stretch := 1.0

class Burst:
	var time: float
	var layer: StringName
	var branch: int
	var order: int

	func _init(at: float, effect_layer: StringName, parent_branch: int, insertion_order: int) -> void:
		time = at
		layer = effect_layer
		branch = parent_branch
		order = insertion_order

var _rng := RandomNumberGenerator.new()
var _particles: Array[Particle] = []
var _events: Array[Burst] = []
var _dust_heads: Array[Particle] = []
var _alpha: MultiMesh
var _add: MultiMesh
var _alpha_material: ShaderMaterial
var _add_material: ShaderMaterial
var _origin := Vector3.ZERO
var _up := Vector3.UP
var _normal := Vector3.UP
var _tangent := Vector3.RIGHT
var _bitangent := Vector3.FORWARD
var _clock := 0.0
var _next_event := 0
var _playing := false

func _ready() -> void:
	top_level = true
	_alpha = _make_batch(ALPHA_SHADER)
	_add = _make_batch(ADD_SHADER)
	set_process(false)

func play(impact_position: Vector3, surface_normal: Vector3, world_up := Vector3.UP, seed_value := -1) -> void:
	_origin = impact_position
	_up = world_up.normalized() if not world_up.is_zero_approx() else Vector3.UP
	_normal = surface_normal.normalized() if not surface_normal.is_zero_approx() else _up
	var guide := Vector3.RIGHT if absf(_normal.dot(_up)) > 0.95 else _up
	if absf(_normal.dot(guide)) > 0.95:
		guide = Vector3.FORWARD
	_tangent = guide.cross(_normal).normalized()
	_bitangent = _normal.cross(_tangent)
	if seed_value < 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value
	global_transform = Transform3D(Basis.IDENTITY, _origin)
	var extent := Vector3.ONE * (22.0 * effect_scale)
	var bounds := AABB(-extent, extent * 2.0)
	_alpha.custom_aabb = bounds
	_add.custom_aabb = bounds
	_alpha_material.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	_add_material.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	_clock = 0.0
	_next_event = 0
	_particles.clear()
	_events.clear()
	_dust_heads.clear()
	_build_timeline()
	_playing = true
	_advance(0.0)
	_draw_particles()
	set_process(true)

func _make_batch(shader: Shader) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = 1 if shader == ADD_SHADER else 0
	if shader == ADD_SHADER:
		_add_material = material
	else:
		_alpha_material = material
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = true
	batch.use_custom_data = true
	batch.mesh = quad
	batch.instance_count = CAPACITY
	batch.visible_instance_count = 0
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = batch
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return batch

func _burst(layer: StringName, count: int, duration := 0.0, branch := -1) -> void:
	for i in count:
		_events.append(Burst.new(duration * float(i) / float(count), layer, branch, _events.size()))

func _build_timeline() -> void:
	_burst(&"ring", 4)
	_burst(&"chunks", 7)
	_burst(&"grit", 45, 45.0 / 800.0)
	for branch in 2:
		_burst(&"dust_head", 1, 0.0, branch)
		_burst(&"dust_trail", 14, 0.4, branch)
	_burst(&"smoke", 11, 0.14)
	_burst(&"smoke_tail", 5, 0.14)
	_burst(&"flame", 3, 0.03)
	_burst(&"core", 3, 0.03)
	_burst(&"ember", 12)
	_burst(&"spark", 15)
	_burst(&"star", 1)
	_burst(&"ray", 10)
	_burst(&"glow", 1)
	_events.sort_custom(func(a: Burst, b: Burst) -> bool:
		return a.time < b.time or (a.time == b.time and a.order < b.order)
	)

func _outward(speed_min: float, speed_max: float, spread: float) -> Vector3:
	return effect_scale * (
		_normal * _rng.randf_range(speed_min, speed_max)
		+ _tangent * _rng.randf_range(-spread, spread)
		+ _bitangent * _rng.randf_range(-spread, spread)
	)

func _new_particle(
	shape: Shape, time: float, life: Vector2, size: Vector2, color: Color, end_color: Color
) -> Particle:
	var p := Particle.new()
	p.shape = shape
	p.birth = time
	p.lifetime = _rng.randf_range(life.x, life.y)
	p.radius = _rng.randf_range(size.x, size.y) * effect_scale
	p.color = color
	p.end_color = end_color
	p.angle = _rng.randf_range(0.0, TAU)
	p.spin = _rng.randf_range(-3.0, 3.0)
	p.seed = _rng.randf()
	return p

func _spawn(event: Burst) -> void:
	var p: Particle
	var t := event.time
	match event.layer:
		&"ring":
			p = _new_particle(Shape.RING, t, Vector2(0.45, 0.55), Vector2(0.85, 1.30), CLAY, SMOKE)
			p.position = _normal * effect_scale * _rng.randf_range(0.17, 0.42)
			p.velocity = _normal * 0.72 * effect_scale
			p.opacity = _rng.randf_range(0.26, 0.40)
		&"chunks", &"grit":
			var large := event.layer == &"chunks"
			var life := Vector2(0.50, 0.90) if large else Vector2(0.70, 1.40)
			var size := Vector2(0.10, 0.25) if large else Vector2(0.025, 0.065)
			p = _new_particle(Shape.SHARD, t, life, size, WARM.lerp(GOLD, _rng.randf()), Color("#4b4035"))
			p.position = _normal * effect_scale * 0.12
			p.velocity = _outward(3.3 if large else 0.8, 10.5, 3.8 if large else 2.8)
			p.gravity = -12.5
			p.motion = Motion.BOUNCE
			p.stretch = 0.82
		&"dust_head":
			p = _new_particle(Shape.STREAK, t, Vector2(0.5, 0.5), Vector2(0.10, 0.17), GOLD, WARM)
			p.velocity = _outward(3.0, 9.0, 6.8)
			p.gravity = -13.0
			p.motion = Motion.BOUNCE
			p.additive = true
			p.stretch = 5.0
			_dust_heads.append(p)
		&"dust_trail":
			if event.branch >= _dust_heads.size():
				return
			p = _new_particle(Shape.SMOKE, t, Vector2(0.80, 1.0), Vector2(0.16, 0.30), WARM, CLAY)
			p.position = _dust_heads[event.branch].position
			p.opacity = 0.54
			p.stretch = 1.40
		&"smoke", &"smoke_tail":
			var early := event.layer == &"smoke"
			var life := Vector2(0.50, 0.50) if early else Vector2(0.90, 1.60)
			var size := Vector2(0.32, 0.59) if early else Vector2(0.29, 0.51)
			p = _new_particle(Shape.SMOKE, t, life, size, Color("#de5c16"), SMOKE)
			p.position = _normal * effect_scale * 0.10
			p.velocity = _outward(2.5, 8.0, 5.6) if early else _outward(1.4, 4.9, 3.1)
			p.gravity = 1.45 if early else 0.75
			p.drag = 5.2 if early else 2.2
			p.opacity = 0.92 if early else _rng.randf_range(0.40, 0.70)
		&"flame", &"core":
			var hot := event.layer == &"core"
			var life := Vector2(0.30, 0.40) if hot else Vector2(0.469, 0.469)
			var size := Vector2(0.29, 0.52) if hot else Vector2(0.36, 0.57)
			p = _new_particle(Shape.FIRE, t, life, size, GOLD if hot else WARM, WARM)
			p.position = _normal * 0.21 * effect_scale
			p.velocity = _outward(2.2, 6.2, 3.5)
			p.gravity = 2.5
			p.drag = 6.2
			p.opacity = 0.97
		&"ember", &"spark", &"ray":
			var flash := event.layer == &"ray"
			var long_ember := event.layer == &"ember"
			var life := Vector2(0.13, 0.17) if flash else Vector2(0.20, 0.55)
			if long_ember:
				life = Vector2(0.50, 0.80)
			p = _new_particle(Shape.STREAK, t, life, Vector2(0.028, 0.082), GOLD, WARM)
			p.position = _normal * 0.09 * effect_scale
			p.velocity = _outward(0.5, 2.0, 3.0) if flash else _outward(1.6, 9.7, 8.3)
			p.motion = Motion.DRIFT if flash else Motion.BOUNCE
			p.gravity = 0.0 if flash else -12.5
			p.stretch = _rng.randf_range(10.0, 23.0) if flash else _rng.randf_range(2.5, 6.5)
			p.additive = true
			p.opacity = 0.82 if flash else 1.0
		&"star", &"glow":
			var star := event.layer == &"star"
			var size := Vector2(0.64, 0.71) if star else Vector2(1.04, 1.25)
			p = _new_particle(Shape.FLASH if star else Shape.GLOW, t, Vector2(0.15, 0.18), size, GOLD, WARM)
			p.position = _normal * 0.32 * effect_scale
			p.additive = true
			p.opacity = 0.75 if star else 0.55
	if p != null:
		_particles.append(p)

func _process(delta: float) -> void:
	_advance(_clock + delta)
	_draw_particles()
	if _next_event == _events.size() and _particles.is_empty() and _playing:
		_playing = false
		set_process(false)
		if auto_free:
			queue_free()
		finished.emit()

func _advance(target: float) -> void:
	while _next_event < _events.size() and _events[_next_event].time <= target:
		var event := _events[_next_event]
		_integrate(event.time - _clock)
		_clock = event.time
		_spawn(event)
		_next_event += 1
	_integrate(target - _clock)
	_clock = target
	for i in range(_particles.size() - 1, -1, -1):
		var p := _particles[i]
		if _clock >= p.birth + p.lifetime:
			_particles.remove_at(i)

func _integrate(delta: float) -> void:
	while delta > 0.000001:
		var step := minf(delta, 1.0 / 90.0)
		delta -= step
		for p in _particles:
			p.velocity += _up * (p.gravity * effect_scale * step)
			p.velocity *= exp(-p.drag * step)
			p.position += p.velocity * step
			if p.motion == Motion.BOUNCE:
				var depth := p.position.dot(_normal)
				if depth < 0.02 * effect_scale:
					p.position += _normal * (0.02 * effect_scale - depth)
					if p.velocity.dot(_normal) < 0.0:
						p.velocity = p.velocity.bounce(_normal) * 0.55

func _draw_particles() -> void:
	var camera := get_viewport().get_camera_3d()
	var view := camera.global_transform.basis.orthonormalized() if camera else Basis.IDENTITY
	var alpha_index := 0
	var add_index := 0
	var ordered := _particles.duplicate()
	ordered.sort_custom(func(a: Particle, b: Particle) -> bool:
		return a.position.dot(view.z) < b.position.dot(view.z)
	)
	for p in ordered:
		if p.additive:
			_draw_particle(_add, add_index, p, view)
			add_index += 1
		else:
			_draw_particle(_alpha, alpha_index, p, view)
			alpha_index += 1
	_alpha.visible_instance_count = alpha_index
	_add.visible_instance_count = add_index

func _draw_particle(batch: MultiMesh, index: int, p: Particle, view: Basis) -> void:
	var age := clampf((_clock - p.birth) / p.lifetime, 0.0, 1.0)
	var color := p.color.lerp(p.end_color, smoothstep(0.0, 0.60, age))
	var size := p.radius
	var fade := 1.0 - smoothstep(0.45, 1.0, age)
	var rotation := p.angle + p.spin * (age * p.lifetime)
	var facing := view
	match p.shape:
		Shape.RING:
			size *= lerpf(0.34, 1.90, pow(age, 0.46))
			fade = 1.0 - age
			facing = Basis(_tangent, _bitangent, _normal)
		Shape.SMOKE:
			size *= lerpf(0.44, 2.05, smoothstep(0.0, 0.55, age)) * lerpf(1.0, 0.76, age)
			fade *= smoothstep(0.0, 0.10, age)
		Shape.FIRE:
			size *= lerpf(0.63, 2.6, pow(age, 0.60))
		Shape.STREAK:
			rotation = atan2(-p.velocity.dot(view.x), p.velocity.dot(view.y))
			size *= lerpf(1.35, 0.32, age)
		Shape.SHARD:
			size *= lerpf(1.0, 0.05, age * age)
		Shape.FLASH, Shape.GLOW:
			size *= lerpf(0.62, 1.75, sin(age * PI))
			fade = 1.0 - age * age
	color.a = fade * p.opacity
	var basis := facing * Basis(Vector3.BACK, rotation) * Basis.from_scale(Vector3(size, size * p.stretch, size))
	batch.set_instance_transform(index, Transform3D(basis, p.position))
	batch.set_instance_color(index, color)
	batch.set_instance_custom_data(index, Color(float(p.shape) / 10.0, age, p.seed, 1.0))
