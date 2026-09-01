class_name TeleportAbility
extends Ability

## EQUIP-cast movement ability.  Pressing its key equips it; firing then teleports
## the player.  Primary teleports forward; secondary is a template for a backward
## alternate.  This is a CLIENT-cast ability: it queues a world-space offset as
## rollback input rather than moving the player via RPC, so the teleport replays
## deterministically under rollback.

@export var distance: float = 10.0

func activate_primary(player: Player) -> void:
	player.player_input.queued_teleport_offset = player.horizontal_forward() * distance

func activate_secondary(player: Player) -> void:
	player.player_input.queued_teleport_offset = -player.horizontal_forward() * distance

func activate_tertiary(player: Player) -> void:
	pass
