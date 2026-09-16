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

@onready var _bg_rect: ColorRect = $BgRect
@onready var _fill_rect: ColorRect = $FillRect
@onready var _label_left: Label = $LabelLeft
@onready var _label_right: Label = $LabelRight

func _init() -> void:
	custom_minimum_size = Vector2(200, bar_height)
	mouse_filter = Control.MOUSE_FILTER_PASS

func _ready() -> void:
	# Apply exported colours to the scene-defined rects.
	_bg_rect.color = bg_color
	_fill_rect.color = team_color

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
