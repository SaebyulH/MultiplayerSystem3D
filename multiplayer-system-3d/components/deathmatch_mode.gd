extends Node
class_name DeathmatchMode

## Deathmatch game-mode logic.
##
## Runs on the server.  Kills are already tracked by the Leaderboard
## singleton (autoload), so this mode simply polls that data and
## signals when a kill-limit or timer-expiry winner is found.

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal deathmatch_ended(winner_name: String, reason: String)
signal announce_kills_remaining(remaining: int)


# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

## Number of kills required to win the match.
@export var kills_to_win: int = 30

## Duration of the round in seconds (overrides GameModeComponent.round_time).
@export var round_duration: float = 600.0  # 10 minutes


# ─────────────────────────────────────────────
#  STATE  (synced to clients via GameModeComponent)
# ─────────────────────────────────────────────

var winner_name: String = ""  # "" = no winner yet
var end_reason: String  = ""  # "kills" | "time" | ""

## Kill counts (of the leader) that trigger a "N kills remaining" announcement.
const ANNOUNCE_REMAINING: Array[int] = [10, 5, 1]

## Which "kills remaining" thresholds have already been announced this match.
var _announced_remaining: Dictionary = {}

## Final player ordering (best first) computed at match end, synced to clients
## so each can play its own podium/defeat line.
var standings: Array = []


# ─────────────────────────────────────────────
#  SYNC STATE  (for _rpc_sync_state)
# ─────────────────────────────────────────────

func get_sync_state() -> Dictionary:
	return {
		"winner_name": winner_name,
		"end_reason": end_reason,
		"standings": standings,
	}

func apply_sync_state(state: Dictionary) -> void:
	winner_name = state.get("winner_name", winner_name)
	end_reason = state.get("end_reason", end_reason)
	standings = state.get("standings", standings)


# ─────────────────────────────────────────────
#  TICK  (called from GameModeComponent._tick_active)
# ─────────────────────────────────────────────

## Returns true if the match has ended this tick.
func tick() -> bool:
	if winner_name != "":
		return true  # Already ended

	# Check each player's kill count against the threshold.
	for p in Leaderboard.get_players():
		if Leaderboard.get_kills(p) >= kills_to_win:
			_end_match(p, "kills")
			return true

	_check_kill_thresholds()
	return false


## Announce when the leader is 10 / 5 / 1 kills away from the kill limit.
## Kills only ever increase in deathmatch, so each threshold fires at most once.
func _check_kill_thresholds() -> void:
	var leader := _max_kills()
	for remaining in ANNOUNCE_REMAINING:
		if remaining >= kills_to_win:
			continue
		if _announced_remaining.has(remaining):
			continue
		if leader >= kills_to_win - remaining:
			_announced_remaining[remaining] = true
			announce_kills_remaining.emit(remaining)


func _max_kills() -> int:
	var most := 0
	for p in Leaderboard.get_players():
		most = maxi(most, Leaderboard.get_kills(p))
	return most


## Called when the round timer expires.  Finds the player with
## the most kills and ends the match.
func determine_timer_winner() -> String:
	if winner_name != "":
		return winner_name

	var best := ""
	var most := -1
	for p in Leaderboard.get_players():
		var k := Leaderboard.get_kills(p)
		if k > most:
			most = k
			best = p

	_end_match(best, "time")
	return best


func reset() -> void:
	winner_name = ""
	end_reason = ""
	standings = []
	_announced_remaining.clear()


# ─────────────────────────────────────────────
#  INTERNAL
# ─────────────────────────────────────────────

func _end_match(player_name: String, reason: String) -> void:
	winner_name = player_name
	end_reason = reason
	standings = _compute_standings()
	deathmatch_ended.emit(winner_name, end_reason)


## Final ordering (best first) computed on the server at match end.
func _compute_standings() -> Array:
	var players := Leaderboard.get_players()
	players.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
	return players
