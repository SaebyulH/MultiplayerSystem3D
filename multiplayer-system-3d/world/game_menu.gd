extends Control

@export var base_sound: AudioStream

var player_id: String
var play_token: int = 0

# -- Leaderboard overlay --
var _lb_canvas: CanvasLayer = null
var _lb_panel: Panel = null
var _lb_label: RichTextLabel = null

# Pitch constants (E-based semitone scaling)
const PITCH_E  := pow(2.0, 0.0 / 12.0)
const PITCH_FS := pow(2.0, 2.0 / 12.0)
const PITCH_G  := pow(2.0, 3.0 / 12.0)
const PITCH_A  := pow(2.0, 5.0 / 12.0)
const PITCH_B  := pow(2.0, 7.0 / 12.0)


func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())
	$ID.text = "ID: " + player_id

	Leaderboard.killstreak_changed.connect(_on_killstreak_changed)
	_build_leaderboard_ui()


func _build_leaderboard_ui() -> void:
	_lb_canvas = CanvasLayer.new()
	_lb_canvas.layer = 5  # above HUD (1), class select (2)
	_lb_canvas.visible = false
	_lb_canvas.name = "LeaderboardCanvas"
	get_tree().root.add_child(_lb_canvas)

	# Dim backdrop
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.06, 0.75)
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

	# Dark panel
	_lb_panel = Panel.new()
	_lb_panel.custom_minimum_size = Vector2(720, 400)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.92)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.3, 0.3, 0.4, 0.8)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	_lb_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_lb_panel)

	# VBox inside the panel
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.anchor_left   = 0.0
	vbox.anchor_right  = 1.0
	vbox.anchor_top    = 0.0
	vbox.anchor_bottom = 1.0
	vbox.add_theme_constant_override("separation", 0)
	_lb_panel.add_child(vbox)

	# Title
	var title: Label = Label.new()
	title.text = "LEADERBOARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	title.add_theme_constant_override("outline_size", 4)
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	# Header separator
	var sep1: HSeparator = HSeparator.new()
	sep1.custom_minimum_size = Vector2(0, 2)
	vbox.add_child(sep1)

	# Column header
	var header: RichTextLabel = RichTextLabel.new()
	header.bbcode_enabled = true
	header.fit_content = true
	header.add_theme_font_size_override("normal_font_size", 14)
	header.add_theme_color_override("default_color", Color(0.6, 0.6, 0.65))
	header.text = _format_row("#", "PLAYER", "K", "D", "STRK", "DMG", "SELF DMG", "HEAL")
	vbox.add_child(header)

	# Header separator
	var sep2: HSeparator = HSeparator.new()
	sep2.custom_minimum_size = Vector2(0, 2)
	vbox.add_child(sep2)

	# Scrollable list
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_lb_label = RichTextLabel.new()
	_lb_label.bbcode_enabled = true
	_lb_label.fit_content = true
	_lb_label.add_theme_font_size_override("normal_font_size", 14)
	_lb_label.add_theme_color_override("default_color", Color(0.82, 0.82, 0.82))
	_lb_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_lb_label)


func _format_row(rank: String, name: String, k: String, d: String, s: String, dmg: String, sdmg: String, heal: String) -> String:
	return "[font=res://assets/fonts/JetBrainsMono-Regular.ttf]%3s  %-14s  %3s  %3s  %4s  %6s  %8s  %5s[/font]" % [rank, name, k, d, s, dmg, sdmg, heal]


func _process(_delta: float) -> void:
	if not _lb_canvas or not _lb_canvas.visible:
		return
	if Leaderboard == null:
		return

	var players = Leaderboard.get_players()
	players.sort_custom(func(a, b):
		return Leaderboard.get_kills(a) > Leaderboard.get_kills(b)
	)

	var lines: PackedStringArray = []
	var my_streak: int = 0
	var rank: int = 0

	for player in players:
		rank += 1
		var kills: int = Leaderboard.get_kills(player)
		var deaths: int = Leaderboard.get_deaths(player)
		var streak: int = Leaderboard.get_killstreak(player)
		var damage: int = int(Leaderboard.get_damage(player))
		var self_dam: int = int(Leaderboard.get_self_damage(player))
		var heal_others: int = int(Leaderboard.get_heal_others(player))
		var heal_self: int = int(Leaderboard.get_self_heal(player))
		var total_heal: int = heal_others + heal_self

		var color_tag: String = ""
		var color_end: String = ""
		if player == player_id:
			color_tag = "[color=#FFD700]"
			color_end = "[/color]"
			my_streak = streak

		# Truncate long names
		var short_name: String = str(player)
		if short_name.length() > 14:
			short_name = short_name.substr(0, 13) + "."

		lines.append(color_tag + _format_row(
			str(rank), short_name,
			str(kills), str(deaths), str(streak),
			str(damage), str(self_dam), str(total_heal)
		) + color_end)

	_lb_label.text = "\n".join(lines)

	# Update killstreak display for our player
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
		1:
			return [PITCH_E]
		2:
			return [PITCH_G]
		3:
			return [PITCH_A]
		4:
			return [PITCH_B]
		5:
			return [PITCH_E, PITCH_E, PITCH_G, PITCH_A, PITCH_B]
		6:
			return [PITCH_E, PITCH_G]
		7:
			return [PITCH_G, PITCH_A]
		8:
			return [PITCH_A, PITCH_B]
		9:
			return [PITCH_B, PITCH_E]
		10:
			return [PITCH_E, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_G]
		11:
			return [PITCH_E, PITCH_FS, PITCH_G]
		12:
			return [PITCH_G, PITCH_A, PITCH_B]
		13:
			return [PITCH_A, PITCH_B, PITCH_E]
		14:
			return [PITCH_FS, PITCH_A, PITCH_B]
		15:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_A, PITCH_G]
		16:
			return [PITCH_E, PITCH_G, PITCH_E, PITCH_B]
		17:
			return [PITCH_G, PITCH_A, PITCH_G, PITCH_E]
		18:
			return [PITCH_A, PITCH_B, PITCH_A, PITCH_G]
		19:
			return [PITCH_B, PITCH_A, PITCH_FS, PITCH_E]
		20:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		21:
			return [PITCH_E, PITCH_G, PITCH_B, PITCH_G, PITCH_E]
		22:
			return [PITCH_FS, PITCH_A, PITCH_B, PITCH_A, PITCH_FS]
		23:
			return [PITCH_G, PITCH_B, PITCH_E, PITCH_B, PITCH_G]
		24:
			return [PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A]
		25:
			return [PITCH_E, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		26:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E]
		27:
			return [PITCH_B, PITCH_A, PITCH_G, PITCH_FS, PITCH_E, PITCH_FS]
		28:
			return [PITCH_E, PITCH_G, PITCH_B, PITCH_E, PITCH_B, PITCH_G, PITCH_E]
		29:
			return [PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G]
		30:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		_:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
