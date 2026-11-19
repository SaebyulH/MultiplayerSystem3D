extends Node3D
## Data-driven, visual-only one-shot effects with original procedural artwork.

signal finished

const PROFILE_PATH := "res://effects/toon_explosions/profiles.json"
const ALPHA := preload("../rocket_impact/rocket_impact.gdshader")
const ADD := preload("../rocket_impact/rocket_impact_add.gdshader")
const CAPACITY := 700
const OPEN_ENDED_PREVIEW_DURATION := 2.5
const SOURCE_UNITS_TO_GODOT := 0.0125

@export var auto_free := true
@export_range(0.05, 20.0, 0.01, "or_greater") var effect_scale := 1.0

class Layer:
	var data: Dictionary
	var parent: Layer
	var particles: Array[Particle] = []

class Particle:
	var layer: Layer
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var gravity := Vector3.ZERO
	var birth := 0.0
	var life := 0.0
	var radius := 0.0
	var alpha := 1.0
	var color := Color.WHITE
	var angle := 0.0
	var spin := 0.0
	var seed := 0.0
	var length := 0.0

class Emission:
	var layer: Layer
	var time := 0.0
	var order := 0

static var _profiles: Dictionary = {}

var _rng := RandomNumberGenerator.new()
var _particles: Array[Particle] = []
var _layers: Array[Layer] = []
var _events: Array[Emission] = []
var _alpha: MultiMesh
var _add: MultiMesh
var _normal := Vector3.UP
var _impact_basis := Basis.IDENTITY
var _world_basis := Basis.IDENTITY
var _units := SOURCE_UNITS_TO_GODOT
var _time := 0.0
var _next := 0

static func _load_profiles() -> void:
	if _profiles.is_empty():
		_profiles = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))

static func effect_catalog() -> Array:
	_load_profiles()
	return _profiles.catalog.duplicate(true)

func _ready() -> void:
	top_level = true
	_alpha = _make_batch(ALPHA, 0)
	_add = _make_batch(ADD, 1)
	set_process(false)

func play(effect_id: String, point: Vector3, normal: Vector3 = Vector3.UP, world_up: Vector3 = Vector3.UP, seed_value := -1) -> bool:
	_load_profiles()
	var entry: Dictionary = {}
	for item: Dictionary in _profiles.catalog:
		if item.id == effect_id:
			entry = item
			break
	if entry.is_empty():
		return false
	var up := world_up.normalized() if not world_up.is_zero_approx() else Vector3.UP
	_normal = normal.normalized() if not normal.is_zero_approx() else up
	_impact_basis = _source_basis(_normal, up)
	_world_basis = _source_basis(up, Vector3.RIGHT)
	_units = SOURCE_UNITS_TO_GODOT * maxf(effect_scale, 0.01)
	global_transform = Transform3D(Basis.IDENTITY, point)
	var size := Vector3.ONE * (128.0 * maxf(effect_scale, 0.01))
	_alpha.custom_aabb = AABB(-size, 2.0 * size)
	_add.custom_aabb = _alpha.custom_aabb
	if seed_value < 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value
	_clear_simulation()
	_time = 0.0
	_next = 0
	_plan(_profiles.packages[entry.package], str(int(entry.root)), 0.0, null)
	_events.sort_custom(func(a: Emission, b: Emission) -> bool:
		return a.time < b.time or (a.time == b.time and a.order < b.order)
	)
	_advance(0.0)
	_draw()
	set_process(true)
	return true

func _clear_simulation() -> void:
	for layer in _layers:
		layer.particles.clear()
	_particles.clear()
	_layers.clear()
	_events.clear()

func _exit_tree() -> void:
	_clear_simulation()

func _source_basis(axis: Vector3, guide: Vector3) -> Basis:
	if absf(axis.dot(guide)) > 0.93:
		guide = Vector3.RIGHT if absf(axis.dot(Vector3.RIGHT)) < 0.93 else Vector3.FORWARD
	var side := guide.cross(axis).normalized()
	return Basis(axis, side, axis.cross(side))

func _source_world(v: Vector3) -> Vector3:
	return _world_basis * Vector3(v.z, v.x, v.y)

func _make_batch(shader: Shader, priority: int) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = priority
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = true
	batch.use_custom_data = true
	batch.mesh = quad
	batch.instance_count = CAPACITY
	batch.visible_instance_count = 0
	var mesh := MultiMeshInstance3D.new()
	mesh.multimesh = batch
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)
	return batch

func _plan(graph: Dictionary, id: String, start: float, parent: Layer) -> void:
	var layer := Layer.new()
	layer.data = graph[id]
	layer.parent = parent
	_layers.append(layer)
	var budget := mini(int(layer.data.max), 112)
	_schedule(layer, mini(int(layer.data.initial), budget), start, 0.0)
	for emitter: Dictionary in layer.data.emit:
		var at := start + maxf(float(emitter.get("emission_start_time", 0.0)), 0.0)
		if emitter.functionName == "emit_instantaneously":
			var count := int(emitter.get("num_to_emit", 0))
			var minimum := int(emitter.get("num_to_emit_minimum", -1))
			if minimum >= 0 and minimum < count:
				count = _rng.randi_range(minimum, count)
			_schedule(layer, mini(count, budget), at, 0.0)
		else:
			var duration := float(emitter.get("emission_duration", 0.0))
			if duration <= 0.0:
				duration = OPEN_ENDED_PREVIEW_DURATION
			var rate := float(emitter.get("emission_rate", 0.0))
			var count := mini(roundi(rate * duration), mini(140, budget * 2))
			_schedule(layer, count, at, duration)
	for edge: Dictionary in layer.data.children:
		_plan(graph, str(int(edge.child)), start + maxf(edge.delay, 0.0), layer)

func _schedule(layer: Layer, count: int, start: float, duration: float) -> void:
	for index in count:
		var event := Emission.new()
		event.layer = layer
		event.time = start + duration * float(index) / count
		event.order = _events.size()
		_events.append(event)

func _range(values: Array) -> float:
	return _rng.randf_range(minf(values[0], values[1]), maxf(values[0], values[1]))

func _vec(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])

func _range_vec(values: Array) -> Vector3:
	var a := _vec(values[0])
	var b := _vec(values[1])
	return Vector3(_rng.randf_range(minf(a.x, b.x), maxf(a.x, b.x)),
		_rng.randf_range(minf(a.y, b.y), maxf(a.y, b.y)),
		_rng.randf_range(minf(a.z, b.z), maxf(a.z, b.z)))

func _color(value: Array) -> Color:
	return Color8(int(value[0]), int(value[1]), int(value[2]))

func _spawn(event: Emission) -> void:
	var layer := event.layer
	var d := layer.data
	if _particles.size() >= CAPACITY or layer.particles.size() >= int(d.max):
		return
	var p := Particle.new()
	p.layer = layer
	p.birth = event.time
	p.life = maxf(_range(d.life), 0.035)
	p.radius = maxf(_range(d.radius) * _units, _units * 0.8)
	p.alpha = clampf(_range(d.alpha) / 255.0, 0.0, 1.0)
	p.color = _color(d.colors[0]).lerp(_color(d.colors[1]), _rng.randf())
	p.angle = deg_to_rad(_range(d.rotation))
	p.spin = deg_to_rad(_range(d.spin))
	p.seed = _rng.randf()
	p.length = _range(d.trail) * _units
	var z := _rng.randf_range(-1.0, 1.0)
	var a := _rng.randf_range(0.0, TAU)
	var radial := sqrt(1.0 - z * z)
	var direction := Vector3(cos(a) * radial, sin(a) * radial, z)
	var bias := _vec(d.distance_bias)
	var absolute := _vec(d.distance_abs)
	for axis in 3:
		if absolute[axis] != 0.0:
			direction[axis] = absf(direction[axis])
	direction *= bias
	var offset := _range_vec(d.offset)
	p.position = _normal * _units + _source_world(direction * _range(d.distance) + _range_vec(d.position_box)) * _units
	p.position += (_impact_basis * offset if d.offset_local else _source_world(offset)) * _units
	p.velocity = (_impact_basis * _range_vec(d.local_speed)
		+ _source_world(direction * _range(d.direction_speed) + _range_vec(d.world_speed))) * _units
	p.gravity = _source_world(_vec(d.gravity)) * _units
	if layer.parent != null and not layer.parent.particles.is_empty() and (d.parent_source or layer.parent.data.child_follow):
		var source := layer.parent.particles[_rng.randi_range(0, layer.parent.particles.size() - 1)]
		p.position += source.position
		p.velocity += source.velocity * float(d.parent_velocity)
	layer.particles.append(p)
	_particles.append(p)

func _advance(target: float) -> void:
	while _next < _events.size() and _events[_next].time <= target:
		var event := _events[_next]
		_move(event.time - _time)
		_time = event.time
		_expire()
		_spawn(event)
		_next += 1
	_move(target - _time)
	_time = target
	_expire()

func _expire() -> void:
	for index in range(_particles.size() - 1, -1, -1):
		var p := _particles[index]
		if _time >= p.birth + p.life:
			p.layer.particles.erase(p)
			_particles.remove_at(index)

func _move(delta: float) -> void:
	if delta <= 0.0:
		return
	for p in _particles:
		var d := p.layer.data
		var drag := float(d.drag) * 14.0
		var velocity_weight := delta if drag < 0.001 else (1.0 - exp(-drag * delta)) / drag
		p.position += p.velocity * velocity_weight + p.gravity * (0.5 * delta * velocity_weight)
		p.velocity = p.velocity * exp(-drag * delta) + p.gravity * velocity_weight
		var depth := p.position.dot(_normal)
		if d.bounce >= 0.0 and depth < _units:
			p.position += _normal * (_units - depth)
			var inward := p.velocity.dot(_normal)
			if inward < 0.0:
				p.velocity -= (1.0 + clampf(d.bounce, 0.0, 1.0)) * inward * _normal

func _process(delta: float) -> void:
	_advance(_time + delta)
	_draw()
	if _particles.is_empty() and _next == _events.size():
		set_process(false)
		if auto_free:
			queue_free()
		finished.emit()

func _phase(from: float, to: float, t: float) -> float:
	if to <= from:
		return 1.0 if t >= to else 0.0
	return clampf((t - from) / (to - from), 0.0, 1.0)

func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	var view := camera.global_basis.orthonormalized() if camera else Basis.IDENTITY
	var visible: Array[Particle] = []
	for p in _particles:
		if p.layer.data.draw:
			visible.append(p)
	visible.sort_custom(func(a: Particle, b: Particle) -> bool:
		return view.z.dot(a.position) < view.z.dot(b.position)
	)
	var alpha_count := 0
	var add_count := 0
	for p in visible:
		if p.layer.data.add:
			_draw_particle(_add, add_count, p, view)
			add_count += 1
		else:
			_draw_particle(_alpha, alpha_count, p, view)
			alpha_count += 1
	_alpha.visible_instance_count = alpha_count
	_add.visible_instance_count = add_count

func _draw_particle(batch: MultiMesh, index: int, p: Particle, view: Basis) -> void:
	var d := p.layer.data
	var age := clampf((_time - p.birth) / p.life, 0.0, 1.0)
	var tint := p.color
	var blend: Dictionary = d.color_fade
	if not blend.is_empty():
		var t := _phase(blend.fade_start_time, blend.fade_end_time, age)
		tint = tint.lerp(_color(blend.color_fade), t)
	var fade: Dictionary = d.fade
	var opacity := p.alpha * (1.0 - smoothstep(0.85, 1.0, age))
	if not fade.is_empty():
		var up := _phase(fade.start_fade_in_time, fade.end_fade_in_time, age)
		var down := _phase(fade.start_fade_out_time, fade.end_fade_out_time, age)
		opacity *= lerpf(fade.start_alpha, 1.0, up) * lerpf(1.0, fade.end_alpha, down)
	tint.a = clampf(opacity, 0.0, 1.0)
	var scale_value := 1.0
	for curve: Dictionary in d.size_curves:
		if age < curve.start_time and curve != d.size_curves[0]:
			continue
		var t := _phase(curve.start_time, curve.end_time, age)
		var bias := clampf(curve.get("scale_bias", 0.5), 0.01, 0.99)
		t = pow(t, log(bias) / log(0.5))
		if curve.get("ease_in_and_out", false):
			t = smoothstep(0.0, 1.0, t)
		scale_value = lerpf(curve.radius_start_scale, curve.radius_end_scale, t)
	var size := clampf(p.radius * scale_value, 0.0001, _units * 510.0)
	var width := size
	var height := size
	var frame := view
	var angle := p.angle + p.spin * (age * p.life)
	var position := p.position
	if int(d.shape) == 0 and int(d.orientation) != 0:
		frame = Basis(_impact_basis.y, _impact_basis.z, _normal)
	elif int(d.shape) == 3:
		var projected := Vector2(p.velocity.dot(view.x), p.velocity.dot(view.y))
		if not projected.is_zero_approx():
			angle = atan2(-projected.x, projected.y)
			height = maxf(size, minf(_units * 130.0, p.length * 0.35 + projected.length() * 0.045))
			position -= (view.x * projected.normalized().x + view.y * projected.normalized().y) * height * 0.5
		width *= 0.45
	var axes := frame * Basis(Vector3.BACK, angle) * Basis.from_scale(Vector3(width, height, size))
	batch.set_instance_transform(index, Transform3D(axes, position))
	batch.set_instance_color(index, tint)
	batch.set_instance_custom_data(index, Color(float(d.shape) / 10.0, age, p.seed, 1.0))
