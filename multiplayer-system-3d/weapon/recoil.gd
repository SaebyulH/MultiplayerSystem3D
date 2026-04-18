extends Node3D

# Rotations
var current_rotation : Vector3
var target_rotation : Vector3

# Recoil vectors
@export var recoil : Vector3
@export var aim_recoil : Vector3

# Settings
@export var snappiness : float
@export var return_speed : float

func _process(delta):
	# Lerp target rotation to (0,0,0) and lerp current rotation to target rotation
	target_rotation = lerp(target_rotation, Vector3.ZERO, return_speed * delta)
	current_rotation = lerp(current_rotation, target_rotation, snappiness * delta)
	
	# Set rotation
	rotation = current_rotation
	
	# Camera z axis tilt fix, ignored if tilt intentional
	# I have no idea why it tilts if recoil.z is set to 0
	if recoil.z == 0 and aim_recoil.z == 0:
		global_rotation.z = 0

@rpc("any_peer", "call_local", "reliable")
func recoilFire(isAiming : bool = false):
	if isAiming:
		target_rotation += Vector3(aim_recoil.x, randf_range(-aim_recoil.y, aim_recoil.y), randf_range(-aim_recoil.z, aim_recoil.z))
	else:
		target_rotation += Vector3(recoil.x, randf_range(-recoil.y, recoil.y), randf_range(-recoil.z, recoil.z))

func setRecoil(newRecoil : Vector3):
	recoil = newRecoil

func setAimRecoil(newRecoil : Vector3):
	aim_recoil = newRecoil
