extends StatusEffect
class_name BleedEffect

## Deals 4 flat damage every tick_interval (0.5 s).


func _on_tick(player: Player, applier: String, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	player.change_health(-4.0, applier)
