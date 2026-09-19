class_name AbilityCircle
extends Control

## Circular ability indicator with a fill-up cooldown pie.
##
## The ability name is drawn via a child Label (set its font from the caller).
## The circle background and the clockwise cooldown pie are drawn in _draw().
##
## Cooldown semantics are "fill up": while on cooldown the circle is dimmed and
## a bright pie wedge grows clockwise with the elapsed fraction; when the
## cooldown is complete (fraction == 1) the circle reads as ready (bright).

const BASE_DIAMETER := 64.0
const ACTIVE_DIAMETER := 76.0

var name_label: Label

## 0..1 elapsed cooldown fraction (1 = ready).
var cooldown_fraction := 0.0
var on_cooldown := false
var active := false


func _init() -> void:
	custom_minimum_size = Vector2(BASE_DIAMETER, BASE_DIAMETER)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	name_label = Label.new()
	name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_constant_override("outline_size", 0)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(name_label)


func set_ability_name(text: String) -> void:
	name_label.text = text


func set_cooldown(fraction: float, is_cd: bool) -> void:
	cooldown_fraction = clampf(fraction, 0.0, 1.0)
	on_cooldown = is_cd
	queue_redraw()


func set_active(a: bool) -> void:
	active = a
	var d := ACTIVE_DIAMETER if a else BASE_DIAMETER
	custom_minimum_size = Vector2(d, d)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 2.0

	# Background disc: dim while cooling, bright when ready/active.
	if on_cooldown:
		draw_circle(center, radius, Color(0.12, 0.12, 0.12, 0.55))
	elif active:
		draw_circle(center, radius, Color(1.0, 1.0, 1.0, 0.9))
	else:
		draw_circle(center, radius, Color(0.30, 0.30, 0.30, 0.55))

	# Fill-up pie: bright wedge grows clockwise from the top as it readies.
	if on_cooldown and cooldown_fraction > 0.0 and cooldown_fraction < 1.0:
		var from := -PI * 0.5
		var sweep := cooldown_fraction * TAU
		var pts := PackedVector2Array([center])
		var steps := 32
		for i in steps + 1:
			var ang := from + sweep * float(i) / float(steps)
			pts.append(center + Vector2(cos(ang), sin(ang)) * radius)
		draw_colored_polygon(pts, Color(1.0, 1.0, 1.0, 0.35))
