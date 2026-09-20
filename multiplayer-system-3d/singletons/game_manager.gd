extends Node

## Multiplier applied to all ragdoll knockback impulses (hitscan, projectiles,
## explosions).  Bump this to make corpses react harder to being shot/blasted.
const RAGDOLL_KNOCKBACK_MULTIPLIER := 20.0

var spawn_parent: Node3D
var game_mode_component: GameModeComponent
var spawn_manager: SpawnManager

## Manual bots (team + character/weapon paths) that persist across return_to_lobby.
## Auto-fill bots are deliberately NOT recorded here, so they're freed on exit.
var lobby_bots: Array[Dictionary] = []

func find_player(id: String) -> Player:
	for child in spawn_parent.get_children():
		if child.name == id and child is Player:
			return child as Player
	return null


func _find_ragdoll(corpse_name: String) -> Node3D:
	for node in get_tree().get_nodes_in_group("ragdolls"):
		if node.name == corpse_name:
			return node as Node3D
	return null


## Walk up from a hit ragdoll bone to the corpse node that owns it.
func find_ragdoll_corpse(node: Node) -> Node3D:
	var n := node
	while n != null:
		if n.is_in_group("ragdolls"):
			return n as Node3D
		n = n.get_parent()
	return null


func _ragdoll_bones(corpse: Node3D) -> Array[PhysicalBone3D]:
	var bones: Array[PhysicalBone3D] = []
	var sim := corpse.find_child("PhysicalBoneSimulator3D", true, false) as PhysicalBoneSimulator3D
	if sim:
		for child in sim.get_children():
			if child is PhysicalBone3D:
				bones.append(child as PhysicalBone3D)
	return bones


func _find_ragdoll_bone(corpse: Node3D, bone_name: StringName) -> PhysicalBone3D:
	for bone in _ragdoll_bones(corpse):
		if bone.bone_name == bone_name:
			return bone
	return null


## Broadcast: apply an impulse to one bone of a ragdoll corpse (a bullet hit it).
@rpc("any_peer", "call_local", "reliable")
func rpc_ragdoll_bone_impulse(corpse_name: String, bone_name: StringName, impulse: Vector3, at: Vector3) -> void:
	var corpse := _find_ragdoll(corpse_name)
	if corpse == null:
		return
	var bone := _find_ragdoll_bone(corpse, bone_name)
	if bone:
		bone.apply_impulse(impulse * RAGDOLL_KNOCKBACK_MULTIPLIER, at)


## Broadcast: push every bone of a ragdoll corpse outward from an explosion.
@rpc("any_peer", "call_local", "reliable")
func rpc_ragdoll_blast(corpse_name: String, origin: Vector3, force: float) -> void:
	var corpse := _find_ragdoll(corpse_name)
	if corpse == null:
		return
	for bone in _ragdoll_bones(corpse):
		var dir := (bone.global_position - origin).normalized()
		bone.apply_central_impulse(dir * force * RAGDOLL_KNOCKBACK_MULTIPLIER)


func get_despawn_position() -> Vector3:
	for node in spawn_parent.get_children():
		if node is Map:
			return node.get_despawn_position()
	return Vector3.ZERO
