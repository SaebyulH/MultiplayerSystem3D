extends RigidBody3D
class_name SimpleProjectile

var _stuck_to: Node3D = null
var _local_offset: Transform3D

# AUX
var shooter_name: String
var shooter_team: Player.Team


#var _distance_traveled: float = 0.0
var _time_alive := 0.0
@export var lifetime: float = 100.5
@export var explode_on_timeout: bool = false
# DAMAGE COMPONENTS
@export var _hitbox_component: HitboxComponent
@export var _explosion_component: ExplosionComponent

enum HurtboxHitMode {DISSAPEAR, PASSTHROUGH, EXPLODE, STICK} #EXPLODE MAKES IT DISSAPEAR
@export var hurtbox_hit_mode: HurtboxHitMode
#@export var explode_on_direct := false

#@export var _world_hit: Area3D
enum WorldHitMode {DISSAPEAR, NOTHING, EXPLODE, STICK} #EXPLODE MAKES IT DISSAPEAR
@export var world_hit_mode: WorldHitMode
#@export var explode_on_world := false

# PHYSICS
#var initial_velocity: Vector3 = Vector3.ZERO

#func set_damage(damage: float):
	#_hitbox_component.damage = damage

func _ready() -> void:
	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)

func _physics_process(delta: float) -> void:
	
	
		
	if not is_multiplayer_authority():
		return

	if _stuck_to:
		# follow target without parenting
		global_transform = _stuck_to.global_transform * _local_offset
		#return
		
	if _time_alive >= lifetime:
		if explode_on_timeout:
			if _explosion_component:
				await start_explode()
		else:
			queue_free()
		return
	else:
		_time_alive += delta

# Damage for DIRECT hits.
func _on_hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority():
		return
		
	#if explode_on_direct:
		#freeze = true
		#if _explosion_component:
			#await _explosion_component.explode()
		#
	if hurtbox_hit_mode == HurtboxHitMode.DISSAPEAR:
		queue_free()

	elif hurtbox_hit_mode == HurtboxHitMode.PASSTHROUGH:
		pass
	elif hurtbox_hit_mode == HurtboxHitMode.EXPLODE:
		await start_explode()
	elif world_hit_mode == WorldHitMode.STICK:
		#_hitbox_component.health_delta = 0.0
		_attach_to(hurtbox)

@rpc("any_peer","call_local", "reliable")
func hide_model():
	for child in get_children():
		if child is MeshInstance3D:
			child.hide()


#This is ONLY FOR THE WORLD it does not collide with PLAYER COLLISION bc its mask
#is only world
func _on_body_entered(body: Node3D) -> void:
	if not is_multiplayer_authority():
		return
	# Optional: ignore shooter
	#if body.name == shooter_name:
		#return
		#
	
	#if body.get
	#if explode_on_world:
		#freeze = true
		#if _explosion_component:
			#await _explosion_component.explode()
	
	if world_hit_mode == WorldHitMode.DISSAPEAR:
		queue_free()
	elif world_hit_mode == WorldHitMode.NOTHING:
		pass
	elif world_hit_mode == WorldHitMode.EXPLODE:

		await start_explode()
	elif world_hit_mode == WorldHitMode.STICK:
		#_hitbox_component.health_delta = 0.0
		_attach_to(body)

func start_explode():
	hide_model.rpc()
	freeze = true
	_explosion_component.explode()
	await get_tree().create_timer(10.0).timeout
	if is_instance_valid(self):
		queue_free()

func _attach_to(body: Node3D) -> void:
	freeze = true
	#	Make it not have dmg
	#
	_stuck_to = body
	
	# store relative transform
	_local_offset = body.global_transform.affine_inverse() * global_transform
