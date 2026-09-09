extends StatusEffect
class_name AimbotEffect

## Timed marker for the aimbot ability.  While active, Player._update_aimbot
## continuously rotates the caster's head toward the best enemy head in view.
## No _on_apply/_on_tick/_on_remove needed — presence is queried via
## StatusEffectManager.has_effect("aimbot") and the effect expires naturally.

func _init() -> void:
	effect_id = "aimbot"
	display_name = "Aimbot"
	is_negative = false
	tick_interval = 0.0
