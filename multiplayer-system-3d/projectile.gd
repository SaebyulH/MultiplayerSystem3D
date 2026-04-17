extends Area3D
class_name Projectile
var velocity : Vector3 = Vector3(5, 5, 0)

var shooter_name : String
var damage :int = 10




# Called when the node enters the scene tree for the first time.
func _ready():
	var mesh := $MeshInstance3D
	
	for i in mesh.get_surface_override_material_count():
		var mat = mesh.get_surface_override_material(i)
		
		if mat:
			mesh.set_surface_override_material(i, mat.duplicate())


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		velocity.y -= 9.8 * delta
		global_position += velocity * delta
	

func _on_body_entered(body: Node3D) -> void:
	
	
	if is_multiplayer_authority():
		if body.name == shooter_name:
			return
			
		var mat = $MeshInstance3D.get_surface_override_material(1)
		if mat:
			mat.albedo_color = Color(1, 0, 0)
			
		if is_multiplayer_authority():
			if body is Player:
				body.change_health(-damage)
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
