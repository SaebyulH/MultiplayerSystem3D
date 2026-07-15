extends Control
class_name ControlPointIndicator

## A square indicator for a single control point showing ownership and capture
## progress.  The fill colour and labels update to reflect the current state.

const SIZE: float = 72.0

var _bg_rect: ColorRect
var _fill_rect: ColorRect
var _label: Label
var _pct_label: Label

func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_PASS

func _ready() -> void:
	_build()

func _build() -> void:
	# Background square
	_bg_rect = ColorRect.new()
	_bg_rect.color = _dim(_team_color(Player.Team.FFA))
	_bg_rect.anchor_left   = 0.0
	_bg_rect.anchor_right  = 1.0
	_bg_rect.anchor_top    = 0.0
	_bg_rect.anchor_bottom = 1.0
	add_child(_bg_rect)

	# Capture progress fill (bottom-up)
	_fill_rect = ColorRect.new()
	_fill_rect.color = _team_color(Player.Team.FFA)
	_fill_rect.anchor_left   = 0.0
	_fill_rect.anchor_right  = 1.0
	_fill_rect.anchor_bottom = 1.0
	_fill_rect.anchor_top    = 1.0
	add_child(_fill_rect)

	# Team / status label
	_label = Label.new()
	_label.anchor_left   = 0.0
	_label.anchor_right  = 1.0
	_label.anchor_top    = 0.0
	_label.anchor_bottom = 0.55
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment   = VERTICAL_ALIGNMENT_BOTTOM
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("outline_size", 4)
	_label.add_theme_font_size_override("font_size", 16)
	add_child(_label)

	# Percentage label
	_pct_label = Label.new()
	_pct_label.anchor_left   = 0.0
	_pct_label.anchor_right  = 1.0
	_pct_label.anchor_top    = 0.45
	_pct_label.anchor_bottom = 1.0
	_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pct_label.vertical_alignment   = VERTICAL_ALIGNMENT_TOP
	_pct_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_pct_label.add_theme_constant_override("outline_size", 4)
	_pct_label.add_theme_font_size_override("font_size", 13)
	add_child(_pct_label)

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
