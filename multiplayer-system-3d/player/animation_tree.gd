extends AnimationTree


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	# This tree lives under Body, which holds the mouse-look yaw. Express the
	# player's velocity in Body-local space so the directional walk animations
	# are picked relative to where the body is actually facing (and the rig's
	# 180° flip cancels out). forward = Body -Z -> (0, -1) = walk_w, etc.
	var body: Node3D = $".."                  # Body
	var player: CharacterBody3D = $"../.."    # Player
	var local_vel: Vector3 = body.global_transform.basis.inverse() * player.velocity
	var blend_vec := Vector2(local_vel.x, local_vel.z).normalized()
	set("parameters/BlendSpace2D/blend_position", blend_vec)
