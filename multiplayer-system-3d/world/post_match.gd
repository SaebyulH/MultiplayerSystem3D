extends CanvasLayer

## Full-screen post-match results overlay.  Uses the existing authoritative
## Leaderboard data; no new stats are invented.

const PANEL_BG := Color(0.05, 0.05, 0.08, 0.97)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const DIM := Color(0.0, 0.02, 0.06, 0.88)

var _winner: Label
var _lines: Label
var _countdown: Label
var _remaining := 10.0


func _ready() -> void:
	layer = 7
	visible = false
	_build()
	set_process(false)


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(900, 560)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(2)
	style.content_margin_left = 24
	style.content_margin_top = 18
	style.content_margin_right = 24
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "MATCH RESULTS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(title)

	_winner = Label.new()
	_winner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner.add_theme_font_size_override("font_size", 22)
	_winner.add_theme_color_override("font_color", Color(0.35, 0.65, 1.0))
	vb.add_child(_winner)

	_lines = Label.new()
	_lines.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lines.add_theme_font_size_override("font_size", 16)
	_lines.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vb.add_child(_lines)

	_countdown = Label.new()
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.add_theme_font_size_override("font_size", 14)
	_countdown.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	vb.add_child(_countdown)

	var back := Button.new()
	back.text = "RETURN TO LOBBY"
	back.add_theme_font_size_override("font_size", 18)
	back.pressed.connect(_leave)
	vb.add_child(back)


func open(winner_text: String) -> void:
	_winner.text = winner_text if winner_text != "" else "Match over"
	_lines.text = _stats_text()
	_remaining = 10.0
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	set_process(true)


func _process(delta: float) -> void:
	if not visible:
		return
	_remaining -= delta
	_countdown.text = "Returning to lobby in %d..." % maxi(0, ceili(_remaining))
	if _remaining <= 0.0:
		set_process(false)
		_leave()


func _stats_text() -> String:
	var lines: PackedStringArray = []
	var players := Leaderboard.get_players()
	players.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
	for pid in players:
		lines.append("%s   K %d   D %d   DMG %d" % [
			pid, Leaderboard.get_kills(pid), Leaderboard.get_deaths(pid),
			int(abs(Leaderboard.get_damage(pid)))])
	return "\n".join(lines)


func _leave() -> void:
	set_process(false)
	visible = false
	NetworkManager.return_to_lobby()
