extends StatusEffect
class_name GravityFlipEffect

## Inverts the player's gravity while active — they fall upward instead of
## downward (e.g. when airborne).  Applied via WeaponFire.status_effects.


func _init() -> void:
	effect_id = "gravity_flip"
	display_name = "Gravity Flip"
	is_negative = true
	base_duration = 10.0
	tick_interval = 0.0


func _on_apply(player: Player, _applier: String, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	player.set_gravity_flipped(true)


func _on_remove(player: Player, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	player.set_gravity_flipped(false)
