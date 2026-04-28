extends CanvasLayer

@onready var phase_label: Label = $PhaseLabel
@onready var timer_label: Label = $TimerLabel
@onready var sci_timer_label: Label = $SCITimer
@onready var spi_timer_label: Label = $SPITimer
@onready var round_wins_label: Label = $RoundWinsLabel

var gmc: GameModeComponent
var _initialized := false


func setup_gmc() -> void:
	# Wait for autoload + network state to settle
	await get_tree().process_frame
	
	
	#gmc = %SpawnParent.get_node("Map/")
	
	gmc = GameManager.game_mode_component
	if not gmc:
		push_warning("HUD: no GameModeComponent found")
		return

	_connect_signals()

	# Small delay allows RPC snapshot sync to arrive for late joiners
	await get_tree().create_timer(0.15).timeout

	_refresh_all()
	_initialized = true


func _connect_signals() -> void:
	gmc.phase_changed.connect(_on_phase_changed)
	gmc.time_updated.connect(_on_time_updated)
	gmc.koth_updated.connect(_on_koth_updated)

	gmc.round_won.connect(_on_round_won)
	gmc.overtime_started.connect(_on_overtime_started)
	gmc.match_won.connect(_on_match_won)


# ─────────────────────────────────────────────
# Signal handlers
# ─────────────────────────────────────────────

func _on_koth_updated(held: Dictionary) -> void:
	if not gmc:
		return

	var target_time: float = gmc.koth_capture_time_to_win
	var target_str: String = _format_time(target_time)

	sci_timer_label.text = "SCI: %s / %s" % [
		_format_time(held.get(Player.Team.SCI, 0.0)),
		target_str
	]

	spi_timer_label.text = "SPI: %s / %s" % [
		_format_time(held.get(Player.Team.SPI, 0.0)),
		target_str
	]


func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	_refresh_all()


func _on_time_updated(remaining: float) -> void:
	timer_label.text = _format_time(remaining)


func _on_round_won(winning_team: Player.Team) -> void:
	round_wins_label.text = _round_wins_text()


func _on_overtime_started() -> void:
	phase_label.text = "OVERTIME"
	phase_label.modulate = Color.ORANGE


func _on_match_won(winning_team: Player.Team) -> void:
	phase_label.text = _team_name(winning_team) + " WINS THE MATCH"
	phase_label.modulate = Color.YELLOW


# ─────────────────────────────────────────────
# UI refresh
# ─────────────────────────────────────────────

func _refresh_all() -> void:
	if not gmc:
		return

	phase_label.text = _phase_text(gmc.current_phase)
	phase_label.modulate = Color.WHITE

	timer_label.text = _format_time(gmc.phase_timer)
	round_wins_label.text = _round_wins_text()

	var is_koth := gmc.game_mode in [
		GameModeComponent.GameMode.KOTH,
		GameModeComponent.GameMode.CONTROL
	]

	if is_koth:
		sci_timer_label.show()
		spi_timer_label.show()
		_on_koth_updated(gmc.koth_time_held)
	else:
		sci_timer_label.hide()
		spi_timer_label.hide()


# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

func _phase_text(phase: GameModeComponent.PhaseState) -> String:
	match phase:
		GameModeComponent.PhaseState.SETUP:
			return "SETUP"
		GameModeComponent.PhaseState.OBJECTIVE_LOCKED:
			return "GET READY"
		GameModeComponent.PhaseState.ACTIVE:
			return "FIGHT"
		GameModeComponent.PhaseState.OVERTIME:
			return "OVERTIME"
		GameModeComponent.PhaseState.ROUND_END:
			return "ROUND OVER"
		GameModeComponent.PhaseState.MATCH_END:
			return "MATCH OVER"
		_:
			return ""


func _round_wins_text() -> String:
	var spi: int = gmc.round_wins.get(Player.Team.SPI, 0)
	var sci: int = gmc.round_wins.get(Player.Team.SCI, 0)
	var target: int = gmc.rounds_to_win

	return "SPI %d/%d  —  SCI %d/%d" % [spi, target, sci, target]


func _team_name(team: Player.Team) -> String:
	match team:
		Player.Team.SPI:
			return "SPI"
		Player.Team.SCI:
			return "SCI"
		_:
			return "DRAW"


func _format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00"

	var m := int(seconds) / 60
	var s := int(seconds) % 60
	return "%d:%02d" % [m, s]
