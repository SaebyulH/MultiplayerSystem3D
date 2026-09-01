extends StatusEffect
class_name EnlargeEffect

## Doubles the player's size (the whole player node — model, collider, hurtboxes
## and weapon) and max health for the effect's duration.
## On expiry the size and max health revert and current health is clamped down.

const SIZE_MULT: float = 2.0
const HEALTH_MULT: float = 2.0

func _init() -> void:
	effect_id = "enlarge"
	display_name = "Enlarged"
	base_duration = 10.0
	tick_interval = 0.0
	is_negative = false

func _on_apply(player: Player, _applier: String, state: Dictionary) -> void:
	if not is_instance_valid(player):
		return

	var base_max: float = player.attribute_component.starting_health if player.attribute_component else 100.0
	state["base_max_health"] = base_max

	var new_max: float = base_max * HEALTH_MULT
	player.set_enlarge_scale(SIZE_MULT)
	if player.attribute_component:
		player.attribute_component.starting_health = new_max
		player.attribute_component.reset_health()  # fill to the new max
	player._rpc_enlarge.rpc(SIZE_MULT, new_max)

func _on_remove(player: Player, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	var base_max: float = _state.get("base_max_health", 100.0)
	player.set_enlarge_scale(1.0)
	if player.attribute_component:
		player.attribute_component.starting_health = base_max
		player.attribute_component.health = minf(player.attribute_component.health, base_max)
	player._rpc_enlarge.rpc(1.0, base_max)
