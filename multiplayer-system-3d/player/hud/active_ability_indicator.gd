class_name ActiveAbilityIndicator
extends Control

## Circular readout for a *running* action ability (shoulder charge, bashdown,
## noclip, heal channel).  The ability icon sits in a dark disc; a ring around it
## drains clockwise from the top as the ability's remaining time runs out.
##
## Drawn rather than composed from nodes so the icon and ring stay welded to the
## disc at any size, like AbilityCircle.  PlayerBodyUI positions and feeds it;
## it holds no game state of its own.

const DIAMETER := 72.0
const RING_WIDTH := 4.0

var icon: Texture2D = null
## Remaining fraction, 1.0 = just started, 0.0 = ending.
var remaining_fraction := 1.0

var _ring_color := Color(0.176, 0.831, 0.749, 1.0)


func _init() -> void:
	custom_minimum_size = Vector2(DIAMETER, DIAMETER)
	size = Vector2(DIAMETER, DIAMETER)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_state(new_icon: Texture2D, fraction: float) -> void:
	icon = new_icon
	remaining_fraction = clampf(fraction, 0.0, 1.0)
	# TEAL normally, AMBER in the last half, RED in the last fifth — the same
	# meaning as the leaderboard ping colours (healthy / warning / urgent).
	if remaining_fraction <= 0.2:
		_ring_color = Color(1, 0.275, 0.333, 1.0)
	elif remaining_fraction <= 0.5:
		_ring_color = Color(1, 0.76, 0.29, 1.0)
	else:
		_ring_color = Color(0.176, 0.831, 0.749, 1.0)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - RING_WIDTH
	draw_circle(center, radius, Color(0.043, 0.055, 0.075, 0.88))
	draw_arc(center, radius, 0.0, TAU, 64, Color(0.165, 0.196, 0.239, 0.9),
		RING_WIDTH, true)
	var sweep := remaining_fraction * TAU
	if sweep > 0.001:
		draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + sweep, 64,
			_ring_color, RING_WIDTH, true)
	_draw_icon(center, radius)


func _draw_icon(center: Vector2, radius: float) -> void:
	if icon == null:
		return
	var tex_size := icon.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var box := (radius - RING_WIDTH) * 1.6
	var scale := minf(box / tex_size.x, box / tex_size.y)
	var draw_size := tex_size * scale
	draw_texture_rect(icon, Rect2(center - draw_size * 0.5, draw_size), false,
		Color(1, 1, 1, 0.95))
