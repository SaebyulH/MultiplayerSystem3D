extends Node3D
class_name ExplosionComponent

var exploded := false

@export var splash_health_delta := -75
@export var splash_radius := 3.0


@export var min_knockback_percent := 0.3 ##For distance based knockball falloff

#Technically rather redunant, but useful to avoid confusuion
@export var self_health_delta_multiplier := 0.1
@export var team_health_delta_multiplier := 0.0
@export var enemy_health_delta_multiplier := 1.0

@export var self_knockback_multiplier := 1.0
@export var team_knockback_multiplier := 0.0
@export var enemy_knockback_multiplier := 1.0




@export var knockback_force := 5.0


# ----------------------------------------------------
# ENTRY POINT (called only once by whoever triggers it)
# ----------------------------------------------------
func explode():
	if exploded:
		return
	exploded = true

	var shooter_name: String = get_parent().shooter_name if ("shooter_name" in get_parent()) else "NONE"
	var shooter_team: Player.Team = get_parent().shooter_team if ("shooter_name" in get_parent()) else "NONE"
	
	

	var space := get_world_3d().direct_space_state
	var players := get_tree().get_nodes_in_group("players")

	if players.is_empty():
		print('NO PLAYERS in group "players"')
	
	var explosion_origin = global_position
	for player in players:

		if not player is Player:
			continue

		var attr: AttributeComponent = player.attribute_component
	
		
		var to_player: Vector3 = player.global_position - explosion_origin
		var dist := to_player.length()

		if dist > splash_radius:
			continue

		# ----------------------------------------------------
		# Line of sight check (NOTE: can be removed for full determinism)
		# ----------------------------------------------------
		var ray := PhysicsRayQueryParameters3D.new()
		ray.from = explosion_origin
		ray.to = player.global_position + Vector3(0, 0.5, 0)
		ray.collision_mask = 1
		ray.exclude = [self]

		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			continue

		# ----------------------------------------------------
		# Damage falloff
		# ----------------------------------------------------
		var falloff: float = 1.0 - clamp(dist / splash_radius, min_knockback_percent, 1.0)
		var damage: float = splash_health_delta * falloff
		
		
		var has_hit_team = player.team == shooter_team
		
		# self damage scaling
		if player.name == shooter_name:
			damage *= self_health_delta_multiplier
		else:
			#Only check for other people after checking self
			if has_hit_team:
				damage *= team_health_delta_multiplier
			else:
				damage *= enemy_health_delta_multiplier
		
		
		
		
		
		
		
		
		attr.apply_health_delta(damage, shooter_name, player.name)

		print("Explosion damaged ", player.name, " for ", damage)

		# ----------------------------------------------------
		# Knockback (deterministic impulse)
		# ----------------------------------------------------
		var dir: Vector3 = to_player.normalized()
		var force: Vector3 = dir * knockback_force * falloff
		
		# self knockback scaling
		if player.name == shooter_name:
			force *= self_knockback_multiplier
		else:
			#Only check for other people after checking self
			if has_hit_team:
				force *= team_knockback_multiplier
			else:
				force *= enemy_knockback_multiplier
		
		player.apply_knockback(force)
	
	_explode_visual.rpc()

# ----------------------------------------------------
# VISUAL EFFECT (replicated locally)
# ----------------------------------------------------
@rpc("call_local", "reliable")
func _explode_visual():
	#set_physics_process(false)
	print("visual explode on: ", multiplayer.get_unique_id())
	$Explosion.start_effect(splash_radius)
	#await get_tree().create_timer($Explosion.duration).timeout

	#$Radius.scale = Vector3(splash_radius, splash_radius, splash_radius)
	#$Radius.show()
	
