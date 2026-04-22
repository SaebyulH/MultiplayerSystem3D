#extends Node
##class_name LeaderboardComponent
##
#var _player_kills: Dictionary = {}
#var _player_deaths: Dictionary = {}
#
#var _killstreak: Dictionary = {}
#var _damage_dealt: Dictionary = {}
#var _self_damage: Dictionary = {}
#var _self_heal: Dictionary = {}
#var _heal_others: Dictionary = {}
#
#signal killstreak_changed(killer_name: String)
#
## -------------------------
## PLAYER MANAGEMENT
## -------------------------
#
#func _ready() -> void:
	#if multiplayer.is_server():
		#set_multiplayer_authority(1) # server peer id
#
#@rpc("any_peer", "call_local")
#func _add_player(player_name: String):
	#if not multiplayer.is_server():
		#return
#
	#_player_deaths[player_name] = 0
	#_player_kills[player_name] = 0
#
	#_killstreak[player_name] = 0
	#_damage_dealt[player_name] = 0
	#_self_damage[player_name] = 0
	#_self_heal[player_name] = 0
	#_heal_others[player_name] = 0
#
	#print("Player %s added" % player_name)
	#_sync_scores()
#
## -------------------------
## COMBAT EVENTS
## -------------------------
#
#@rpc("any_peer", "call_local")
#func _add_kill(killer_name: String):
	#if not multiplayer.is_server():
		#return
#
	#_player_kills[killer_name] = _player_kills.get(killer_name, 0) + 1
	#_killstreak[killer_name] = _killstreak.get(killer_name, 0) + 1
	#_sync_scores()
	#killstreak_changed.emit(killer_name)
	#print("Kill:", killer_name)
#
#
#@rpc("any_peer", "call_local")
#func _add_death(dead_player_name: String):
	#if not multiplayer.is_server():
		#return
#
	#_player_deaths[dead_player_name] = _player_deaths.get(dead_player_name, 0) + 1
	#_killstreak[dead_player_name] = 0
#
	#print("Death:", dead_player_name)
	#_sync_scores()
#
#
#@rpc("any_peer", "call_local")
#func _add_damage(player_name: String, amount: float):
	#if not multiplayer.is_server():
		#return
#
	#_damage_dealt[player_name] = _damage_dealt.get(player_name, 0) + amount
	#_sync_scores()
#
#
## -------------------------
## NEW: SELF DAMAGE
## -------------------------
#
#@rpc("any_peer", "call_local")
#func _add_self_damage(player_name: String, amount: float):
	#if not multiplayer.is_server():
		#return
#
	#_self_damage[player_name] = _self_damage.get(player_name, 0) + amount
	#_sync_scores()
#
#
#@rpc("any_peer", "call_local")
#func _add_self_heal(player_name: String, amount: float):
	#if not multiplayer.is_server():
		#return
#
	#_self_heal[player_name] = _self_heal.get(player_name, 0) + amount
	#_sync_scores()
#
#
#@rpc("any_peer", "call_local")
#func _add_heal_other(healer_name: String, amount: float):
	#if not multiplayer.is_server():
		#return
#
	#_heal_others[healer_name] = _heal_others.get(healer_name, 0) + amount
	#_sync_scores()
#
## -------------------------
## SYNC
## -------------------------
#
#func _sync_scores():
	#rpc("_receive_scores",
		#_player_kills,
		#_player_deaths,
		#_killstreak,
		#_damage_dealt,
		#_self_damage,
		#_self_heal,
		#_heal_others
	#)
#
#
#@rpc("any_peer", "reliable")
#func _receive_scores(kills: Dictionary,
#
	#deaths: Dictionary,
	#killstreak: Dictionary,
	#damage: Dictionary,
	#self_damage: Dictionary,
	#self_heal: Dictionary,
	#heal_others: Dictionary):
#
	#_player_kills = kills.duplicate()
	#_player_deaths = deaths.duplicate()
	#_killstreak = killstreak.duplicate()
	#_damage_dealt = damage.duplicate()
	#_self_damage = self_damage.duplicate()
	#_self_heal = self_heal.duplicate()
	#_heal_others = heal_others.duplicate()
	#
#
## -------------------------
## REQUEST API
## -------------------------
#
#func request_add_player(player_name: String):
	#_add_player.rpc_id(1, player_name)
#
#func request_add_kill(killer_name: String):
	#_add_kill.rpc_id(1, killer_name)
#
#func request_add_death(dead_name: String):
	#_add_death.rpc_id(1, dead_name)
#
#func request_add_damage(player_name: String, amount: float):
	#_add_damage.rpc_id(1, player_name, amount)
#
#func request_add_self_damage(player_name: String, amount: float):
	#_add_self_damage.rpc_id(1, player_name, amount)
#
#func request_add_self_heal(player_name: String, amount: float):
	#_add_self_heal.rpc_id(1, player_name, amount)
#
#func request_add_heal_other(healer_name: String, amount: float):
	#_add_heal_other.rpc_id(1, healer_name, amount)
#
## -------------------------
## READ API
## -------------------------
#
#func get_players() -> Array:
	#var players = {}
#
	#for p in _player_kills.keys():
		#players[p] = true
	#for p in _player_deaths.keys():
		#players[p] = true
	#for p in _damage_dealt.keys():
		#players[p] = true
	#for p in _self_damage.keys():
		#players[p] = true
	#for p in _self_heal.keys():
		#players[p] = true
	#for p in _heal_others.keys():
		#players[p] = true
#
	#return players.keys()
#
#
#func get_kills(player_name: String) -> int:
	#return _player_kills.get(player_name, 0)
#
#func get_deaths(player_name: String) -> int:
	#return _player_deaths.get(player_name, 0)
#
#func get_killstreak(player_name: String) -> int:
	#return _killstreak.get(player_name, 0)
#
#func get_damage(player_name: String) -> float:
	#return _damage_dealt.get(player_name, 0)
#
#func get_self_damage(player_name: String) -> float:
	#return _self_damage.get(player_name, 0)
#
#func get_self_heal(player_name: String) -> float:
	#return _self_heal.get(player_name, 0)
#
#func get_heal_others(player_name: String) -> float:
	#return _heal_others.get(player_name, 0)
