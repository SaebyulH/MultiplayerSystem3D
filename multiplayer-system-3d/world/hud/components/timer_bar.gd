extends Control
class_name TimerBar

## A full-width countdown bar whose fill shrinks and changes colour as time
## runs out.  Overlaid centre text shows the formatted time.
##
## Colours:
##   green  (> 50 % remaining)
##   yellow (25–50 %)
##   red    (< 25 % or overtime)

@export var bar_height: float = 32.0
@export var warning_threshold: float = 0.5   # below this → yellow
@export var danger_threshold: float  = 0.25  # below this → red

var _bg_rect: ColorRect
var _fill_rect: ColorRect
var _label: Label

var _is_overtime: bool = false

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _init() -> void:
	custom_minimum_size = Vector2(0, bar_height)

func _ready() -> void:
	_build()

func _build() -> void:
	# Background
	_bg_rect = ColorRect.new()
	_bg_rect.color = Color(0.08, 0.08, 0.08, 0.85)
	_bg_rect.anchor_left   = 0.0
	_bg_rect.anchor_right  = 1.0
	_bg_rect.anchor_top    = 0.0
	_bg_rect.anchor_bottom = 1.0
	add_child(_bg_rect)

	# Shrinking fill
	_fill_rect = ColorRect.new()
	_fill_rect.color = Color(0.25, 0.75, 0.25)  # green
	_fill_rect.anchor_left   = 0.0
	_fill_rect.anchor_right  = 1.0
	_fill_rect.anchor_top    = 0.0
	_fill_rect.anchor_bottom = 1.0
	add_child(_fill_rect)

	# Centre overlay label
	_label = Label.new()
	_label.anchor_left   = 0.0
	_label.anchor_right  = 1.0
	_label.anchor_top    = 0.0
	_label.anchor_bottom = 1.0
	_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("outline_size", 8)
	_label.add_theme_font_size_override("font_size", 22)
	add_child(_label)

# ─────────────────────────────────────────────
#  Public API
# ─────────────────────────────────────────────

## Call every frame or whenever the remaining time changes.
func set_time(remaining: float, max_time: float) -> void:
	var pct := 1.0
	if max_time > 0.0:
		pct = clampf(remaining / max_time, 0.0, 1.0)

	_fill_rect.anchor_right = pct
	_label.text = _fmt(remaining)

	if _is_overtime:
		_fill_rect.color = Color(0.85, 0.15, 0.15)  # solid red
	elif pct <= danger_threshold:
		_fill_rect.color = Color(0.85, 0.15, 0.15)   # red
	elif pct <= warning_threshold:
		_fill_rect.color = Color(0.85, 0.75, 0.1)    # yellow
	else:
		_fill_rect.color = Color(0.25, 0.75, 0.25)   # green

## Toggle overtime appearance (solid red bar).
func set_overtime(active: bool) -> void:
	_is_overtime = active

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

static func _fmt(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00"
	var m := int(seconds) / 60
	var s := int(seconds) % 60
	return "%d:%02d" % [m, s]
