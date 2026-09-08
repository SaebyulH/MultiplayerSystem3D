extends StatusEffect
class_name NoclipEffect

## While active the player passes through walls and other players, keeping only
## floor collision (surfaces within floor_max_angle of up).  Movement, damage
## immunity and rendering all read StatusEffectManager.has_effect("noclip")
## directly, so this effect is a permanent marker that only ends on manual
## cancel (the NoclipAbility toggle) or death (clear_all_effects).

func _init() -> void:
	effect_id = "noclip"
	display_name = "Noclip"
	is_negative = false
	is_permanent = true
	tick_interval = 0.0


func _on_remove(player: Player, _state: Dictionary) -> void:
	if is_instance_valid(player):
		player._start_noclip_exit_pulse()
