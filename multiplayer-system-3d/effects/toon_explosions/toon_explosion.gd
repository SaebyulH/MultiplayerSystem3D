extends Node3D
## Data-driven, visual-only one-shot effects with original procedural artwork.

signal finished

const Profiles := preload("explosion_profiles.gd")
const ALPHA := preload("../rocket_impact/rocket_impact.gdshader")
const ADD := preload("../rocket_impact/rocket_impact_add.gdshader")
const SELF_ADD := preload("../rocket_impact/rocket_impact_self_add.gdshader")
const ROPE_SHADER := preload("explosion_rope.gdshader")
const CENTER_SHADER := preload("impact_center.gdshader")
const REFERENCE_HZ := 60.0
const CAPACITY := 1024
const OPEN_ENDED_PREVIEW_DURATION := 2.5
const SOURCE_UNITS_TO_GODOT := 0.0125

@export var auto_free := true
@export var source_informed := true
enum PreviewLayer { ALL, SMOKE, FLAME, DEBRIS_AND_SPARKS }
var preview_layer := PreviewLayer.ALL
@export_range(0.05, 20.0, 0.01, "or_greater") var effect_scale := 1.0
## Preview-only playback multiplier (the asset viewer's speed slider).  Gameplay
## never changes it, so it stays at 1.0 in every explosion.
@export_range(0.05, 4.0, 0.01) var speed_scale := 1.0
## Colour saturation applied after the palette/tint math.  The Filmic tonemap
## desaturates bright additive layers toward white, so >1 restores the authored
## hue without changing the shapes, layer weights or timing.
@export_range(0.0, 3.0, 0.05) var saturation := 1.45
## Multiplied with every particle and palette colour, so one calibrated preset
## can carry a weapon's colour (heal green, poison purple) without duplicating
## the graph.  Set before adding the scene to the tree.
@export var tint := Color.WHITE

class Layer:
	var data: Dictionary
	var parent: Layer
	var start := 0.0
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
static var _palette: ImageTexture
## Finished gameplay explosions are recycled instead of freed: `_ready()` is the
## expensive part (four 1024-instance MultiMesh batches + rope material).
const POOL_LIMIT := 24
static var _pool: Array = []

## A finished gameplay explosion, or null.  Detach-only; the caller re-parents
## and calls `play()`.  The asset viewer sets `auto_free = false` and owns its.
static func acquire() -> Node3D:
	while not _pool.is_empty():
		var node := _pool.pop_back() as Node3D
		if not is_instance_valid(node):
			continue
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		return node
	return null

var _rng := RandomNumberGenerator.new()
var _particles: Array[Particle] = []
var _layers: Array[Layer] = []
var _events: Array[Emission] = []
var _alpha: MultiMesh
var _add: MultiMesh
var _self_add: MultiMesh
var _center: MultiMesh
var _sprite_materials: Array[ShaderMaterial] = []
var _rope := ImmediateMesh.new()
var _normal := Vector3.UP
var _impact_basis := Basis.IDENTITY
var _world_basis := Basis.IDENTITY
var _units := SOURCE_UNITS_TO_GODOT
var _time := 0.0
var _next := 0

static func _load_profiles() -> void:
	if _profiles.is_empty():
		_profiles = JSON.parse_string(Profiles.JSON_DATA)
		var samples: Array = _profiles.palette
		var image := Image.create_empty(samples.size(), 3, false, Image.FORMAT_RGBA8)
		for column in samples.size():
			for band in 3:
				var rgb: Array = samples[column][band]
				image.set_pixel(column, band, Color8(int(rgb[0]), int(rgb[1]), int(rgb[2])))
		_palette = ImageTexture.create_from_image(image)

static func effect_catalog() -> Array:
	_load_profiles()
	return _profiles.catalog.duplicate(true)

func _ready() -> void:
	top_level = true
	_load_profiles()
	_alpha = _make_batch(ALPHA, 0)
	_add = _make_batch(ADD, 2)
	_self_add = _make_batch(SELF_ADD, 1)
	_center = _make_batch(CENTER_SHADER, 0)
	var rope_instance := MeshInstance3D.new()
	rope_instance.mesh = _rope
	var material := ShaderMaterial.new()
	material.shader = ROPE_SHADER
	material.render_priority = 1
	material.set_shader_parameter("saturation", saturation)
	material.set_shader_parameter("color_tint", Vector3(tint.r, tint.g, tint.b))
	rope_instance.material_override = material
	rope_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rope_instance)
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
	for material in _sprite_materials:
		material.set_shader_parameter("preserve_tint", source_informed)
	var size := Vector3.ONE * (128.0 * maxf(effect_scale, 0.01))
	_alpha.custom_aabb = AABB(-size, 2.0 * size)
	_add.custom_aabb = _alpha.custom_aabb
	_self_add.custom_aabb = _alpha.custom_aabb
	_center.custom_aabb = _alpha.custom_aabb
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
	if shader != CENTER_SHADER:
		material.set_shader_parameter("self_add", shader == SELF_ADD)
		material.set_shader_parameter("preserve_tint", source_informed)
		material.set_shader_parameter("saturation", saturation)
		material.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
		_sprite_materials.append(material)
	else:
		material.set_shader_parameter("frame_palette", _palette)
		material.set_shader_parameter("saturation", saturation)
		material.set_shader_parameter("color_tint", Vector3(tint.r, tint.g, tint.b))
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
	layer.start = start
	_layers.append(layer)
	var budget := int(layer.data.max)
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
			var count := mini(roundi(rate * duration), 4000)
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
	for remap: Dictionary in d.alpha_birth_remaps:
		var birth := event.time - layer.start
		var lo := float(remap["input minimum"])
		var hi := float(remap["input maximum"])
		if remap["only active within specified input range"] and (birth < lo or birth > hi):
			continue
		var value := lerpf(remap["output minimum"], remap["output maximum"], _phase(lo, hi, birth))
		if remap["output is scalar of initial random range"]:
			p.alpha *= value
		else:
			p.alpha = clampf(value, 0.0, 1.0)
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
	elif layer.parent == null and d.parent_source:
		# Isolated preview of a child emitter that normally samples a moving parent.
		p.position += _impact_basis * Vector3(0.3, 1.6, 0.0) * (event.time - layer.start) * effect_scale
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
		if source_informed and d.get("body_drag", false):
			# Interpret the normalized drag as a per-reference-tick retention loss.
			# At any integration step use the equivalent continuous decay.
			drag = -REFERENCE_HZ * log(1.0 - clampf(d.drag, 0.0, 0.98))
		var velocity_weight := delta if drag < 0.001 else (1.0 - exp(-drag * delta)) / drag
		var gravity_weight := 0.5 * delta * velocity_weight
		if source_informed and drag >= 0.001:
			gravity_weight = (delta - velocity_weight) / drag
		p.position += p.velocity * velocity_weight + p.gravity * gravity_weight
		p.velocity = p.velocity * exp(-drag * delta) + p.gravity * velocity_weight
		var depth := p.position.dot(_normal)
		if d.bounce >= 0.0 and depth < _units:
			p.position += _normal * (_units - depth)
			var inward := p.velocity.dot(_normal)
			if inward < 0.0:
				p.velocity -= (1.0 + clampf(d.bounce, 0.0, 1.0)) * inward * _normal

func _process(delta: float) -> void:
	_advance(_time + delta * speed_scale)
	_draw()
	if _particles.is_empty() and _next == _events.size():
		set_process(false)
		finished.emit()
		if auto_free:
			_recycle()


## Stop and park this explosion for the next detonation.  Buffers and materials
## stay; `play()` resets the simulation and transform.
func _recycle() -> void:
	_clear_simulation()
	_time = 0.0
	_next = 0
	_rope.clear_surfaces()
	for batch in [_alpha, _add, _self_add, _center]:
		if batch != null:
			batch.visible_instance_count = 0
	if _pool.size() < POOL_LIMIT:
		_pool.append(self)
	else:
		queue_free()

func _phase(from: float, to: float, t: float) -> float:
	if to <= from:
		return 1.0 if t >= to else 0.0
	return clampf((t - from) / (to - from), 0.0, 1.0)

func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	var view := camera.global_basis.orthonormalized() if camera else Basis.IDENTITY
	var visible: Array[Particle] = []
	for p in _particles:
		if not p.layer.data.draw:
			continue
		var pass_group := _preview_group(p.layer.data)
		if preview_layer == PreviewLayer.ALL or preview_layer == pass_group:
			visible.append(p)
	visible.sort_custom(func(a: Particle, b: Particle) -> bool:
		return view.z.dot(a.position) < view.z.dot(b.position)
	)
	if preview_layer in [PreviewLayer.ALL, PreviewLayer.DEBRIS_AND_SPARKS]:
		_draw_ropes(view)
	else:
		_rope.clear_surfaces()
	var batches: Array[MultiMesh] = [_alpha, _add, _self_add, _center]
	var counts := [0, 0, 0, 0]
	for p in visible:
		if source_informed and p.layer.data.has("center_card"):
			if counts[3] < CAPACITY and _draw_center_card(p, p.layer.data.center_card, counts[3], view):
				counts[3] += 1
			continue
		for draw_pass: Dictionary in p.layer.data.passes:
			var mode := int(draw_pass.mode)
			if int(draw_pass.shape) == 10 or counts[mode] >= CAPACITY:
				continue
			if _draw_particle(batches[mode], counts[mode], p, draw_pass, view):
				counts[mode] += 1
	for index in batches.size():
		batches[index].visible_instance_count = counts[index]

func _preview_group(data: Dictionary) -> PreviewLayer:
	if data.has("center_card"):
		return PreviewLayer.SMOKE if int(data.center_card.style) < 2 else PreviewLayer.FLAME
	return PreviewLayer.DEBRIS_AND_SPARKS

func _draw_center_card(p: Particle, profile: Dictionary, index: int, view: Basis) -> bool:
	var elapsed := maxf(0.0, _time - p.birth)
	var age := clampf(elapsed / p.life, 0.0, 1.0)
	var d := p.layer.data
	var sequences: Array = profile.sequences
	var sequence: Dictionary = sequences[mini(int(p.seed * sequences.size()), sequences.size() - 1)]
	var frames: Array = sequence.frames
	var rate := float(profile.fps)
	if not profile.rate_is_fps:
		rate *= frames.size()
	var frame := age * float(frames.size()) if profile.fit else elapsed * rate
	frame = clampf(frame, 0.0, float(frames.size() - 1))
	var base := int(frame)
	var part := fposmod(frame, 1.0) if profile.interpolate else 0.0
	var a: Array = frames[base]
	var b: Array = frames[mini(base + 1, frames.size() - 1)]
	var tint := _particle_tint(p, d, age)
	var radius := _particle_radius(p, d, age)
	var width := lerpf(a[1], b[1], part)
	var height := lerpf(a[0], b[0], part)
	var occupancy := lerpf(a[2], b[2], part)
	# Coverage is the mean alpha over the full frame. Normalize by its bounds
	# before applying the footprint so thinning is accounted for only once.
	tint.a *= clampf(occupancy / maxf(0.018, width * height * 0.75), 0.0, 1.0)
	if tint.a < 0.008:
		return false
	var roll := p.angle + p.spin * elapsed
	var facing := view * Basis(Vector3.BACK, roll)
	var scale_value := Vector3(maxf(width, 0.06), maxf(height, 0.06), 1.0) * radius
	_center.set_instance_transform(index, Transform3D(facing.scaled_local(scale_value), p.position))
	_center.set_instance_color(index, tint)
	var palette_u := (float(sequence.start) + float(base) + part + 0.5) / float(_palette.get_width())
	var mode := int(profile.style) * 3 + int(profile.blend)
	# Reserve room within each mode for the material's overbright parameter.
	var overbright := clampf(log(maxf(float(d.passes[0].gain), 1.0)) / log(8.0), 0.0, 1.0)
	var style_and_blend := (float(mode) + 0.125 + 0.75 * overbright) / 12.0
	_center.set_instance_custom_data(index, Color(style_and_blend, age, p.seed, palette_u))
	return true

func _draw_ropes(view: Basis) -> void:
	_rope.clear_surfaces()
	var open := false
	for layer in _layers:
		if layer.particles.size() < 2 or not layer.data.passes.any(func(pass_data: Dictionary) -> bool:
			return int(pass_data.shape) == 10
		):
			continue
		var path := layer.particles
		var distances := PackedFloat32Array([0.0])
		for i in range(1, path.size()):
			distances.append(distances[-1] + path[i - 1].position.distance_to(path[i].position))
		var length := distances[-1]
		if length < 0.0001:
			continue
		var texture_scale := maxf(effect_scale, 0.01)
		var last_side := Vector3.ZERO
		for i in path.size() - 1:
			var a := path[i]
			var b := path[i + 1]
			var previous := path[maxi(i - 1, 0)].position
			var following := path[mini(i + 2, path.size() - 1)].position
			var axis_a := (b.position - previous).cross(view.z).normalized()
			var axis_b := (following - a.position).cross(view.z).normalized()
			if axis_a.is_zero_approx():
				axis_a = view.x
			if axis_b.is_zero_approx():
				axis_b = axis_a
			if axis_a.dot(last_side) < 0.0:
				axis_a = -axis_a
			if axis_b.dot(axis_a) < 0.0:
				axis_b = -axis_b
			var age_a := clampf((_time - a.birth) / a.life, 0.0, 1.0)
			var age_b := clampf((_time - b.birth) / b.life, 0.0, 1.0)
			var col_a := _particle_tint(a, layer.data, age_a)
			var col_b := _particle_tint(b, layer.data, age_b)
			last_side = axis_b
			var u := distances[i] / texture_scale
			var next_u := distances[i + 1] / texture_scale
			var start_fraction := distances[i] / length
			var end_fraction := distances[i + 1] / length
			if maxf(col_a.a, col_b.a) >= 0.008 and next_u > u:
				if not open:
					_rope.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
					open = true
				var side_a := axis_a * _particle_radius(a, layer.data, age_a)
				var side_b := axis_b * _particle_radius(b, layer.data, age_b)
				_rope_vertex(a.position - side_a, Vector2(u, 0.0), col_a, start_fraction)
				_rope_vertex(a.position + side_a, Vector2(u, 1.0), col_a, start_fraction)
				_rope_vertex(b.position - side_b, Vector2(next_u, 0.0), col_b, end_fraction)
				_rope_vertex(b.position - side_b, Vector2(next_u, 0.0), col_b, end_fraction)
				_rope_vertex(a.position + side_a, Vector2(u, 1.0), col_a, start_fraction)
				_rope_vertex(b.position + side_b, Vector2(next_u, 1.0), col_b, end_fraction)
	if open:
		_rope.surface_end()

func _rope_vertex(point: Vector3, uv: Vector2, tint: Color, along: float) -> void:
	_rope.surface_set_uv(uv)
	_rope.surface_set_uv2(Vector2(along, 0.0))
	_rope.surface_set_color(tint)
	_rope.surface_add_vertex(point)

func _particle_tint(p: Particle, d: Dictionary, age: float) -> Color:
	var tint := p.color
	var blend: Dictionary = d.color_fade
	if not blend.is_empty():
		var t := _phase(blend.fade_start_time, blend.fade_end_time, age)
		tint = tint.lerp(_color(blend.color_fade), smoothstep(0.0, 1.0, t) if d.color_ease else t)
	var fade: Dictionary = d.fade
	var opacity := p.alpha
	if not fade.is_empty():
		var up := _phase(fade.start_fade_in_time, fade.end_fade_in_time, age)
		var down := _phase(fade.start_fade_out_time, fade.end_fade_out_time, age)
		opacity *= lerpf(fade.start_alpha, 1.0, smoothstep(0.0, 1.0, up))
		opacity *= lerpf(1.0, fade.end_alpha, smoothstep(0.0, 1.0, down))
	if d.get("electrical", false):
		var flicker := sin(TAU * (age * lerpf(4.0, 8.0, p.seed) + 0.5))
		opacity *= 0.69 + 0.31 * flicker
	tint.a = clampf(opacity, 0.0, 1.0)
	return tint

func _particle_radius(p: Particle, d: Dictionary, age: float) -> float:
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
	return clampf(p.radius * scale_value, 0.0001, _units * 510.0)

func _draw_particle(batch: MultiMesh, index: int, p: Particle, draw_pass: Dictionary, view: Basis) -> bool:
	var d := p.layer.data
	var age := clampf((_time - p.birth) / p.life, 0.0, 1.0)
	var tint := _particle_tint(p, d, age)
	if tint.a < 0.008:
		return false
	var size := _particle_radius(p, d, age)
	var width := size
	var height := size
	var shape := int(draw_pass.shape)
	if shape == 8:
		var vibration := sin(TAU * (age * lerpf(8.0, 9.0, p.seed) + 0.5))
		width *= (0.88 + vibration * 0.18) * 0.85
		height *= 1.24 + vibration * 0.23
	var frame := view
	var angle := p.angle + p.spin * (age * p.life)
	var position := p.position
	if shape == 0 and int(draw_pass.orientation) != 0:
		frame = Basis(_impact_basis.y, _impact_basis.z, _normal)
	elif shape in [3, 9]:
		var projected := Vector2(p.velocity.dot(view.x), p.velocity.dot(view.y))
		var speed := projected.length()
		var stretch := p.length * 0.7 + speed * 0.09
		var min_length := float(draw_pass.min_length) * _units
		var max_length := float(draw_pass.max_length) * _units
		var ramp := _phase(0.0, draw_pass.length_fade, _time - p.birth)
		height = clampf(stretch, min_length, max_length) * 0.5 * ramp
		if shape == 9:
			height = maxf(height, size * 1.9)
			width *= 0.89
		else:
			# Size curves control thickness. The renderer's length fade
			# controls travel along the streak, including at birth.
			if height < _units * 0.16:
				return false
			width = minf(size * 0.48, height * float(d.get("streak_aspect", 0.22)))
		if speed > 0.10:
			angle = atan2(-projected.x, projected.y)
			var direction := projected.normalized()
			position -= (view.x * direction.x + view.y * direction.y) * minf(height * 0.38, 0.45 * effect_scale)
	var axes := frame * Basis(Vector3.BACK, angle) * Basis.from_scale(Vector3(width, height, size))
	batch.set_instance_transform(index, Transform3D(axes, position))
	batch.set_instance_color(index, tint)
	batch.set_instance_custom_data(index, Color(float(shape) / 16.0, age, p.seed, clampf(draw_pass.gain / 8.0, 0.0, 1.0)))
	return true
