extends BaseModePanel
class_name HybridPanel

## HYBRID mode panel (capture point, then escort payload).
##
## Phase 1 – Capture: shows a single SPI progress bar for point capture.
## Phase 2 – Escort:  switches to a payload-progress bar with state info.

var _phase_header: Label
var _capture_bar: TeamProgressBar
var _escort_container: Control
var _escort_fill: ColorRect
var _escort_state: Label
var _escort_pct: Label
var _escort_info: Label
var _escort_cp_container: Control

var _checkpoint_markers: Array[ColorRect] = []

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	_build()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.anchor_left   = 0.0
	vbox.anchor_right  = 1.0
	vbox.anchor_top    = 0.0
	vbox.anchor_bottom = 1.0
	add_child(vbox)

	# Header
	var header := Label.new()
	header.text = "── HYBRID ──"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	header.add_theme_constant_override("outline_size", 6)
	header.add_theme_font_size_override("font_size", 20)
	vbox.add_child(header)

	# Phase label
	_phase_header = Label.new()
	_phase_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_phase_header.add_theme_constant_override("outline_size", 4)
	_phase_header.add_theme_font_size_override("font_size", 18)
	_phase_header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.6))
	vbox.add_child(_phase_header)

	# ── Phase 1: Capture bar ──────────────────
	_capture_bar = TeamProgressBar.new()
	vbox.add_child(_capture_bar)
	_capture_bar.set_bar_color(Color(0.88, 0.24, 0.24))

	# ── Phase 2: Escort bar ───────────────────
	_escort_container = Control.new()
	_escort_container.custom_minimum_size = Vector2(0, 38)
	_escort_container.visible = false
	vbox.add_child(_escort_container)

	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.12, 0.85)
	bg.anchor_left   = 0.0
	bg.anchor_right  = 1.0
	bg.anchor_top    = 0.0
	bg.anchor_bottom = 1.0
	_escort_container.add_child(bg)

	_escort_fill = ColorRect.new()
	_escort_fill.color = Color(0.88, 0.24, 0.24)
	_escort_fill.anchor_left   = 0.0
	_escort_fill.anchor_right  = 0.0
	_escort_fill.anchor_top    = 0.0
	_escort_fill.anchor_bottom = 1.0
	_escort_container.add_child(_escort_fill)

	_escort_state = Label.new()
	_escort_state.anchor_left   = 0.0
	_escort_state.anchor_right  = 0.55
	_escort_state.anchor_top    = 0.0
	_escort_state.anchor_bottom = 1.0
	_escort_state.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_escort_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_escort_state.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_escort_state.add_theme_constant_override("outline_size", 6)
	_escort_state.add_theme_font_size_override("font_size", 18)
	_escort_container.add_child(_escort_state)

	_escort_pct = Label.new()
	_escort_pct.anchor_left   = 0.55
	_escort_pct.anchor_right  = 1.0
	_escort_pct.anchor_top    = 0.0
	_escort_pct.anchor_bottom = 1.0
	_escort_pct.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_escort_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_escort_pct.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_escort_pct.add_theme_constant_override("outline_size", 6)
	_escort_pct.add_theme_font_size_override("font_size", 18)
	_escort_container.add_child(_escort_pct)

	# Checkpoint markers (escort phase)
	_escort_cp_container = Control.new()
	_escort_cp_container.custom_minimum_size = Vector2(0, 10)
	_escort_cp_container.visible = false
	vbox.add_child(_escort_cp_container)

	# Info line
	_escort_info = Label.new()
	_escort_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_escort_info.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_escort_info.add_theme_constant_override("outline_size", 4)
	_escort_info.add_theme_font_size_override("font_size", 16)
	_escort_info.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_escort_info.visible = false
	vbox.add_child(_escort_info)

# ─────────────────────────────────────────────
#  Update
# ─────────────────────────────────────────────

func update_display(data: Dictionary) -> void:
	var captured: bool = data.get("point_captured", false)

	if not captured:
		_show_capture_phase(data)
	else:
		_show_escort_phase(data)

func _show_capture_phase(data: Dictionary) -> void:
	_phase_header.text = "CAPTURE THE POINT"
	_capture_bar.visible = true
	_escort_container.visible = false
	_escort_cp_container.visible = false
	_escort_info.visible = false

	var time_held: float   = data.get("time_held", 0.0)
	var cap_target: float  = data.get("capture_time_to_win", 30.0)

	var pct: float = time_held / cap_target if cap_target > 0.0 else 0.0
	_capture_bar.set_progress(pct)
	_capture_bar.set_labels("SPI", _fmt(time_held) + " / " + _fmt(cap_target))

func _show_escort_phase(data: Dictionary) -> void:
	_phase_header.text = "ESCORT THE PAYLOAD"
	_capture_bar.visible = false
	_escort_container.visible = true
	_escort_cp_container.visible = true
	_escort_info.visible = true

	var progress: float   = data.get("payload_progress", 0.0)
	var state: String     = data.get("payload_state", "IDLE")
	var attackers: int    = data.get("attackers", 0)
	var defenders: int    = data.get("defenders", 0)
	var return_cd: float  = data.get("return_countdown", 0.0)
	var checkpoints: Array = data.get("checkpoint_progresses", [])
	var next_cp: int      = data.get("next_checkpoint_index", 0)

	_escort_fill.anchor_right = clampf(progress, 0.0, 1.0)
	_escort_pct.text = "%d%%" % int(progress * 100.0)

	match state:
		"PUSHING":
			_escort_state.text = "PUSHING  ×%d" % attackers
			_escort_fill.color = Color(0.88, 0.24, 0.24)
		"CONTESTED":
			_escort_state.text = "CONTESTED"
			_escort_fill.color = Color(0.95, 0.65, 0.10)
		"RETURNING":
			_escort_state.text = "RETURNING"
			_escort_fill.color = Color(0.35, 0.55, 0.90)
		"IDLE":
			_escort_state.text = "IDLE  (%.1fs)" % return_cd
			_escort_fill.color = Color(0.45, 0.45, 0.45)
		"AT_CHECKPOINT":
			_escort_state.text = "CHECKPOINT"
			_escort_fill.color = Color(0.85, 0.75, 0.10)
		"DELIVERED":
			_escort_state.text = "DELIVERED!"
			_escort_fill.color = Color(0.20, 0.75, 0.20)
		"LOCKED":
			_escort_state.text = "LOCKED"
			_escort_fill.color = Color(0.20, 0.20, 0.20)
		_:
			_escort_state.text = state
			_escort_fill.color = Color(0.50, 0.50, 0.50)

	_rebuild_checkpoints(checkpoints, next_cp)

	if attackers > 0:
		_escort_info.text = "Attackers: %d" % attackers
	elif return_cd > 0.0 and state != "IDLE":
		_escort_info.text = "Rollback in: %.1fs" % return_cd
	else:
		_escort_info.text = ""

# ─────────────────────────────────────────────
#  Checkpoints
# ─────────────────────────────────────────────

func _rebuild_checkpoints(checkpoints: Array, next_idx: int) -> void:
	for m in _checkpoint_markers:
		m.queue_free()
	_checkpoint_markers.clear()

	if checkpoints.is_empty():
		return

	for i in checkpoints.size():
		var cp_p := checkpoints[i] as float
		var marker := ColorRect.new()
		marker.color = Color.WHITE if i >= next_idx else Color(0.30, 0.30, 0.30)
		marker.anchor_left  = clampf(cp_p, 0.0, 1.0)
		marker.anchor_right = clampf(cp_p, 0.0, 1.0)
		marker.anchor_top    = 0.0
		marker.anchor_bottom = 1.0
		marker.custom_minimum_size = Vector2(4, 0)
		_escort_cp_container.add_child(marker)
		_checkpoint_markers.append(marker)

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

static func _fmt(seconds: float) -> String:
	var m := int(seconds) / 60
	var s := int(seconds) % 60
	return "%d:%02d" % [m, s]

func get_panel_name() -> String:
	return "HybridPanel"
