extends Control
class_name ControlPointIndicator

## A square indicator for a single control point showing ownership and capture
## progress.  The fill colour and labels update to reflect the current state.

const SIZE: float = 72.0

@onready var _bg_rect: ColorRect = $BgRect
@onready var _fill_rect: ColorRect = $FillRect
@onready var _label: Label = $Label
@onready var _pct_label: Label = $PctLabel

func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_PASS

func set_cp_state(data: Dictionary) -> void:
	var owning_team := data.get("owning_team", Player.Team.FFA) as int
	var capture_team := data.get("capture_team", Player.Team.FFA) as int
	var progress := data.get("capture_progress", 0.0) as float
	var contested := data.get("is_contested", false) as bool
	var locked := data.get("is_locked", false) as bool

	if locked:
		_bg_rect.color = Color(0.1, 0.1, 0.1, 0.85)
		_fill_rect.color = Color(0.2, 0.2, 0.2)
		_fill_rect.anchor_top = 1.0
		_label.text = "LOCKED"
		_label.modulate = Color(0.5, 0.5, 0.5)
		_pct_label.text = ""
		return

	_bg_rect.color = _dim(_team_color(owning_team))

	if contested:
		_fill_rect.color = Color.WHITE
		_fill_rect.anchor_top = 0.0
		_label.text = "CONTESTED"
		_label.modulate = Color.WHITE
		_pct_label.text = ""
	elif capture_team != Player.Team.FFA and capture_team != owning_team:
		_fill_rect.color = _team_color(capture_team)
		_fill_rect.anchor_top = 1.0 - clampf(progress, 0.0, 1.0)
		_label.text = _team_name(capture_team)
		_label.modulate = _team_color(capture_team)
		_pct_label.text = "%d%%" % int(progress * 100)
		_pct_label.modulate = Color(1, 1, 1, 0.9)
	elif owning_team != Player.Team.FFA:
		_fill_rect.color = _team_color(owning_team)
		_fill_rect.anchor_top = 1.0 - clampf(progress, 0.0, 1.0)
		_label.text = _team_name(owning_team)
		_label.modulate = _team_color(owning_team)
		_pct_label.text = "OWNED"
		_pct_label.modulate = Color(1, 1, 1, 0.6)
	else:
		_fill_rect.color = _team_color(Player.Team.FFA)
		_fill_rect.anchor_top = 1.0
		_label.text = "NEUTRAL"
		_label.modulate = _team_color(Player.Team.FFA)
		_pct_label.text = ""

static func _team_color(team: Player.Team) -> Color:
	match team:
		Player.Team.SPI: return Color(0.88, 0.24, 0.24)
		Player.Team.SCI: return Color(0.25, 0.65, 0.90)
		_: return Color(0.45, 0.45, 0.45)

static func _dim(c: Color) -> Color:
	return Color(c.r * 0.3, c.g * 0.3, c.b * 0.3, 0.90)

static func _team_name(team: Player.Team) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return ""
