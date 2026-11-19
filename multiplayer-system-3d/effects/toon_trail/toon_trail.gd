extends Node3D
## Follow a projectile's exhaust marker while retaining the emitted trail in world space.

signal finished

const Profiles := preload("trail_profiles.gd")
const SpriteAlpha := preload("trail_sprite.gdshader")
const SpriteAdd := preload("trail_sprite_add.gdshader")
const RibbonAlpha := preload("ribbon.gdshader")
const RibbonAdd := preload("ribbon_add.gdshader")
const BATCH_CAPACITY := 512
const UNIT := 0.023
const SHAPES := {"ring": 0, "smoke": 1, "fire": 2, "spark": 3, "star": 5, "glow": 6, "bubble": 7, "arc": 8}

@export var auto_free := true
@export_range(0.05, 16.0, 0.01) var effect_scale := 1.0
## Preview-only playback multiplier (the asset viewer's speed slider).  Gameplay
## never changes it, so it stays at 1.0 in every projectile.
@export_range(0.05, 4.0, 0.01) var speed_scale := 1.0

class Sample:
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var gravity := Vector3.ZERO
	var birth := 0.0
	var life := 1.0
	var radius := 0.1
	var opacity := 1.0
	var tint := Color.WHITE
	var roll := 0.0
	var seed := 0.0
	var forward := Vector3.FORWARD

class Layer:
	var profile: Dictionary
	var samples: Array[Sample] = []
	var next_times: PackedFloat64Array

static var _catalog: Array = []

var _layers: Array[Layer] = []
var _source: Node3D
var _last_position := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _emitting := false
var _current_position := Vector3.ZERO
var _current_forward := Vector3.FORWARD
var _alpha: MultiMesh
var _add: MultiMesh
var _ribbon_alpha: ImmediateMesh
var _ribbon_add: ImmediateMesh

static func _load_catalog() -> void:
	if _catalog.is_empty():
		_catalog = JSON.parse_string(Profiles.JSON_DATA)

static func catalog() -> Array[Dictionary]:
	_load_catalog()
	var entries: Array[Dictionary] = []
	for record: Dictionary in _catalog:
		entries.append({"id": record.id, "title": record.title, "group": record.group})
	return entries

func _ready() -> void:
	top_level = true
	_alpha = _make_sprites(SpriteAlpha, 0)
	_add = _make_sprites(SpriteAdd, 2)
	_ribbon_alpha = _make_ribbon(RibbonAlpha, 0)
	_ribbon_add = _make_ribbon(RibbonAdd, 1)
	set_process(false)

## The nozzle uses Godot's local -Z as its forward direction.
func start(preset_id: String, nozzle: Node3D, seed_value := -1) -> bool:
	if not is_instance_valid(nozzle) or not nozzle.is_inside_tree():
		return false
	_load_catalog()
	var preset: Dictionary = {}
	for candidate: Dictionary in _catalog:
		if candidate.id == preset_id:
			preset = candidate
			break
	if preset.is_empty():
		return false
	if seed_value < 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value
	_layers.clear()
	for profile: Dictionary in preset.layers:
		var layer := Layer.new()
		layer.profile = profile
		for op: Dictionary in profile.emitters:
			layer.next_times.append(float(profile.delay) + float(op.get("emission_start_time", 0.0)))
		_layers.append(layer)
	_source = nozzle
	global_transform = Transform3D(Basis.IDENTITY, nozzle.global_position)
	_last_position = Vector3.ZERO
	_current_position = Vector3.ZERO
	_current_forward = -nozzle.global_basis.z.normalized()
	_time = 0.0
	_emitting = true
	_alpha.visible_instance_count = 0
	_add.visible_instance_count = 0
	_ribbon_alpha.clear_surfaces()
	_ribbon_add.clear_surfaces()
	set_process(true)
	return true

## Stop spawning. Emitted fire, smoke and ribbons continue to age.
func stop() -> void:
	_emitting = false
	_source = null

func _make_sprites(shader: Shader, priority: int) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = true
	batch.use_custom_data = true
	batch.mesh = quad
	batch.instance_count = BATCH_CAPACITY
	batch.visible_instance_count = 0
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = batch
	instance.material_override = _material(shader, priority)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return batch

func _make_ribbon(shader: Shader, priority: int) -> ImmediateMesh:
	var stream := ImmediateMesh.new()
	var instance := MeshInstance3D.new()
	instance.mesh = stream
	var material := _material(shader, priority)
	material.set_shader_parameter("outline_amount", 0.7 if priority == 0 else 0.14)
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return stream

func _material(shader: Shader, priority: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = priority
	return material

func _process(delta: float) -> void:
	if _advance(delta * speed_scale):
		_draw()
	else:
		_draw()
		set_process(false)
		if auto_free:
			queue_free()
		finished.emit()

func _advance(delta: float) -> bool:
	if _emitting and not is_instance_valid(_source):
		stop()
	_time += delta
	if _emitting:
		_current_position = _source.global_position - global_position
		_current_forward = -_source.global_basis.z.normalized()
		var motion := (_current_position - _last_position) / maxf(delta, 0.0001)
		var frame := _basis(_current_forward)
		for layer in _layers:
			_cull(layer)
			_emit(layer, delta, frame, motion)
		_last_position = _current_position
		return true
	var alive := false
	for layer in _layers:
		_cull(layer)
		alive = alive or not layer.samples.is_empty()
	return alive

func _cull(layer: Layer) -> void:
	for i in range(layer.samples.size() - 1, -1, -1):
		var p := layer.samples[i]
		if _time - p.birth >= p.life:
			layer.samples.remove_at(i)

func _emit(layer: Layer, delta: float, frame: Basis, velocity: Vector3) -> void:
	var d := layer.profile
	for i in d.emitters.size():
		var op: Dictionary = d.emitters[i]
		var next := layer.next_times[i]
		if next > _time:
			continue
		if op.functionName == "emit_instantaneously":
			for _index in mini(int(op.get("num_to_emit", 0)), 12):
				_spawn(layer, next, delta, frame, velocity)
			layer.next_times[i] = INF
			continue
		var rate := clampf(op.get("emission_rate", 0.0), 0.0, 100.0)
		if rate <= 0.0:
			layer.next_times[i] = INF
			continue
		var duration := float(op.get("emission_duration", 0.0))
		var deadline := INF
		if duration > 0.0:
			deadline = float(d.delay) + float(op.get("emission_start_time", 0)) + duration
		var emitted := 0
		while next <= minf(deadline, _time) and emitted < 16:
			_spawn(layer, next, delta, frame, velocity)
			next += 1.0 / rate
			emitted += 1
		layer.next_times[i] = INF if next >= deadline else maxf(next, _time - 0.15)

func _basis(forward: Vector3) -> Basis:
	var backward := -forward
	var guide := Vector3.UP if absf(backward.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var side := guide.cross(backward).normalized()
	return Basis(backward, side, backward.cross(side))

func _vector(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

func _rand(span: Array) -> float:
	return _rng.randf_range(minf(span[0], span[1]), maxf(span[0], span[1]))

func _rand_vector(span: Array) -> Vector3:
	var a := _vector(span[0])
	var b := _vector(span[1])
	return Vector3(_rng.randf_range(minf(a.x, b.x), maxf(a.x, b.x)),
		_rng.randf_range(minf(a.y, b.y), maxf(a.y, b.y)),
		_rng.randf_range(minf(a.z, b.z), maxf(a.z, b.z)))

func _color(a: Array) -> Color:
	return Color8(int(a[0]), int(a[1]), int(a[2]))

func _spawn(layer: Layer, at: float, delta: float, frame: Basis, velocity: Vector3) -> void:
	var d := layer.profile
	var limit := mini(int(d.cap), 170)
	if limit <= 0:
		return
	if layer.samples.size() >= limit:
		layer.samples.pop_front()
	var p := Sample.new()
	var units := UNIT * effect_scale
	var z := _rng.randf_range(-1.0, 1.0)
	var theta := _rng.randf_range(0.0, TAU)
	var radial := sqrt(1.0 - z * z)
	var direction := Vector3(radial * cos(theta), radial * sin(theta), z)
	var blend := clampf(1.0 - (_time - at) / maxf(delta, 0.0001), 0.0, 1.0)
	var base := _last_position.lerp(_current_position, blend)
	var offset := _rand_vector(d.offset) + direction * _rand(d.distance)
	if int(d.parent) >= 0:
		var parent := _layers[int(d.parent)].profile
		var angle := at * deg_to_rad(float(parent.helix))
		offset += Vector3(0.0, cos(angle), sin(angle)) * float(parent.helix_radius)
	p.position = base + frame * offset * units
	p.velocity = frame * (_rand_vector(d.speed) + direction * _rand(d.radial_speed)) * units
	p.velocity += velocity * clampf(d.inherit, -0.2, 0.2)
	var gravity := _vector(d.gravity)
	p.gravity = Vector3(gravity.x, gravity.z, -gravity.y) * units
	p.birth = at
	p.life = maxf(_rand(d.life), 0.025)
	p.radius = maxf(_rand(d.radius) * units, 0.008)
	p.opacity = clampf(_rand(d.alpha) / 255.0, 0.0, 1.0)
	p.tint = _color(d.color[0]).lerp(_color(d.color[1]), _rng.randf())
	p.roll = _rng.randf_range(0.0, TAU)
	p.seed = _rng.randf()
	p.forward = _current_forward
	layer.samples.append(p)

func _phase(start: float, end: float, t: float) -> float:
	if end <= start:
		return 1.0 if t >= end else 0.0
	return clampf((t - start) / (end - start), 0.0, 1.0)

func _radius(p: Sample, d: Dictionary, age: float) -> float:
	var scale_value := 1.0
	for i in d.size.size():
		var curve: Array = d.size[i]
		if age < curve[0] and i > 0:
			break
		var x := _phase(curve[0], curve[1], age)
		x = pow(x, log(clampf(curve[4], 0.01, 0.99)) / log(0.5))
		scale_value = lerpf(curve[2], curve[3], x)
	return clampf(p.radius * scale_value, 0.001, 2.5 * effect_scale)

func _tint(p: Sample, d: Dictionary, age: float) -> Color:
	var tint := p.tint
	if not d.color_fade.is_empty():
		var color_mix := _phase(d.color_window[0], d.color_window[1], age)
		tint = tint.lerp(_color(d.color_fade), color_mix)
	var rise := _phase(d.alpha_in[0], d.alpha_in[1], age)
	var fall := _phase(d.alpha_out[0], d.alpha_out[1], age)
	tint.a = p.opacity * rise * (1.0 - fall)
	return tint

func _position(p: Sample, d: Dictionary) -> Vector3:
	var elapsed := maxf(_time - p.birth, 0.0)
	var drag := float(d.drag) * 9.0
	var travel := elapsed if drag < 0.001 else (1.0 - exp(-drag * elapsed)) / drag
	var point := p.position + p.velocity * travel + p.gravity * elapsed * elapsed * 0.5
	if _emitting and float(d.lock_until) != 0.0:
		var weight := 1.0 - smoothstep(0.0, maxf(d.lock_until, 0.6), elapsed / p.life)
		point = point.lerp(_current_position + p.velocity * travel, weight * 0.8)
	return point

func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	var view := camera.global_basis.orthonormalized() if camera else Basis.IDENTITY
	var eye := camera.global_position - global_position if camera else Vector3.BACK * 10.0
	_ribbon_alpha.clear_surfaces()
	_ribbon_add.clear_surfaces()
	var ribbon_open := [false, false]
	var counts := [0, 0]
	for layer in _layers:
		var d := layer.profile
		var index := int(d.additive)
		if d.kind == "ribbon":
			var mesh := _ribbon_add if d.additive else _ribbon_alpha
			_draw_ribbon(layer, mesh, eye, view, ribbon_open, index)
		elif d.kind != "none":
			var batch := _add if d.additive else _alpha
			for p in layer.samples:
				if counts[index] >= BATCH_CAPACITY:
					break
				if _draw_sprite(p, d, batch, counts[index], view):
					counts[index] += 1
	if ribbon_open[0]:
		_ribbon_alpha.surface_end()
	if ribbon_open[1]:
		_ribbon_add.surface_end()
	_alpha.visible_instance_count = counts[0]
	_add.visible_instance_count = counts[1]

func _draw_sprite(p: Sample, d: Dictionary, batch: MultiMesh, index: int, view: Basis) -> bool:
	var age := clampf((_time - p.birth) / p.life, 0.0, 1.0)
	var tint := _tint(p, d, age)
	if tint.a < 0.003:
		return false
	var radius := _radius(p, d, age)
	var frame := view
	var height := radius
	var width := radius
	var angle := p.roll + deg_to_rad(float(d.spin)) * age * p.life
	match String(d.kind):
		"ring":
			var axes := _basis(p.forward)
			frame = Basis(axes.y, axes.z, axes.x)
		"arc", "spark":
			height *= 2.3
			width *= 0.65
			var direction := Vector2(p.forward.dot(view.x), p.forward.dot(view.y))
			if not direction.is_zero_approx():
				angle = atan2(-direction.x, direction.y) + (p.seed - 0.5) * 1.1
	frame = frame * Basis(Vector3.BACK, angle) * Basis.from_scale(Vector3(width, height, radius))
	batch.set_instance_transform(index, Transform3D(frame, _position(p, d)))
	batch.set_instance_color(index, tint)
	batch.set_instance_custom_data(index, Color(float(SHAPES[d.kind]) / 10.0, age, p.seed, 1.0))
	return true

func _draw_ribbon(layer: Layer, mesh: ImmediateMesh, eye: Vector3, view: Basis, opened: Array, index: int) -> void:
	var d := layer.profile
	var points := PackedVector3Array()
	var colors := PackedColorArray()
	var widths := PackedFloat32Array()
	for p in layer.samples:
		var age := clampf((_time - p.birth) / p.life, 0.0, 1.0)
		var point := _position(p, d)
		if not points.is_empty() and point.distance_squared_to(points[-1]) < 0.000001:
			continue
		points.append(point)
		colors.append(_tint(p, d, age))
		widths.append(_radius(p, d, age))
	if _emitting and not points.is_empty() and points[-1].distance_squared_to(_current_position) > 0.000001:
		points.append(_current_position)
		var head := colors[-1]
		head.a *= 0.5
		colors.append(head)
		widths.append(widths[-1] * 0.65)
	if points.size() < 2:
		return
	var path := PackedVector3Array()
	var tints := PackedColorArray()
	var sizes := PackedFloat32Array()
	var subdivisions := clampi(int(d.subdivisions), 1, 4)
	for i in points.size() - 1:
		for j in subdivisions:
			var f := float(j) / subdivisions
			var curved := points[i].cubic_interpolate(points[i + 1], points[maxi(i - 1, 0)], points[mini(i + 2, points.size() - 1)], f)
			path.append(curved)
			tints.append(colors[i].lerp(colors[i + 1], f))
			sizes.append(lerpf(widths[i], widths[i + 1], f))
	path.append(points[-1])
	tints.append(colors[-1])
	sizes.append(widths[-1])
	var last_left := Vector3.ZERO
	var last_right := Vector3.ZERO
	var last_u := 0.0
	for i in path.size():
		var tangent := (path[mini(i + 1, path.size() - 1)] - path[maxi(0, i - 1)]).normalized()
		var side := tangent.cross((eye - path[i]).normalized()).normalized()
		if side.is_zero_approx():
			side = view.x
		var left := path[i] - side * sizes[i]
		var right := path[i] + side * sizes[i]
		if i > 0:
			var u := last_u + path[i - 1].distance_to(path[i]) / maxf(effect_scale, 0.01)
			if tints[i].a > 0.004 or tints[i - 1].a > 0.004:
				if not opened[index]:
					mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
					opened[index] = true
				_vertex(mesh, last_left, last_u, 0.0, tints[i - 1])
				_vertex(mesh, last_right, last_u, 1.0, tints[i - 1])
				_vertex(mesh, left, u, 0.0, tints[i])
				_vertex(mesh, left, u, 0.0, tints[i])
				_vertex(mesh, last_right, last_u, 1.0, tints[i - 1])
				_vertex(mesh, right, u, 1.0, tints[i])
			last_u = u
		last_left = left
		last_right = right

func _vertex(mesh: ImmediateMesh, point: Vector3, u: float, v: float, tint: Color) -> void:
	mesh.surface_set_color(tint)
	mesh.surface_set_uv(Vector2(u, v))
	mesh.surface_add_vertex(point)
