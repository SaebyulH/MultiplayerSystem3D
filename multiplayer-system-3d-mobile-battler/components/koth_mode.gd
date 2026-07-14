extends Node
class_name KothMode

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal round_won(winning_team: Player.Team)
signal time_held_updated(time_held: Dictionary)

# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

## How long a team must hold the point to win the round (seconds)
@export var capture_time_to_win: float = 30.0
## Whether the capture clock pauses when the point is contested
@export var pause_on_contest: bool = true

# ─────────────────────────────────────────────
#  STATE  (injected by GameModeComponent)
# ─────────────────────────────────────────────
func get_sync_state() -> Dictionary:
	return {
		"time_held": time_held,
		"contested": _is_contested(),
	}

func apply_sync_state(state: Dictionary) -> void:
	time_held = state.get("time_held", time_held)





var _control_points: Array[ControlPoint] = []

var time_held: Dictionary = {
	Player.Team.SPI: 0.0,
	Player.Team.SCI: 0.0,
}

# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func register_control_point(cp: ControlPoint) -> void:
	if cp not in _control_points:
		_control_points.append(cp)

func unregister_control_point(cp: ControlPoint) -> void:
	_control_points.erase(cp)

func tick(delta: float) -> void:
	var holding_team := _get_holder()
	var contested := _is_contested()

	if holding_team != Player.Team.FFA:
		if not (pause_on_contest and contested):
			time_held[holding_team] += delta
			time_held_updated.emit(time_held)
			if time_held[holding_team] >= capture_time_to_win:
				round_won.emit(holding_team)

func is_contested() -> bool:
	return _is_contested()

func determine_tiebreak_winner() -> Player.Team:
	if time_held[Player.Team.SPI] > time_held[Player.Team.SCI]:
		return Player.Team.SPI
	elif time_held[Player.Team.SCI] > time_held[Player.Team.SPI]:
		return Player.Team.SCI
	return Player.Team.FFA

func reset() -> void:
	time_held[Player.Team.SPI] = 0.0
	time_held[Player.Team.SCI] = 0.0
	for cp in _control_points:
		cp.reset_for_new_round()

# ─────────────────────────────────────────────
#  INTERNAL
# ─────────────────────────────────────────────

func _get_holder() -> Player.Team:
	if _control_points.is_empty():
		return Player.Team.FFA
	return _control_points[0].owning_team

func _is_contested() -> bool:
	if _control_points.is_empty():
		return false
	return _control_points[0].is_contested
