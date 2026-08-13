extends Node3D


var _own_model := false


const RIM_LAYER := 1 << 9  # render layer 10, the shared rim-light layer


func _ready() -> void:
	# The Player root is always authority 1 (the server); the owning peer is
	# stored on `body`, so check that to detect our own first-person model.
	_own_model = get_parent().body.is_multiplayer_authority() and not get_parent().is_bot
	if _own_model:
		
		
		
		
		
		$AreaLight3D.visible = false
		$AreaLight3D2.visible = false
		_disable_rim_layer()
		


# Our own model is first-person, so it shouldn't catch rim light from any
# light (our own or a teammate's). Strip render layer 10 off its meshes.
func _disable_rim_layer() -> void:
	var flier := get_parent().get_node("Body/flier")
	for mesh in flier.find_children("*", "MeshInstance3D", true, false):
		mesh.layers &= ~RIM_LAYER


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
