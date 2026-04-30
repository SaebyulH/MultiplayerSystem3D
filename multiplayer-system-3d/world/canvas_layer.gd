extends CanvasLayer

@onready var label: Label = $Label

var gmc: GameModeComponent
var _control_points: Array[ControlPoint] = []
var _initialized := false

# ─────────────────────────────────────────────
#  SETUP
# ─────────────────────────────────────────────

func setup_gmc() -> void:
	await get_tree().process_frame

	gmc = GameManager.game_mode_component
	if not gmc:
		push_warning("HUD: no GameModeComponent found")
		return

	_connect_signals()
	await get_tree().create_timer(0.15).timeout
	_initialized = true

func _connect_signals() -> void:
	gmc.phase_changed.connect(_on_any_change)
	gmc.time_updated.connect(_on_any_change)
	gmc.round_won.connect(_on_any_change)
	gmc.match_won.connect(_on_any_change)
	gmc.overtime_started.connect(_on_any_change)
	gmc.overtime_ended.connect(_on_any_change)
	gmc.koth_updated.connect(_on_any_change)

	if gmc.domination_mode:
		gmc.domination_mode.points_updated.connect(_on_any_change)

	if gmc.hybrid_mode:
		gmc.hybrid_point_captured_signal.connect(_on_any_change)

func register_control_point(cp: ControlPoint) -> void:
	if cp not in _control_points:
		_control_points.append(cp)
		cp.capture_progress_changed.connect(_on_any_change)
		cp.contested.connect(_on_any_change)
		cp.captured.connect(_on_any_change)

# ─────────────────────────────────────────────
#  PROCESS  (fallback polling for return countdown)
# ─────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not _initialized:
		return
	# Payload return countdown isn't signal-driven so we poll it
	var needs_poll := gmc.game_mode in [
		GameModeComponent.GameMode.ESCORT,
		GameModeComponent.GameMode.HYBRID,
	]
	if needs_poll:
		_refresh()

# ─────────────────────────────────────────────
#  SIGNAL SINK
# ─────────────────────────────────────────────

func _on_any_change(_a = null, _b = null, _c = null) -> void:
	_refresh()

# ─────────────────────────────────────────────
#  MAIN REFRESH
# ─────────────────────────────────────────────

func _refresh() -> void:
	if not gmc:
		return
	var lines: Array[String] = []

	lines.append(_phase_line())
	lines.append(_timer_line())
	lines.append(_round_wins_line())
	lines.append("")

	match gmc.game_mode:
		GameModeComponent.GameMode.KOTH, GameModeComponent.GameMode.CONTROL:
			lines.append_array(_koth_lines())
		GameModeComponent.GameMode.DOMINATION:
			lines.append_array(_domination_lines())
		GameModeComponent.GameMode.ESCORT:
			lines.append_array(_escort_lines())
		GameModeComponent.GameMode.HYBRID:
			lines.append_array(_hybrid_lines())

	if not _control_points.is_empty():
		lines.append("")
		lines.append_array(_control_point_lines())

	label.text = "\n".join(lines)

# ─────────────────────────────────────────────
#  SHARED LINES
# ─────────────────────────────────────────────

func _phase_line() -> String:
	var phase_str := _phase_text(gmc.current_phase)
	if gmc.current_phase == GameModeComponent.PhaseState.OVERTIME:
		return "⚠ OVERTIME"
	return phase_str

func _timer_line() -> String:
	if gmc.round_time <= 0.0:
		return "Time: ∞"
	return "Time: %s" % _fmt(gmc.phase_timer)

func _round_wins_line() -> String:
	var spi: int = gmc.round_wins.get(Player.Team.SPI, 0)
	var sci: int = gmc.round_wins.get(Player.Team.SCI, 0)
	var target: int = gmc.rounds_to_win
	return "Rounds  SPI %d/%d  —  SCI %d/%d" % [spi, target, sci, target]

# ─────────────────────────────────────────────
#  MODE LINES
# ─────────────────────────────────────────────

func _koth_lines() -> Array[String]:
	var lines: Array[String] = []
	if not gmc.koth_mode:
		return lines
	var held := gmc.koth_mode.time_held
	var target := gmc.koth_mode.capture_time_to_win
	lines.append("── KOTH ──")
	lines.append("SPI  %s / %s  %s" % [
		_fmt(held.get(Player.Team.SPI, 0.0)),
		_fmt(target),
		_koth_bar(held.get(Player.Team.SPI, 0.0), target),
	])
	lines.append("SCI  %s / %s  %s" % [
		_fmt(held.get(Player.Team.SCI, 0.0)),
		_fmt(target),
		_koth_bar(held.get(Player.Team.SCI, 0.0), target),
	])
	return lines

func _domination_lines() -> Array[String]:
	var lines: Array[String] = []
	if not gmc.domination_mode:
		return lines
	var pts := gmc.domination_mode.points
	var target := gmc.domination_mode.points_to_win
	var owned := _count_owned_points()
	lines.append("── DOMINATION ──")
	lines.append("SPI  %d / %d  (+%d pts/s)  %s" % [
		int(pts.get(Player.Team.SPI, 0.0)),
		int(target),
		owned.get(Player.Team.SPI, 0),
		_score_bar(pts.get(Player.Team.SPI, 0.0), target),
	])
	lines.append("SCI  %d / %d  (+%d pts/s)  %s" % [
		int(pts.get(Player.Team.SCI, 0.0)),
		int(target),
		owned.get(Player.Team.SCI, 0),
		_score_bar(pts.get(Player.Team.SCI, 0.0), target),
	])
	return lines

func _escort_lines() -> Array[String]:
	var lines: Array[String] = []
	var payload := _get_payload()
	if not payload:
		lines.append("── ESCORT ──")
		lines.append("(no payload)")
		return lines
	lines.append("── ESCORT ──")
	lines.append(_payload_line(payload))
	return lines

func _hybrid_lines() -> Array[String]:
	var lines: Array[String] = []
	var hm := gmc.hybrid_mode
	if not hm:
		return lines

	if not hm.point_is_captured:
		lines.append("── HYBRID: CAPTURE PHASE ──")
		var pct := int((hm.time_held / hm.capture_time_to_win) * 100.0)
		lines.append("SPI cap progress: %d%%  %s" % [pct, _progress_bar(hm.time_held, hm.capture_time_to_win)])
	else:
		lines.append("── HYBRID: ESCORT PHASE ──")
		var payload := _get_payload()
		if payload:
			lines.append(_payload_line(payload))
		else:
			lines.append("(no payload)")
	return lines

# ─────────────────────────────────────────────
#  CONTROL POINT LINES
# ─────────────────────────────────────────────

func _control_point_lines() -> Array[String]:
	var lines: Array[String] = []
	lines.append("── CONTROL POINTS ──")
	for i in _control_points.size():
		var cp: ControlPoint = _control_points[i]
		lines.append(_cp_line(i + 1, cp))
	return lines

func _cp_line(idx: int, cp: ControlPoint) -> String:
	var owner_str := _team_name(cp.owning_team)
	var spi_n := cp._count_team(Player.Team.SPI)
	var sci_n := cp._count_team(Player.Team.SCI)

	var status: String
	if cp.is_locked:
		status = "LOCKED"
	elif cp.is_contested:
		status = "CONTESTED  SPI×%d vs SCI×%d" % [spi_n, sci_n]
	elif cp.capture_progress < 1.0 and cp.capture_team != Player.Team.FFA:
		var capping_team := _team_name(cp.capture_team)
		var cappers := spi_n if cp.capture_team == Player.Team.SPI else sci_n
		status = "%s capping %d%%  ×%d  %s" % [
			capping_team,
			int(cp.capture_progress * 100),
			cappers,
			_progress_bar(cp.capture_progress, 1.0),
		]
	else:
		status = "Held by %s" % owner_str

	return "CP%d [%s]  %s" % [idx, owner_str, status]

# ─────────────────────────────────────────────
#  PAYLOAD LINE
# ─────────────────────────────────────────────

func _payload_line(payload: PayloadNode) -> String:
	var pct := int(payload.progress * 100)
	var state_str: String

	match payload.payload_state:
		PayloadNode.PayloadState.LOCKED:
			state_str = "LOCKED"
		PayloadNode.PayloadState.PUSHING:
			var atk := payload.get_attackers_on_point()
			state_str = "PUSHING ×%d" % atk
		PayloadNode.PayloadState.CONTESTED:
			var atk := payload.get_attackers_on_point()
			var def := payload.get_defenders_on_point()
			state_str = "CONTESTED  ATK×%d vs DEF×%d" % [atk, def]
		PayloadNode.PayloadState.RETURNING:
			state_str = "RETURNING"
		PayloadNode.PayloadState.IDLE:
			state_str = "IDLE  (rollback in %.1fs)" % payload._return_countdown
		PayloadNode.PayloadState.AT_CHECKPOINT:
			state_str = "AT CHECKPOINT"
		PayloadNode.PayloadState.DELIVERED:
			state_str = "DELIVERED"
		_:
			state_str = "?"

	# Build checkpoint markers inline: ──●──●──○
	var cp_str := _checkpoint_string(payload)

	return "Payload  %d%%  [%s]  %s  %s" % [pct, state_str, _progress_bar(payload.progress, 1.0), cp_str]

func _checkpoint_string(payload: PayloadNode) -> String:
	if payload._checkpoint_progresses.is_empty():
		return ""
	var parts: Array[String] = []
	for i in payload._checkpoint_progresses.size():
		var passed := payload._next_checkpoint_index > i
		parts.append("●" if passed else "○")
	return "CPs: " + "  ".join(parts)

# ─────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────

func _get_payload() -> PayloadNode:
	# Prefer the cached reference on the mode nodes
	if gmc.escort_mode and gmc.escort_mode._payload:
		return gmc.escort_mode._payload
	if gmc.hybrid_mode and gmc.hybrid_mode._payload:
		return gmc.hybrid_mode._payload
	# Fallback: scan the tree in case register_payload hasn't fired yet
	var found := get_tree().get_nodes_in_group("payload")
	if not found.is_empty():
		return found[0] as PayloadNode
	return null

func _count_owned_points() -> Dictionary:
	var owned := { Player.Team.SPI: 0, Player.Team.SCI: 0 }
	for cp in _control_points:
		if cp.owning_team in owned:
			owned[cp.owning_team] += 1
	return owned

func _progress_bar(value: float, max_value: float, steps: int = 10) -> String:
	var filled := int((value / max_value) * steps)
	filled = clampi(filled, 0, steps)
	return "[" + "█".repeat(filled) + "░".repeat(steps - filled) + "]"

func _koth_bar(value: float, max_value: float) -> String:
	return _progress_bar(value, max_value, 12)

func _score_bar(value: float, max_value: float) -> String:
	return _progress_bar(value, max_value, 15)

func _fmt(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00"
	var m := int(seconds) / 60
	var s := int(seconds) % 60
	return "%d:%02d" % [m, s]

func _phase_text(phase: GameModeComponent.PhaseState) -> String:
	match phase:
		GameModeComponent.PhaseState.WAITING_FOR_PLAYERS: return "WAITING"
		GameModeComponent.PhaseState.SETUP:               return "SETUP"
		GameModeComponent.PhaseState.OBJECTIVE_LOCKED:    return "GET READY"
		GameModeComponent.PhaseState.ACTIVE:              return "ACTIVE"
		GameModeComponent.PhaseState.OVERTIME:            return "OVERTIME"
		GameModeComponent.PhaseState.ROUND_END:           return "ROUND OVER"
		GameModeComponent.PhaseState.MATCH_END:           return "MATCH OVER"
		_:                                                return ""

func _team_name(team: Player.Team) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_:               return "---"
