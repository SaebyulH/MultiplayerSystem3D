extends Control
class_name DamageNumberPopup

## A single floating damage or heal number.  Damage pops out the right side
## of the target, heals out the left side — so both are visible simultaneously.

var _target_node: Node3D = null
var _world_pos: Vector3
var _offset: Vector3
var _value: float = 0.0
var _is_heal: bool = false
var _is_headshot: bool = false
var _falloff_mult: float = 1.0
var _age: float = 0.0
var _lifetime: float = 4.0
var _fade_start: float = 0.4
var _max_float: float = 0.6   # max Y drift before freezing

const FALLOFF_VISIBLE_THRESHOLD := 0.995


func setup(target: Node3D, value: float, is_heal: bool, is_headshot: bool = false, falloff_mult: float = 1.0) -> void:
	_target_node = target
	_world_pos = target.global_position
	_value = value
	_is_heal = is_heal
	_is_headshot = is_headshot
	_falloff_mult = falloff_mult
	_age = 0.0
	modulate = Color(1, 1, 1, 1)
	_reset_offset()
	_refresh_label()
	_refresh_falloff_label()


func add_value(value: float, is_headshot: bool = false, falloff_mult: float = 1.0) -> void:
	_value += value
	_age = 0.0
	_is_headshot = is_headshot
	_falloff_mult = falloff_mult
	if _target_node and is_instance_valid(_target_node) and _target_node.spawned:
		_world_pos = _target_node.global_position
	_reset_offset()
	_refresh_label()
	_refresh_falloff_label()


func _reset_offset() -> void:
	# Damage → right, heal → left.  Vertical at body centre with slight randomness.
	var side: float = 0.8 if _is_heal else -0.8
	_offset = Vector3(side + randf_range(-0.2, 0.2), 1.0 + randf_range(-0.2, 0.2), 0)


func _refresh_label() -> void:
	var lbl: Label = _get_label()
	if lbl == null:
		return
	lbl.text = ("+%d" if _is_heal else "-%d") % int(abs(_value))

	var color: Color
	if _is_heal:
		color = Color(0.25, 0.95, 0.25)
	elif _is_headshot:
		color = Color(1.0, 0.85, 0.0)  # yellow for headshot crits
	else:
		color = Color(1.0, 0.2, 0.2)

	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.add_theme_font_size_override("font_size", 36)


func _refresh_falloff_label() -> void:
	var lbl: Label = _get_falloff_label()
	if lbl == null:
		return
	# Only show when falloff meaningfully reduced the damage.
	if _falloff_mult < FALLOFF_VISIBLE_THRESHOLD:
		lbl.text = "(×%.2f)" % _falloff_mult
		lbl.visible = true
		# Position the falloff label to the right of the main label.
		var main: Label = _get_label()
		if main:
			lbl.position = main.position + Vector2(main.size.x + 4.0, main.size.y - lbl.size.y)
	else:
		lbl.visible = false


func _get_label() -> Label:
	return get_node_or_null("Label") as Label


func _get_falloff_label() -> Label:
	var lbl: Label = get_node_or_null("FalloffLabel") as Label
	if lbl == null:
		lbl = Label.new()
		lbl.name = "FalloffLabel"
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_color_override("font_color", Color.WHITE)
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		lbl.add_theme_constant_override("outline_size", 3)
		lbl.add_theme_font_size_override("font_size", 18)
		add_child(lbl)
	return lbl


func _process(delta: float) -> void:
	if _target_node != null and is_instance_valid(_target_node):
		if _target_node.spawned:
			_world_pos = _target_node.global_position
		else:
			_target_node = null

	_age += delta

	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return

	var proj_pos: Vector3 = _world_pos + _offset
	var screen_pos: Vector2 = camera.unproject_position(proj_pos)
	if camera.is_position_behind(proj_pos):
		visible = false
		return
	visible = true

	position = screen_pos - size * 0.5

	# Float upward but cap so it doesn't drift too far.
	var prev_y: float = _offset.y
	_offset.y += 1.0 * delta
	_offset.y = minf(_offset.y, prev_y + _max_float)

	var progress: float = _age / _lifetime
	if progress > _fade_start:
		modulate = Color(1, 1, 1, clampf(1.0 - (progress - _fade_start) / (1.0 - _fade_start), 0.0, 1.0))

	if _age >= _lifetime:
		queue_free()
