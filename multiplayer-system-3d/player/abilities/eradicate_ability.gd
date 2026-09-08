class_name EradicateAbility
extends TargetedAbility

## Instant-cast targeted ability: deals [member damage] to every enemy in a full
## 360° radius around the caster (no aim cone).

@export var damage: float = 1000.0

func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	for target in targets:
		if is_instance_valid(target):
			target.change_health(-damage, player.name)
