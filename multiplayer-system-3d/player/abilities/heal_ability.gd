class_name HealAbility
extends Ability

## Instant-cast ability that heals the caster for [member heal_amount] health.

@export var heal_amount: float = 40.0

func activate(player: Player) -> void:
	player.change_health(heal_amount, player.name)
