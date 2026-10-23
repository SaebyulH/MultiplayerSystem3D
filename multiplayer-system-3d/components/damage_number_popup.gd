extends Control
class_name DamageNumberPopup

## A single floating damage or heal number.  Damage pops out the right side
## of the target, heals out the left side — so both are visible simultaneously.

## Weak reference to the player this number belongs to.  The popup lives for
## several seconds and its target is freed on a bot removal / disconnect, so a
## strong reference would dangle.  Godot 4.7 makes a freed reference compare
## `== null` and test falsy, but casting or dereferencing it still raises
## "Trying to cast a freed object" — so `WeakRef.get_ref()` (which yields null)
## is the only structurally safe way to hold it.
var _target_ref: WeakRef = null
var _world_pos: Vector3
var _offset: Vector3
var _value: float = 0.0
var _is_heal: bool = false
var _is_headshot: bool = false
var _is_backshot: bool = false
var _falloff_mult: float = 1.0
var _age: float = 0.0
var _lifetime: float = 4.0
var _fade_start: float = 0.4
var _max_float: float = 0.6   # max Y drift before freezing

const FALLOFF_VISIBLE_THRESHOLD := 0.995
const BOLD_FONT_PATH := "res://assets/CenturyGothic-Bold - Century Gothic - Bold.ttf"

var _bold_font: Font = null


## The target, if it is still alive; null once it has been freed.
func _live_target() -> Node3D:
	if _target_ref == null:
		return null
	var ref: Variant = _target_ref.get_ref()
	if not is_instance_valid(ref):
		return null
	return ref as Node3D


## True while this popup still belongs to [param node].  Used to merge a new
## hit into an existing popup; a freed target simply never matches.
func targets(node: Node3D) -> bool:
	return _live_target() == node


func setup(target: Node3D, value: float, is_heal: bool, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false) -> void:
	_target_ref = weakref(target)
	_world_pos = target.global_position
	_value = value
	_is_heal = is_heal
	_is_headshot = is_headshot
	_is_backshot = is_backshot
	_falloff_mult = falloff_mult
	_age = 0.0
	modulate = Color(1, 1, 1, 1)
	_reset_offset()
	_refresh_label()
	_refresh_falloff_label()


func add_value(value: float, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false) -> void:
	_value += value
	_age = 0.0
	_is_headshot = is_headshot
	_is_backshot = is_backshot
	_falloff_mult = falloff_mult
	var target := _live_target()
	if target != null and target.spawned:
		_world_pos = target.global_position
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
	elif _is_headshot or _is_backshot:
		color = Color(1.0, 0.85, 0.0)  # yellow for headshot/backshot crits
	else:
		color = Color(1.0, 0.2, 0.2)

	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", 36)
	_apply_damage_font(lbl)


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
		lbl.add_theme_font_size_override("font_size", 18)
		_apply_damage_font(lbl)
		add_child(lbl)
	return lbl


## Apply the bold Century Gothic font and a soft drop shadow (instead of an
## outline) so damage numbers pop against the world.
func _apply_damage_font(lbl: Label) -> void:
	if _bold_font == null:
		_bold_font = load(BOLD_FONT_PATH) as Font
	if _bold_font:
		lbl.add_theme_font_override("font", _bold_font)
	lbl.add_theme_constant_override("outline_size", 0)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.add_theme_constant_override("shadow_outline_size", 1)


func _process(delta: float) -> void:
	var target := _live_target()
	if target != null:
		if target.spawned:
			_world_pos = target.global_position
		else:
			# Dead or parked: stop tracking, leave the number at its last position.
			_target_ref = null
			target = null

	_age += delta

	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return

	var proj_pos: Vector3 = _world_pos + _offset
	var screen_pos: Vector2 = camera.unproject_position(proj_pos)
	if camera.is_position_behind(proj_pos):
		visible = false
		return
	# Hide when the target isn't currently "seen" by the viewer — occluded and
	# not revealed through a wallhack.
	var p := target as Player
	if p != null and not p._seen_by_local:
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
