class_name MovementAbility
extends Ability

## Base class for abilities that move the player through the rollback simulation.
##
## Movement abilities are CLIENT-cast: their activate*() hook runs on the owning
## client and queues deterministic rollback input (never a direct position or
## velocity write, and never an RPC), which Player._rollback_tick consumes and
## replays deterministically on every peer.
##
## See shoulder_charge_ability.gd (sustained velocity) for a concrete example.

func _init() -> void:
	cast_mode = CastMode.CLIENT
