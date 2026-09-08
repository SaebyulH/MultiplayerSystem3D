class_name BurnAbility
extends TargetedAbility

## Confirm-cast (EQUIP) targeted ability: applies a burn to the locked targets.

@export var burn_duration: float = 4.0

func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	for target in targets:
		if not is_instance_valid(target) or target.status_effect_manager == null:
			continue
		var effect := BurnEffect.new()
		effect.base_duration = burn_duration
		target.status_effect_manager.apply_effect(effect, player.name)
