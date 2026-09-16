extends BaseModePanel
class_name HybridPanel

## HYBRID mode panel (capture point, then escort payload).
##
## Phase 1 – Capture: shows a single SPI progress bar for point capture.
## Phase 2 – Escort:  switches to a payload-progress bar with state info.

const _marker_scene := preload("res://world/hud/components/checkpoint_marker.tscn")

@onready var _phase_header: Label = $VBox/PhaseHeader
@onready var _capture_bar: TeamProgressBar = $VBox/CaptureBar
@onready var _escort_container: Control = $VBox/EscortContainer
@onready var _escort_fill: ColorRect = $VBox/EscortContainer/EscortFill
@onready var _escort_state: Label = $VBox/EscortContainer/EscortState
@onready var _escort_pct: Label = $VBox/EscortContainer/EscortPct
@onready var _escort_info: Label = $VBox/EscortInfo
@onready var _escort_cp_container: Control = $VBox/EscortCpContainer

var _checkpoint_markers: Array[ColorRect] = []

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
	# Reuse markers across calls instead of free + re-instantiate every tick
	# (update_display runs at the 10 Hz state sync, so this was churning nodes).
	while _checkpoint_markers.size() > checkpoints.size():
		var m: ColorRect = _checkpoint_markers.pop_back()
		m.queue_free()
	while _checkpoint_markers.size() < checkpoints.size():
		var marker := _marker_scene.instantiate() as ColorRect
		_escort_cp_container.add_child(marker)
		_checkpoint_markers.append(marker)

	for i in checkpoints.size():
		var cp_p := checkpoints[i] as float
		var marker: ColorRect = _checkpoint_markers[i]
		marker.color = Color.WHITE if i >= next_idx else Color(0.30, 0.30, 0.30)
		marker.anchor_left  = clampf(cp_p, 0.0, 1.0)
		marker.anchor_right = clampf(cp_p, 0.0, 1.0)

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

static func _fmt(seconds: float) -> String:
	var m: int = int(seconds / 60.0)
	var s: int = int(seconds) % 60
	return "%d:%02d" % [m, s]

func get_panel_name() -> String:
	return "HybridPanel"
