extends Node
class_name LeaderboardComponent

var _player_kills: Dictionary = {}
var _player_deaths: Dictionary = {}

@rpc("any_peer", "call_local")
func _add_player(player_name: String):
	if not multiplayer.is_server():
		return
	
	_player_deaths[player_name] = 0
	_player_kills[player_name] = 0
	
	print("Player %s added" % player_name)
	_sync_scores()

@rpc("any_peer", "call_local")
func _add_death(dead_player_name: String):
	if not multiplayer.is_server():
		return
	
	_player_deaths[dead_player_name] = _player_deaths.get(dead_player_name, 0) + 1
	
	print("Death:", dead_player_name)
	_sync_scores()

@rpc("any_peer", "call_local")
func _add_kill(killer_name: String):
	if not multiplayer.is_server():
		return
	
	_player_kills[killer_name] = _player_kills.get(killer_name, 0) + 1
	
	print("Kill:", killer_name)
	_sync_scores()

# -------------------------
# SYNC
# -------------------------

func _sync_scores():
	# send to all clients
	rpc("_receive_scores", _player_kills, _player_deaths)

@rpc("any_peer", "reliable")
func _receive_scores(kills: Dictionary, deaths: Dictionary):
	print("Received scores on peer:", multiplayer.get_unique_id())
	
	_player_kills = kills.duplicate()
	_player_deaths = deaths.duplicate()

func request_add_kill(killer_name: String):
	_add_kill.rpc_id(1, killer_name)

func request_add_death(dead_name: String):
	_add_death.rpc_id(1, dead_name)

func request_add_player(player_name: String):
	_add_player.rpc_id(1, player_name)
# -------------------------
# READ API
# -------------------------

func get_players() -> Array:
	var players = {}
	
	for p in _player_kills.keys():
		players[p] = true
	for p in _player_deaths.keys():
		players[p] = true
	
	return players.keys()

func get_kills(player_name: String) -> int:
	return _player_kills.get(player_name, 0)

func get_deaths(player_name: String) -> int:
	return _player_deaths.get(player_name, 0)
