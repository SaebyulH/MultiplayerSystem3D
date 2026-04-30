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
@export var points_to_win: float = 1000.0
## Points earned per second per captured control point
@export var points_per_second_per_point: float = 1.0

# ─────────────────────────────────────────────
#  STATE
# ─────────────────────────────────────────────

var _control_points: Array[ControlPoint] = []

var points: Dictionary = {
	Player.Team.SPI: 0.0,
	Player.Team.SCI: 0.0,
}


func get_sync_state() -> Dictionary:
	return {
		"points": points,
	}

func apply_sync_state(state: Dictionary) -> void:
	points = state.get("points", points)




# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func register_control_point(cp: ControlPoint) -> void:
	if cp not in _control_points:
		_control_points.append(cp)

func unregister_control_point(cp: ControlPoint) -> void:
	_control_points.erase(cp)

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
