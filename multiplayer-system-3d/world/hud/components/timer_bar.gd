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

@onready var _bg_rect: ColorRect = $BgRect
@onready var _fill_rect: ColorRect = $FillRect
@onready var _label: Label = $Label

var _is_overtime: bool = false

func _init() -> void:
	custom_minimum_size = Vector2(0, bar_height)

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
	var m: int = int(seconds / 60.0)
	var s: int = int(seconds) % 60
	return "%d:%02d" % [m, s]
