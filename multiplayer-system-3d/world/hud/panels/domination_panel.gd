extends BaseModePanel
class_name DominationPanel

## DOMINATION mode panel.
##
## Shows team score bars, points-per-second rates, how many control
## points each team owns, and per-point capture status indicators.

const _cp_indicator_scene := preload("res://world/hud/components/control_point_indicator.tscn")

@onready var _spi_bar: TeamProgressBar = $VBox/SpiBar
@onready var _sci_bar: TeamProgressBar = $VBox/SciBar
@onready var _info_label: Label = $VBox/InfoLabel
@onready var _cp_container: HBoxContainer = $VBox/CpContainer

var _cp_indicators: Array[ControlPointIndicator] = []

func update_display(data: Dictionary) -> void:
	var points := data.get("points", {}) as Dictionary
	var target := data.get("points_to_win", 100.0) as float
	var owned := data.get("owned_points", {}) as Dictionary
	var pps := data.get("pps", 1.0) as float

	var spi_p := points.get(Player.Team.SPI, 0.0) as float
	var sci_p := points.get(Player.Team.SCI, 0.0) as float

	_spi_bar.set_progress(spi_p / target if target > 0 else 0.0)
	_sci_bar.set_progress(sci_p / target if target > 0 else 0.0)

	_spi_bar.set_labels("SPI", "%d  /  %d" % [int(spi_p), int(target)])
	_sci_bar.set_labels("SCI", "%d  /  %d" % [int(sci_p), int(target)])

	var spi_pts: int = owned.get(Player.Team.SPI, 0)
	var sci_pts: int = owned.get(Player.Team.SCI, 0)

	_info_label.text = "SPI +%d pts/s  (%d CP)  --  SCI +%d pts/s  (%d CP)" % [
		int(spi_pts * pps), spi_pts,
		int(sci_pts * pps), sci_pts,
	]

	# Control point indicators
	var cp_states: Array = data.get("control_points", [])
	_refresh_cp_indicators(cp_states)

func _refresh_cp_indicators(cp_states: Array) -> void:
	while _cp_indicators.size() < cp_states.size():
		var ind := _cp_indicator_scene.instantiate() as ControlPointIndicator
		_cp_container.add_child(ind)
		_cp_indicators.append(ind)
	while _cp_indicators.size() > cp_states.size():
		var ind: ControlPointIndicator = _cp_indicators.pop_back()
		ind.queue_free()

	for i in cp_states.size():
		_cp_indicators[i].set_cp_state(cp_states[i])

func get_panel_name() -> String:
	return "DominationPanel"
