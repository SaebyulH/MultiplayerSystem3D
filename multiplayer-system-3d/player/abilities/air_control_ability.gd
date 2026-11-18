class_name AirControlAbility
extends MeteredAbility

## A passive, metered air-strafe meter: it drains while the player is airborne
## and steering, and refills while they are not.  While any meter remains the
## character's own [member Character.air_accel_mult] / air_speed_cap_mult apply;
## once the pool is empty the player falls back to the authored
## [member depleted_air_accel_mult] / [member depleted_air_speed_cap_mult] —
## Juggernaut-level air control — until it recharges.
##
## ## It is metered, but it is not a toggle
##
## Unlike noclip it is never cast; [method Ability.is_castable] is false so the
## ability key cannot toggle it.  The meter is driven by the movement simulation
## itself (Player._update_air_control_meter), which is why it does NOT live in
## AbilityManager's per-peer pool: [method Player._air_accelerate] reads it inside
## the rollback tick, so the server and the owning client must derive the same
## value from the same inputs and delta.  It is therefore rollback state on
## `Player` (`air_control_meter`, in the RollbackSynchronizer's state_properties).
##
## AbilityManager still owns the *display*: [method AbilityManager.get_meter_fraction]
## and [method AbilityManager.is_meter_active] delegate their answers for this
## class to the Player, so the HUD's meter bar shows the rollback value instead of
## the unused local pool.

@export_group("Depleted Air Control")
## Air-acceleration multiplier once the meter is empty.  0.5 is the Juggernaut's
## authored value.
@export var depleted_air_accel_mult: float = 0.5
## Air-speed-cap multiplier once the meter is empty.  0.5 is the Juggernaut's
## authored value.
@export var depleted_air_speed_cap_mult: float = 0.5


## Driven by the simulation, never by a key press.
func is_castable() -> bool:
	return false
