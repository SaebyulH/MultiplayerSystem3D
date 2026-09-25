extends Node
class_name StatusEffectManager

## ---------------------------------------------------------------------------
## StatusEffectManager — runtime tracker for active status effects on a Player.
##
## Add this node as a child of Player.  It ticks all active effects on a
## periodic Timer, handles negative-effect stacking (extends duration), and
## exposes query methods (is_invincible, is_stunned) for other systems.
##
## Networking: effects are applied and ticked entirely on the server.
## Remaining times are pushed to clients on apply/remove and on a periodic
## timer (~10 Hz) — not every frame.  Clients do NO local ticking — the server
## is the sole timing authority.
## ---------------------------------------------------------------------------

signal effect_applied(effect_id: String)
signal effect_removed(effect_id: String)
## Emitted whenever the client-facing effect mirror changes — on the server
## after a sync, and on clients when an RPC sync arrives.  UI listens to this
## to rebuild effect displays instead of polling every frame.
signal client_effects_changed()

## { effect_id : { effect, remaining, applier, state } } — server only.
var _active_effects: Dictionary = {}

## { effect_id : remaining } — mirror kept in sync by the server and pushed
## to clients via RPC.  This is the single source read by UI on all peers.
var _client_effects: Dictionary = {}

## { effect_id : display_name } — mirrored alongside _client_effects so clients
## can show human-readable effect names without holding the effect resources.
var _client_effect_names: Dictionary = {}

var _player: Player = null

## How often (seconds) the server ticks active effects and pushes remaining
## times to clients.  Effect durations are ~0.5 s+, so 0.1 s granularity is
## plenty, and it cuts the sync RPC from render-rate to ~10 Hz.
const TICK_INTERVAL: float = 0.1

var _tick_timer: Timer


func _ready() -> void:
	_player = get_parent() as Player
	_tick_timer = Timer.new()
	_tick_timer.name = "EffectTickTimer"
	_tick_timer.wait_time = TICK_INTERVAL
	_tick_timer.one_shot = false
	_tick_timer.timeout.connect(_on_tick_timeout)
	add_child(_tick_timer)


func _on_tick_timeout() -> void:
	if not _player or not _player.spawned:
		return

	if not multiplayer.is_server():
		return  # Only the server ticks — clients receive times via RPC.

	_tick_server(TICK_INTERVAL)


func _tick_server(delta: float) -> void:
	var expired: Array[String] = []

	# Iterate a key snapshot: an effect's teardown can remove other effects (and
	# itself) through this manager, which would invalidate a live iteration.
	for id in _active_effects.keys():
		if not _active_effects.has(id):
			continue  # removed by an earlier teardown in this same pass
		var data: Dictionary = _active_effects[id]
		var effect: StatusEffect = data["effect"]
		var remaining: float = data["remaining"]

		# Permanent effects never tick down or expire.
		if effect.is_permanent:
			continue

		remaining -= delta
		data["remaining"] = remaining

		if remaining <= 0.0:
			# Deregister before the teardown, for the same re-entrancy reason as
			# remove_effect(): `_on_remove` may run clear_all_effects() from
			# inside itself, and running it twice on one expiry is never right.
			_active_effects.erase(id)
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
		effect_removed.emit(id)

	# Only push a snapshot when there is a *timed* effect to update (or one just
	# expired). Permanent markers (wallhacked/health-visible) never change, so
	# re-broadcasting them at 10 Hz was pure waste — and, because every player
	# always carries two passives, the timer never idled and every bot broadcast
	# an RPC every 100 ms forever.
	var has_timed := false
	for id in _active_effects:
		if not _active_effects[id]["effect"].is_permanent:
			has_timed = true
			break

	if has_timed or not expired.is_empty():
		_sync_to_clients()

	# Stop ticking once no timed effect remains (restarted by the next apply).
	if not has_timed:
		_tick_timer.stop()
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
		_sync_to_clients()
		return

	# Create a fresh runtime instance.  Permanent effects use an infinite
	# remaining time so they never expire (skipped by _tick_server).
	var remaining: float = INF if effect.is_permanent else effect.base_duration
	var state: Dictionary = {}
	_active_effects[effect.effect_id] = {
		"effect": effect,
		"remaining": remaining,
		"applier": applier,
		"tick_timer": effect.tick_interval if effect.tick_interval > 0.0 else 0.0,
		"state": state,
	}

	effect._on_apply(_player, applier, state)
	effect_applied.emit(effect.effect_id)
	if not effect.is_permanent and _tick_timer.is_stopped():
		_tick_timer.start()
	_sync_to_clients()


## Force-remove an effect by id (server-authoritative).
func remove_effect(effect_id: String) -> void:
	if not multiplayer.is_server():
		return
	if not _active_effects.has(effect_id):
		return
	# Deregister *before* running the teardown, then tear down.  `_on_remove` can
	# re-enter this manager: EnlargeEffect writes the player's health back, and
	# AttributeComponent's `health` setter emits `no_health` whenever the value
	# lands at <= 0, which calls clear_all_effects().  While the id was still
	# registered that re-entry ran `_on_remove` again, unbounded — the stack
	# overflow at 1024 frames.  Erasing first makes any re-entry a no-op, so this
	# holds for every current and future effect, not just the one that bit us.
	var data: Dictionary = _active_effects[effect_id]
	_active_effects.erase(effect_id)
	_client_effects.erase(effect_id)
	_client_effect_names.erase(effect_id)
	data["effect"]._on_remove(_player, data.get("state", {}))
	effect_removed.emit(effect_id)
	_sync_to_clients()
	if _active_effects.is_empty():
		_tick_timer.stop()


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
	for id in _active_effects.keys():
		remove_effect(id)
	# Force an empty snapshot to clients even when there were no active effects to
	# remove, so a stale client mirror can never survive a respawn.
	_sync_to_clients()


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

func _sync_to_clients(target_peer: int = 0) -> void:
	"""Push the authoritative remaining-time snapshot to all peers (or one peer)."""
	if not multiplayer.is_server():
		return
	_refresh_client_mirror()
	var ids: Array = []
	var names: Array = []
	var times: Array = []
	for id in _client_effects:
		ids.append(id)
		names.append(_client_effect_names.get(id, id))
		times.append(_client_effects[id])
	if target_peer > 0:
		_rpc_sync_effects.rpc_id(target_peer, ids, names, times)
	else:
		_rpc_sync_effects.rpc(ids, names, times)
	client_effects_changed.emit()


## Rebuild [_client_effects] / [_client_effect_names] from [_active_effects].
## Poison is hidden until its 3 s drain delay elapses (drain_started == true).
func _refresh_client_mirror() -> void:
	_client_effects.clear()
	_client_effect_names.clear()
	for id in _active_effects:
		var data: Dictionary = _active_effects[id]
		if id == "poison" and not data.get("state", {}).get("drain_started", false):
			continue
		_client_effects[id] = data["remaining"]
		_client_effect_names[id] = data["effect"].display_name


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_effects(effect_ids: Array, effect_names: Array, remaining_times: Array) -> void:
	_client_effects.clear()
	_client_effect_names.clear()
	for i in effect_ids.size():
		_client_effects[effect_ids[i]] = remaining_times[i]
		_client_effect_names[effect_ids[i]] = effect_names[i]
	client_effects_changed.emit()
