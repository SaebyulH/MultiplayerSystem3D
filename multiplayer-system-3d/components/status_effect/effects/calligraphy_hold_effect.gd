extends StatusEffect
class_name CalligraphyHoldEffect

## The middle phase of the calligraphy sequence: the canvas is down and the player
## is holding what they drew, waiting to throw it.
##
## Like CalligraphyEffect this is a bare permanent marker with no _on_remove — its
## entire job is to keep the gun locked (StatusEffectManager.is_fire_blocked names
## it directly) between the canvas closing and the throw landing, so the player
## cannot shoot their way out of the hold.  The throw itself is a client-requested
## RPC that removes this effect and fires; the hold is also cancellable, and
## cancelling is just a removal with no shot.
##
## It is a *second* effect rather than a flag on the first because the two phases
## have to be distinguishable from the effect mirror alone: CalligraphySphere drives
## its whole visual state off which of the two is present, on every peer.

func _init() -> void:
	effect_id = "calligraphy_hold"
	display_name = "Calligraphy (held)"
	is_negative = false
	is_permanent = true
	tick_interval = 0.0
