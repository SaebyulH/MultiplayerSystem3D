extends CanvasLayer
class_name HUDController

## Central HUD controller.  Replaces the old text-based canvas_layer.gd.
##
## Architecture
## ────────────
##   HUDController (CanvasLayer)        ← replaces canvas_layer.gd
##   ├── Shared elements (phase label, timer bar, round scores)
##   └── ModePanelContainer
##        └── BaseModePanel subclass    ← one per game mode, swapped in
##
## Signals are routed from GameModeComponent through this controller to the
## active panel.  Panels are created once and hidden/shown on mode switch.
##
## To add a new game mode:
##   1. Create a panel script in panels/ extending BaseModePanel
##   2. Add it to _create_panel_registry()
##   3. Add a data-building case in _build_mode_data()
##   4. (Optional) connect mode-specific signals in _connect_mode_signals()

# ─────────────────────────────────────────────
#  Exports
# ─────────────────────────────────────────────

@export var hud_width: float = 520.0
@export var hud_margin_top: float = 80.0  # below killstreak

# ─────────────────────────────────────────────
#  References
# ─────────────────────────────────────────────

var gmc: GameModeComponent

# Shared UI nodes
var _root: Control
var _phase_label: Label
var _timer_bar: TimerBar
var _round_score_label: Label
var _overtime_label: Label
var _panel_container: Control

# Active panel
var _active_panel: BaseModePanel = null
var _panel_registry: Dictionary = {}

# Internal
var _initialized := false

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	_build_shared_ui()

func _process(_delta: float) -> void:
	if not _initialized or not gmc:
		return

	# Hide the HUD while the class-select screen is open so the two don't overlap.
	_root.visible = not PlayerInput.ui_open

	# Timer bar updates every frame
	_timer_bar.set_time(gmc.phase_timer, gmc.round_time)

	# Payload-based modes need polling (return countdown isn't signal-driven)
	var needs_poll: bool = gmc.game_mode in [
		GameModeComponent.GameMode.ESCORT,
		GameModeComponent.GameMode.HYBRID,
	]
	if needs_poll:
		_push_data_to_panel()

# ─────────────────────────────────────────────
#  Build shared UI (called from _ready)
# ─────────────────────────────────────────────

func _build_shared_ui() -> void:
	layer = 1  # above game world but below console (layer 3)

	_root = Control.new()
	_root.anchor_left   = 0.5
	_root.anchor_top    = 0.0
	_root.anchor_right  = 0.5
	_root.anchor_bottom = 0.0
	_root.offset_left   = -hud_width * 0.5
	_root.offset_top    = hud_margin_top
	_root.offset_right  = hud_width * 0.5
	add_child(_root)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 8)
	main_vbox.anchor_left   = 0.0
	main_vbox.anchor_right  = 1.0
	main_vbox.anchor_top    = 0.0
	main_vbox.anchor_bottom = 1.0
	_root.add_child(main_vbox)

	# ── Phase label ────────────────────────
	_phase_label = Label.new()
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_phase_label.add_theme_constant_override("outline_size", 10)
	_phase_label.add_theme_font_size_override("font_size", 28)
	_phase_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	main_vbox.add_child(_phase_label)

	# ── Timer bar ──────────────────────────
	_timer_bar = TimerBar.new()
	_timer_bar.custom_minimum_size = Vector2(0, 28)
	main_vbox.add_child(_timer_bar)

	# ── Round score ────────────────────────
	_round_score_label = Label.new()
	_round_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_score_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_round_score_label.add_theme_constant_override("outline_size", 6)
	_round_score_label.add_theme_font_size_override("font_size", 18)
	_round_score_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	main_vbox.add_child(_round_score_label)

	# ── Mode panel container ───────────────
	_panel_container = Control.new()
	_panel_container.custom_minimum_size = Vector2(0, 120)
	_panel_container.anchor_left   = 0.0
	_panel_container.anchor_right  = 1.0
	main_vbox.add_child(_panel_container)

	# ── Overtime label ─────────────────────
	_overtime_label = Label.new()
	_overtime_label.text = "⚠ OVERTIME ⚠"
	_overtime_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overtime_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_overtime_label.add_theme_constant_override("outline_size", 10)
	_overtime_label.add_theme_font_size_override("font_size", 26)
	_overtime_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	_overtime_label.visible = false
	main_vbox.add_child(_overtime_label)

# ─────────────────────────────────────────────
#  Setup — called by Map._enter_tree()
# ─────────────────────────────────────────────

func setup_gmc() -> void:
	await get_tree().process_frame

	gmc = GameManager.game_mode_component
	if not gmc:
		push_warning("HUD: no GameModeComponent found")
		return

	_connect_mode_signals()
	_create_panel_registry()
	_switch_to_mode(gmc.game_mode)
	_update_round_score()
	_initialized = true

# ─────────────────────────────────────────────
#  Signal wiring
# ─────────────────────────────────────────────

func _connect_mode_signals() -> void:
	gmc.phase_changed.connect(_on_phase_changed)
	gmc.time_updated.connect(_on_time_updated)
	gmc.round_won.connect(_on_round_won)
	gmc.match_won.connect(_on_match_won)
	gmc.overtime_started.connect(_on_overtime_started)
	gmc.overtime_ended.connect(_on_overtime_ended)
	gmc.koth_updated.connect(_on_koth_updated)

	if gmc.domination_mode:
		gmc.domination_mode.points_updated.connect(_on_domination_updated)

	if gmc.hybrid_mode:
		gmc.hybrid_point_captured_signal.connect(_on_hybrid_updated)

	# Escort mode is polled in _process() — no extra signals needed

func _create_panel_registry() -> void:
	# Create one panel per game mode; they stay hidden until switched to.
	_panel_registry[GameModeComponent.GameMode.KOTH]      = _make_panel(KothPanel.new())
	_panel_registry[GameModeComponent.GameMode.CONTROL]    = _make_panel(KothPanel.new())
	_panel_registry[GameModeComponent.GameMode.DOMINATION] = _make_panel(DominationPanel.new())
	_panel_registry[GameModeComponent.GameMode.ESCORT]     = _make_panel(EscortPanel.new())
	_panel_registry[GameModeComponent.GameMode.HYBRID]     = _make_panel(HybridPanel.new())

func _make_panel(panel: BaseModePanel) -> BaseModePanel:
	panel.visible = false
	panel.anchor_left   = 0.0
	panel.anchor_right  = 1.0
	panel.anchor_top    = 0.0
	panel.anchor_bottom = 1.0
	_panel_container.add_child(panel)
	return panel

# ─────────────────────────────────────────────
#  Panel switching
# ─────────────────────────────────────────────

func _switch_to_mode(mode: GameModeComponent.GameMode) -> void:
	# Hide previous
	if _active_panel:
		_active_panel.visible = false

	# Show new
	_active_panel = _panel_registry.get(mode)
	if _active_panel:
		_active_panel.visible = true

	# Immediate data push
	_push_data_to_panel()

# ─────────────────────────────────────────────
#  Data gathering & push
# ─────────────────────────────────────────────

func _push_data_to_panel() -> void:
	if not _active_panel or not gmc:
		return
	_active_panel.update_display(_build_mode_data())

func _build_mode_data() -> Dictionary:
	match gmc.game_mode:
		GameModeComponent.GameMode.KOTH, GameModeComponent.GameMode.CONTROL:
			return _koth_data()
		GameModeComponent.GameMode.DOMINATION:
			return _domination_data()
		GameModeComponent.GameMode.ESCORT:
			return _escort_data()
		GameModeComponent.GameMode.HYBRID:
			return _hybrid_data()
	return {}

func _koth_data() -> Dictionary:
	if not gmc.koth_mode:
		return {}
	return {
		"time_held":          gmc.koth_mode.time_held.duplicate(),
		"capture_time_to_win": gmc.koth_mode.capture_time_to_win,
	}

func _domination_data() -> Dictionary:
	if not gmc.domination_mode:
		return {}
	var owned: Dictionary = _count_owned_cps()
	return {
		"points":                     gmc.domination_mode.points.duplicate(),
		"points_to_win":              gmc.domination_mode.points_to_win,
		"owned_points":               owned,
		"pps":                        gmc.domination_mode.points_per_second_per_point,
	}

func _escort_data() -> Dictionary:
	var payload := _get_payload()
	if not payload:
		return {"state": "LOCKED", "progress": 0.0}
	return {
		"progress":             payload.progress,
		"state":                EscortPanel.state_name(payload.payload_state),
		"attackers":            payload.get_attackers_on_point(),
		"defenders":            payload.get_defenders_on_point(),
		"return_countdown":     payload._return_countdown,
		"checkpoint_progresses": payload._checkpoint_progresses.duplicate(),
		"next_checkpoint_index": payload._next_checkpoint_index,
	}

func _hybrid_data() -> Dictionary:
	if not gmc.hybrid_mode:
		return {}
	var hm := gmc.hybrid_mode
	var data: Dictionary = {
		"point_captured":      hm.point_is_captured,
		"time_held":           hm.time_held,
		"capture_time_to_win": hm.capture_time_to_win,
	}
	if hm.point_is_captured:
		var payload := _get_payload()
		if payload:
			data["payload_progress"]       = payload.progress
			data["payload_state"]          = EscortPanel.state_name(payload.payload_state)
			data["attackers"]              = payload.get_attackers_on_point()
			data["defenders"]              = payload.get_defenders_on_point()
			data["return_countdown"]       = payload._return_countdown
			data["checkpoint_progresses"]  = payload._checkpoint_progresses.duplicate()
			data["next_checkpoint_index"]  = payload._next_checkpoint_index
	return data

func _count_owned_cps() -> Dictionary:
	var owned := { Player.Team.SPI: 0, Player.Team.SCI: 0 }
	# The HUD's control points are registered via register_control_point()
	# but for simplicity we trust the server state.
	if gmc.domination_mode and gmc.domination_mode.has_method("_count_owned_points"):
		return gmc.domination_mode._count_owned_points()
	return owned

func _get_payload() -> PayloadNode:
	if gmc and gmc.escort_mode and gmc.escort_mode._payload:
		return gmc.escort_mode._payload
	if gmc and gmc.hybrid_mode and gmc.hybrid_mode._payload:
		return gmc.hybrid_mode._payload
	var found := get_tree().get_nodes_in_group("payload")
	if not found.is_empty():
		return found[0] as PayloadNode
	return null

# ─────────────────────────────────────────────
#  Signal handlers
# ─────────────────────────────────────────────

func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	_phase_label.text = _phase_text(new_phase)
	_overtime_label.visible = (new_phase == GameModeComponent.PhaseState.OVERTIME)
	_timer_bar.set_overtime(new_phase == GameModeComponent.PhaseState.OVERTIME)
	_push_data_to_panel()

func _on_time_updated(_remaining: float) -> void:
	# Timer bar syncs in _process(), but also push data for payload poll
	_push_data_to_panel()

func _on_round_won(_team, _wins) -> void:
	_update_round_score()
	_push_data_to_panel()

func _on_match_won(_team) -> void:
	_update_round_score()
	_push_data_to_panel()

func _on_overtime_started() -> void:
	_overtime_label.visible = true
	_timer_bar.set_overtime(true)

func _on_overtime_ended() -> void:
	_overtime_label.visible = false
	_timer_bar.set_overtime(false)

func _on_koth_updated(_held) -> void:
	_push_data_to_panel()

func _on_domination_updated(_points) -> void:
	_push_data_to_panel()

func _on_hybrid_updated() -> void:
	_push_data_to_panel()

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

func _update_round_score() -> void:
	if not gmc:
		return
	var spi = gmc.round_wins.get(Player.Team.SPI, 0)
	var sci = gmc.round_wins.get(Player.Team.SCI, 0)
	var target: int = gmc.rounds_to_win
	_round_score_label.text = "Rounds:  SPI %d/%d  —  SCI %d/%d" % [spi, target, sci, target]

func _phase_text(phase: GameModeComponent.PhaseState) -> String:
	match phase:
		GameModeComponent.PhaseState.WAITING_FOR_PLAYERS:  return "WAITING FOR PLAYERS"
		GameModeComponent.PhaseState.SETUP:                return "SETUP"
		GameModeComponent.PhaseState.OBJECTIVE_LOCKED:     return "GET READY"
		GameModeComponent.PhaseState.ACTIVE:               return "ACTIVE"
		GameModeComponent.PhaseState.OVERTIME:             return "⚠ OVERTIME ⚠"
		GameModeComponent.PhaseState.ROUND_END:            return "ROUND OVER"
		GameModeComponent.PhaseState.MATCH_END:            return "MATCH OVER"
		_:                                                 return ""
