extends Node
class_name StatusEffectManager

## ---------------------------------------------------------------------------
## StatusEffectManager — runtime tracker for active status effects on a Player.
##
## Add this node as a child of Player.  It ticks all active effects in
## _process, handles negative-effect stacking (extends duration), and
## exposes query methods (is_invincible, is_stunned) for other systems.
## ---------------------------------------------------------------------------

signal effect_applied(effect_id: String)
signal effect_removed(effect_id: String)

## { effect_id : { effect, remaining, applier, state } }
var _active_effects: Dictionary = {}

var _player: Player = null


func _ready() -> void:
	_player = get_parent() as Player


func _process(delta: float) -> void:
	if not _player or not _player.spawned:
		return

	# Iterate over keys so we can safely erase expired effects.
	var ids: Array = _active_effects.keys()
	for id in ids:
		var data: Dictionary = _active_effects[id]
		var effect: StatusEffect = data["effect"]
		var remaining: float = data["remaining"]

		remaining -= delta
		data["remaining"] = remaining

		if remaining <= 0.0:
			effect._on_remove(_player, data.get("state", {}))
			_active_effects.erase(id)
			effect_removed.emit(id)
			continue

		# Tick at configured interval.
		if effect.tick_interval > 0.0:
			var tick_timer: float = data.get("tick_timer", 0.0)
			tick_timer -= delta
			while tick_timer <= 0.0:
				tick_timer += effect.tick_interval
				effect._on_tick(_player, data["applier"], data.get("state", {}))
			data["tick_timer"] = tick_timer


# ------------------------------------------------------------------ public API

## Apply a status effect to the owning player.
## Negative effects stack duration on top of an existing instance instead of
## creating a second copy.
func apply_effect(effect: StatusEffect, applier: String) -> void:
	if not effect or effect.effect_id.is_empty():
		return

	# Negative effects extend duration when already active.
	if effect.is_negative and _active_effects.has(effect.effect_id):
		_active_effects[effect.effect_id]["remaining"] += effect.base_duration
		return

	# Create a fresh runtime instance.
	var state: Dictionary = {}
	_active_effects[effect.effect_id] = {
		"effect": effect,
		"remaining": effect.base_duration,
		"applier": applier,
		"tick_timer": effect.tick_interval if effect.tick_interval > 0.0 else 0.0,
		"state": state,
	}

	effect._on_apply(_player, applier, state)
	effect_applied.emit(effect.effect_id)


## Force-remove an effect by id.
func remove_effect(effect_id: String) -> void:
	if not _active_effects.has(effect_id):
		return
	var data: Dictionary = _active_effects[effect_id]
	data["effect"]._on_remove(_player, data.get("state", {}))
	_active_effects.erase(effect_id)
	effect_removed.emit(effect_id)


## Returns true if an effect with the given id is currently active.
func has_effect(effect_id: String) -> bool:
	return _active_effects.has(effect_id)


## Remove all effects marked is_negative.
func clear_negative_effects() -> void:
	var to_remove: Array[String] = []
	for id in _active_effects:
		var data: Dictionary = _active_effects[id]
		if data["effect"].is_negative:
			to_remove.append(id)
	for id in to_remove:
		remove_effect(id)


## Remove every active effect (used on death / respawn).
func clear_all_effects() -> void:
	var ids: Array = _active_effects.keys()
	for id in ids:
		remove_effect(id)


## Whether the player is currently invincible.
func is_invincible() -> bool:
	return _active_effects.has("invincible")


## Whether the player is currently stunned.
func is_stunned() -> bool:
	return _active_effects.has("stun")


## Returns the per-instance state dictionary for an effect, if it's active.
## Useful for UI to inspect poison's drain_started flag, etc.
func get_effect_state(effect_id: String) -> Dictionary:
	if _active_effects.has(effect_id):
		return _active_effects[effect_id].get("state", {})
	return {}


## Returns a dictionary of {effect_id: remaining_time} for all active effects.
func get_active_effect_times() -> Dictionary:
	var result: Dictionary = {}
	for id in _active_effects:
		result[id] = _active_effects[id]["remaining"]
	return result
