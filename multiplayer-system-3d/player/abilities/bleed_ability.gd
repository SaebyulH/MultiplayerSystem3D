class_name BleedAbility
extends TargetedAbility

## Confirm-cast (EQUIP) targeted ability: applies a bleed to the locked targets.

@export var bleed_duration: float = 4.0

func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	for target in targets:
		if not is_instance_valid(target) or target.status_effect_manager == null:
			continue
		var effect := BleedEffect.new()
		effect.base_duration = bleed_duration
		target.status_effect_manager.apply_effect(effect, player.name)
