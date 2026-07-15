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


# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

## Number of kills required to win the match.
@export var kills_to_win: int = 20

## Duration of the round in seconds (overrides GameModeComponent.round_time).
@export var round_duration: float = 600.0  # 10 minutes


# ─────────────────────────────────────────────
#  STATE  (synced to clients via GameModeComponent)
# ─────────────────────────────────────────────

var winner_name: String = ""  # "" = no winner yet
var end_reason: String  = ""  # "kills" | "time" | ""


# ─────────────────────────────────────────────
#  SYNC STATE  (for _rpc_sync_state)
# ─────────────────────────────────────────────

func get_sync_state() -> Dictionary:
	return {
		"winner_name": winner_name,
		"end_reason": end_reason,
	}

func apply_sync_state(state: Dictionary) -> void:
	winner_name = state.get("winner_name", winner_name)
	end_reason = state.get("end_reason", end_reason)


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

	return false


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


# ─────────────────────────────────────────────
#  INTERNAL
# ─────────────────────────────────────────────

func _end_match(player_name: String, reason: String) -> void:
	winner_name = player_name
	end_reason = reason
	deathmatch_ended.emit(winner_name, end_reason)
