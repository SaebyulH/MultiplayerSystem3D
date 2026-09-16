extends Node3D

@export var head: Node3D

var mouse_sens_x: float = 0.002
var mouse_sens_y: float = 0.002

## Maximum body yaw turn speed (radians/second).  0 = unlimited.
var max_turn_speed: float = 0.0

var _last_motion_msec: int = -1

@onready var _player := $".." as Player
@onready var _third_person_root: Node3D = $"../ThirdPersonRoot"
@onready var _third_person_pitch: Node3D = $"../ThirdPersonRoot/ThirdPersonPitch"

func _ready() -> void:
	if is_multiplayer_authority() and not $"..".is_bot:
		pass
		#$Recoil/Head/Face.hide()
		#$Torso.hide()
		#$LeftLeg.hide()
		#$RighLeg.hide()
		#$Recoil/Head/RightEye.hide()
		#$Recoil/Head/LeftEye.hide()
func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		_apply_mouse_look(event as InputEventMouseMotion)


## Apply a mouse-motion look delta.  First person rotates the body yaw + head
## pitch; third person rotates the ThirdPersonRoot rig instead (the body/head
## then aim at the third-person raycast — see player.gd `_update_third_person_aim`).
func _apply_mouse_look(motion: InputEventMouseMotion) -> void:
	var now: int = Time.get_ticks_msec()
	var dt: float = 0.0
	if _last_motion_msec >= 0:
		dt = float(now - _last_motion_msec) / 1000.0
	_last_motion_msec = now
	if dt <= 0.0:
		dt = 1.0 / 60.0

	var yaw_delta: float = -motion.relative.x * mouse_sens_x
	if max_turn_speed > 0.0:
		yaw_delta = clampf(yaw_delta, -max_turn_speed * dt, max_turn_speed * dt)
	var pitch_delta: float = -motion.relative.y * mouse_sens_y

	if _player.third_person:
		_third_person_root.rotation.y += yaw_delta
		_third_person_pitch.rotation.x = clamp(_third_person_pitch.rotation.x + pitch_delta, -PI / 2, PI / 2)
	else:
		rotation.y += yaw_delta
		head.rotation.x = clamp(head.rotation.x + pitch_delta, -PI / 2, PI / 2)

#@rpc("any_peer", "unreliable")
#func sync_rotation(yaw: float, pitch: float):
	#rotation.y = yaw
	#rotation.x = pitch
#
#func _process(_delta):
	#if not is_multiplayer_authority():
		#return
#
	#sync_rotation.rpc(rotation.y, rotation.x)
