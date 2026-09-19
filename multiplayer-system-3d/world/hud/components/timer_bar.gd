extends Control
class_name TimerBar

## A centered, downward-pointing dark banner showing the remaining match time
## in white text.  Restyled for the clean HUD (no fill bar, no text outline).

@export var banner_width: float = 180.0
@export var banner_height: float = 52.0

@onready var _label: Label = $Label

var _is_overtime: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(0, banner_height)


func _ready() -> void:
	var font := load("res://assets/CenturyGothic - Century Gothic - Regular.ttf") as Font
	if font:
		_label.add_theme_font_override("font", font)
	_label.add_theme_constant_override("outline_size", 0)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))


## Call every frame or whenever the remaining time changes.
func set_time(remaining: float, max_time: float) -> void:
	_label.text = _fmt(remaining)
	if _is_overtime:
		_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	else:
		_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))


func set_overtime(active: bool) -> void:
	_is_overtime = active


func _draw() -> void:
	var w := size.x
	var h := size.y
	var bw := minf(banner_width, w)
	var cx := w * 0.5
	var top_y := (h - banner_height) * 0.5
	var bot_y := top_y + banner_height
	# Downward-pointing banner (narrower at the bottom).
	var half_top := bw * 0.5
	var half_bot := half_top * 0.7
	var pts := PackedVector2Array([
		Vector2(cx - half_top, top_y),
		Vector2(cx + half_top, top_y),
		Vector2(cx + half_bot, bot_y),
		Vector2(cx - half_bot, bot_y),
	])
	draw_colored_polygon(pts, Color(0.0, 0.0, 0.0, 0.85))


static func _fmt(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00"
	var m: int = int(seconds / 60.0)
	var s: int = int(seconds) % 60
	return "%d:%02d" % [m, s]
