extends RigidBody3D
class_name SimpleProjectile

var _stuck_to: Node3D = null
var _local_offset: Transform3D

# AUX
var shooter_name: String
var shooter_team: Player.Team


var _time_alive := 0.0
@export var lifetime: float = 5.0
@export var explode_on_timeout: bool = false
# DAMAGE COMPONENTS
@export var _hitbox_component: HitboxComponent
@export var _explosion_component: ExplosionComponent

enum HurtboxHitMode {DISSAPEAR, PASSTHROUGH, EXPLODE, STICK}
@export var hurtbox_hit_mode: HurtboxHitMode

enum WorldHitMode {DISSAPEAR, NOTHING, EXPLODE, STICK}
@export var world_hit_mode: WorldHitMode

func _ready() -> void:
	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	if _stuck_to:
		global_transform = _stuck_to.global_transform * _local_offset

	if _time_alive >= lifetime:
		if explode_on_timeout:
			if _explosion_component:
				await start_explode()
		else:
			queue_free()
		return
	else:
		_time_alive += delta

func _on_hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority():
		return

	if hurtbox_hit_mode == HurtboxHitMode.DISSAPEAR:
		queue_free()

	elif hurtbox_hit_mode == HurtboxHitMode.PASSTHROUGH:
		pass
	elif hurtbox_hit_mode == HurtboxHitMode.EXPLODE:
		await start_explode()
	elif world_hit_mode == WorldHitMode.STICK:
		_attach_to(hurtbox)

@rpc("any_peer","call_local", "reliable")
func hide_model():
	for child in get_children():
		if child is MeshInstance3D:
			child.hide()


func _on_body_entered(body: Node3D) -> void:
	if not is_multiplayer_authority():
		return

	if world_hit_mode == WorldHitMode.DISSAPEAR:
		queue_free()
	elif world_hit_mode == WorldHitMode.NOTHING:
		pass
	elif world_hit_mode == WorldHitMode.EXPLODE:
		await start_explode()
	elif world_hit_mode == WorldHitMode.STICK:
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
	_stuck_to = body
	_local_offset = body.global_transform.affine_inverse() * global_transform
