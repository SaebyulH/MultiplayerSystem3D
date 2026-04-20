extends Node3D
class_name ExplosionComponent

var exploded := false

@export var splash_damage := 100
@export var splash_radius := 5.0
@export var self_damage_percent := 0.25
@export var knockback_force := 20.0


func explode():
	if exploded:
		return
	exploded = true

	_explode_visual.rpc()

	var explosion_origin := global_position
	var space := get_world_3d().direct_space_state
	var players := get_tree().get_nodes_in_group("players")

	if players.is_empty():
		print('NO PLAYERS in group "players"')

	var shooter_name :String= get_parent().shooter_name if ("shooter_name" in get_parent()) else "NONE"

	for player in players:

		if not player is Player:
			continue

		var attr :AttributeComponent= player.attribute_component

		var to_player :Vector3 = player.global_position - explosion_origin
		var dist := to_player.length()

		if dist > splash_radius:
			continue

		var ray := PhysicsRayQueryParameters3D.new()
		ray.from = explosion_origin
		ray.to = player.global_position + Vector3(0, 0.5, 0)
		ray.collision_mask = 1
		ray.exclude = [self]

		if not space.intersect_ray(ray).is_empty():
			continue

		var falloff :float = 1.0 - clamp(dist / splash_radius, 0.0, 1.0)

		var dmg :float= splash_damage * falloff

		# self damage handling
		if player.name == shooter_name:
			dmg = dmg * self_damage_percent

		# -------------------------
		# APPLY DAMAGE (NEW SYSTEM)
		# -------------------------
		attr.apply_health_delta(dmg, shooter_name, player.name)

		print("Explosion damaged ", player.name, " for ", dmg)

		# KNOCKBACK
		var dir := to_player.normalized()
		var force := dir * knockback_force * falloff
		player.apply_knockback(force)

	await get_tree().create_timer(0.5).timeout
	queue_free()


# -------------------------
# VISUAL ONLY (CLIENT)
# -------------------------
@rpc("any_peer", "call_local", "reliable")
func _explode_visual():
	print("visual explode on: ", multiplayer.get_unique_id())

	$Radius.scale = Vector3(splash_radius, splash_radius, splash_radius)
	$Radius.show()
	set_physics_process(false)
