extends BaseModePanel
class_name EscortPanel

## ESCORT / Payload mode panel.
##
## Shows a wide payload-progress bar with checkpoint markers along it,
## state-dependent colouring, and player-count info.

## Convert a PayloadNode.PayloadState enum to a display string.
static func state_name(state) -> String:
	match state:
		PayloadNode.PayloadState.LOCKED:       return "LOCKED"
		PayloadNode.PayloadState.IDLE:         return "IDLE"
		PayloadNode.PayloadState.PUSHING:      return "PUSHING"
		PayloadNode.PayloadState.CONTESTED:    return "CONTESTED"
		PayloadNode.PayloadState.RETURNING:    return "RETURNING"
		PayloadNode.PayloadState.AT_CHECKPOINT: return "AT_CHECKPOINT"
		PayloadNode.PayloadState.DELIVERED:    return "DELIVERED"
		_:                                     return "?"

var _progress_container: Control
var _fill_rect: ColorRect
var _state_label: Label
var _pct_label: Label
var _info_label: Label
var _cp_container: Control

var _checkpoint_markers: Array[ColorRect] = []

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	_build()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.anchor_left   = 0.0
	vbox.anchor_right  = 1.0
	vbox.anchor_top    = 0.0
	vbox.anchor_bottom = 1.0
	add_child(vbox)

	# Header
	var header := Label.new()
	header.text = "── ESCORT ──"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	header.add_theme_constant_override("outline_size", 6)
	header.add_theme_font_size_override("font_size", 20)
	vbox.add_child(header)

	# ── Progress bar ──────────────────────────
	_progress_container = Control.new()
	_progress_container.custom_minimum_size = Vector2(0, 38)
	vbox.add_child(_progress_container)

	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.12, 0.85)
	bg.anchor_left   = 0.0
	bg.anchor_right  = 1.0
	bg.anchor_top    = 0.0
	bg.anchor_bottom = 1.0
	_progress_container.add_child(bg)

	_fill_rect = ColorRect.new()
	_fill_rect.color = Color(0.88, 0.24, 0.24)
	_fill_rect.anchor_left   = 0.0
	_fill_rect.anchor_right  = 0.0
	_fill_rect.anchor_top    = 0.0
	_fill_rect.anchor_bottom = 1.0
	_progress_container.add_child(_fill_rect)

	# State label (left overlay)
	_state_label = Label.new()
	_state_label.anchor_left   = 0.0
	_state_label.anchor_right  = 0.55
	_state_label.anchor_top    = 0.0
	_state_label.anchor_bottom = 1.0
	_state_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_state_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_state_label.add_theme_constant_override("outline_size", 6)
	_state_label.add_theme_font_size_override("font_size", 18)
	_progress_container.add_child(_state_label)

	# Percentage label (right overlay)
	_pct_label = Label.new()
	_pct_label.anchor_left   = 0.55
	_pct_label.anchor_right  = 1.0
	_pct_label.anchor_top    = 0.0
	_pct_label.anchor_bottom = 1.0
	_pct_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pct_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_pct_label.add_theme_constant_override("outline_size", 6)
	_pct_label.add_theme_font_size_override("font_size", 18)
	_progress_container.add_child(_pct_label)

	# ── Checkpoint markers strip ─────────────
	_cp_container = Control.new()
	_cp_container.custom_minimum_size = Vector2(0, 10)
	vbox.add_child(_cp_container)

	# ── Info line ─────────────────────────────
	_info_label = Label.new()
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_info_label.add_theme_constant_override("outline_size", 4)
	_info_label.add_theme_font_size_override("font_size", 16)
	_info_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(_info_label)

# ─────────────────────────────────────────────
#  Update
# ─────────────────────────────────────────────

func update_display(data: Dictionary) -> void:
	var progress: float         = data.get("progress", 0.0)
	var state: String           = data.get("state", "IDLE")
	var attackers: int          = data.get("attackers", 0)
	var defenders: int          = data.get("defenders", 0)
	var return_cd: float        = data.get("return_countdown", 0.0)
	var checkpoints: Array      = data.get("checkpoint_progresses", [])
	var next_cp: int            = data.get("next_checkpoint_index", 0)

	_fill_rect.anchor_right = clampf(progress, 0.0, 1.0)
	_pct_label.text = "%d%%" % int(progress * 100.0)

	match state:
		"PUSHING":
			_state_label.text = "PUSHING  ×%d" % attackers
			_fill_rect.color = Color(0.88, 0.24, 0.24)
		"CONTESTED":
			_state_label.text = "CONTESTED  ATK×%d  DEF×%d" % [attackers, defenders]
			_fill_rect.color = Color(0.95, 0.65, 0.10)
		"RETURNING":
			_state_label.text = "RETURNING"
			_fill_rect.color = Color(0.35, 0.55, 0.90)
		"IDLE":
			_state_label.text = "IDLE  (%.1fs)" % return_cd
			_fill_rect.color = Color(0.45, 0.45, 0.45)
		"AT_CHECKPOINT":
			_state_label.text = "CHECKPOINT"
			_fill_rect.color = Color(0.85, 0.75, 0.10)
		"DELIVERED":
			_state_label.text = "DELIVERED!"
			_fill_rect.color = Color(0.20, 0.75, 0.20)
		"LOCKED":
			_state_label.text = "LOCKED"
			_fill_rect.color = Color(0.20, 0.20, 0.20)
		_:
			_state_label.text = state
			_fill_rect.color = Color(0.50, 0.50, 0.50)

	_rebuild_checkpoints(checkpoints, next_cp)

	if attackers > 0:
		_info_label.text = "Attackers: %d" % attackers
	elif return_cd > 0.0 and state != "IDLE":
		_info_label.text = "Rollback in: %.1fs" % return_cd
	else:
		_info_label.text = ""

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
		_cp_container.add_child(marker)
		_checkpoint_markers.append(marker)

func get_panel_name() -> String:
	return "EscortPanel"
