extends RigidBody3D
class_name RigidBodyProjectile

@export var lifetime: float = 1.5
var velocity: Vector3 = Vector3.ZERO
var shooter_name: String
var _has_hit := false
var _time_alive := 0.0
var gravity := 9.8 # m/s^2

@export var _hitbox_component: HitboxComponent
@export var _collision: CollisionObject3D
var has_hit := false

func _ready() -> void:
	var mesh := $MeshInstance3D
	for i in mesh.get_surface_override_material_count():
		var mat = mesh.get_surface_override_material(i)
		if mat:
			mesh.set_surface_override_material(i, mat.duplicate())

	_hitbox_component.hit_hurtbox.connect(_hit_hurtbox)
	
	
	
	if is_multiplayer_authority():
		linear_velocity = velocity
		await get_tree().create_timer(1.0).timeout
		queue_free()

func _on_body_entered(body: Node) -> void:
	pass

func _hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if is_multiplayer_authority():
		rpc_hit_flash.rpc()

@rpc("call_local", "unreliable")
func rpc_hit_flash() -> void:
	var mesh := $MeshInstance3D
	var mat = mesh.get_surface_override_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
		mesh.set_surface_override_material(0, mat)
	mat.albedo_color = Color(0.0, 0.578, 0.808, 1.0)
	
	await get_tree().create_timer(0.1).timeout
	#if is_multiplayer_authority():
		#queue_free()
		


func set_damage(damage: float):
	_hitbox_component.damage = damage
