extends Node3D

@export var head: Node3D

var mouse_sens_x: float = 0.002
var mouse_sens_y: float = 0.002

func _ready() -> void:
	if is_multiplayer_authority() and not $"..".is_bot:
		$Recoil/Head/Face.hide()
		$Torso.hide()
		$LeftLeg.hide()
		$RighLeg.hide()
		$Recoil/Head/RightEye.hide()
		$Recoil/Head/LeftEye.hide()
func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		rotation.y -= event.relative.x * mouse_sens_x

		head.rotation.x -= event.relative.y * mouse_sens_y
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
