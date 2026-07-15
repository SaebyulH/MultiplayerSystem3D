extends Control
class_name TeamProgressBar

## A team-colored horizontal progress bar with left/right overlay labels.
##
## Usage:
##   var bar := TeamProgressBar.new()
##   bar.team_color = Color.RED
##   bar.set_labels("SPI", "0:18 / 0:30")
##   bar.set_progress(0.6)
##   add_child(bar)

@export var team_color: Color = Color.WHITE
@export var bg_color: Color = Color(0.12, 0.12, 0.12, 0.85)
@export var bar_height: float = 28.0

var _bg_rect: ColorRect
var _fill_rect: ColorRect
var _label_left: Label
var _label_right: Label

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _init() -> void:
	custom_minimum_size = Vector2(200, bar_height)
	mouse_filter = Control.MOUSE_FILTER_PASS

func _ready() -> void:
	_build()

func _build() -> void:
	# Background bar
	_bg_rect = ColorRect.new()
	_bg_rect.color = bg_color
	_bg_rect.anchor_left   = 0.0
	_bg_rect.anchor_right  = 1.0
	_bg_rect.anchor_top    = 0.0
	_bg_rect.anchor_bottom = 1.0
	add_child(_bg_rect)

	# Filled portion
	_fill_rect = ColorRect.new()
	_fill_rect.color = team_color
	_fill_rect.anchor_left   = 0.0
	_fill_rect.anchor_right  = 0.0  # updated by set_progress()
	_fill_rect.anchor_top    = 0.0
	_fill_rect.anchor_bottom = 1.0
	add_child(_fill_rect)

	# Left label (team name)
	_label_left = Label.new()
	_label_left.anchor_left   = 0.0
	_label_left.anchor_right  = 0.5
	_label_left.anchor_top    = 0.0
	_label_left.anchor_bottom = 1.0
	_label_left.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_label_left.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label_left.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label_left.add_theme_constant_override("outline_size", 6)
	_label_left.add_theme_font_size_override("font_size", 18)
	add_child(_label_left)

	# Right label (value)
	_label_right = Label.new()
	_label_right.anchor_left   = 0.5
	_label_right.anchor_right  = 1.0
	_label_right.anchor_top    = 0.0
	_label_right.anchor_bottom = 1.0
	_label_right.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_label_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label_right.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label_right.add_theme_constant_override("outline_size", 6)
	_label_right.add_theme_font_size_override("font_size", 18)
	_label_right.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	add_child(_label_right)

# ─────────────────────────────────────────────
#  Public API
# ─────────────────────────────────────────────

## Set the fill amount (0.0 – 1.0).
func set_progress(pct: float) -> void:
	pct = clampf(pct, 0.0, 1.0)
	if _fill_rect:
		_fill_rect.anchor_right = pct

## Set the left and right label text.
func set_labels(left: String, right: String) -> void:
	if _label_left:
		_label_left.text = left
	if _label_right:
		_label_right.text = right

## Change the bar colour after construction.
func set_bar_color(color: Color) -> void:
	team_color = color
	if _fill_rect:
		_fill_rect.color = color
