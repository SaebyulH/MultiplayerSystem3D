extends Node3D
class_name ExplosionComponent
var exploded := false
@export var splash_damage := 100
@export var splash_radius = 5.0

var self_damage_percent = 0.25

@export var knockback_force: float = 20.0


func explode():
	if exploded:
		return
	exploded = true

	# run visuals on everyone
	_explode_visual.rpc()

	# --- SERVER LOGIC ---
	var explosion_origin = global_position
	var space = get_world_3d().direct_space_state
	var players = get_tree().get_nodes_in_group("players")
	
	if players.size() == 0:
		print('NO PLAYERS in group "players"')
	
	for player in players:
		
		if not player is Player:
			continue

		var player_id = player.name.to_int()
		var to_player = player.global_position - explosion_origin
		var dist = to_player.length()

		if dist > splash_radius:
			continue
		
		var ray = PhysicsRayQueryParameters3D.new()
		ray.from = explosion_origin
		ray.to = player.global_position + Vector3(0, 0.5, 0)
		ray.collision_mask = 1
		ray.exclude = [self]

		if not space.intersect_ray(ray).is_empty():
			continue
		print(player.name)
		var falloff = 1.0 - clamp(dist / splash_radius, 0.0, 1.0)

		# DAMAGE
		var dmg = int(splash_damage * falloff)
		if str(player_id) == get_parent().shooter_name:
			dmg = int(dmg * self_damage_percent)

		player.change_health(-dmg)
		print("explosion damaged player by " + str(dmg))
		
		#take_damage.rpc_id(player_id, dmg, shooter_id)

		# KNOCKBACK (client-side)
		var dir = to_player.normalized()
		var force = dir * knockback_force * falloff
		player.apply_knockback(force)

	await get_tree().create_timer(0.5).timeout
	queue_free()


@rpc("any_peer", "call_local", "reliable")
func _explode_visual():
	print("visual explode on: ", multiplayer.get_unique_id())

	$Radius.scale = Vector3(splash_radius, splash_radius, splash_radius) #Assuming its 1m Radius
	$Radius.show()
	set_physics_process(false)
	#velocity = V
	#$Explosion.emitting = true
