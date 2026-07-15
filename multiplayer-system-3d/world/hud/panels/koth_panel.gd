extends BaseModePanel
class_name KothPanel

## KOTH / CONTROL mode panel.
##
## Shows two team-coloured progress bars (SPI / SCI) racing toward the
## capture-time-to-win target.

var _spi_bar: TeamProgressBar
var _sci_bar: TeamProgressBar
var _target_label: Label

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	_build()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.anchor_left   = 0.0
	vbox.anchor_right  = 1.0
	vbox.anchor_top    = 0.0
	vbox.anchor_bottom = 1.0
	add_child(vbox)

	# Header
	var header := Label.new()
	header.text = "── KOTH ──"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	header.add_theme_constant_override("outline_size", 6)
	header.add_theme_font_size_override("font_size", 20)
	vbox.add_child(header)

	# SPI bar
	_spi_bar = TeamProgressBar.new()
	vbox.add_child(_spi_bar)
	_spi_bar.set_bar_color(Color(0.88, 0.24, 0.24))   # red

	# SCI bar
	_sci_bar = TeamProgressBar.new()
	vbox.add_child(_sci_bar)
	_sci_bar.set_bar_color(Color(0.20, 0.60, 0.86))   # blue

	# Target info
	_target_label = Label.new()
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_target_label.add_theme_constant_override("outline_size", 4)
	_target_label.add_theme_font_size_override("font_size", 16)
	_target_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(_target_label)

# ─────────────────────────────────────────────
#  Update
# ─────────────────────────────────────────────

func update_display(data: Dictionary) -> void:
	var time_held: Dictionary = data.get("time_held", {})
	var target: float = data.get("capture_time_to_win", 30.0)

	var spi_t: float = time_held.get(Player.Team.SPI, 0.0)
	var sci_t: float = time_held.get(Player.Team.SCI, 0.0)

	_spi_bar.set_progress(spi_t / target if target > 0 else 0.0)
	_sci_bar.set_progress(sci_t / target if target > 0 else 0.0)

	_spi_bar.set_labels("SPI", _fmt(spi_t) + " / " + _fmt(target))
	_sci_bar.set_labels("SCI", _fmt(sci_t) + " / " + _fmt(target))

	_target_label.text = "Cap to win:  " + _fmt(target)

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

static func _fmt(seconds: float) -> String:
	var m := int(seconds) / 60
	var s := int(seconds) % 60
	return "%d:%02d" % [m, s]

func get_panel_name() -> String:
	return "KothPanel"
