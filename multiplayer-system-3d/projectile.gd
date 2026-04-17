extends Node3D
class_name Projectile
var velocity : Vector3 = Vector3(5, 5, 0)

var shooter_name : String
var damage :int = 10
@onready var _hitbox_component : HitboxComponent= $HitboxComponent



# Called when the node enters the scene tree for the first time.
func _ready():
	var mesh := $MeshInstance3D
	
	for i in mesh.get_surface_override_material_count():
		var mat = mesh.get_surface_override_material(i)
		
		if mat:
			mesh.set_surface_override_material(i, mat.duplicate())
	_hitbox_component.hit_hurtbox.connect(_hit_hurtbox)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		velocity.y -= 9.8 * delta
		global_position += velocity * delta
	

func _hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	
	
	if is_multiplayer_authority():
			
		var mat = $MeshInstance3D.get_surface_override_material(0)
		if mat:
			mat.albedo_color = Color(1, 0, 0)
			
		if is_multiplayer_authority():
				rpc_hit_flash.rpc()  #across ALL
			
@rpc("call_local", "unreliable")
func rpc_hit_flash():
	var mesh := $MeshInstance3D
	
	var mat = mesh.get_surface_override_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
		mesh.set_surface_override_material(0, mat)

	mat.albedo_color = Color(0.0, 0.578, 0.808, 1.0)

	# Optional: revert after a short delay
	await get_tree().create_timer(0.1).timeout
	mat.albedo_color = Color(1, 1, 1)
