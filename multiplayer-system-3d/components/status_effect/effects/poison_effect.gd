extends StatusEffect
class_name PoisonEffect

## After a 3-second hidden delay, deals 30 DPS for the remaining duration.
## The victim does NOT see the effect in their UI until the drain phase begins.
##
## Total timeline (example with base_duration = 13 s):
##   0 s … 3 s   — hidden delay (no damage, invisible in UI)
##   3 s … 13 s  — 30 DPS drain (visible in UI)


func _on_tick(player: Player, applier: String, state: Dictionary) -> void:
	if not is_instance_valid(player):
		return

	# Ensure per-instance state keys exist.
	if not state.has("drain_started"):
		state["drain_started"] = false
	if not state.has("delay_elapsed"):
		state["delay_elapsed"] = 0.0

	if not state["drain_started"]:
		state["delay_elapsed"] += tick_interval
		if state["delay_elapsed"] >= 3.0:
			state["drain_started"] = true
		return

	# Drain phase — 30 DPS.
	var dmg := 30.0 * tick_interval
	player.change_health(-dmg, applier)
