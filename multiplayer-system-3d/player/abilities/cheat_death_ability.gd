class_name CheatDeathAbility
extends Ability

## Self-revive: respawn immediately, skipping the respawn timer.  Marked
## can_be_used_while_dead so it can be cast while despawned.  Casting while
## alive does nothing.

func _init() -> void:
	can_be_used_while_dead = true

func activate(player: Player) -> void:
	if not player.spawned:
		player.cheat_death()
