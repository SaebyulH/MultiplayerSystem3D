extends Node
class_name DominationMode

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal round_won(winning_team: Player.Team)
signal points_updated(points: Dictionary)

# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

## Points required to win the round
@export var points_to_win: float = 100.0
## Points earned per second per captured control point
@export var points_per_second_per_point: float = 1.0
## Rounds needed to win the match (overrides GameModeComponent.rounds_to_win when > 0)
@export var rounds_to_win: int = 1

# ─────────────────────────────────────────────
#  STATE
# ─────────────────────────────────────────────

var _control_points: Array[ControlPoint] = []

var points: Dictionary = {
	Player.Team.SPI: 0.0,
	Player.Team.SCI: 0.0,
}


func get_sync_state() -> Dictionary:
	var cp_states: Array[Dictionary] = []
	for cp in _control_points:
		cp_states.append(cp.get_cp_state())
	return {
		"points": points,
		"control_points": cp_states,
	}

func apply_sync_state(state: Dictionary) -> void:
	points = state.get("points", points)

	# Apply control-point states so late-joiners see current capture progress
	var cp_states: Array = state.get("control_points", [])
	for i in mini(cp_states.size(), _control_points.size()):
		_control_points[i].apply_cp_state(cp_states[i])




# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func register_control_point(cp: ControlPoint) -> void:
	if cp not in _control_points:
		_control_points.append(cp)

func unregister_control_point(cp: ControlPoint) -> void:
	_control_points.erase(cp)

## Returns snapshot dictionaries for all registered control points.
func get_cp_states() -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for cp in _control_points:
		states.append(cp.get_cp_state())
	return states

func tick(delta: float) -> void:
	var owned := _count_owned_points()

	for team in owned:
		if owned[team] == 0:
			continue
		points[team] += owned[team] * points_per_second_per_point * delta

	points_updated.emit(points)

	for team in points:
		if points[team] >= points_to_win:
			round_won.emit(team)
			return

func determine_tiebreak_winner() -> Player.Team:
	if points[Player.Team.SPI] > points[Player.Team.SCI]:
		return Player.Team.SPI
	elif points[Player.Team.SCI] > points[Player.Team.SPI]:
		return Player.Team.SCI
	return Player.Team.FFA

func reset() -> void:
	points[Player.Team.SPI] = 0.0
	points[Player.Team.SCI] = 0.0
	for cp in _control_points:
		cp.reset_for_new_round()

# ─────────────────────────────────────────────
#  INTERNAL
# ─────────────────────────────────────────────

## Returns how many control points each team currently owns
func _count_owned_points() -> Dictionary:
	var owned: Dictionary = {
		Player.Team.SPI: 0,
		Player.Team.SCI: 0,
	}
	for cp in _control_points:
		if cp.owning_team in owned:
			owned[cp.owning_team] += 1
	return owned
