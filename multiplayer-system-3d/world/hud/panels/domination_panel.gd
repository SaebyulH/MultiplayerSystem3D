extends BaseModePanel
class_name DominationPanel

## DOMINATION mode panel.
##
## Shows team score bars, points-per-second rates, and how many control
## points each team owns.

var _spi_bar: TeamProgressBar
var _sci_bar: TeamProgressBar
var _info_label: Label

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
	header.text = "── DOMINATION ──"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	header.add_theme_constant_override("outline_size", 6)
	header.add_theme_font_size_override("font_size", 20)
	vbox.add_child(header)

	# SPI bar
	_spi_bar = TeamProgressBar.new()
	vbox.add_child(_spi_bar)
	_spi_bar.set_bar_color(Color(0.88, 0.24, 0.24))

	# SCI bar
	_sci_bar = TeamProgressBar.new()
	vbox.add_child(_sci_bar)
	_sci_bar.set_bar_color(Color(0.20, 0.60, 0.86))

	# Info line
	_info_label = Label.new()
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_info_label.add_theme_constant_override("outline_size", 4)
	_info_label.add_theme_font_size_override("font_size", 16)
	_info_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(_info_label)

# ─────────────────────────────────────────────
#  Update
# ─────────────────────────────────────────────

func update_display(data: Dictionary) -> void:
	var points: Dictionary = data.get("points", {})
	var target: float      = data.get("points_to_win", 1000.0)
	var owned: Dictionary  = data.get("owned_points", {})
	var pps: float         = data.get("pps", 1.0)

	var spi_p: float = points.get(Player.Team.SPI, 0.0)
	var sci_p: float = points.get(Player.Team.SCI, 0.0)

	_spi_bar.set_progress(spi_p / target if target > 0 else 0.0)
	_sci_bar.set_progress(sci_p / target if target > 0 else 0.0)

	_spi_bar.set_labels("SPI", "%d  /  %d" % [int(spi_p), int(target)])
	_sci_bar.set_labels("SCI", "%d  /  %d" % [int(sci_p), int(target)])

	var spi_pts: int = owned.get(Player.Team.SPI, 0)
	var sci_pts: int = owned.get(Player.Team.SCI, 0)

	_info_label.text = "SPI +%d pts/s  (%d CP)  —  SCI +%d pts/s  (%d CP)" % [
		int(spi_pts * pps), spi_pts,
		int(sci_pts * pps), sci_pts,
	]

func get_panel_name() -> String:
	return "DominationPanel"
