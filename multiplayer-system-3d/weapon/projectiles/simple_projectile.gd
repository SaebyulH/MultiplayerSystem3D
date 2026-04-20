extends RigidBody3D
class_name SimpleProjectile


# AUX
var shooter_name: String
#var _distance_traveled: float = 0.0
var _time_alive := 0.0
@export var lifetime: float = 100.5
@export var explode_on_timeout: bool = false
# DAMAGE COMPONENTS
@export var _hitbox_component: HitboxComponent
@export var _explosion_component: ExplosionComponent

enum HurtboxHitMode {DISSAPEAR, PASSTHROUGH}
@export var hurtbox_hit_mode: HurtboxHitMode
@export var explode_on_direct := false

#@export var _world_hit: Area3D
enum WorldHitMode {DISSAPEAR, NOTHING}
@export var world_hit_mode: WorldHitMode
@export var explode_on_world := false

# PHYSICS
#var initial_velocity: Vector3 = Vector3.ZERO

#func set_damage(damage: float):
	#_hitbox_component.damage = damage

func _ready() -> void:
	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	_time_alive += delta
	
	if _time_alive >= lifetime:
		if explode_on_timeout:
			await _explosion_component.explode()
			queue_free()
		queue_free()
		return

# Damage for DIRECT hits.
func _on_hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority():
		return
		
	if explode_on_direct:
		freeze = true
		await _explosion_component.explode()
		
	if hurtbox_hit_mode == HurtboxHitMode.DISSAPEAR:
		queue_free()

	elif hurtbox_hit_mode == HurtboxHitMode.PASSTHROUGH:
		pass

func _on_body_entered(body: Node3D) -> void:
	if not is_multiplayer_authority():
		return
	# Optional: ignore shooter
	if body.name == shooter_name:
		return
	
	if explode_on_world:
		freeze = true
		await _explosion_component.explode()
	
	if world_hit_mode == WorldHitMode.DISSAPEAR:
		queue_free()
	elif world_hit_mode == WorldHitMode.NOTHING:
		pass
	
