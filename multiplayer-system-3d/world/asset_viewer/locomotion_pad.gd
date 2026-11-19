extends Control

## Continuous joystick for the asset viewer's locomotion preview.
##
## Drag inside the circle to set a direction (forward is (0, -1), Godot screen
## space).  The value is continuous — the AnimationTree blend spaces accept any
## direction, so there is no 8-way snapping.

signal direction_changed(direction: Vector2)

const RADIUS := 32.0
const KNOB := 11.0
const DEADZONE := 0.22

var _direction := Vector2(0.0, -1.0)
var _dragging := false


func _ready() -> void:
	custom_minimum_size = Vector2(84, 84)
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func set_direction(direction: Vector2) -> void:
	_direction = direction
	queue_redraw()


func get_direction() -> Vector2:
	return _direction


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_dragging = mb.pressed
		if mb.pressed:
			_apply_pointer(mb.position)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_apply_pointer(mm.position)
		accept_event()


func _apply_pointer(position: Vector2) -> void:
	var offset := position - size * 0.5
	var direction := Vector2.ZERO
	if offset.length() > RADIUS * DEADZONE:
		# Continuous, not 8-way: the real blend spaces accept any direction.
		direction = offset.normalized()
	if direction == _direction:
		return
	_direction = direction
	queue_redraw()
	direction_changed.emit(direction)


func _draw() -> void:
	var center := size * 0.5
	draw_circle(center, RADIUS, Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.92))
	draw_arc(center, RADIUS, 0.0, TAU, 48, UITheme.LINE_HI, 1.0, true)
	for i in 8:
		var angle := TAU * float(i) / 8.0
		var axis := Vector2(cos(angle), sin(angle))
		draw_line(center + axis * (RADIUS - 5.0), center + axis * (RADIUS - 2.0),
			UITheme.LINE_HI, 1.0)
	var knob := center + _direction * (RADIUS - KNOB - 3.0)
	var active := _direction.length_squared() > 0.0
	draw_circle(knob, KNOB, UITheme.TEAL if active else UITheme.MUTED)
	draw_arc(knob, KNOB, 0.0, TAU, 32, Color(0.0, 0.0, 0.0, 0.35), 1.0, true)
