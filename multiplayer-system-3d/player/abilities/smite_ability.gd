class_name SmiteAbility
extends TargetedAbility

## Instant-cast targeted ability: deals [member damage] to the locked targets.

@export var damage: float = 50.0

func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	for target in targets:
		if is_instance_valid(target):
			target.change_health(-damage, player.name)
