extends Node
class_name StatusEffectManager

## ---------------------------------------------------------------------------
## StatusEffectManager — runtime tracker for active status effects on a Player.
##
## Add this node as a child of Player.  It ticks all active effects in
## _process, handles negative-effect stacking (extends duration), and
## exposes query methods (is_invincible, is_stunned) for other systems.
##
## Networking: effects are applied and ticked entirely on the server.
## Remaining times are pushed to clients every frame while effects are active.
## Clients do NO local ticking — the server is the sole timing authority.
## ---------------------------------------------------------------------------

signal effect_applied(effect_id: String)
signal effect_removed(effect_id: String)

## { effect_id : { effect, remaining, applier, state } } — server only.
var _active_effects: Dictionary = {}

## { effect_id : remaining } — mirror kept in sync by the server and pushed
## to clients via RPC.  This is the single source read by UI on all peers.
var _client_effects: Dictionary = {}

## { effect_id : display_name } — mirrored alongside _client_effects so clients
## can show human-readable effect names without holding the effect resources.
var _client_effect_names: Dictionary = {}

var _player: Player = null


func _ready() -> void:
	_player = get_parent() as Player


func _process(delta: float) -> void:
	if not _player or not _player.spawned:
		return

	if not multiplayer.is_server():
		return  # Only the server ticks — clients receive times via RPC.

	_tick_server(delta)


func _tick_server(delta: float) -> void:
	var expired: Array[String] = []

	for id in _active_effects:
		var data: Dictionary = _active_effects[id]
		var effect: StatusEffect = data["effect"]
		var remaining: float = data["remaining"]

		remaining -= delta
		data["remaining"] = remaining

		if remaining <= 0.0:
			effect._on_remove(_player, data.get("state", {}))
			expired.append(id)
			continue

		# Tick at configured interval.
		if effect.tick_interval > 0.0:
			var tick_timer: float = data.get("tick_timer", 0.0)
			tick_timer -= delta
			while tick_timer <= 0.0:
				tick_timer += effect.tick_interval
				effect._on_tick(_player, data["applier"], data.get("state", {}))
			data["tick_timer"] = tick_timer

	for id in expired:
		_active_effects.erase(id)
		_client_effects.erase(id)
		_client_effect_names.erase(id)
		effect_removed.emit(id)

	# Mirror remaining times into _client_effects so UI reads consistent data
	# on the server too.  Poison is hidden from UI until the 3 s drain delay
	# elapses (drain_started == true).
	for id in _active_effects:
		var data: Dictionary = _active_effects[id]
		if id == "poison" and not data.get("state", {}).get("drain_started", false):
			_client_effects.erase(id)
			_client_effect_names.erase(id)
			continue
		_client_effects[id] = data["remaining"]
		_client_effect_names[id] = data["effect"].display_name

	# Push authoritative times to clients.  Sync whenever there is any change
	# -- including the frame where the last effect expires (empty snapshot).
	var had_effects := not _client_effects.is_empty()
	if had_effects or not expired.is_empty():
		_sync_to_clients()
# ------------------------------------------------------------------ public API

## Apply a status effect to the owning player (server-authoritative).
## Negative effects stack duration on top of an existing instance instead of
## creating a second copy.
func apply_effect(effect: StatusEffect, applier: String) -> void:
	if not effect or effect.effect_id.is_empty():
		return

	if not multiplayer.is_server():
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


## Force-remove an effect by id (server-authoritative).
func remove_effect(effect_id: String) -> void:
	if not multiplayer.is_server():
		return
	if not _active_effects.has(effect_id):
		return
	var data: Dictionary = _active_effects[effect_id]
	data["effect"]._on_remove(_player, data.get("state", {}))
	_active_effects.erase(effect_id)
	_client_effects.erase(effect_id)
	_client_effect_names.erase(effect_id)
	effect_removed.emit(effect_id)
	_sync_to_clients()


## Returns true if an effect with the given id is currently active.
func has_effect(effect_id: String) -> bool:
	return _client_effects.has(effect_id)


## Remove all effects marked is_negative.
func clear_negative_effects() -> void:
	if not multiplayer.is_server():
		return
	var to_remove: Array[String] = []
	for id in _active_effects:
		var data: Dictionary = _active_effects[id]
		if data["effect"].is_negative:
			to_remove.append(id)
	for id in to_remove:
		remove_effect(id)


## Remove every active effect (used on death / respawn).
func clear_all_effects() -> void:
	if not multiplayer.is_server():
		return
	for id in _active_effects:
		remove_effect(id)


## Whether the player is currently invincible.
func is_invincible() -> bool:
	return _client_effects.has("invincible")


## Whether the player is currently stunned.
func is_stunned() -> bool:
	return _client_effects.has("stun")


## Whether the player is currently pinned (carried by a shoulder charge).
func is_pinned() -> bool:
	return _client_effects.has("pinned")


## Returns the per-instance state dictionary for an effect, if it's active.
## Only available on the authority.
func get_effect_state(effect_id: String) -> Dictionary:
	if _active_effects.has(effect_id):
		return _active_effects[effect_id].get("state", {})
	return {}


## Returns a dictionary of {effect_id: remaining_time} for all active effects.
func get_active_effect_times() -> Dictionary:
	var result: Dictionary = {}
	for id in _client_effects:
		result[id] = _client_effects[id]
	return result


## Returns a dictionary of {effect_id: display_name} for all active effects.
func get_active_effect_names() -> Dictionary:
	var result: Dictionary = {}
	for id in _client_effect_names:
		result[id] = _client_effect_names[id]
	return result


# ----------------------------------------------------------------- networking

func _sync_to_clients() -> void:
	"""Push the authoritative remaining-time snapshot to all peers."""
	if not multiplayer.is_server():
		return
	var ids: Array = []
	var names: Array = []
	var times: Array = []
	for id in _client_effects:
		ids.append(id)
		names.append(_client_effect_names.get(id, id))
		times.append(_client_effects[id])
	_rpc_sync_effects.rpc(ids, names, times)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_effects(effect_ids: Array, effect_names: Array, remaining_times: Array) -> void:
	_client_effects.clear()
	_client_effect_names.clear()
	for i in effect_ids.size():
		_client_effects[effect_ids[i]] = remaining_times[i]
		_client_effect_names[effect_ids[i]] = effect_names[i]
