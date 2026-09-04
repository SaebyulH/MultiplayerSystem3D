extends AnimationTree
# Blend-tree layout:
#   air (AnimationNodeBlend2) ──→ output
#     ├─ Input 0: Blend3 (ground: crouch / walk / sprint)
#     └─ Input 1: Animation (air / jump)
#
#   Blend3 blend_amount:  -1 = crouch   0 = walk   1 = sprint
#   air    blend_amount:   0 = ground   1 = air

# Exponential smoothing rates (higher = snappier). Unlike move_toward's
# constant speed, these give a fast initial response that eases into the
# target — feels responsive on input but never abrupt on arrival.
const DIRECTION_SMOOTH_RATE: float = 18.0
const SPRINT_ENTER_RATE: float = 14.0
const CROUCH_ENTER_RATE: float = 9.0
const CROUCH_RETURN_RATE: float = 7.0
const AIR_ENTER_RATE: float = 16.0
const AIR_EXIT_RATE: float = 10.0

var _blend_vec: Vector2 = Vector2.ZERO


func _process(delta: float) -> void:
	var body: Node3D = $".."
	var player: CharacterBody3D = $"../.."
	var local_vel: Vector3 = body.global_transform.basis.inverse() * player.velocity
	var target_vec := Vector2(local_vel.x, local_vel.z)
	if target_vec.length_squared() > 0.0:
		target_vec /= max(abs(target_vec.x), abs(target_vec.y))

	# Smooth the directional input itself so quick direction changes
	# (e.g. strafe reversals) blend instead of popping.
	_blend_vec = _smooth_towards_vec(_blend_vec, target_vec, DIRECTION_SMOOTH_RATE, delta)

	# Push the same directional input to all three blend spaces so whichever
	# one is active already has the correct blend position.
	set("parameters/CrouchBlendSpace/blend_position", _blend_vec)
	set("parameters/WalkBlendSpace/blend_position", _blend_vec)
	set("parameters/SprintBlendSpace/blend_position", _blend_vec)

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

	var target_ground: float = 0.0
	if is_crouching:
		target_ground = -1.0
	elif is_sprinting:
		target_ground = 1.0

	var current_ground: float = get("parameters/CrouchWalkSprintBlend3/blend_amount")

	# Pick a rate based on which transition is happening: crouch has its
	# own smoother entry and an even gentler return, sprint keeps its
	# punchier default rate.
	var ground_rate: float = SPRINT_ENTER_RATE
	if target_ground < 0.0:
		ground_rate = CROUCH_ENTER_RATE
	elif current_ground < 0.0 and target_ground >= 0.0:
		ground_rate = CROUCH_RETURN_RATE

	set(
		"parameters/CrouchWalkSprintBlend3/blend_amount",
		_smooth_towards(current_ground, target_ground, ground_rate, delta)
	)

	# ── Air blend ─────────────────────────────────────────────────────
	# Only go to air when actually airborne and not crouching — crouch
	# takes priority so the crouch animation isn't interrupted by brief
	# floor-state flickers.
	var target_air: float = 1.0 if (not is_on_floor and not is_crouching) else 0.0
	var current_air: float = get("parameters/JumpBlend/blend_amount")
	# Snap into the air pose quickly (jump should feel immediate) but
	# land a bit more gently.
	var air_rate: float = AIR_ENTER_RATE if target_air > current_air else AIR_EXIT_RATE
	set(
		"parameters/JumpBlend/blend_amount",
		_smooth_towards(current_air, target_air, air_rate, delta)
	)


## Frame-rate-independent exponential smoothing. Reacts fast to a change in
## target but decelerates naturally as it approaches it, instead of moving
## at move_toward's constant linear speed.
func _smooth_towards(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


func _smooth_towards_vec(current: Vector2, target: Vector2, rate: float, delta: float) -> Vector2:
	return current.lerp(target, 1.0 - exp(-rate * delta))
