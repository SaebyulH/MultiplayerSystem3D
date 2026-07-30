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

	var is_headshot := false
	if hurtbox_component.is_head and not is_equal_approx(hitbox_component.headshot_multiplier, 1.0):
		health_delta *= hitbox_component.headshot_multiplier
		is_headshot = true

	attribute_component.apply_health_delta(health_delta, _resolve_changer_name(hitbox_component), get_parent().name, is_headshot, hitbox_component.current_falloff_multiplier)

	# Apply status effects from the hitbox (e.g. projectile-delivered effects).
	var parent := get_parent()
	if parent is Player and parent.status_effect_manager and not hitbox_component.status_effects.is_empty():
		for effect in hitbox_component.status_effects:
			if effect:
				parent.status_effect_manager.apply_effect(effect, changer)


func _resolve_changer_name(hitbox_component: HitboxComponent) -> String:
	var parent = hitbox_component.get_parent()

	if parent != null and "shooter_name" in parent:
		return parent.shooter_name

	# fallback (works for NPCs or projectiles)
	if parent != null:
		return parent.name

	return "UNKNOWN"
