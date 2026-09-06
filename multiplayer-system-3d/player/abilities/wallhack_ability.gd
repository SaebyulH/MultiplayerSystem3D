class_name WallhackAbility
extends Ability

## Grants the caster the "wallhacking" status effect, letting them see enemy
## outlines through walls for [member duration] seconds.

@export var duration: float = 10.0

func activate(player: Player) -> void:
	if not player.status_effect_manager:
		return
	var effect := StatusEffect.new()
	effect.effect_id = "wallhacking"
	effect.display_name = "Wallhacking"
	effect.is_negative = false
	effect.base_duration = duration
	effect.tick_interval = 0.0
	player.status_effect_manager.apply_effect(effect, player.name)
