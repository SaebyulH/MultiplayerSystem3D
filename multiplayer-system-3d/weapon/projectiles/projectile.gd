extends CollisionObject3D
class_name Projectile

@export var lifetime: float = 1.5
var velocity: Vector3 = Vector3.ZERO
var shooter_name: String
var _has_hit := false
var _time_alive := 0.0
var gravity := 9.8 # m/s^2

@export var _hitbox_component: HitboxComponent
@export var _collision: CollisionObject3D

func _ready() -> void:
	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	# Lifetime handling
	_time_alive += delta
	if _time_alive >= lifetime:
		queue_free()
		return

	# Movement (fixed)
	velocity.y -= gravity * delta
	global_position += velocity * delta


func _on_hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority() or _has_hit:
		return

	_has_hit = true
	
	# TODO: apply damage here if needed
	# hurtbox.apply_damage(...)

	queue_free()
