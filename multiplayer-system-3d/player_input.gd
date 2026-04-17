extends Node
class_name PlayerInput

var input_dir: Vector2
var jump_input : bool
signal primary_fire


func _physics_process(delta: float) -> void:
	
	# If the local system controls this node, then we can control it
	if get_tree().get_multiplayer().has_multiplayer_peer() and is_multiplayer_authority():
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")

		if Input.is_action_just_pressed("ui_accept"):
			jump_input = true
		else:
			jump_input = false
		
		if Input.is_action_just_pressed("primary_fire"):
			primary_fire.emit()
		
