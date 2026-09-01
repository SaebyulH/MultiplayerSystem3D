class_name ShoulderChargeAbility
extends MovementAbility

## Instant-cast movement ability: charge forward at high speed for a few seconds.
## While charging the player cannot crouch, shoot, cast other abilities, or turn
## their head faster than [member turn_speed].  Enemy players hit are pinned
## (carried) until the charge ends; hitting a wall releases them early with a
## [member wall_stun_duration] stun.

@export var charge_duration: float = 4.0
@export var charge_speed: float = 14.0
## Maximum head turn speed (radians/second) while charging.  0 = unlimited.
@export var turn_speed: float = 1.5
## Horizontal radius within which enemy players are grabbed.
@export var grab_radius: float = 1.5
## Stun duration applied to released enemies that were slammed into a wall.
@export var wall_stun_duration: float = 3.0
## Damage dealt to an enemy on impact (the grab).
@export var impact_damage: float = 30.0
## Damage dealt to a pinned enemy slammed into a wall.
@export var wall_damage: float = 40.0

func activate(player: Player) -> void:
	player.player_input.queued_charge_trigger_dir = player.horizontal_forward()
