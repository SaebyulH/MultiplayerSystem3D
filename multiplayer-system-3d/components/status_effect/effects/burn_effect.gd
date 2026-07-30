extends StatusEffect
class_name BurnEffect

## Deals 2 % of max health per tick_interval (0.5 s).


func _on_tick(player: Player, applier: String, _state: Dictionary) -> void:
	if not is_instance_valid(player) or not player.attribute_component:
		return
	var dmg := player.attribute_component.starting_health * 0.02
	player.change_health(-dmg, applier)
