extends Node3D

@export var head: Node3D

var mouse_sens_x: float = 0.002
var mouse_sens_y: float = 0.002

## Maximum body yaw turn speed (radians/second).  0 = unlimited.
var max_turn_speed: float = 0.0

var _last_motion_msec: int = -1

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
		var motion := event as InputEventMouseMotion
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

		rotation.y += yaw_delta

		head.rotation.x -= motion.relative.y * mouse_sens_y
		head.rotation.x = clamp(head.rotation.x, -PI / 2, PI / 2)

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
