class_name RampageAbility
extends Ability

## Doubles the player's size (the whole player node) and max health for a short
## duration. Server-cast: applies an EnlargeEffect through the status-effect
## system, so the buff is timed, synced to clients, and reverted on expiry.

@export var duration: float = 10.0

func activate(player: Player) -> void:
	var effect := EnlargeEffect.new()
	effect.base_duration = duration
	if player.status_effect_manager:
		player.status_effect_manager.apply_effect(effect, player.name)
