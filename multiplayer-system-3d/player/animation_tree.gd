extends AnimationTree


# Blend-tree layout:
#   air (AnimationNodeBlend2) ──→ output
#     ├─ Input 0: Blend3 (ground: crouch / walk / sprint)
#     └─ Input 1: Animation (air / jump)
#
#   Blend3 blend_amount:  -1 = crouch   0 = walk   1 = sprint
#   air    blend_amount:   0 = ground   1 = air

const BLEND_TRANSITION_SPEED: float = 10.0


func _process(delta: float) -> void:
	var body: Node3D = $".."
	var player: CharacterBody3D = $"../.."
	var local_vel: Vector3 = body.global_transform.basis.inverse() * player.velocity

	var blend_vec := Vector2(local_vel.x, local_vel.z)

	if blend_vec.length_squared() > 0.0:
		blend_vec /= max(abs(blend_vec.x), abs(blend_vec.y))
	
	#print(blend_vec)

	# Push the same directional input to all three blend spaces so whichever
	# one is active already has the correct blend position.
	set("parameters/CrouchBlendSpace/blend_position", blend_vec)
	set("parameters/WalkBlendSpace/blend_position", blend_vec)
	set("parameters/SprintBlendSpace/blend_position", blend_vec)

	# ── Ground-state selection (Blend3) ──────────────────────────────
	var is_crouching: bool = player.is_crouching
	var is_on_floor: bool = player.is_on_floor()
	var h_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	var is_sprinting: bool = (
		is_on_floor
		and not is_crouching
		and not player.ads
		and h_speed > Player.NORMAL_SPEED * 0.85
	)

	var target_ground: float = 0.0   # default: walk / idle
	if is_crouching:
		target_ground = -1.0           # crouch
	elif is_sprinting:
		target_ground = 1.0            # sprint

	var current_ground: float = get("parameters/CrouchWalkSprintBlend3/blend_amount")
	set("parameters/CrouchWalkSprintBlend3/blend_amount", move_toward(current_ground, target_ground, BLEND_TRANSITION_SPEED * delta))

	# ── Air blend ─────────────────────────────────────────────────────
	# Only go to air when actually airborne and not crouching — crouch
	# takes priority so the crouch animation isn't interrupted by brief
	# floor-state flickers.
	var target_air: float = 1.0 if (not is_on_floor and not is_crouching) else 0.0
	var current_air: float = get("parameters/JumpBlend/blend_amount")
	set("parameters/JumpBlend/blend_amount", move_toward(current_air, target_air, BLEND_TRANSITION_SPEED * delta))
