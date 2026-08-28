extends Camera3D
## The head-bone attachment the camera/weapon assembly follows.
## Assigned by Player._spawn_character_model when the character model spawns.
@export var bone_attachment: Node3D


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if bone_attachment:
		global_position = bone_attachment.global_position
