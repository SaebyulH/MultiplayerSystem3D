extends Node

## Multiplier applied to all ragdoll knockback impulses (hitscan, projectiles,
## explosions).  Bump this to make corpses react harder to being shot/blasted.
const RAGDOLL_KNOCKBACK_MULTIPLIER := 20.0

## Server-side "a sound happened here" notification.  Emitters supply a hearing
## radius; BotController connects while alive, checks distance and resolves the
## source, then starts a SEARCH toward an enemy noise (and glances at it) unless
## it is already engaging an enemy.  Never networked.
signal sound_made(position: Vector3, radius: float, source_name: String, kind: StringName)

var spawn_parent: Node3D


func report_sound(position: Vector3, radius: float, source_name: String,
		kind: StringName = &"sound") -> void:
	sound_made.emit(position, radius, source_name, kind)

## Where projectiles (and the tracer / decal / impact effects that ride the same
## parent) are added.  Lives on the world scene, not on the Player: a Player can be
## hidden or freed on death/disconnect, and `despawn()`'s `hide()` would cascade to
## anything parented under it.  Set by `world_1.gd`, which also owns its
## `ProjectileSpawner` -- the two must stay together, since the spawner replicates
## whatever lands under this node.
var projectile_parent: Node3D

var game_mode_component: GameModeComponent
var spawn_manager: SpawnManager

## Manual bots (team + character/weapon paths) that persist across return_to_lobby.
## Auto-fill bots are deliberately NOT recorded here, so they're freed on exit.
var lobby_bots: Array[Dictionary] = []

# --- Dev-menu display flags (world/dev_menu.gd) ---------------------------
# Purely local: they are never networked and only affect the peer that set
# them.  They live on GameManager (not on the world) so they survive a world
# swap; world_1.gd re-applies the HUD one when it builds the world again.

## Hide the local player's own HUD (PlayerUI, FPS counter, ability previews,
## damage numbers).  Menus are never affected.
var dev_hide_player_hud := false

## Hide the rest of the on-screen HUD (mode timer/score/team bars, kill feed,
## other players' projected health bars).  Menus — including the leaderboard —
## are never affected.
var dev_hide_world_hud := false

## Stop every bot's AI.  Server-local: bots only simulate on peer 1.
var dev_freeze_bots := false

## Draw each bot's remaining travel route as a world-space line: green for the
## navmesh, orange for a navmesh route that could only reach a partial approach,
## blue for the TravelGraph fallback, red for direct steering.  Server-local and
## display-only, like the rest of the debug overlay: bots only simulate on peer 1,
## so a client has no route to draw and never reads this flag.
var dev_show_bot_paths := false

func find_player(id: String) -> Player:
	# `spawn_parent` is a plain reference that can be null before the world is
	# built, or a freed node during teardown — `is_instance_valid` is the only
	# reliable check for both.
	if not is_instance_valid(spawn_parent):
		return null
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
	if not is_instance_valid(spawn_parent):
		return Vector3.ZERO
	for node in spawn_parent.get_children():
		if node is Map:
			return node.get_despawn_position()
	return Vector3.ZERO
