class_name NoclipAbility
extends Ability

## Toggle noclip on/off.  While active the Ghost passes through walls and other
## players (floors only), cannot take damage, and renders semi-transparent black.
## Exiting fires a 999-damage overlap pulse.  Cooldown is 0 so the off-press is
## never blocked by the manager's cooldown gate.

func activate(player: Player) -> void:
	if player.status_effect_manager == null:
		return
	if player.status_effect_manager.has_effect("noclip"):
		player.status_effect_manager.remove_effect("noclip")
	else:
		player.status_effect_manager.apply_effect(NoclipEffect.new(), player.name)
