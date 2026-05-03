extends Node
class_name HurtComponent

@export var hurtbox_component: HurtboxComponent
@export var attribute_component: AttributeComponent


func _ready() -> void:
	hurtbox_component.hurt_or_heal.connect(_on_hurt_or_heal)


func _on_hurt_or_heal(hitbox_component: HitboxComponent, is_ally_hit: bool) -> void:
	if not is_multiplayer_authority():
		return

	var health_delta := hitbox_component.health_delta
	
	if not is_ally_hit:
		health_delta *= hitbox_component.enemy_delta_multiplier
	
	var changer := _resolve_changer_name(hitbox_component)

	var original_health := attribute_component.health
	
	if hurtbox_component.is_head:
		health_delta *= hitbox_component.headshot_multiplier
	
	
	# Centralized health_delta handling (leaderboard + death logic included)
	#attribute_component.apply_health_delta(health_delta, changer, str(get_parent().name))
	
	attribute_component.apply_health_delta(health_delta, _resolve_changer_name(hitbox_component), get_parent().name)
	print(
		"Health of entity " + str(get_parent().name) +
		": " + str(original_health) +
		" -> " + str(attribute_component.health) +
		" | changer: " + changer
	)


func _resolve_changer_name(hitbox_component: HitboxComponent) -> String:
	var parent = hitbox_component.get_parent()

	if parent != null and "shooter_name" in parent:
		return parent.shooter_name

	# fallback (works for NPCs or projectiles)
	if parent != null:
		return parent.name

	return "UNKNOWN"
