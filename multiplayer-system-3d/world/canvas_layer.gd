extends CanvasLayer

@onready var phase_label: Label = $PhaseLabel
@onready var timer_label: Label = $TimerLabel
@onready var sci_timer_label: Label = $SCITimer
@onready var spi_timer_label: Label = $SPITimer

@onready var round_wins_label: Label = $RoundWinsLabel

var gmc: GameModeComponent

func _ready() -> void:
	# Wait a frame so Map has finished _ready() and set GameManager.game_mode_component
	await get_tree().process_frame
	gmc = GameManager.game_mode_component
	if not gmc:
		push_warning("HUD: no GameModeComponent found")
		return
	_connect_signals()
	_refresh_all()

func _connect_signals() -> void:
	gmc.phase_changed.connect(_on_phase_changed)
	gmc.time_updated.connect(_on_time_updated)
	gmc.koth_updated.connect(_on_koth_updated)
	
	gmc.round_won.connect(_on_round_won)
	gmc.overtime_started.connect(_on_overtime_started)
	gmc.match_won.connect(_on_match_won)

# ── Signal handlers ──────────────────────────────────
func _on_koth_updated(held: Dictionary):
	sci_timer_label.text = "SCI " + _format_time(held[GameModeComponent.TeamID.SCI])
	spi_timer_label.text = "SCI " + _format_time(held[GameModeComponent.TeamID.SPI])


func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	_refresh_all()

func _on_time_updated(remaining: float) -> void:
	timer_label.text = _format_time(remaining)

func _on_round_won(winning_team: GameModeComponent.TeamID) -> void:
	round_wins_label.text = _round_wins_text()

func _on_overtime_started() -> void:
	phase_label.text = "OVERTIME"
	phase_label.modulate = Color.ORANGE

func _on_match_won(winning_team: GameModeComponent.TeamID) -> void:
	phase_label.text = _team_name(winning_team) + " WINS THE MATCH"
	phase_label.modulate = Color.YELLOW

# ── Helpers ──────────────────────────────────────────

func _refresh_all() -> void:
	phase_label.text = _phase_text(gmc.current_phase)
	phase_label.modulate = Color.WHITE
	timer_label.text = _format_time(gmc.phase_timer)
	round_wins_label.text = _round_wins_text()

func _phase_text(phase: GameModeComponent.PhaseState) -> String:
	match phase:
		GameModeComponent.PhaseState.SETUP:            return "SETUP"
		GameModeComponent.PhaseState.OBJECTIVE_LOCKED: return "GET READY"
		GameModeComponent.PhaseState.ACTIVE:           return "FIGHT"
		GameModeComponent.PhaseState.OVERTIME:         return "OVERTIME"
		GameModeComponent.PhaseState.ROUND_END:        return "ROUND OVER"
		GameModeComponent.PhaseState.MATCH_END:        return "MATCH OVER"
		_:                                             return ""

func _round_wins_text() -> String:
	var spi :int = gmc.round_wins.get(GameModeComponent.TeamID.SPI, 0)
	var sci :int = gmc.round_wins.get(GameModeComponent.TeamID.SCI, 0)
	return "SPI %d  —  SCI %d" % [spi, sci]

func _team_name(team: GameModeComponent.TeamID) -> String:
	match team:
		GameModeComponent.TeamID.SPI: return "SPI"
		GameModeComponent.TeamID.SCI: return "SCI"
		_:                            return "DRAW"

func _format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00"
	var m := int(seconds) / 60
	var s := int(seconds) % 60
	return "%d:%02d" % [m, s]
