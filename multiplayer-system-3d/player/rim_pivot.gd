extends Node3D
class_name RimPivot


var _own_model := false


func _ready() -> void:
	# The Player root is always authority 1 (the server); the owning peer is
	# stored on `body`, so check that to detect our own first-person model.
	_own_model = get_parent().body.is_multiplayer_authority() and not get_parent().is_bot
	if _own_model:
		
		
		
		
		
		$AreaLight3D.visible = false
		$AreaLight3D2.visible = false
		


# Keep the rim light on the far side of the player relative to the camera.
func _process(_delta: float) -> void:
	if _own_model:
		return

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var toward := camera.global_position - global_position
	if toward.is_zero_approx():
		return

	# -Z is the node's forward axis; the light sits on its +Z side. Pointing
	# forward at the camera leaves the light behind the player, away from it.
	look_at(camera.global_position, Vector3.UP)
