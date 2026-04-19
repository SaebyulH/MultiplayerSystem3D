extends Node3D

@export var head: Node3D

const MOUSE_SENS_X: float = 0.002
const MOUSE_SENS_Y: float = 0.002

func _ready() -> void:
	if is_multiplayer_authority():
		$Recoil/Head/Skin2.hide()
		$Recoil/Head/Skin3.hide()

func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		rotation.y -= event.relative.x * MOUSE_SENS_X

		head.rotation.x -= event.relative.y * MOUSE_SENS_Y
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
