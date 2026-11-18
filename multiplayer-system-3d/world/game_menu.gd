extends Control

@export var base_sound: AudioStream

# When true, the 1st kill plays the ENTIRE song (streaks 1-30 back-to-back)
# instead of just the 1st-kill note. Useful for previewing the full theme
# without needing to rack up 30 real kills.
@export var test_mode: bool = false 

var player_id: String
var play_token: int = 0

# -- Leaderboard overlay --
var _lb_canvas: CanvasLayer = null
var _lb_rows: VBoxContainer = null
## player name -> ping label, so a new ping snapshot updates text in place
## instead of rebuilding the table (which would reset the scroll position).
var _lb_ping_labels: Dictionary = {}

# Pitch constants (E-based semitone scaling)
const PITCH_E   := pow(2.0, 0.0 / 12.0)
const PITCH_F   := pow(2.0, 1.0 / 12.0)
const PITCH_FS  := pow(2.0, 2.0 / 12.0)
const PITCH_G   := pow(2.0, 3.0 / 12.0)
const PITCH_GS  := pow(2.0, 4.0 / 12.0)
const PITCH_A   := pow(2.0, 5.0 / 12.0)
const PITCH_AS  := pow(2.0, 6.0 / 12.0)
const PITCH_B   := pow(2.0, 7.0 / 12.0)
const PITCH_C   := pow(2.0, 8.0 / 12.0)
const PITCH_CS  := pow(2.0, 9.0 / 12.0)
const PITCH_D   := pow(2.0, 10.0 / 12.0)
const PITCH_DS  := pow(2.0, 11.0 / 12.0)
const PITCH_E2  := pow(2.0, 12.0 / 12.0)

# Global tempo multiplier applied to every note/chord/rest duration below.
# 1.0 == the raw numbers written in _get_pitch_sequence(); raise this to
# slow the whole theme down uniformly, lower it to speed it up.
# 1.3 puts the fastest early notes (0.1s apart) at ~130ms, matching the
# reference tab's feel.
const TEMPO_SCALE := 1.3

# Leaderboard column layout.  Rows are HBox panels, not one shared grid, so
# fixed widths keep columns aligned across sections while still allowing a
# per-row background and accent strip.
const LB_PORTRAIT := 40.0
const LB_NAME := 200.0
const LB_NUM := 66.0
const LB_PING := 60.0

const LB_HDR_COL := Color(0.541, 0.58, 0.639)   # muted
const LB_SELF := Color(1, 0.76, 0.29)          # amber: you
const LB_TEAM := Color(0.929, 0.945, 0.961)    # text
const LB_ENEMY := Color(1, 0.275, 0.333)       # red


# A single "note" in a killstreak sting: one or more simultaneous pitches
# (a chord when more than one), played for `duration` seconds. An empty
# `pitches` array is a rest (spacing with no sound). Duration is scaled by
# TEMPO_SCALE automatically.
class NoteEvent:
	var pitches: Array[float]
	var duration: float

	func _init(p: Array[float], d: float, scale: float) -> void:
		pitches = p
		duration = d * scale


# A single note. Duration controls how long this event lasts before the
# next event is triggered.
func _n(pitch: float, duration: float = 0.14) -> NoteEvent:
	return NoteEvent.new([pitch], duration, TEMPO_SCALE)

func _c(pitches: Array[float], duration: float = 0.14) -> NoteEvent:
	return NoteEvent.new(pitches, duration, TEMPO_SCALE)

# Explicit silence. Unlike simply making a note short, this gives the
# phrase a deliberate rhythmic gap.
func _r(duration: float = 0.10) -> NoteEvent:
	return NoteEvent.new([], duration, TEMPO_SCALE)

# Alias for readability when designing rhythmic phrases.
# _p() means "pause", whereas _r() can still be used anywhere you already
# have it.
func _p(duration: float = 0.10) -> NoteEvent:
	return NoteEvent.new([], duration, TEMPO_SCALE)

# Concatenates two typed NoteEvent arrays. Plain "+" between typed arrays
# can hand back an untyped Array in GDScript, which then fails to assign
# into an Array[NoteEvent]-typed variable or return slot - so every
# sequence-building spot below goes through this instead.
func _join(a: Array[NoteEvent], b: Array[NoteEvent]) -> Array[NoteEvent]:
	var result: Array[NoteEvent] = a.duplicate()
	result.append_array(b)
	return result

# Classic "spy" chromatic line cliché: a held pedal tone under an inner
# voice that steps through the 5th, flat-6th, and natural-6th degrees
# above it (e.g. E pedal under B-C-C#-C-B) - the specific half-step
# movement that gives Bond-style themes their sneaky, suspended quality.
func _line_cliche(pedal: float, deg5: float, b6: float, nat6: float, note_dur: float = 0.09, tail_dur: float = 0.2) -> Array[NoteEvent]:
	return [
		_n(pedal, note_dur), _n(deg5, note_dur), _n(b6, note_dur),
		_n(nat6, note_dur), _n(b6, note_dur), _n(deg5, note_dur), _n(pedal, tail_dur),
	]

# Shifts a pitch ratio up one octave - used for wider chord voicings
# (e.g. topping the spy chord with a high 9th) without needing a whole
# extra set of octave-specific constants.
func _up(pitch: float) -> float:
	return pitch * 2.0


func _ready() -> void:
	player_id = MatchSession.local_id_string()
	if has_node("ID"):
		$ID.text = "ID: " + player_id

	Leaderboard.killstreak_changed.connect(_on_killstreak_changed)
	Leaderboard.scores_changed.connect(_on_scores_changed)
	Leaderboard.player_removed.connect(_on_scores_changed)
	# Entering/leaving spectator mode moves a row between sections without a
	# score change.
	Leaderboard.roster_changed.connect(_on_scores_changed)
	MatchSession.pings_changed.connect(_refresh_ping_labels)
	_build_leaderboard_ui()


func _lb_cell(text: String, width: float, align: int, col: Color, font_size: int, expand: bool = false, clip: bool = false, tooltip: String = "") -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(width, 0)
	lbl.horizontal_alignment = align
	if expand:
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	lbl.add_theme_color_override("font_color", col)
	if clip:
		lbl.clip_text = true
		lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if not tooltip.is_empty():
		lbl.tooltip_text = tooltip
	return lbl


func _lb_portrait(portrait: Texture2D) -> TextureRect:
	var rect: TextureRect = TextureRect.new()
	rect.custom_minimum_size = Vector2(LB_PORTRAIT, LB_PORTRAIT)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.texture = portrait
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _lb_spacer(width: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(width, 1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## One shared header row.  Same widths as the player rows so the columns line
## up across SPI / SCI / FFA without a GridContainer coupling them.
func _lb_header_row() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.flat_style(Color(UITheme.SLATE.r, UITheme.SLATE.g, UITheme.SLATE.b, 0.9), 0, 4.0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	row.add_child(_lb_spacer(3.0))
	row.add_child(_lb_spacer(LB_PORTRAIT))
	row.add_child(_lb_cell("PLAYER", LB_NAME, HORIZONTAL_ALIGNMENT_LEFT, LB_HDR_COL, 11, true))
	for entry in [
		["K", "Kills"], ["D", "Deaths"], ["STREAK", "Killstreak"],
		["DMG", "Damage Dealt"], ["SELF DMG", "Self Damage"],
		["SELF HEAL", "Heal Self"], ["HEAL OTHER", "Heal Others"],
	]:
		row.add_child(_lb_cell(entry[0], LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT,
			LB_HDR_COL, 11, false, false, entry[1]))
	row.add_child(_lb_cell("PING", LB_PING, HORIZONTAL_ALIGNMENT_RIGHT,
		LB_HDR_COL, 11, false, false, "Round-trip time in ms"))
	return panel


func _lb_team_name(team: int) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return "FFA"


func _lb_team_color(team: int) -> Color:
	match team:
		Player.Team.SPI: return Color(1, 0.275, 0.333)
		Player.Team.SCI: return Color(0.176, 0.831, 0.749)
		_: return Color(1, 0.76, 0.29)


## Section band: tinted slate with a 3 px accent strip on the left.
func _lb_section_header(text: String, color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := UITheme.flat_style(
		Color(UITheme.SLATE.r, UITheme.SLATE.g, UITheme.SLATE.b, 0.55), 0, 0.0)
	style.content_margin_left = 10.0
	style.content_margin_top = 5.0
	style.content_margin_right = 10.0
	style.content_margin_bottom = 5.0
	style.border_color = color
	style.border_width_left = 3
	panel.add_theme_stylebox_override("panel", style)
	var lbl := UITheme.section_label(text, color)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.custom_minimum_size = Vector2(0, 22)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(lbl)
	return panel


func _lb_team_header(team: int) -> Control:
	return _lb_section_header(_lb_team_name(team), _lb_team_color(team))


func _lb_disconnected_header() -> Control:
	return _lb_section_header("DISCONNECTED PLAYERS", LB_HDR_COL)


func _lb_spectator_header() -> Control:
	return _lb_section_header("SPECTATORS", LB_HDR_COL)


func _lb_row_color(is_self: bool, team: int, self_team: int) -> Color:
	if is_self:
		return LB_SELF
	if self_team == Player.Team.FFA or team != self_team:
		return LB_ENEMY
	return LB_TEAM


func _lb_add_row(parent: VBoxContainer, player_name: String, self_team: int) -> void:
	var is_self: bool = player_name == player_id
	var pnode: Player = GameManager.find_player(player_name)
	var team: int = pnode.team if pnode else Player.Team.FFA
	var accent: Color = _lb_team_color(team)
	var col: Color = _lb_row_color(is_self, team, self_team)

	var panel := PanelContainer.new()
	var style := UITheme.card_style(UITheme.State.NORMAL)
	style.bg_color = Color(UITheme.SLATE.r, UITheme.SLATE.g, UITheme.SLATE.b, 0.42)
	style.border_color = Color(accent.r, accent.g, accent.b, 0.35)
	if is_self:
		style.bg_color = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.10)
		style.border_color = UITheme.AMBER
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var strip := ColorRect.new()
	strip.color = accent
	strip.custom_minimum_size = Vector2(3, 0)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(strip)

	var char_res := UITheme.player_character(pnode)
	row.add_child(_lb_portrait(char_res.portrait if char_res else null))

	row.add_child(_lb_cell(str(player_name), LB_NAME, HORIZONTAL_ALIGNMENT_LEFT, col, 14, true, true))
	row.add_child(_lb_cell(str(Leaderboard.get_kills(player_name)), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))
	row.add_child(_lb_cell(str(Leaderboard.get_deaths(player_name)), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))
	row.add_child(_lb_cell(str(Leaderboard.get_killstreak(player_name)), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))
	row.add_child(_lb_cell(str(int(abs(Leaderboard.get_damage(player_name)))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))
	row.add_child(_lb_cell(str(int(abs(Leaderboard.get_self_damage(player_name)))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))
	row.add_child(_lb_cell(str(int(Leaderboard.get_self_heal(player_name))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))
	row.add_child(_lb_cell(str(int(Leaderboard.get_heal_others(player_name))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 14))

	var ping := _lb_cell("", LB_PING, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 14)
	_lb_ping_labels[player_name] = ping
	_update_ping_label(ping, player_name, pnode)
	row.add_child(ping)


func _update_ping_label(label: Label, player_name: String, pnode: Player) -> void:
	if pnode != null and pnode.is_bot:
		label.text = "BOT"
		label.add_theme_color_override("font_color", LB_HDR_COL)
		return
	var ms := MatchSession.ping_ms_for(player_name)
	if ms < 0:
		label.text = "—"
		label.add_theme_color_override("font_color", Color(0.361, 0.396, 0.447))
		return
	label.text = str(ms)
	label.add_theme_color_override("font_color",
		UITheme.TEAL if ms <= 40 else (UITheme.AMBER if ms <= 90 else UITheme.RED))


## A ping snapshot arrived: rewrite the visible ping cells in place so the
## table does not rebuild (and the scroll position does not jump).
func _refresh_ping_labels() -> void:
	for player_name in _lb_ping_labels:
		var label: Label = _lb_ping_labels[player_name]
		if is_instance_valid(label):
			_update_ping_label(label, str(player_name), GameManager.find_player(str(player_name)))


func _lb_team_grid(players: Array, self_team: int) -> VBoxContainer:
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	for p in players:
		_lb_add_row(list, p, self_team)
	return list


func _get_team(player_name: String) -> int:
	var pnode: Player = GameManager.find_player(player_name)
	if pnode:
		return pnode.team
	return Player.Team.FFA


func _get_self_team() -> int:
	return _get_team(player_id)


func _build_leaderboard_ui() -> void:
	_lb_canvas = CanvasLayer.new()
	_lb_canvas.layer = 5
	_lb_canvas.visible = false
	_lb_canvas.name = "LeaderboardCanvas"
	get_tree().root.add_child(_lb_canvas)

	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.045, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lb_canvas.add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lb_canvas.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(1080, 600)
	var pstyle: StyleBoxFlat = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.067, 0.086, 0.114, 0.96)
	pstyle.set_border_width_all(1)
	pstyle.border_color = Color(0.165, 0.196, 0.239, 1)
	pstyle.content_margin_left = 22.0
	pstyle.content_margin_top = 16.0
	pstyle.content_margin_right = 22.0
	pstyle.content_margin_bottom = 16.0
	panel.add_theme_stylebox_override("panel", pstyle)
	center.add_child(panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title: Label = Label.new()
	title.text = "LEADERBOARD  //  HOLD TAB"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.add_theme_font_override("font", UITheme.FONT_DISPLAY)
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.929, 0.945, 0.961))
	vbox.add_child(title)
	vbox.add_child(UITheme.accent_bar(UITheme.RED, 2))

	vbox.add_child(HSeparator.new())

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_lb_rows = VBoxContainer.new()
	_lb_rows.add_theme_constant_override("separation", 6)
	_lb_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_lb_rows)


func _on_scores_changed(_player_name = null) -> void:
	_rebuild_leaderboard()


func _rebuild_leaderboard() -> void:
	if not _lb_canvas or not _lb_canvas.visible:
		return
	if Leaderboard == null:
		return

	for child in _lb_rows.get_children():
		_lb_rows.remove_child(child)
		child.queue_free()
	_lb_ping_labels.clear()

	_lb_rows.add_child(_lb_header_row())

	var self_team: int = _get_self_team()
	var teams := {Player.Team.SPI: [], Player.Team.SCI: [], Player.Team.FFA: []}
	var spectators: Array = []
	for p in Leaderboard.get_players():
		var pnode: Player = GameManager.find_player(p)
		# Spectators keep their stats but are listed in their own section, not
		# under their team.
		if pnode != null and pnode.is_spectating:
			spectators.append(p)
			continue
		var t: int = _get_team(p)
		teams[t].append(p)

	for team in [Player.Team.SPI, Player.Team.SCI, Player.Team.FFA]:
		var players: Array = teams[team]
		if players.is_empty():
			continue
		players.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
		_lb_rows.add_child(_lb_team_header(team))
		_lb_rows.add_child(_lb_team_grid(players, self_team))

	if not spectators.is_empty():
		spectators.sort_custom(func(a, b): return str(a) < str(b))
		_lb_rows.add_child(_lb_spectator_header())
		_lb_rows.add_child(_lb_team_grid(spectators, self_team))

	var disconnected := Leaderboard.get_disconnected_players()
	if not disconnected.is_empty():
		disconnected.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
		_lb_rows.add_child(_lb_disconnected_header())
		_lb_rows.add_child(_lb_team_grid(disconnected, self_team))


func show_leaderboard() -> void:
	if _lb_canvas:
		_lb_canvas.visible = true
		_rebuild_leaderboard()

func hide_leaderboard() -> void:
	if _lb_canvas:
		_lb_canvas.visible = false


func _on_killstreak_changed(player_name: String, killstreak: int) -> void:
	if player_name != player_id:
		return

	play_token += 1
	var token: int = play_token
	var seq: Array[NoteEvent]
	if test_mode and killstreak == 1:
		seq = _get_full_song_sequence()
	else:
		seq = _get_pitch_sequence(killstreak)
	_play_sequence_async(seq, token)

# Concatenates every killstreak's sequence (1 through 30) into one long
# sequence, so test_mode can play the whole theme in order on the 1st kill.
func _get_full_song_sequence() -> Array[NoteEvent]:
	var full: Array[NoteEvent] = []
	for ks in range(1, 31):
		full.append_array(_get_pitch_sequence(ks))
	return full

func _play_sequence_async(seq: Array[NoteEvent], token: int) -> void:
	for event in seq:
		if token != play_token:
			return
		if not is_inside_tree():
			return
		for pitch in event.pitches:
			var p: AudioStreamPlayer = AudioStreamPlayer.new()
			p.stream = base_sound
			p.pitch_scale = pitch
			add_child(p)
			p.play()
			p.finished.connect(func(): p.queue_free())
		await get_tree().create_timer(event.duration).timeout
	if token == play_token:
		if not is_inside_tree():
			return
		await get_tree().create_timer(0.3).timeout

# ============================================================
# SPY KILLSTREAK THEME – Full 30-kill progression
# ============================================================
# Inspired by: James Bond, Kingsman, Mission: Impossible,
#              The Incredibles, Team Fortress 2.
# Key: E minor (with Dorian, melodic minor, and chromatic twists)
# Spy chord: E min-maj9 (E–G–B–D#–F#)
# Ostinato: driving 5/4 or 4/4 with half‑step tension
# ============================================================
func _get_pitch_sequence(ks: int) -> Array[NoteEvent]:
	match ks:
		# ================================================================
		# ACT I — SHADOWS
		# Deliberate, spacious rhythm.
		# ================================================================

		# 1 — LONG ... short ... LONG
		1: return [
			_n(PITCH_E / 2.0, 0.28),
			_p(0.10),
			_n(PITCH_B / 2.0, 0.38),
		]

		# 2 — SHORT SHORT — LONG
		2: return [
			_n(PITCH_E, 0.09),
			_n(PITCH_G, 0.09),
			_p(0.05),
			_n(PITCH_B, 0.32),
		]

		# 3 — Three quick notes, then a deliberate arrival.
		3: return [
			_n(PITCH_E, 0.08),
			_n(PITCH_FS, 0.08),
			_n(PITCH_G, 0.13),
			_p(0.08),
			_n(PITCH_FS, 0.34),
		]

		# 4 — Motif fragment with a real breath.
		4: return [
			_n(PITCH_E, 0.09),
			_n(PITCH_G, 0.09),
			_n(PITCH_FS, 0.14),
			_p(0.10),
			_n(PITCH_DS, 0.34),
		]

		# 5 — FULL MOTIF
		# SHORT SHORT / MEDIUM SHORT / LONG
		5: return [
			_n(PITCH_E, 0.09),
			_n(PITCH_G, 0.09),
			_p(0.04),
			_n(PITCH_FS, 0.12),
			_n(PITCH_DS, 0.10),
			_p(0.08),
			_n(PITCH_E, 0.48),
		]


		# ================================================================
		# ACT II
		# More syncopation, but still readable.
		# ================================================================

		# 6 — LONG SHORT SHORT — LONG
		6: return [
			_n(PITCH_G, 0.22),
			_n(PITCH_FS, 0.08),
			_n(PITCH_E, 0.08),
			_p(0.07),
			_n(PITCH_B, 0.34),
		]

		# 7 — Broken motif with asymmetric rhythm.
		7: return [
			_n(PITCH_E, 0.08),
			_n(PITCH_G, 0.14),
			_n(PITCH_B, 0.08),
			_p(0.06),
			_n(PITCH_FS, 0.10),
			_n(PITCH_DS, 0.10),
			_n(PITCH_E2, 0.36),
		]

		# 8 — SHORT SHORT — LONG / SHORT — LONG
		8: return [
			_n(PITCH_G, 0.07),
			_n(PITCH_A, 0.07),
			_n(PITCH_B, 0.28),
			_p(0.08),
			_n(PITCH_DS * 2.0, 0.09),
			_n(PITCH_E2, 0.36),
		]

		# 9 — Repeated motif fragment, but with staggered accents.
		9: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_G, 0.11),
			_n(PITCH_FS, 0.07),
			_p(0.05),
			_n(PITCH_DS, 0.20),
			_n(PITCH_FS, 0.08),
			_n(PITCH_G, 0.08),
			_p(0.06),
			_n(PITCH_B, 0.36),
		]

		# 10 — FULL MOTIF + dominant.
		10: return [
			_n(PITCH_E, 0.08),
			_n(PITCH_G, 0.08),
			_n(PITCH_FS, 0.11),
			_n(PITCH_DS, 0.10),
			_p(0.08),
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_A * 2.0], 0.26),
			_p(0.06),
			_n(PITCH_B * 2.0, 0.12),
			_n(PITCH_DS * 2.0, 0.10),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.60),
		]


		# ================================================================
		# ACT III
		# Rhythmic identity becomes more pronounced.
		# ================================================================

		11: return [
			_n(PITCH_G, 0.08),
			_n(PITCH_FS, 0.08),
			_p(0.04),
			_n(PITCH_DS, 0.14),
			_n(PITCH_E, 0.22),
			_p(0.06),
			_n(PITCH_G, 0.08),
			_n(PITCH_B, 0.34),
		]

		12: return [
			_n(PITCH_E, 0.09),
			_n(PITCH_FS, 0.09),
			_n(PITCH_G, 0.20),
			_p(0.06),
			_n(PITCH_B, 0.08),
			_n(PITCH_A, 0.08),
			_n(PITCH_B, 0.36),
		]

		13: return [
			_n(PITCH_B, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_E2, 0.20),
			_p(0.08),
			_n(PITCH_FS * 2.0, 0.08),
			_n(PITCH_G * 2.0, 0.12),
			_n(PITCH_B * 2.0, 0.38),
		]

		14: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_G, 0.07),
			_n(PITCH_B, 0.15),
			_p(0.05),
			_n(PITCH_DS * 2.0, 0.08),
			_n(PITCH_FS * 2.0, 0.08),
			_n(PITCH_G * 2.0, 0.38),
		]

		# 15 — FULL MOTIF
		# A more deliberate rhythm rather than five equally weighted notes.
		15: return [
			_n(PITCH_E2, 0.10),
			_n(PITCH_G * 2.0, 0.10),
			_p(0.04),
			_n(PITCH_FS * 2.0, 0.13),
			_n(PITCH_DS * 2.0, 0.10),
			_p(0.09),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.72),
		]


		# ================================================================
		# ACT IV
		# Faster internal rhythm, but with stronger rests.
		# ================================================================

		16: return [
			_n(PITCH_E2, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.16),
			_p(0.05),
			_n(PITCH_B * 2.0, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_E2 * 2.0, 0.34),
		]

		17: return [
			_n(PITCH_E, 0.08),
			_n(PITCH_B, 0.16),
			_p(0.05),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.07),
			_n(PITCH_G * 2.0, 0.11),
			_p(0.05),
			_n(PITCH_B * 2.0, 0.38),
		]

		18: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_G, 0.07),
			_n(PITCH_B, 0.12),
			_p(0.05),
			_n(PITCH_D * 2.0, 0.08),
			_n(PITCH_FS * 2.0, 0.08),
			_n(PITCH_A * 2.0, 0.38),
		]

		19: return [
			_n(PITCH_E2, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.06),
			_n(PITCH_DS * 2.0, 0.12),
			_p(0.07),
			_n(PITCH_FS * 2.0, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_B * 2.0, 0.40),
		]

		# 20 — FULL MOTIF + iiø-V7-i.
		20: return [
			_c([PITCH_FS, PITCH_A, PITCH_C * 2.0, PITCH_E2], 0.20),
			_p(0.07),
			_n(PITCH_E2, 0.07),
			_n(PITCH_G * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.11),
			_n(PITCH_DS * 2.0, 0.10),
			_p(0.07),
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_FS * 2.0, PITCH_A * 2.0], 0.24),
			_p(0.05),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.75),
		]


		# ================================================================
		# ACT V
		# Very energetic, but rhythmic rather than simply "more notes".
		# ================================================================

		21: return [
			_n(PITCH_E2, 0.055),
			_n(PITCH_G * 2.0, 0.055),
			_n(PITCH_FS * 2.0, 0.10),
			_p(0.04),
			_n(PITCH_DS * 2.0, 0.055),
			_n(PITCH_FS * 2.0, 0.055),
			_n(PITCH_G * 2.0, 0.10),
			_n(PITCH_B * 2.0, 0.36),
		]

		22: return [
			_n(PITCH_B, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_p(0.04),
			_n(PITCH_FS * 2.0, 0.12),
			_n(PITCH_A * 2.0, 0.07),
			_n(PITCH_B * 2.0, 0.14),
			_p(0.05),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.38),
		]

		23: return [
			_n(PITCH_E2, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_B * 2.0, 0.10),
			_p(0.04),
			_n(PITCH_DS * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.10),
			_n(PITCH_B * 2.0, 0.12),
			_n(PITCH_E2 * 2.0, 0.40),
		]

		24: return [
			_n(PITCH_B, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_A * 2.0, 0.16),
			_p(0.07),
			_n(PITCH_B * 2.0, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.10),
			_p(0.04),
			_n(PITCH_E2 * 2.0, 0.42),
		]

		# 25 — FULL MOTIF / MAJOR CLIMAX.
		25: return [
			_n(PITCH_E2, 0.07),
			_n(PITCH_G * 2.0, 0.07),
			_p(0.035),
			_n(PITCH_FS * 2.0, 0.09),
			_n(PITCH_DS * 2.0, 0.08),
			_p(0.06),
			_n(PITCH_E2 * 2.0, 0.15),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0,
				PITCH_B * 2.0
			], 0.90),
		]

		26: return [
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_B * 2.0, 0.08),
			_p(0.035),
			_n(PITCH_DS * 2.0, 0.05),
			_n(PITCH_FS * 2.0, 0.05),
			_n(PITCH_G * 2.0, 0.08),
			_n(PITCH_B * 2.0, 0.12),
			_p(0.04),
			_n(PITCH_E2 * 2.0, 0.38),
		]

		27: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_B, 0.07),
			_p(0.04),
			_n(PITCH_E2, 0.08),
			_n(PITCH_G * 2.0, 0.08),
			_n(PITCH_B * 2.0, 0.11),
			_p(0.04),
			_n(PITCH_DS * 2.0, 0.08),
			_n(PITCH_FS * 2.0, 0.42),
		]

		# 28 — Ascending chord rhythm.
		# Notice that the final chord gets substantially more space.
		28: return [
			_c([PITCH_E, PITCH_G, PITCH_B], 0.11),
			_p(0.045),
			_c([PITCH_FS, PITCH_A, PITCH_C * 2.0], 0.11),
			_p(0.045),
			_c([PITCH_G, PITCH_B, PITCH_DS * 2.0], 0.12),
			_p(0.04),
			_c([PITCH_A, PITCH_C * 2.0, PITCH_E2], 0.13),
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_FS * 2.0, PITCH_A * 2.0], 0.17),
			_p(0.06),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.78),
		]

		# 29 — Dominant hit, pause, then the payoff.
		29: return [
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_A * 2.0], 0.25),
			_p(0.09),
			_n(PITCH_B * 2.0, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.11),
			_p(0.05),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.95),
		]

		# 30 — Final statement.
		# Notice the hesitation before the final chord.
		30: return [
			_n(PITCH_E2, 0.07),
			_n(PITCH_G * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.09),
			_n(PITCH_DS * 2.0, 0.08),
			_p(0.10),
			_n(PITCH_E2 * 2.0, 0.18),
			_p(0.08),
			_c([
				PITCH_E,
				PITCH_G,
				PITCH_B,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0,
				PITCH_B * 2.0,
				PITCH_E2 * 2.0
			], 2.0),
		]

		_: return [
			_n(PITCH_E, 0.10),
			_n(PITCH_G, 0.10),
			_p(0.05),
			_n(PITCH_FS, 0.12),
			_n(PITCH_E2, 0.34),
		]
