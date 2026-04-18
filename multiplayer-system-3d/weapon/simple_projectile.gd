extends Area3D
class_name SimpleProjectile

#@export var gravity: float = 9.8
@export var lifetime: float = 1.5

var velocity: Vector3 = Vector3.ZERO
var shooter_name: String

var _has_hit := false
var _time_alive := 0.0

#@export var _hitbox_component: HitboxComponent
@onready var _mesh: MeshInstance3D = $MeshInstance3D
@export var _hitbox_component: HitboxComponent


func _ready() -> void:
	# Make materials unique (correct, keep this)
	for i in _mesh.get_surface_override_material_count():
		var mat = _mesh.get_surface_override_material(i)
		if mat:
			_mesh.set_surface_override_material(i, mat.duplicate())

	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)
	#body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	# Lifetime handling
	_time_alive += delta
	if _time_alive >= lifetime:
		queue_free()
		return

	# Movement (fixed)
	#velocity.y -= gravity * delta
	global_position += velocity * delta


func _on_hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority() or _has_hit:
		return

	_has_hit = true
	
	# TODO: apply damage here if needed
	# hurtbox.apply_damage(...)

	rpc_hit_flash.rpc()
	queue_free()


func _on_body_entered(body: Node) -> void:
	if not is_multiplayer_authority() or _has_hit:
		return

	# Optional: ignore shooter
	if body.name == shooter_name:
		return

	_has_hit = true
	rpc_hit_flash.rpc()
	queue_free()


@rpc("call_local", "unreliable")
func rpc_hit_flash() -> void:
	var mat = _mesh.get_surface_override_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
		_mesh.set_surface_override_material(0, mat)

	mat.albedo_color = Color(0.0, 0.578, 0.808)

	# purely visual, no authority check needed
	await get_tree().create_timer(0.1).timeout



func set_damage(damage: float):
	_hitbox_component.damage = damage
