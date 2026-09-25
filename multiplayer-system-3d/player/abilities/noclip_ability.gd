class_name NoclipAbility
extends MeteredAbility

## Noclip as a **metered** toggle: it drains the meter while the Ghost is flying
## and refills it while they are not, so a full bar buys MAX_METER seconds of
## free flight and an empty one takes RECHARGE_SECONDS to come back.
##
## While active the Ghost passes through walls and other players (floors only),
## cannot take damage, and renders semi-transparent black.  Turning off fires a
## 999-damage overlap pulse — including when the meter simply runs out, so
## burning the last of the bar inside an enemy is still lethal.  That is
## automatic: deactivate() removes the effect, and NoclipEffect._on_remove() is
## what starts the pulse, exactly as for a manual off.
##
## The 1 s toggle delay comes from Ability.cooldown, which MeteredAbility._init()
## pins (see the base class).  Everything else — the pool, exhaustion, the HUD
## bar — is AbilityManager's.

func activate(player: Player) -> void:
	if player.status_effect_manager == null:
		return
	player.status_effect_manager.apply_effect(NoclipEffect.new(), player.name)


func deactivate(player: Player) -> void:
	if player.status_effect_manager == null:
		return
	# The effect is the toggle state: every gameplay hook reads
	# has_effect("noclip") (movement, hurtboxes, damage immunity, rendering).
	player.status_effect_manager.remove_effect("noclip")
