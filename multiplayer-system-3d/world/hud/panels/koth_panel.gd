extends BaseModePanel
class_name KothPanel

## KOTH / CONTROL mode panel.
##
## Shows two team-coloured progress bars (SPI / SCI) racing toward the
## capture-time-to-win target, plus control-point status indicators.

const _cp_indicator_scene := preload("res://world/hud/components/control_point_indicator.tscn")

@onready var _spi_bar: TeamProgressBar = $VBox/SpiBar
@onready var _sci_bar: TeamProgressBar = $VBox/SciBar
@onready var _target_label: Label = $VBox/TargetLabel
@onready var _cp_container: HBoxContainer = $VBox/CpContainer

var _cp_indicators: Array[ControlPointIndicator] = []

func update_display(data: Dictionary) -> void:
	var time_held := data.get("time_held", {}) as Dictionary
	var target := data.get("capture_time_to_win", 30.0) as float

	var spi_t := time_held.get(Player.Team.SPI, 0.0) as float
	var sci_t := time_held.get(Player.Team.SCI, 0.0) as float

	_spi_bar.set_progress(spi_t / target if target > 0 else 0.0)
	_sci_bar.set_progress(sci_t / target if target > 0 else 0.0)

	_spi_bar.set_labels("SPI", _fmt(spi_t) + " / " + _fmt(target))
	_sci_bar.set_labels("SCI", _fmt(sci_t) + " / " + _fmt(target))

	_target_label.text = "Cap to win:  " + _fmt(target)

	# Control point indicators
	var cp_states: Array = data.get("control_points", [])
	_refresh_cp_indicators(cp_states)

func _refresh_cp_indicators(cp_states: Array) -> void:
	# Ensure we have the right number of indicators
	while _cp_indicators.size() < cp_states.size():
		var ind := _cp_indicator_scene.instantiate() as ControlPointIndicator
		_cp_container.add_child(ind)
		_cp_indicators.append(ind)
	while _cp_indicators.size() > cp_states.size():
		var ind: ControlPointIndicator = _cp_indicators.pop_back()
		ind.queue_free()

	for i in cp_states.size():
		_cp_indicators[i].set_cp_state(cp_states[i])

static func _fmt(seconds: float) -> String:
	var m: int = int(seconds / 60.0)
	var s: int = int(seconds) % 60
	return "%d:%02d" % [m, s]

func get_panel_name() -> String:
	return "KothPanel"
