extends Node
class_name HurtComponent

@export var hurtbox_components: Array[HurtboxComponent] = []
@export var attribute_component: AttributeComponent


func _ready() -> void:
	for hb in hurtbox_components:
		hb.hurt_or_heal.connect(_on_hurt_or_heal.bind(hb))


func _on_hurt_or_heal(hitbox_component: HitboxComponent, is_ally_hit: bool, hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority():
		return

	var health_delta := hitbox_component.health_delta

	if not is_ally_hit:
		health_delta *= hitbox_component.enemy_delta_multiplier

	var changer := _resolve_changer_name(hitbox_component)

	var is_headshot := false
	if hurtbox.is_head and not is_equal_approx(hitbox_component.headshot_multiplier, 1.0):
		health_delta *= hitbox_component.headshot_multiplier
		is_headshot = true

	# Backshot: the projectile hit from behind the victim's body facing.
	var is_backshot := _is_backshot(hitbox_component)
	if is_backshot and not is_equal_approx(hitbox_component.backshot_multiplier, 1.0):
		health_delta *= hitbox_component.backshot_multiplier
		var shooter := GameManager.find_player(changer)
		if shooter and not shooter.is_bot:
			shooter.weapon_controller.play_backshot_sound.rpc_id(changer.to_int())

	attribute_component.apply_health_delta(health_delta, _resolve_changer_name(hitbox_component), get_parent().name, is_headshot, hitbox_component.current_falloff_multiplier, is_backshot)

	# Apply knockback from the hitbox (e.g. projectile-delivered knockback).
	if hitbox_component.hit_knockback > 0.0:
		var kb_parent: Node = get_parent()
		if kb_parent is Player:
			var kb_dir: Vector3 = (kb_parent.global_position - hitbox_component.global_position).normalized()
			kb_parent.apply_knockback(kb_dir * hitbox_component.hit_knockback)

	# Apply status effects from the hitbox (e.g. projectile-delivered effects).
	var parent := get_parent()
	if parent is Player and parent.status_effect_manager and not hitbox_component.status_effects.is_empty():
		for effect in hitbox_component.status_effects:
			if effect and effect.should_trigger(is_headshot, is_backshot):
				parent.status_effect_manager.apply_effect(effect, changer)


func _resolve_changer_name(hitbox_component: HitboxComponent) -> String:
	var parent = hitbox_component.get_parent()

	if parent != null and "shooter_name" in parent:
		return parent.shooter_name

	# fallback (works for NPCs or projectiles)
	if parent != null:
		return parent.name

	return "UNKNOWN"


## True when the projectile that owns [param hitbox_component] is behind the
## victim's body facing (rear 180°, body yaw only — no head rotation).
func _is_backshot(hitbox_component: HitboxComponent) -> bool:
	var victim := get_parent() as Player
	var projectile := hitbox_component.get_parent() as Node3D
	if victim == null or projectile == null:
		return false
	var forward := -victim.body.global_transform.basis.z
	forward.y = 0.0
	var to_projectile := projectile.global_position - victim.global_position
	to_projectile.y = 0.0
	if to_projectile.length_squared() < 0.01:
		return false
	return forward.normalized().dot(to_projectile.normalized()) < 0.0
