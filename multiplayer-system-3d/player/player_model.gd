class_name PlayerModel
extends Node3D

## Render layer the RimPivot spotlights illuminate (light_cull_mask 512).
## Meshes on this layer catch the shared rim light.
const RIM_LAYER := 1 << 9  # render layer 10


## Head/face meshes that would clip the first-person camera.  Set these in the
## inspector on each character model scene; they are hidden in first person and
## excluded from team colouring.
@export var head_meshes: Array[MeshInstance3D] = []


## Every MeshInstance3D under this model, collected once in _ready().
var _meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_meshes.clear()
	for node in find_children("*", "MeshInstance3D", true, false):
		_meshes.append(node as MeshInstance3D)


## Hide the head meshes so they don't clip the local player's first-person view.
func hide_head_meshes() -> void:
	for mesh in head_meshes:
		if is_instance_valid(mesh):
			mesh.hide()


## Stop this model from catching the rim light (the local player's own
## first-person model).
func disable_rim_layer() -> void:
	for mesh in _meshes:
		mesh.layers &= ~RIM_LAYER


## Make this model catch the rim light (teammates and enemies).
func enable_rim_layer() -> void:
	for mesh in _meshes:
		mesh.layers |= RIM_LAYER


## All meshes except the head meshes — the ones that receive team colouring.
func get_skin_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh in _meshes:
		if not head_meshes.has(mesh):
			result.append(mesh)
	return result
