extends CanvasLayer

## Full-screen post-match results overlay.  Uses the existing authoritative
## Leaderboard data; no new stats are invented.

var _winner: Label
var _rows: VBoxContainer
var _countdown: Label
var _remaining := 10.0


func _ready() -> void:
	layer = 7
	visible = false
	_build()
	set_process(false)


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(980, 620)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 30))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var title := UITheme.display_label("MATCH RESULTS", 34, UITheme.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	_winner = UITheme.display_label("", 22, UITheme.TEAL)
	_winner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_winner)
	vb.add_child(UITheme.accent_bar(UITheme.RED, 3))

	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", UITheme.flat_style(UITheme.SLATE, 0))
	vb.add_child(header)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 10)
	header.add_child(hrow)
	hrow.add_child(_cell("PLAYER", 0, true))
	hrow.add_child(_cell("K", 64))
	hrow.add_child(_cell("D", 64))
	hrow.add_child(_cell("DMG", 110))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 4)
	scroll.add_child(_rows)

	_countdown = UITheme.body_label("", UITheme.FS_SMALL, UITheme.MUTED)
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_countdown)

	var back := Button.new()
	back.text = "RETURN TO LOBBY"
	back.custom_minimum_size = Vector2(0, 46)
	back.add_theme_font_override("font", UITheme.FONT_EXTRABOLD)
	back.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.PRIMARY))
	back.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.PRIMARY, true))
	back.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.PRIMARY, false, true))
	back.pressed.connect(_leave)
	vb.add_child(back)


func _cell(text: String, width: int, expand := false) -> Control:
	var lbl := UITheme.section_label(text, UITheme.MUTED)
	lbl.custom_minimum_size = Vector2(width, 0)
	if expand:
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return lbl


func _make_row(pid: String, rank: int, kills: int, deaths: int, damage: int) -> Control:
	var player := GameManager.find_player(pid)
	var team := int(player.team) if player else int(Player.Team.FFA)
	var accent := UITheme.team_color(team)
	var panel := PanelContainer.new()
	var style := UITheme.card_style(UITheme.State.NORMAL)
	style.bg_color = Color(UITheme.SLATE.r, UITheme.SLATE.g, UITheme.SLATE.b, 0.6 if rank % 2 == 0 else 0.35)
	style.border_color = Color(accent.r, accent.g, accent.b, 0.4)
	panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var bar := ColorRect.new()
	bar.color = accent
	bar.custom_minimum_size = Vector2(3, 0)
	row.add_child(bar)

	var name_box := HBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.add_theme_constant_override("separation", 8)
	row.add_child(name_box)
	var rank_lbl := UITheme.body_label("%02d" % (rank + 1), UITheme.FS_SMALL, UITheme.MUTED)
	rank_lbl.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	name_box.add_child(rank_lbl)
	var portrait := TextureRect.new()
	portrait.custom_minimum_size = Vector2(28, 28)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var char_res := UITheme.player_character(player)
	portrait.texture = char_res.portrait if char_res else null
	name_box.add_child(portrait)
	var name_lbl := UITheme.body_label(pid, UITheme.FS_BODY, UITheme.TEXT)
	name_lbl.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	name_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_child(name_lbl)
	var team_lbl := UITheme.section_label(UITheme.team_name(team), accent)
	team_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_child(team_lbl)

	row.add_child(_value(str(kills), 64))
	row.add_child(_value(str(deaths), 64))
	row.add_child(_value(str(damage), 110))
	return panel


func _value(text: String, width: int) -> Control:
	var lbl := UITheme.body_label(text, UITheme.FS_BODY, UITheme.TEXT)
	lbl.custom_minimum_size = Vector2(width, 0)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	return lbl


func open(winner_text: String) -> void:
	_winner.text = (winner_text if winner_text != "" else "Match over").to_upper()
	_winner.add_theme_color_override("font_color", _winner_color(winner_text))
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	var players := Leaderboard.get_players()
	players.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
	var rank := 0
	for pid in players:
		_rows.add_child(_make_row(pid,
			rank,
			Leaderboard.get_kills(pid),
			Leaderboard.get_deaths(pid),
			int(abs(Leaderboard.get_damage(pid)))))
		rank += 1
	_remaining = 10.0
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	set_process(true)


func _winner_color(text: String) -> Color:
	if text.to_upper().contains("SPI"):
		return UITheme.RED
	if text.to_upper().contains("SCI"):
		return UITheme.TEAL
	return UITheme.MUTED


func _process(delta: float) -> void:
	if not visible:
		return
	_remaining -= delta
	_countdown.text = "RETURNING TO LOBBY IN %d…" % maxi(0, ceili(_remaining))
	if _remaining <= 0.0:
		set_process(false)
		_leave()


func _leave() -> void:
	set_process(false)
	visible = false
	NetworkManager.return_to_lobby()
