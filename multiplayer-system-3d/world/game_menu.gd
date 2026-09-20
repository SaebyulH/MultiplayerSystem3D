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

# Leaderboard column layout
const LB_COLS := 9
const LB_PORTRAIT := 48.0
const LB_NAME := 240.0
const LB_NUM := 96.0

const LB_HDR_COL := Color(0.55, 0.55, 0.6)
const LB_SELF := Color(0.35, 0.65, 1.0)    # blue
const LB_TEAM := Color(0.72, 0.72, 0.74)   # grey
const LB_ENEMY := Color(0.95, 0.42, 0.42)  # red


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
	player_id = str(multiplayer.get_unique_id())
	if has_node("ID"):
		$ID.text = "ID: " + player_id

	Leaderboard.killstreak_changed.connect(_on_killstreak_changed)
	Leaderboard.scores_changed.connect(_on_scores_changed)
	Leaderboard.player_removed.connect(_on_scores_changed)
	_build_leaderboard_ui()


func _lb_cell(text: String, width: float, align: int, col: Color, font_size: int, expand: bool = false, clip: bool = false, tooltip: String = "") -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(width, 0)
	lbl.horizontal_alignment = align
	if expand:
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", font_size)
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
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.texture = portrait
	return rect


func _lb_header_grid() -> GridContainer:
	var grid: GridContainer = GridContainer.new()
	grid.columns = LB_COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	grid.add_child(_lb_cell("", LB_PORTRAIT, HORIZONTAL_ALIGNMENT_CENTER, LB_HDR_COL, 15))
	grid.add_child(_lb_cell("PLAYER", LB_NAME, HORIZONTAL_ALIGNMENT_LEFT, LB_HDR_COL, 15, true))
	grid.add_child(_lb_cell("K", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Kills"))
	grid.add_child(_lb_cell("D", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Deaths"))
	grid.add_child(_lb_cell("Streak", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Killstreak"))
	grid.add_child(_lb_cell("DMG", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Damage Dealt"))
	grid.add_child(_lb_cell("Self DMG", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Self Damage"))
	grid.add_child(_lb_cell("Self Heal", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Heal Self"))
	grid.add_child(_lb_cell("Heal Other", LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, LB_HDR_COL, 15, false, false, "Heal Others"))
	return grid


func _lb_team_name(team: int) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return "FFA"


func _lb_team_color(team: int) -> Color:
	match team:
		Player.Team.SPI: return Color(0.95, 0.5, 0.5)
		Player.Team.SCI: return Color(0.5, 0.7, 1.0)
		_: return Color(0.7, 0.7, 0.7)


func _lb_team_header(team: int) -> Label:
	var lbl: Label = Label.new()
	lbl.text = _lb_team_name(team)
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", _lb_team_color(team))
	return lbl


func _lb_row_color(is_self: bool, team: int, self_team: int) -> Color:
	if is_self:
		return LB_SELF
	if self_team == Player.Team.FFA or team != self_team:
		return LB_ENEMY
	return LB_TEAM


func _lb_add_row(grid: GridContainer, player_name: String, self_team: int) -> void:
	var is_self: bool = player_name == player_id
	var pnode: Player = GameManager.find_player(player_name)
	var team: int = pnode.team if pnode else Player.Team.FFA
	var col: Color = _lb_row_color(is_self, team, self_team)

	var portrait: Texture2D = null
	if pnode and pnode._character:
		portrait = pnode._character.portrait

	grid.add_child(_lb_portrait(portrait))
	grid.add_child(_lb_cell(str(player_name), LB_NAME, HORIZONTAL_ALIGNMENT_LEFT, col, 16, true, true))
	grid.add_child(_lb_cell(str(Leaderboard.get_kills(player_name)), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))
	grid.add_child(_lb_cell(str(Leaderboard.get_deaths(player_name)), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))
	grid.add_child(_lb_cell(str(Leaderboard.get_killstreak(player_name)), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))
	grid.add_child(_lb_cell(str(int(abs(Leaderboard.get_damage(player_name)))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))
	grid.add_child(_lb_cell(str(int(abs(Leaderboard.get_self_damage(player_name)))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))
	grid.add_child(_lb_cell(str(int(Leaderboard.get_self_heal(player_name))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))
	grid.add_child(_lb_cell(str(int(Leaderboard.get_heal_others(player_name))), LB_NUM, HORIZONTAL_ALIGNMENT_RIGHT, col, 16))


func _lb_team_grid(players: Array, self_team: int) -> GridContainer:
	var grid: GridContainer = GridContainer.new()
	grid.columns = LB_COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	for p in players:
		_lb_add_row(grid, p, self_team)
	return grid


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
	dim.color = Color(0.0, 0.02, 0.06, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lb_canvas.add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lb_canvas.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(1080, 600)
	var pstyle: StyleBoxFlat = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.05, 0.05, 0.08, 0.94)
	pstyle.set_border_width_all(2)
	pstyle.border_color = Color(0.3, 0.3, 0.4, 0.8)
	pstyle.content_margin_left = 20.0
	pstyle.content_margin_top = 14.0
	pstyle.content_margin_right = 20.0
	pstyle.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", pstyle)
	center.add_child(panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title: Label = Label.new()
	title.text = "LEADERBOARD  (hold Tab)"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(title)

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
		child.queue_free()

	_lb_rows.add_child(_lb_header_grid())

	var self_team: int = _get_self_team()
	var teams := {Player.Team.SPI: [], Player.Team.SCI: [], Player.Team.FFA: []}
	for p in Leaderboard.get_players():
		var t: int = _get_team(p)
		teams[t].append(p)

	var my_streak: int = 0
	for team in [Player.Team.SPI, Player.Team.SCI, Player.Team.FFA]:
		var players: Array = teams[team]
		if players.is_empty():
			continue
		players.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
		_lb_rows.add_child(_lb_team_header(team))
		_lb_rows.add_child(_lb_team_grid(players, self_team))
		for p in players:
			if p == player_id:
				my_streak = Leaderboard.get_killstreak(p)

	if has_node("Killstreak"):
		$Killstreak.text = "%d kills" % my_streak if my_streak > 0 else ""


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
