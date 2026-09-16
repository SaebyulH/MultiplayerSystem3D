extends Area3D
class_name HitboxComponent

signal hit_hurtbox(hurtbox)
@export var health_delta: float = -10.0
@export var headshot_multiplier: float = 1.0
## Extra damage when the projectile hits the victim from behind (rear 180°,
## relative to the victim's body yaw).  1.0 = no bonus.
@export var backshot_multiplier: float = 1.0
@export var can_hit_shooter: bool = false

@export var can_hit_other_teamates: bool = false ##DOES NOT INCLUDE YOU
@export var can_hit_enemy: bool = true
@export var enemy_delta_multiplier: float = 1.0  ##Like crusaders crossbow if -2.0 etc.

## With this enabled, STICK projectiles are basically poisonous! Warning!
@export var can_hit_multiple_times: bool = false

## Set by projectiles each frame to their current travel-time falloff multiplier.
## Read by HurtComponent to display in damage numbers.
var current_falloff_multiplier: float = 1.0

## Status effects applied to the target on hit.  Set in the scene or at
## runtime by WeaponController when spawning a projectile.  Read by HurtComponent.
@export var status_effects: Array[StatusEffect] = []
## Knockback force applied to the target on hit.  Set by WeaponController
## when spawning a projectile.  Read by HurtComponent.
@export var hit_knockback: float = 0.0

func _ready() -> void:
	area_entered.connect(_on_hurtbox_entered)
	body_entered.connect(_on_ragdoll_body_entered)
	# Also detect ragdoll physical bones (layer 8) so projectiles can knock them.
	collision_mask |= (1 << 7)


func _on_hurtbox_entered(hurtbox: HurtboxComponent):
	_process_hurtbox_hit(hurtbox, false)


## Shared hurtbox-hit logic for area (shield) and body (player bone) hurtboxes.
func _process_hurtbox_hit(hurtbox: HurtboxComponent, from_body: bool) -> void:
	# Resolve the owning Player — physical-bone hurtboxes are no longer direct
	# children of the Player, so get_parent() isn't the owner anymore.
	var owner_player := hurtbox.get_owner_player()
	if owner_player == null:
		return

	var hit_self: bool = (get_parent().shooter_name == owner_player.name)

	if not can_hit_shooter and hit_self:
		return

	var hit_ally: bool = (owner_player.team == get_parent().shooter_team)
	# FFA has no allies — same team doesn't mean friendly.
	if hit_ally and owner_player.team == Player.Team.FFA:
		hit_ally = owner_player.name == get_parent().shooter_name

	var hit_other_ally: bool = hit_ally and not hit_self

	if hit_other_ally and not can_hit_other_teamates:
		return
	elif not can_hit_enemy:
		return

	hurtbox.hurt_or_heal.emit(self, hit_ally)
	hit_hurtbox.emit(hurtbox)

	if not can_hit_multiple_times:
		if from_body:
			body_entered.disconnect(_on_ragdoll_body_entered)
		else:
			area_entered.disconnect(_on_hurtbox_entered)


## A projectile's hitbox overlapped a physical body — either a living player's
## bone hurtbox (carries HurtboxComponent) or a ragdoll corpse bone.
func _on_ragdoll_body_entered(body: Node3D) -> void:
	if not body is PhysicalBone3D:
		return
	if not is_multiplayer_authority():
		return
	var corpse := GameManager.find_ragdoll_corpse(body)
	if corpse == null:
		# Not a ragdoll — a living player's physical-bone hurtbox.
		if body is HurtboxComponent:
			_process_hurtbox_hit(body as HurtboxComponent, true)
		return

	var proj := get_parent() as Node3D
	var dir: Vector3 = Vector3.ZERO
	if proj is RigidBody3D:
		dir = (proj as RigidBody3D).linear_velocity
	elif proj is Projectile:
		dir = (proj as Projectile).velocity
	if dir.length_squared() < 0.0001:
		dir = -proj.global_transform.basis.z
	dir = dir.normalized()

	var kb_force := hit_knockback if hit_knockback > 0.0 else 2.0
	GameManager.rpc_ragdoll_bone_impulse.rpc(corpse.name, (body as PhysicalBone3D).bone_name, dir * kb_force, body.global_position)
