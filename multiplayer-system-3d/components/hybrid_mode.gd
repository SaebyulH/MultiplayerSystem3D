extends Node
class_name HybridMode

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal round_won(winning_team: Player.Team)
signal point_captured()

# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

## How long SPI must hold the capture point to unlock the payload
@export var capture_time_to_win: float = 30.0
## Whether the capture clock pauses when the point is contested
@export var pause_on_contest: bool = true

# ─────────────────────────────────────────────
#  STATE  (injected by GameModeComponent)
# ─────────────────────────────────────────────

var _payload: PayloadNode = null
var _control_points: Array[ControlPoint] = []

var point_is_captured: bool = false
var time_held: float = 0.0

# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func register_payload(p: PayloadNode) -> void:
	_payload = p

func register_control_point(cp: ControlPoint) -> void:
	if cp not in _control_points:
		_control_points.append(cp)

func unregister_control_point(cp: ControlPoint) -> void:
	_control_points.erase(cp)

func tick(delta: float) -> void:
	if point_is_captured:
		return  # Phase 2: PayloadNode drives itself

	# Phase 1: KOTH-style cap for attackers only
	var holder := _get_holder()
	var contested := _is_contested()

	if holder == Player.Team.SPI:
		if not (pause_on_contest and contested):
			time_held += delta
			if time_held >= capture_time_to_win:
				_on_point_captured()

func on_payload_delivered(winning_team: Player.Team) -> void:
	round_won.emit(winning_team)

func is_objective_contested() -> bool:
	if not point_is_captured:
		return _is_contested()
	if _payload:
		return _payload.is_contested or _payload.is_being_pushed
	return false

func reset() -> void:
	point_is_captured = false
	time_held = 0.0
	if _payload:
		_payload.set_locked(true)
	for cp in _control_points:
		cp.reset_for_new_round()

# ─────────────────────────────────────────────
#  INTERNAL
# ─────────────────────────────────────────────

func _on_point_captured() -> void:
	point_is_captured = true
	if _payload:
		_payload.set_locked(false)
	point_captured.emit()

func _get_holder() -> Player.Team:
	if _control_points.is_empty():
		return Player.Team.FFA
	return _control_points[0].owning_team

func _is_contested() -> bool:
	if _control_points.is_empty():
		return false
	return _control_points[0].is_contested
