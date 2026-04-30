extends Node
class_name EscortMode

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal round_won(winning_team: Player.Team)

# ─────────────────────────────────────────────
#  STATE  (injected by GameModeComponent)
# ─────────────────────────────────────────────

var _payload: PayloadNode = null

# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func register_payload(p: PayloadNode) -> void:
	_payload = p

func tick(_delta: float) -> void:
	pass  # PayloadNode drives itself and calls on_payload_delivered()

func on_payload_delivered(winning_team: Player.Team) -> void:
	round_won.emit(winning_team)

func is_contested() -> bool:
	if _payload:
		return _payload.is_contested or _payload.is_being_pushed
	return false

func reset() -> void:
	pass  # PayloadNode resets itself via round_won signal
