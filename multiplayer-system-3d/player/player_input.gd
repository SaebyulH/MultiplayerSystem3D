extends Node
class_name PlayerInput
var input_dir: Vector2
var body_rotation_y: float = 0.0
var head_rotation_x: float = 0.0
#var recoil_rotation: Vector3 = Vector3.ZERO



var jump_input: bool
signal primary_fire  # fires every frame the button is held
signal primary_fire_just_pressed  # fires only on initial press
const MOUSE_SENS_X: float = 0.002
const MOUSE_SENS_Y: float = 0.002
signal primary_fire_released



func _physics_process(delta: float) -> void:
	if get_tree().get_multiplayer().has_multiplayer_peer() and is_multiplayer_authority():
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		
		if Input.is_action_pressed("ui_accept"):
			jump_input = true
		else:
			jump_input = false
		if Input.is_action_just_pressed("primary_fire"):
			if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			primary_fire_just_pressed.emit()
		if Input.is_action_pressed("primary_fire"):
			if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			primary_fire.emit()
		if Input.is_action_just_released("primary_fire"):
			primary_fire_released.emit()

func _input(event):
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if not is_multiplayer_authority():
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		body_rotation_y -= event.relative.x * MOUSE_SENS_X
		head_rotation_x -= event.relative.y * MOUSE_SENS_Y
		head_rotation_x = clamp(head_rotation_x, -PI / 2, PI / 2)
