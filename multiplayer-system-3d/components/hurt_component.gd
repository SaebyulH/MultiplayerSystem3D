extends Node
class_name HurtComponent

@export var hurtbox_component: HurtboxComponent
@export var attribute_component: AttributeComponent


func _ready() -> void:
	hurtbox_component.hurt_or_heal.connect(_on_hurt_or_heal)


func _on_hurt_or_heal(hitbox_component: HitboxComponent) -> void:
	if not is_multiplayer_authority():
		return

	var damage := hitbox_component.damage
	var changer := _resolve_changer_name(hitbox_component)

	var original_health := attribute_component.health

	# Centralized damage handling (leaderboard + death logic included)
	#attribute_component.apply_health_delta(damage, changer, str(get_parent().name))
	
	attribute_component.health -=damage
	print(
		"Health of entity " + str(get_parent().name) +
		": " + str(original_health) +
		" -> " + str(attribute_component.health) +
		" | changer: " + changer
	)


func _resolve_changer_name(hitbox_component: HitboxComponent) -> String:
	var parent = hitbox_component.get_parent()

	if parent != null and parent.has_method("get_player_name"):
		return parent.get_player_name()

	# fallback (works for NPCs or projectiles)
	if parent != null:
		return parent.name

	return "UNKNOWN"
