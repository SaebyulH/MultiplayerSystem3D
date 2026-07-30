extends StatusEffect
class_name InvincibleEffect

## Clears all negative effects on application.  While active, the player
## cannot take damage and is immune to new negative effects.


func _init() -> void:
	effect_id = "invincible"
	display_name = "Invincible"
	is_negative = false
	base_duration = 5.0
	tick_interval = 0.0


func _on_apply(player: Player, _applier: String, _state: Dictionary) -> void:
	if player.status_effect_manager:
		player.status_effect_manager.clear_negative_effects()
