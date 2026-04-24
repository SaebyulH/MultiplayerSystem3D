extends Node3D
class_name ExplosionComponent

var exploded := false

@export var splash_health_delta := -100
@export var splash_radius := 5.0
@export var self_damage_percent := 0.25
@export var knockback_force := 20.0

# ----------------------------------------------------
# ENTRY POINT (called only once by whoever triggers it)
# ----------------------------------------------------
func explode():
	if exploded:
		return
	exploded = true
	var shooter_name: String = get_parent().shooter_name if ("shooter_name" in get_parent()) else "NONE"

	var space := get_world_3d().direct_space_state
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		print('NO PLAYERS in group "players"')

	var explosion_origin := global_position

	for player in players:
		if not player is Player:
			continue

		var to_player: Vector3 = player.global_position - explosion_origin
		var dist := to_player.length()
		if dist > splash_radius:
			continue

		# --- Line of sight check ---
		var ray := PhysicsRayQueryParameters3D.new()
		ray.from = explosion_origin
		ray.to = player.global_position + Vector3(0, 0.5, 0)
		ray.collision_mask = 1
		ray.exclude = [self]
		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			continue

		# --- Damage falloff ---
		var falloff: float = 1.0 - clamp(dist / splash_radius, 0.0, 1.0)
		var damage: float = splash_health_delta * falloff
		if player.name == shooter_name:
			damage *= self_damage_percent

		var attr: AttributeComponent = player.attribute_component
		attr.apply_health_delta(damage, shooter_name, player.name)
		print("Explosion damaged ", player.name, " for ", damage)

		# --- Knockback ---
		# Apply on the server's local copy of the player so authoritative state
		# has the knockback. Also RPC to the owning client so it feels it
		# immediately without waiting for state sync.
		var dir: Vector3 = to_player.normalized()
		var force: Vector3 = dir * knockback_force * falloff
		var owner_id := player.name.to_int()

		# Server applies to its own copy directly
		player._pending_knockback += force

		# Tell owning client only if they are a different peer
		if owner_id != multiplayer.get_unique_id():
			player._receive_knockback.rpc_id(owner_id, force)

	_explode_visual.rpc()


# ----------------------------------------------------
# VISUAL EFFECT (replicated to all peers)
# ----------------------------------------------------
@rpc("call_local", "reliable")
func _explode_visual():
	print("visual explode on: ", multiplayer.get_unique_id())
	$Explosion.start_effect(splash_radius)
