extends StatusEffect
class_name SlowEffect

## Reduces the player's movement speed by [member slow_percent].
## 0.5 = half speed, 0.0 = full stop (not recommended).
## Applied as a status effect via WeaponFire.status_effects.

## Speed multiplier applied while this effect is active.
## 1.0 = normal speed, 0.5 = half speed.
@export var slow_percent: float = 0.5


func _init() -> void:
	effect_id = "slow"
	display_name = "Slow"
	is_negative = true
	base_duration = 0.5
	tick_interval = 0.0


func _on_apply(player: Player, _applier: String, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	player.add_speed_modifier(effect_id, slow_percent)


func _on_remove(player: Player, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	player.remove_speed_modifier(effect_id)
