extends Node
#class_name LeaderboardComponent
#
var _player_kills: Dictionary = {}
var _player_deaths: Dictionary = {}

var _killstreak: Dictionary = {}
var _damage_dealt: Dictionary = {}
var _self_damage: Dictionary = {}
var _self_heal: Dictionary = {}
var _heal_others: Dictionary = {}
var _dirty: bool = false
var _sync_cooldown: float = 0.0
const LEADERBOARD_SYNC_INTERVAL: float = 0.5

signal killstreak_changed(player_name: String, killstreak: int)
signal player_removed(player_name: String)
signal kill_feed_entry(killer_name: String, victim_name: String, weapon_name: String)

# -------------------------
# PLAYER MANAGEMENT
# -------------------------

func _ready() -> void:
	if multiplayer.is_server():
		set_multiplayer_authority(1)

@rpc("any_peer", "call_local")
func _add_player(player_name: String):
	if not multiplayer.is_server():
		return

	_player_deaths[player_name] = 0
	_player_kills[player_name] = 0

	_killstreak[player_name] = 0
	_damage_dealt[player_name] = 0
	_self_damage[player_name] = 0
	_self_heal[player_name] = 0
	_heal_others[player_name] = 0

	if OS.is_debug_build():
		print("Player %s added" % player_name)
	_mark_dirty()

@rpc("any_peer", "call_local")
func _remove_player(player_name: String):
	if not multiplayer.is_server():
		return

	_player_kills.erase(player_name)
	_player_deaths.erase(player_name)
	_killstreak.erase(player_name)
	_damage_dealt.erase(player_name)
	_self_damage.erase(player_name)
	_self_heal.erase(player_name)
	_heal_others.erase(player_name)

	if OS.is_debug_build():
		print("Player %s removed" % player_name)
	_mark_dirty()
	rpc("_receive_player_removed", player_name)

# -------------------------
# COMBAT EVENTS
# -------------------------

@rpc("any_peer", "call_local")
func _add_kill(killer_name: String, victim_name: String = "", weapon_name: String = ""):
	if not multiplayer.is_server():
		return

	_player_kills[killer_name] = _player_kills.get(killer_name, 0) + 1
	_killstreak[killer_name] = _killstreak.get(killer_name, 0) + 1
	_mark_dirty()
	killstreak_changed.emit(killer_name, _killstreak[killer_name])

	# Broadcast kill feed event to all peers.
	if not victim_name.is_empty():
		_broadcast_kill_feed.rpc(killer_name, victim_name, weapon_name)
	if OS.is_debug_build():
		print("Kill:", killer_name)


@rpc("any_peer", "call_local")
func _add_death(dead_player_name: String):
	if not multiplayer.is_server():
		return

	_player_deaths[dead_player_name] = _player_deaths.get(dead_player_name, 0) + 1
	_killstreak[dead_player_name] = 0

	if OS.is_debug_build():
		print("Death:", dead_player_name)
	_mark_dirty()


@rpc("any_peer", "call_local")
func _add_damage(player_name: String, amount: float):
	if not multiplayer.is_server():
		return

	_damage_dealt[player_name] = _damage_dealt.get(player_name, 0) + amount
	_mark_dirty()


# -------------------------
# SELF DAMAGE
# -------------------------

@rpc("any_peer", "call_local")
func _add_self_damage(player_name: String, amount: float):
	if not multiplayer.is_server():
		return

	_self_damage[player_name] = _self_damage.get(player_name, 0) + amount
	_mark_dirty()


@rpc("any_peer", "call_local")
func _add_self_heal(player_name: String, amount: float):
	if not multiplayer.is_server():
		return

	_self_heal[player_name] = _self_heal.get(player_name, 0) + amount
	_mark_dirty()


@rpc("any_peer", "call_local")
func _add_heal_other(healer_name: String, amount: float):
	if not multiplayer.is_server():
		return

	_heal_others[healer_name] = _heal_others.get(healer_name, 0) + amount
	_mark_dirty()

# -------------------------
# SYNC
# -------------------------

func _mark_dirty() -> void:
	_dirty = true

func _process(delta: float) -> void:
	if not _dirty:
		return
	_sync_cooldown -= delta
	if _sync_cooldown <= 0.0:
		_sync_cooldown = LEADERBOARD_SYNC_INTERVAL
		_dirty = false
		_sync_scores()

func _sync_scores():
	rpc("_receive_scores",
		_player_kills,
		_player_deaths,
		_killstreak,
		_damage_dealt,
		_self_damage,
		_self_heal,
		_heal_others
	)


@rpc("any_peer", "reliable")
func _receive_scores(kills: Dictionary,
	deaths: Dictionary,
	killstreak: Dictionary,
	damage: Dictionary,
	self_damage: Dictionary,
	self_heal: Dictionary,
	heal_others: Dictionary):

	_player_kills = kills.duplicate()
	_player_deaths = deaths.duplicate()
	_damage_dealt = damage.duplicate()
	_self_damage = self_damage.duplicate()
	_self_heal = self_heal.duplicate()
	_heal_others = heal_others.duplicate()

	for player_name in killstreak.keys():
		var new_streak: int = killstreak[player_name]
		if _killstreak.get(player_name, 0) != new_streak:
			killstreak_changed.emit(player_name, new_streak)

	_killstreak = killstreak.duplicate()


@rpc("any_peer", "reliable")
func _receive_player_removed(player_name: String):
	player_removed.emit(player_name)

## Broadcasts a single kill event to all peers for the kill feed.
@rpc("any_peer", "call_local", "reliable")
func _broadcast_kill_feed(killer_name: String, victim_name: String, weapon_name: String) -> void:
	kill_feed_entry.emit(killer_name, victim_name, weapon_name)

# -------------------------
# REQUEST API
# -------------------------

func request_add_player(player_name: String):
	_add_player.rpc_id(1, player_name)

func request_remove_player(player_name: String):
	_remove_player.rpc_id(1, player_name)

func request_add_kill(killer_name: String, victim_name: String = "", weapon_name: String = ""):
	_add_kill.rpc_id(1, killer_name, victim_name, weapon_name)

func request_add_death(dead_name: String):
	_add_death.rpc_id(1, dead_name)

func request_add_damage(player_name: String, amount: float):
	_add_damage.rpc_id(1, player_name, amount)

func request_add_self_damage(player_name: String, amount: float):
	_add_self_damage.rpc_id(1, player_name, amount)

func request_add_self_heal(player_name: String, amount: float):
	_add_self_heal.rpc_id(1, player_name, amount)

func request_add_heal_other(healer_name: String, amount: float):
	_add_heal_other.rpc_id(1, healer_name, amount)

# -------------------------
# READ API
# -------------------------

func get_players() -> Array:
	var players = {}

	for p in _player_kills.keys():
		players[p] = true
	for p in _player_deaths.keys():
		players[p] = true
	for p in _damage_dealt.keys():
		players[p] = true
	for p in _self_damage.keys():
		players[p] = true
	for p in _self_heal.keys():
		players[p] = true
	for p in _heal_others.keys():
		players[p] = true

	return players.keys()


func get_kills(player_name: String) -> int:
	return _player_kills.get(player_name, 0)

func get_deaths(player_name: String) -> int:
	return _player_deaths.get(player_name, 0)

func get_killstreak(player_name: String) -> int:
	return _killstreak.get(player_name, 0)

func get_damage(player_name: String) -> float:
	return _damage_dealt.get(player_name, 0)

func get_self_damage(player_name: String) -> float:
	return _self_damage.get(player_name, 0)

func get_self_heal(player_name: String) -> float:
	return _self_heal.get(player_name, 0)

func get_heal_others(player_name: String) -> float:
	return _heal_others.get(player_name, 0)

func has_player(player_name: String) -> bool:
	return _player_kills.has(player_name)
