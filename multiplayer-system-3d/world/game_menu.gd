extends Control

@export var base_sound: AudioStream

var player_id: String
var play_token: int = 0

# -- Leaderboard overlay --
var _lb_canvas: CanvasLayer = null
var _lb_rows: VBoxContainer = null

# Pitch constants (E-based semitone scaling)
const PITCH_E  := pow(2.0, 0.0 / 12.0)
const PITCH_FS := pow(2.0, 2.0 / 12.0)
const PITCH_G  := pow(2.0, 3.0 / 12.0)
const PITCH_A  := pow(2.0, 5.0 / 12.0)
const PITCH_B  := pow(2.0, 7.0 / 12.0)

# Column widths
const COL_RANK := 40
const COL_NAME := 130
const COL_CHAR := 110
const COL_K   := 36
const COL_D   := 36
const COL_STRK := 50
const COL_DMG := 64
const COL_SD  := 64
const COL_HO  := 56


func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())
	if has_node("ID"):
		$ID.text = "ID: " + player_id

	Leaderboard.killstreak_changed.connect(_on_killstreak_changed)
	_build_leaderboard_ui()


func _make_label(text: String, width: float, font_size: int, col: Color) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(width, 0)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if width <= 50 else HORIZONTAL_ALIGNMENT_LEFT
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", col)
	return lbl


func _build_leaderboard_ui() -> void:
	_lb_canvas = CanvasLayer.new()
	_lb_canvas.layer = 5
	_lb_canvas.visible = false
	_lb_canvas.name = "LeaderboardCanvas"
	get_tree().root.add_child(_lb_canvas)

	# Dim backdrop
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.06, 0.78)
	dim.anchor_left   = 0.0
	dim.anchor_right  = 1.0
	dim.anchor_top    = 0.0
	dim.anchor_bottom = 1.0
	_lb_canvas.add_child(dim)

	# Centered container
	var center: CenterContainer = CenterContainer.new()
	center.anchor_left   = 0.0
	center.anchor_right  = 1.0
	center.anchor_top    = 0.0
	center.anchor_bottom = 1.0
	_lb_canvas.add_child(center)

	# Outer VBox (title + scroll area)
	var outer: VBoxContainer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	center.add_child(outer)

	# Dark panel background
	var panel: Panel = Panel.new()
	panel.custom_minimum_size = Vector2(900, 400)
	var pstyle: StyleBoxFlat = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.05, 0.05, 0.08, 0.94)
	pstyle.border_width_left = 2
	pstyle.border_width_right = 2
	pstyle.border_width_top = 2
	pstyle.border_width_bottom = 2
	pstyle.border_color = Color(0.3, 0.3, 0.4, 0.8)
	pstyle.corner_radius_top_left = 8
	pstyle.corner_radius_top_right = 8
	pstyle.corner_radius_bottom_left = 8
	pstyle.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", pstyle)
	outer.add_child(panel)

	# VBox inside panel
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.anchor_left   = 0.0
	vbox.anchor_right  = 1.0
	vbox.anchor_top    = 0.0
	vbox.anchor_bottom = 1.0
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	# Title
	var title: Label = Label.new()
	title.text = "LEADERBOARD  (hold Tab)"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(title)

	# Separator
	var sep: HSeparator = HSeparator.new()
	vbox.add_child(sep)

	# Header row
	var header_hbox: HBoxContainer = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 2)
	var hdr_col: Color = Color(0.55, 0.55, 0.6)
	header_hbox.add_child(_make_label("#", COL_RANK, 12, hdr_col))
	header_hbox.add_child(_make_label("Player", COL_NAME, 12, hdr_col))
	header_hbox.add_child(_make_label("Character", COL_CHAR, 12, hdr_col))
	header_hbox.add_child(_make_label("K", COL_K, 12, hdr_col))
	header_hbox.add_child(_make_label("D", COL_D, 12, hdr_col))
	header_hbox.add_child(_make_label("Strk", COL_STRK, 12, hdr_col))
	header_hbox.add_child(_make_label("DMG", COL_DMG, 12, hdr_col))
	header_hbox.add_child(_make_label("Self DMG", COL_SD, 12, hdr_col))
	header_hbox.add_child(_make_label("Heal Self", COL_HO, 12, hdr_col))
	header_hbox.add_child(_make_label("Heal Oth.", COL_HO, 12, hdr_col))
	vbox.add_child(header_hbox)

	# Separator
	var sep2: HSeparator = HSeparator.new()
	vbox.add_child(sep2)

	# Scrollable player rows
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_lb_rows = VBoxContainer.new()
	_lb_rows.add_theme_constant_override("separation", 0)
	_lb_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_lb_rows)


func _build_row(rank: String, name: String, char_name: String, kills: String, deaths: String, streak: String, dmg: String, self_dmg: String, heal_self: String, heal_oth: String, is_self: bool) -> HBoxContainer:
	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 2)
	var col: Color = Color(1.0, 0.84, 0.0) if is_self else Color(0.82, 0.82, 0.82)
	hbox.add_child(_make_label(rank,      COL_RANK, 13, col))
	hbox.add_child(_make_label(name,      COL_NAME, 13, col))
	hbox.add_child(_make_label(char_name, COL_CHAR, 13, col))
	hbox.add_child(_make_label(kills,     COL_K,   13, col))
	hbox.add_child(_make_label(deaths,    COL_D,   13, col))
	hbox.add_child(_make_label(streak,    COL_STRK, 13, col))
	hbox.add_child(_make_label(dmg,       COL_DMG, 13, col))
	hbox.add_child(_make_label(self_dmg,  COL_SD,  13, col))
	hbox.add_child(_make_label(heal_self, COL_HO,  13, col))
	hbox.add_child(_make_label(heal_oth,  COL_HO,  13, col))
	return hbox


func _process(_delta: float) -> void:
	if not _lb_canvas or not _lb_canvas.visible:
		return
	if Leaderboard == null:
		return

	var players = Leaderboard.get_players()
	players.sort_custom(func(a, b):
		return Leaderboard.get_kills(a) > Leaderboard.get_kills(b)
	)

	# Clear old rows
	for child in _lb_rows.get_children():
		child.queue_free()

	var rank: int = 0
	var my_streak: int = 0

	for player in players:
		rank += 1
		var kills: int = Leaderboard.get_kills(player)
		var deaths: int = Leaderboard.get_deaths(player)
		var streak: int = Leaderboard.get_killstreak(player)
		var damage: int = int(abs(Leaderboard.get_damage(player)))
		var self_dam: int = int(abs(Leaderboard.get_self_damage(player)))
		var heal_others: int = int(Leaderboard.get_heal_others(player))
		var heal_self: int = int(Leaderboard.get_self_heal(player))

		var is_self: bool = (player == player_id)
		if is_self:
			my_streak = streak

		# Character name
		var char_name: String = ""
		var pnode: Player = GameManager.find_player(player)
		if pnode and pnode._character:
			char_name = pnode._character.character_name

		# Truncate long names
		var short_name: String = str(player)
		if short_name.length() > 14:
			short_name = short_name.substr(0, 13) + "."

		_lb_rows.add_child(_build_row(
			str(rank), short_name, char_name,
			str(kills), str(deaths), str(streak),
			str(damage), str(self_dam), str(heal_self), str(heal_others),
			is_self
		))

	# Update killstreak display
	if has_node("Killstreak"):
		$Killstreak.text = "%d kills" % my_streak if my_streak > 0 else ""


func show_leaderboard() -> void:
	if _lb_canvas:
		_lb_canvas.visible = true

func hide_leaderboard() -> void:
	if _lb_canvas:
		_lb_canvas.visible = false


func _on_killstreak_changed(player_name: String, killstreak: int) -> void:
	if player_name != player_id:
		return

	play_token += 1
	var token: int = play_token
	var seq: Array[float] = _get_pitch_sequence(killstreak)
	_play_sequence_async(seq, token)

func _play_sequence_async(seq: Array[float], token: int) -> void:
	for pitch in seq:
		if token != play_token:
			return
		if not is_inside_tree():
			return
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.stream = base_sound
		p.pitch_scale = pitch
		add_child(p)
		p.play()
		p.finished.connect(func(): p.queue_free())
		await get_tree().create_timer(0.15).timeout
	if token == play_token:
		if not is_inside_tree():
			return
		await get_tree().create_timer(0.3).timeout


func _get_pitch_sequence(ks: int) -> Array[float]:
	match ks:
		1:  return [PITCH_E]
		2:  return [PITCH_G]
		3:  return [PITCH_A]
		4:  return [PITCH_B]
		5:  return [PITCH_E, PITCH_E, PITCH_G, PITCH_A, PITCH_B]
		6:  return [PITCH_E, PITCH_G]
		7:  return [PITCH_G, PITCH_A]
		8:  return [PITCH_A, PITCH_B]
		9:  return [PITCH_B, PITCH_E]
		10: return [PITCH_E, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_G]
		11: return [PITCH_E, PITCH_FS, PITCH_G]
		12: return [PITCH_G, PITCH_A, PITCH_B]
		13: return [PITCH_A, PITCH_B, PITCH_E]
		14: return [PITCH_FS, PITCH_A, PITCH_B]
		15: return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_A, PITCH_G]
		16: return [PITCH_E, PITCH_G, PITCH_E, PITCH_B]
		17: return [PITCH_G, PITCH_A, PITCH_G, PITCH_E]
		18: return [PITCH_A, PITCH_B, PITCH_A, PITCH_G]
		19: return [PITCH_B, PITCH_A, PITCH_FS, PITCH_E]
		20: return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		21: return [PITCH_E, PITCH_G, PITCH_B, PITCH_G, PITCH_E]
		22: return [PITCH_FS, PITCH_A, PITCH_B, PITCH_A, PITCH_FS]
		23: return [PITCH_G, PITCH_B, PITCH_E, PITCH_B, PITCH_G]
		24: return [PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A]
		25: return [PITCH_E, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		26: return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E]
		27: return [PITCH_B, PITCH_A, PITCH_G, PITCH_FS, PITCH_E, PITCH_FS]
		28: return [PITCH_E, PITCH_G, PITCH_B, PITCH_E, PITCH_B, PITCH_G, PITCH_E]
		29: return [PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G]
		30: return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		_: return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
