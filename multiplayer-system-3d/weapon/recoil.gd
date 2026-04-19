extends Node3D
class_name Recoil

var current_rotation : Vector3
var target_rotation : Vector3

@export var recoil : Vector3
@export var aim_recoil : Vector3
@export var snappiness : float
@export var return_speed : float

func _process(delta):
	target_rotation = lerp(target_rotation, Vector3.ZERO, return_speed * delta)
	current_rotation = lerp(current_rotation, target_rotation, snappiness * delta)
	rotation = current_rotation

	if recoil.z == 0 and aim_recoil.z == 0:
		global_rotation.z = 0

func recoilFire(isAiming : bool = false):
	if isAiming:
		target_rotation += Vector3(aim_recoil.x, randf_range(-aim_recoil.y, aim_recoil.y), randf_range(-aim_recoil.z, aim_recoil.z))
	else:
		target_rotation += Vector3(recoil.x, randf_range(-recoil.y, recoil.y), randf_range(-recoil.z, recoil.z))

func setRecoil(newRecoil : Vector3):
	recoil = newRecoil

func setAimRecoil(newRecoil : Vector3):
	aim_recoil = newRecoil
