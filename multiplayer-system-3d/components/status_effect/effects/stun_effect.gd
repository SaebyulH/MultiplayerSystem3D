extends StatusEffect
class_name StunEffect

## Prevents the player from taking any actions while active.
## Presence is checked via StatusEffectManager.is_stunned().


func _init() -> void:
	effect_id = "stun"
	display_name = "Stun"
	base_duration = 2.0
	tick_interval = 0.0
