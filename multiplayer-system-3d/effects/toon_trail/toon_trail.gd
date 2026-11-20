extends Node3D
## Follow a projectile's exhaust marker while retaining the emitted trail in world space.

signal finished

const Profiles := preload("trail_profiles.gd")
const SpriteAlpha := preload("trail_sprite.gdshader")
const SpriteAdd := preload("trail_sprite_add.gdshader")
const SpriteSelfAdd := preload("trail_sprite_self_add.gdshader")
const RibbonAlpha := preload("ribbon.gdshader")
const RibbonAdd := preload("ribbon_add.gdshader")
const BATCH_CAPACITY := 1024
const UNIT := 0.023
const SHAPES := {"ring": 0, "smoke": 1, "fire": 2, "spark": 3, "star": 5, "glow": 6, "bubble": 7, "arc": 8}

@export var auto_free := true
@export_range(0.05, 16.0, 0.01) var effect_scale := 1.0
## Preview-only playback multiplier (the asset viewer's speed slider).  Gameplay
## never changes it, so it stays at 1.0 in every projectile.
@export_range(0.05, 4.0, 0.01) var speed_scale := 1.0

class Sample:
	var position := Vector3.ZERO
	var origin := Vector3.ZERO
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
var _self_add: MultiMesh
var _ribbon_alpha: ImmediateMesh
var _ribbon_add: ImmediateMesh
## Sprite capacity actually allocated for this trail.  Sized from the preset's
## layer caps in `_ensure_buffers()`, so a ribbon-only trail (the generic and
## grenade trails) allocates no MultiMesh at all.
var _sprite_capacity := 0
## Scratch arrays reused by every `_draw()`; clear-before-reuse, never per-frame
## allocations.
var _counts := [0, 0, 0]
var _ribbon_open := [false, false]
var _points := PackedVector3Array()
var _colors := PackedColorArray()
var _widths := PackedFloat32Array()
var _path := PackedVector3Array()
var _path_tints := PackedColorArray()
var _path_sizes := PackedFloat32Array()
var _lengths := PackedFloat32Array()
## Shared across every trail instance: the quad mesh and one material per
## (shader, priority).  Neither carries per-trail state.
static var _shared_quad: QuadMesh
static var _shared_materials := {}
## Finished game trails are recycled instead of freed, so rapid-fire weapons do
## not allocate node/mesh/MultiMesh objects per shot.  Nodes here are outside the
## tree; `acquire()` hands one back and the caller re-adds it.
const POOL_LIMIT := 24
static var _pool: Array = []


## A finished trail for re-use, or null.  Gameplay only: the asset viewer sets
## `auto_free = false` and owns its nodes.  The returned node is detached; the
## caller parents it to its host and calls `start()`.
static func acquire() -> Node3D:
	while not _pool.is_empty():
		var trail := _pool.pop_back() as Node3D
		if not is_instance_valid(trail):
			# Its host world was freed (map swap); drop the stale reference.
			continue
		if trail.get_parent() != null:
			trail.get_parent().remove_child(trail)
		return trail
	return null

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
	_ensure_buffers(preset)
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
	if _alpha != null:
		_alpha.visible_instance_count = 0
		_add.visible_instance_count = 0
		_self_add.visible_instance_count = 0
	if _ribbon_alpha != null:
		_ribbon_alpha.clear_surfaces()
		_ribbon_add.clear_surfaces()
	set_process(true)
	return true

## Stop spawning. Emitted fire, smoke and ribbons continue to age.
func stop() -> void:
	_emitting = false
	_source = null

## Allocate only the buffers this preset can actually use.  Ribbon layers draw
## through `ImmediateMesh`, so a ribbon-only preset needs no MultiMesh; a sprite
## preset gets capacities sized from its layer caps instead of a flat 1024.
func _ensure_buffers(preset: Dictionary) -> void:
	var sprite_capacity := 0
	var has_ribbon := false
	for profile: Dictionary in preset.layers:
		var kind := str(profile.get("kind", ""))
		if kind == "ribbon":
			has_ribbon = true
		elif kind != "none":
			sprite_capacity += int(profile.get("cap", 0))
	sprite_capacity = mini(sprite_capacity, BATCH_CAPACITY)
	if sprite_capacity > 0:
		if _alpha == null:
			_alpha = _make_sprites(SpriteAlpha, 0, sprite_capacity)
			_add = _make_sprites(SpriteAdd, 3, sprite_capacity)
			_self_add = _make_sprites(SpriteSelfAdd, 2, sprite_capacity)
			_sprite_capacity = sprite_capacity
		elif sprite_capacity > _sprite_capacity:
			# Restarted with a heavier preset: grow the existing buffers.
			for batch in [_alpha, _add, _self_add]:
				batch.instance_count = sprite_capacity
			_sprite_capacity = sprite_capacity
	if has_ribbon and _ribbon_alpha == null:
		_ribbon_alpha = _make_ribbon(RibbonAlpha, 0)
		_ribbon_add = _make_ribbon(RibbonAdd, 1)

func _make_sprites(shader: Shader, priority: int, capacity: int) -> MultiMesh:
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = true
	batch.use_custom_data = true
	batch.mesh = _quad_mesh()
	batch.instance_count = capacity
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
	instance.material_override = _material(shader, priority)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return stream

static func _quad_mesh() -> QuadMesh:
	if _shared_quad == null:
		_shared_quad = QuadMesh.new()
		_shared_quad.size = Vector2(2.0, 2.0)
	return _shared_quad

func _material(shader: Shader, priority: int) -> ShaderMaterial:
	var key := "%s:%d" % [shader.resource_path, priority]
	if _shared_materials.has(key):
		return _shared_materials[key]
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = priority
	if shader == SpriteAlpha or shader == SpriteAdd or shader == SpriteSelfAdd:
		material.set_shader_parameter("self_add", shader == SpriteSelfAdd)
	else:
		material.set_shader_parameter("outline_amount", 0.7 if priority == 0 else 0.14)
	_shared_materials[key] = material
	return material

func _process(delta: float) -> void:
	var alive := _advance(delta * speed_scale)
	_draw()
	if alive:
		return
	set_process(false)
	finished.emit()
	if auto_free:
		_recycle()


## Stop and detach this trail, returning it to the shared pool.  Buffers stay
## allocated for the next projectile; per-run state is cleared by `start()`.
func _recycle() -> void:
	stop()
	_layers.clear()
	_time = 0.0
	if _alpha != null:
		_alpha.visible_instance_count = 0
		_add.visible_instance_count = 0
		_self_add.visible_instance_count = 0
	if _ribbon_alpha != null:
		_ribbon_alpha.clear_surfaces()
		_ribbon_add.clear_surfaces()
	# Stay parked under the world node that hosted it (a Node3D parent, so the
	# transform hierarchy is valid).  Stopped and visible-instance 0, it does no
	# work; a map swap frees it and `acquire()` drops the stale reference.
	if _pool.size() < POOL_LIMIT:
		_pool.append(self)
	else:
		queue_free()

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
		var rate := clampf(op.get("emission_rate", 0.0), 0.0, 512.0)
		if rate <= 0.0:
			layer.next_times[i] = INF
			continue
		var duration := float(op.get("emission_duration", 0.0))
		var deadline := INF
		if duration > 0.0:
			deadline = float(d.delay) + float(op.get("emission_start_time", 0)) + duration
		var emitted := 0
		while next <= minf(deadline, _time) and emitted < 96:
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
	var limit := mini(int(d.cap), 512)
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
	p.origin = base
	p.position = base + frame * offset * units
	p.velocity = frame * (_rand_vector(d.speed) + direction * _rand(d.radial_speed)) * units
	p.velocity += velocity * clampf(d.inherit, -0.2, 0.2)
	var gravity := _vector(d.gravity)
	p.gravity = Vector3(gravity.x, gravity.z, -gravity.y) * units
	p.birth = at
	p.life = maxf(_rand(d.life), 0.025)
	p.radius = maxf(_rand(d.radius) * units, 0.008)
	p.opacity = clampf(_rand(d.alpha) / 255.0, 0.0, 1.0)
	for remap: Dictionary in d.alpha_birth_remaps:
		var birth := at - float(d.delay)
		var lo := float(remap["input minimum"])
		var hi := float(remap["input maximum"])
		if remap["only active within specified input range"] and (birth < lo or birth > hi):
			continue
		var value := lerpf(remap["output minimum"], remap["output maximum"], _phase(lo, hi, birth))
		if remap["output is scalar of initial random range"]:
			p.opacity *= value
		else:
			p.opacity = clampf(value, 0.0, 1.0)
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
		tint = tint.lerp(_color(d.color_fade), smoothstep(0.0, 1.0, color_mix) if d.color_ease else color_mix)
	var rise := _phase(d.alpha_in[0], d.alpha_in[1], age)
	var fall := _phase(d.alpha_out[0], d.alpha_out[1], age)
	var from_alpha := lerpf(d.alpha_endpoints[0], 1.0, smoothstep(0.0, 1.0, rise))
	var to_alpha := lerpf(1.0, d.alpha_endpoints[1], smoothstep(0.0, 1.0, fall))
	tint.a = p.opacity * from_alpha * to_alpha
	return tint

func _position(p: Sample, d: Dictionary) -> Vector3:
	var elapsed := maxf(_time - p.birth, 0.0)
	var drag := float(d.drag) * 9.0
	var travel := elapsed if drag < 0.001 else (1.0 - exp(-drag * elapsed)) / drag
	var point := p.position + p.velocity * travel + p.gravity * elapsed * elapsed * 0.5
	if _emitting and float(d.lock_until) != 0.0:
		var weight := 1.0 - smoothstep(0.0, maxf(d.lock_until, 0.6), elapsed / p.life)
		point += (_current_position - p.origin) * weight * 0.8
	return point

func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	var view := camera.global_basis.orthonormalized() if camera else Basis.IDENTITY
	var eye := camera.global_position - global_position if camera else Vector3.BACK * 10.0
	if _ribbon_alpha != null:
		_ribbon_alpha.clear_surfaces()
		_ribbon_add.clear_surfaces()
	_ribbon_open[0] = false
	_ribbon_open[1] = false
	_counts[0] = 0
	_counts[1] = 0
	_counts[2] = 0
	for layer in _layers:
		var d := layer.profile
		var index := int(d.additive and not d.smoke_mix)
		if d.kind == "ribbon":
			var mesh := _ribbon_add if index == 1 else _ribbon_alpha
			if mesh != null:
				_draw_ribbon(layer, mesh, eye, view, _ribbon_open, index)
		elif d.kind != "none":
			index = 2 if d.self_add else int(d.additive)
			var batch := _self_add if index == 2 else (_add if index == 1 else _alpha)
			if batch == null:
				continue
			for p in layer.samples:
				if _counts[index] >= _sprite_capacity:
					break
				if _draw_sprite(p, d, batch, _counts[index], view):
					_counts[index] += 1
	if _ribbon_open[0]:
		_ribbon_alpha.surface_end()
	if _ribbon_open[1]:
		_ribbon_add.surface_end()
	if _alpha != null:
		_alpha.visible_instance_count = _counts[0]
		_add.visible_instance_count = _counts[1]
		_self_add.visible_instance_count = _counts[2]

func _draw_sprite(p: Sample, d: Dictionary, batch: MultiMesh, index: int, view: Basis) -> bool:
	var age := clampf((_time - p.birth) / p.life, 0.0, 1.0)
	var tint := _tint(p, d, age)
	if d.kind == "arc":
		# Overlapping additive cards would otherwise clip all RGB channels to white.
		tint.a *= 0.48
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
	batch.set_instance_custom_data(index, Color(float(SHAPES[d.kind]) / 10.0, age, p.seed, clampf(d.gain / 8.0, 0.0, 1.0)))
	return true

func _draw_ribbon(layer: Layer, mesh: ImmediateMesh, eye: Vector3, view: Basis, opened: Array, index: int) -> void:
	var d := layer.profile
	_points.clear()
	_colors.clear()
	_widths.clear()
	for p in layer.samples:
		var age := clampf((_time - p.birth) / p.life, 0.0, 1.0)
		var point := _position(p, d)
		if not _points.is_empty() and point.distance_squared_to(_points[-1]) < 0.000001:
			continue
		_points.append(point)
		_colors.append(_tint(p, d, age))
		_widths.append(_radius(p, d, age))
	if _emitting and int(d.parent) < 0 and not _points.is_empty() and _points[-1].distance_squared_to(_current_position) > 0.000001:
		_points.append(_current_position)
		var head := _colors[-1]
		head.a *= 0.5
		_colors.append(head)
		_widths.append(_widths[-1] * 0.65)
	if _points.size() < 2:
		return
	_path.clear()
	_path_tints.clear()
	_path_sizes.clear()
	var subdivisions := clampi(int(d.subdivisions), 1, 6)
	for i in _points.size() - 1:
		for j in subdivisions:
			var f := float(j) / subdivisions
			var curved := _points[i].cubic_interpolate(_points[i + 1], _points[maxi(i - 1, 0)], _points[mini(i + 2, _points.size() - 1)], f)
			_path.append(curved)
			_path_tints.append(_colors[i].lerp(_colors[i + 1], f))
			_path_sizes.append(lerpf(_widths[i], _widths[i + 1], f))
	_path.append(_points[-1])
	_path_tints.append(_colors[-1])
	_path_sizes.append(_widths[-1])
	_lengths.clear()
	_lengths.append(0.0)
	for i in range(1, _path.size()):
		_lengths.append(_lengths[-1] + _path[i - 1].distance_to(_path[i]))
	var length := _lengths[-1]
	if length < 0.0001:
		return
	var last_side := Vector3.ZERO
	var last_left := Vector3.ZERO
	var last_right := Vector3.ZERO
	var scroll_speed := clampf(float(d.scroll) * 0.017, -3.0, 3.0)
	var tile_length := maxf(float(d.texel_size) * effect_scale, 0.1)
	var offset := fposmod(_time * scroll_speed, TAU)
	var last_u := offset
	for i in _path.size():
		var tangent := (_path[mini(i + 1, _path.size() - 1)] - _path[maxi(0, i - 1)]).normalized()
		var side := tangent.cross((eye - _path[i]).normalized()).normalized()
		if side.is_zero_approx():
			side = view.x
		if side.dot(last_side) < 0.0:
			side = -side
		last_side = side
		var left := _path[i] - side * _path_sizes[i]
		var right := _path[i] + side * _path_sizes[i]
		if i > 0:
			var u := offset + _lengths[i] / tile_length
			var start_fraction := _lengths[i - 1] / length
			var end_fraction := _lengths[i] / length
			if _path_tints[i].a > 0.004 or _path_tints[i - 1].a > 0.004:
				if not opened[index]:
					mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
					opened[index] = true
				_vertex(mesh, last_left, last_u, 0.0, _path_tints[i - 1], start_fraction)
				_vertex(mesh, last_right, last_u, 1.0, _path_tints[i - 1], start_fraction)
				_vertex(mesh, left, u, 0.0, _path_tints[i], end_fraction)
				_vertex(mesh, left, u, 0.0, _path_tints[i], end_fraction)
				_vertex(mesh, last_right, last_u, 1.0, _path_tints[i - 1], start_fraction)
				_vertex(mesh, right, u, 1.0, _path_tints[i], end_fraction)
			last_u = u
		last_left = left
		last_right = right

func _vertex(mesh: ImmediateMesh, point: Vector3, u: float, v: float, tint: Color, along: float) -> void:
	mesh.surface_set_color(tint)
	mesh.surface_set_uv(Vector2(u, v))
	mesh.surface_set_uv2(Vector2(along, 0.0))
	mesh.surface_add_vertex(point)
