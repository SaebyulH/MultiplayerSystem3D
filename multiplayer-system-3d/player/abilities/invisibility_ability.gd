class_name InvisibilityAbility
extends Ability

## Grants the "invisible" status effect for [member duration] seconds.  Rendering
## is purely client-side (Player._update_visibility / Player.set_ghost_tier):
## enemies see nothing, while teammates and the caster see translucent glass.

@export var duration: float = 6.0

func activate(player: Player) -> void:
	if not player.status_effect_manager:
		return
	var effect := StatusEffect.new()
	effect.effect_id = "invisible"
	effect.display_name = "Invisible"
	effect.is_negative = false
	effect.base_duration = duration
	effect.tick_interval = 0.0
	player.status_effect_manager.apply_effect(effect, player.name)
