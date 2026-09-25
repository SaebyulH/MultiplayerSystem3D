extends StatusEffect
class_name HealOverTimeEffect

## Channeled heal, built per cast by HealAbility — never a shared .tres, because
## [member total_heal] / [member base_duration] / [member tick_interval] are
## per-cast values off the ability resource.
##
## Normally a .tres effect is authored once and instanced from disk; this one is
## constructed with `HealOverTimeEffect.new()` on the server for each activation,
## so the fields below are plain (non-@export) vars set by the ability.


## Total health restored across the whole duration, split evenly over the ticks.
var total_heal: float = 40.0


func _init() -> void:
	effect_id = "heal_over_time"
	display_name = "Healing"
	is_negative = false
	base_duration = 5.0
	tick_interval = 0.5


func _on_apply(_player: Player, applier: String, state: Dictionary) -> void:
	# _on_remove does not receive the applier, so carry it in the per-instance state.
	state["applier"] = applier
	state["healed"] = 0.0


func _on_tick(player: Player, applier: String, state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	# Even split.  Whatever the ticks miss (or don't get to, if the player was
	# already at full health) is reconciled in _on_remove.
	var amount := per_tick_amount()
	state["healed"] = float(state.get("healed", 0.0)) + amount
	player.change_health(amount, applier)


## Health restored by a single tick.
func per_tick_amount() -> float:
	if base_duration <= 0.0 or tick_interval <= 0.0:
		return total_heal  # degenerate config — pay it out in one go
	return total_heal * tick_interval / base_duration


func _on_remove(player: Player, state: Dictionary) -> void:
	if not is_instance_valid(player) or player.attribute_component == null:
		return
	# Death clears effects, and Player.no_health() -> clear_all_effects() runs
	# while health is still <= 0 — writing a positive delta there would revive
	# the player and re-enter the death path (known-issues #32).  The remainder
	# only ever exists to make up a dropped final tick, so drop it instead.
	if player.attribute_component.health <= 0.0:
		return
	var remainder := total_heal - float(state.get("healed", 0.0))
	if remainder > 0.0001:
		# On respawn the health reset has already clamped this to a zero delta,
		# so this can never credit a heal the player did not receive.
		player.change_health(remainder, str(state.get("applier", player.name)))
