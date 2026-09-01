extends StatusEffect
class_name PinnedEffect

## Marks a player as pinned to a charging player during a shoulder charge.
## Presence blocks movement and firing (see PlayerInput).  The carry itself is
## driven by the charger via Player.pinned_charger_name, not by this effect —
## this effect only represents the "stuck to the charger" state and is removed
## when the victim is released (with or without a follow-up stun).

func _init() -> void:
	effect_id = "pinned"
	display_name = "Pinned"
	base_duration = 4.0
	tick_interval = 0.0
