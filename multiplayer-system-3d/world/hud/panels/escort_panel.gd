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

const _marker_scene := preload("res://world/hud/components/checkpoint_marker.tscn")

@onready var _progress_container: Control = $VBox/ProgressContainer
@onready var _fill_rect: ColorRect = $VBox/ProgressContainer/FillRect
@onready var _state_label: Label = $VBox/ProgressContainer/StateLabel
@onready var _pct_label: Label = $VBox/ProgressContainer/PctLabel
@onready var _info_label: Label = $VBox/InfoLabel
@onready var _cp_container: Control = $VBox/CpContainer

var _checkpoint_markers: Array[ColorRect] = []

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
	# Reuse markers across calls instead of free + re-instantiate every tick
	# (update_display runs at the 10 Hz state sync, so this was churning nodes).
	while _checkpoint_markers.size() > checkpoints.size():
		var m: ColorRect = _checkpoint_markers.pop_back()
		m.queue_free()
	while _checkpoint_markers.size() < checkpoints.size():
		var marker := _marker_scene.instantiate() as ColorRect
		_cp_container.add_child(marker)
		_checkpoint_markers.append(marker)

	for i in checkpoints.size():
		var cp_p := checkpoints[i] as float
		var marker: ColorRect = _checkpoint_markers[i]
		marker.color = Color.WHITE if i >= next_idx else Color(0.30, 0.30, 0.30)
		marker.anchor_left  = clampf(cp_p, 0.0, 1.0)
		marker.anchor_right = clampf(cp_p, 0.0, 1.0)

func get_panel_name() -> String:
	return "EscortPanel"
