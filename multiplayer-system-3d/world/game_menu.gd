extends Control

@export var base_sound: AudioStream

# When true, the 1st kill plays the ENTIRE song (streaks 1-30 back-to-back)
# instead of just the 1st-kill note. Useful for previewing the full theme
# without needing to rack up 30 real kills.
@export var test_mode: bool = true 

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


func _n(pitch: float, duration: float = 0.14) -> NoteEvent:
	return NoteEvent.new([pitch], duration, TEMPO_SCALE)

func _c(pitches: Array[float], duration: float = 0.14) -> NoteEvent:
	return NoteEvent.new(pitches, duration, TEMPO_SCALE)

func _r(duration: float = 0.14) -> NoteEvent:
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
		# MOTIF
		#
		# Core melodic cell:
		#
		#     E  G  F# D# --- E
		#     S  S  S  S     L
		#
		# It is deliberately NOT always played literally.
		# Fragments, inversions, octave displacement, and harmonic
		# transformations recur throughout the sequence.
		#
		# The overall trajectory is:
		#
		#   low/sparse
		#        ↓
		#   melodic
		#        ↓
		#   rhythmic
		#        ↓
		#   harmonically dense
		#        ↓
		#   high/violent
		#        ↓
		#   full motif / climax
		# ================================================================


		# ================================================================
		# ACT I — SHADOWS
		# Very sparse. The motif is barely recognizable.
		# ================================================================

		# 1 — Just the opening E.
		1: return [
			_n(PITCH_E / 2.0, 0.18),
			_r(0.08),
			_n(PITCH_B / 2.0, 0.35),
		]

		# 2 — First fragment: E -> G, then a long B.
		2: return [
			_n(PITCH_E, 0.08),
			_n(PITCH_G, 0.08),
			_n(PITCH_B, 0.32),
		]

		# 3 — Chromatic approach to the motif's F#.
		3: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_FS, 0.07),
			_n(PITCH_G, 0.16),
			_n(PITCH_FS, 0.30),
		]

		# 4 — Motif fragment, interrupted before resolution.
		4: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_G, 0.07),
			_n(PITCH_FS, 0.07),
			_r(0.08),
			_n(PITCH_DS, 0.32),
		]

		# 5 — FULL MOTIF, first appearance.
		# Quiet, low, and relatively simple.
		5: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_G, 0.07),
			_n(PITCH_FS, 0.07),
			_n(PITCH_DS, 0.10),
			_n(PITCH_E, 0.42),
		]


		# ================================================================
		# ACT II — THE MOTIF STARTS MOVING
		# More rhythmic variation and harmonic implication.
		# ================================================================

		# 6 — G-F#-E fragment, then leaps upward.
		6: return [
			_n(PITCH_G, 0.09),
			_n(PITCH_FS, 0.07),
			_n(PITCH_E, 0.13),
			_r(0.07),
			_n(PITCH_B, 0.30),
		]

		# 7 — Motif disguised as an arpeggiated shape.
		7: return [
			_n(PITCH_E, 0.06),
			_n(PITCH_G, 0.06),
			_n(PITCH_B, 0.18),
			_n(PITCH_FS, 0.08),
			_n(PITCH_DS, 0.08),
			_n(PITCH_E2, 0.32),
		]

		# 8 — Short-short-LONG rhythmic idea.
		# The long note moves upward rather than resolving downward.
		8: return [
			_n(PITCH_G, 0.06),
			_n(PITCH_A, 0.06),
			_n(PITCH_B, 0.30),
			_r(0.07),
			_n(PITCH_DS * 2.0, 0.09),
			_n(PITCH_E2, 0.34),
		]

		# 9 — Increasing tension through repetition.
		9: return [
			_n(PITCH_E, 0.06),
			_n(PITCH_G, 0.06),
			_n(PITCH_FS, 0.06),
			_n(PITCH_DS, 0.18),
			_n(PITCH_FS, 0.07),
			_n(PITCH_G, 0.07),
			_n(PITCH_B, 0.34),
		]

		# 10 — FULL MOTIF + dominant tension.
		# The motif is now harmonized instead of merely stated.
		10: return [
			_n(PITCH_E, 0.06),
			_n(PITCH_G, 0.06),
			_n(PITCH_FS, 0.06),
			_n(PITCH_DS, 0.08),
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_A * 2.0], 0.22),
			_n(PITCH_B * 2.0, 0.10),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.55),
		]


		# ================================================================
		# ACT III — DISCOVERY / MOMENTUM
		# Higher register, more syncopation, motif fragments become
		# increasingly obvious.
		# ================================================================

		# 11 — Motif starts on G instead of E.
		11: return [
			_n(PITCH_G, 0.06),
			_n(PITCH_FS, 0.06),
			_n(PITCH_DS, 0.06),
			_n(PITCH_E, 0.18),
			_n(PITCH_G, 0.08),
			_n(PITCH_B, 0.30),
		]

		# 12 — Ascending sequence with a displaced long note.
		12: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_FS, 0.07),
			_n(PITCH_G, 0.18),
			_n(PITCH_B, 0.07),
			_n(PITCH_A, 0.07),
			_n(PITCH_B, 0.34),
		]

		# 13 — Motif fragment hidden inside a larger contour.
		13: return [
			_n(PITCH_B, 0.06),
			_n(PITCH_DS * 2.0, 0.06),
			_n(PITCH_E2, 0.18),
			_r(0.06),
			_n(PITCH_FS * 2.0, 0.07),
			_n(PITCH_G * 2.0, 0.07),
			_n(PITCH_B * 2.0, 0.35),
		]

		# 14 — Rising broken figure, with D# acting as tension.
		14: return [
			_n(PITCH_E, 0.06),
			_n(PITCH_G, 0.06),
			_n(PITCH_B, 0.12),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.07),
			_n(PITCH_G * 2.0, 0.34),
		]

		# 15 — FULL MOTIF, now high and harmonically expanded.
		# EmMaj9.
		15: return [
			_n(PITCH_E2, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.06),
			_n(PITCH_DS * 2.0, 0.08),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.65),
		]


		# ================================================================
		# ACT IV — FIREFIGHT
		# The motif is now being fragmented rhythmically.
		# Wider leaps, faster notes, higher register.
		# ================================================================

		# 16 — Three-note motif fragment, repeated at a higher level.
		16: return [
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_FS * 2.0, 0.15),
			_n(PITCH_B * 2.0, 0.05),
			_n(PITCH_DS * 2.0, 0.05),
			_n(PITCH_E2 * 2.0, 0.30),
		]

		# 17 — Wide leap followed by compressed motif.
		17: return [
			_n(PITCH_E, 0.07),
			_n(PITCH_B, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.07),
			_n(PITCH_G * 2.0, 0.07),
			_n(PITCH_B * 2.0, 0.34),
		]

		# 18 — Rising minor-11 color, but not as a constant chord.
		18: return [
			_n(PITCH_E, 0.06),
			_n(PITCH_G, 0.06),
			_n(PITCH_B, 0.06),
			_n(PITCH_D * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.08),
			_n(PITCH_A * 2.0, 0.32),
		]

		# 19 — Rapid motif fragment interrupted by a high D#.
		19: return [
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_FS * 2.0, 0.05),
			_n(PITCH_DS * 2.0, 0.05),
			_r(0.05),
			_n(PITCH_FS * 2.0, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_B * 2.0, 0.36),
		]

		# 20 — FULL MOTIF over iiø-V7-i.
		# Much more overtly cinematic.
		20: return [
			_c([PITCH_FS, PITCH_A, PITCH_C * 2.0, PITCH_E2], 0.16),
			_n(PITCH_E2, 0.06),
			_n(PITCH_G * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.06),
			_n(PITCH_DS * 2.0, 0.08),
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_FS * 2.0, PITCH_A * 2.0], 0.20),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.7),
		]


		# ================================================================
		# ACT V — CLIMAX
		# Very high register, aggressive rhythm, wider harmonic structures.
		# ================================================================

		# 21 — Motif chopped into very short attacks.
		21: return [
			_n(PITCH_E2, 0.045),
			_n(PITCH_G * 2.0, 0.045),
			_n(PITCH_FS * 2.0, 0.045),
			_n(PITCH_DS * 2.0, 0.045),
			_n(PITCH_FS * 2.0, 0.07),
			_n(PITCH_G * 2.0, 0.07),
			_n(PITCH_B * 2.0, 0.32),
		]

		# 22 — Wider melodic jumps.
		22: return [
			_n(PITCH_B, 0.06),
			_n(PITCH_DS * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.06),
			_n(PITCH_A * 2.0, 0.06),
			_n(PITCH_B * 2.0, 0.08),
			_n(PITCH_DS * 2.0, 0.08),
			_n(PITCH_FS * 2.0, 0.34),
		]

		# 23 — Ascending broken Em9.
		23: return [
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_B * 2.0, 0.05),
			_n(PITCH_DS * 2.0, 0.05),
			_n(PITCH_FS * 2.0, 0.10),
			_n(PITCH_B * 2.0, 0.10),
			_n(PITCH_E2 * 2.0, 0.35),
		]

		# 24 — Dominant pressure, then upward release.
		24: return [
			_n(PITCH_B, 0.05),
			_n(PITCH_DS * 2.0, 0.05),
			_n(PITCH_A * 2.0, 0.05),
			_r(0.05),
			_n(PITCH_B * 2.0, 0.07),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_FS * 2.0, 0.07),
			_n(PITCH_E2 * 2.0, 0.38),
		]

		# 25 — FULL MOTIF, huge.
		# This is the first point where the motif is almost a fanfare.
		25: return [
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_FS * 2.0, 0.05),
			_n(PITCH_DS * 2.0, 0.06),
			_n(PITCH_E2 * 2.0, 0.12),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0,
				PITCH_B * 2.0
			], 0.85),
		]

		# 26 — Motif fragmented into ascending triplet-like bursts.
		26: return [
			_n(PITCH_E2, 0.045),
			_n(PITCH_G * 2.0, 0.045),
			_n(PITCH_B * 2.0, 0.045),
			_n(PITCH_DS * 2.0, 0.045),
			_n(PITCH_FS * 2.0, 0.045),
			_n(PITCH_G * 2.0, 0.045),
			_n(PITCH_B * 2.0, 0.30),
		]

		# 27 — Very wide ascending contour.
		27: return [
			_n(PITCH_E, 0.05),
			_n(PITCH_B, 0.05),
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_B * 2.0, 0.06),
			_n(PITCH_DS * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.34),
		]

		# 28 — RETAINED CORE IDEA.
		# Ascending harmonic blocks. This now represents the culmination
		# of the harmonic progression established throughout the sequence.
		28: return [
			_c([PITCH_E, PITCH_G, PITCH_B], 0.09),
			_c([PITCH_FS, PITCH_A, PITCH_C * 2.0], 0.09),
			_c([PITCH_G, PITCH_B, PITCH_DS * 2.0], 0.09),
			_c([PITCH_A, PITCH_C * 2.0, PITCH_E2], 0.10),
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_FS * 2.0, PITCH_A * 2.0], 0.13),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.70),
		]

		# 29 — RETAINED CORE IDEA.
		# Dominant roar. The motif is implied by B -> D# -> F# -> E.
		29: return [
			_c([PITCH_B, PITCH_DS * 2.0, PITCH_A * 2.0], 0.22),
			_n(PITCH_B * 2.0, 0.06),
			_n(PITCH_DS * 2.0, 0.06),
			_n(PITCH_FS * 2.0, 0.08),
			_c([
				PITCH_E2,
				PITCH_G * 2.0,
				PITCH_B * 2.0,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0
			], 0.90),
		]

		# 30 — FINAL MOTIF.
		# The entire identity of the killstreak finally appears at full
		# register and maximum harmonic weight.
		30: return [
			_n(PITCH_E2, 0.05),
			_n(PITCH_G * 2.0, 0.05),
			_n(PITCH_FS * 2.0, 0.05),
			_n(PITCH_DS * 2.0, 0.07),
			_n(PITCH_E2 * 2.0, 0.12),
			_c([
				PITCH_E,
				PITCH_G,
				PITCH_B,
				PITCH_DS * 2.0,
				PITCH_FS * 2.0,
				PITCH_B * 2.0,
				PITCH_E2 * 2.0
			], 1.8),
		]

		_: return [
			_n(PITCH_E, 0.08),
			_n(PITCH_G, 0.08),
			_n(PITCH_FS, 0.08),
			_n(PITCH_E2, 0.30),
		]
