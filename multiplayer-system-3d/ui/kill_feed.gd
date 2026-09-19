extends CanvasLayer
class_name KillFeed

## Two-section TF2-style kill feed in the top-right corner.  Newest entry appears
## at the bottom and older entries are pushed up.
##
## Each entry is a single horizontal row with two tinted sections side by side:
##   [killer portrait | killer name | gun icon | HS/BS] [killee name | portrait]
##   - Killer section: red if the killer is an enemy, gray if a teammate, blue if
##     you.
##   - Killee section: the *light* variant of the killee's own relation (enemy /
##     teammate / you).
##
## Weapon icons are pre-rendered PNGs (generated once with
## weapon/killfeed_icon_generator.gd); character portraits with
## player/character_portrait_generator.gd.  No runtime SubViewport overhead.

const MAX_VISIBLE := 5
const ENTRY_LIFETIME: float = 8.0
const FADE_DURATION: float = 1.5
const SLIDE_DURATION: float = 0.25
const ENTRY_HEIGHT: float = 40.0
const ENTRY_SEPARATION: float = 3.0

# Layout
const PANEL_RIGHT: float = 16.0
const PANEL_TOP: float = 48.0
const PANEL_MAX_WIDTH: float = 500.0

# Character portrait display size (square, matches ENTRY_HEIGHT).
const PORTRAIT_SIZE: float = ENTRY_HEIGHT

const NAME_FONT_SIZE := 18
const TAG_FONT_SIZE := 15

# Section background colours, keyed by the player's relation to the local player.
const COLOR_ENEMY := Color(0.62, 0.12, 0.12)
const COLOR_ENEMY_LIGHT := Color(0.80, 0.34, 0.34)
const COLOR_TEAMMATE := Color(0.30, 0.30, 0.33)
const COLOR_TEAMMATE_LIGHT := Color(0.52, 0.52, 0.55)
const COLOR_YOU := Color(0.16, 0.40, 0.72)
const COLOR_YOU_LIGHT := Color(0.34, 0.56, 0.85)

enum Relationship { YOU, TEAMMATE, ENEMY }

var _panel: Control = null
var _vbox: VBoxContainer = null


func _ready() -> void:
	layer = 4
	name = "KillFeedCanvas"

	_panel = Control.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.name = "EntryList"
	_vbox.add_theme_constant_override("separation", ENTRY_SEPARATION)
	_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	_vbox.anchor_left = 0.0
	_vbox.anchor_right = 1.0
	_vbox.anchor_top = 0.0
	_vbox.anchor_bottom = 1.0
	_panel.add_child(_vbox)

	# Anchor top-right.
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0

	_reposition()

	# Listen for kill events from Leaderboard.
	if Leaderboard and not Leaderboard.kill_feed_entry.is_connected(_on_kill_event):
		Leaderboard.kill_feed_entry.connect(_on_kill_event)


func _reposition() -> void:
	# Resize the panel to fit entries, anchored top-right.
	var count: int = _vbox.get_child_count()
	var content_h: float = float(count * ENTRY_HEIGHT + max(0, count - 1) * ENTRY_SEPARATION)
	var total_w: float = PANEL_MAX_WIDTH

	_panel.offset_left = -(total_w + PANEL_RIGHT)
	_panel.offset_top = PANEL_TOP
	_panel.offset_right = -PANEL_RIGHT
	_panel.offset_bottom = PANEL_TOP + max(content_h, 0.0)


func _on_kill_event(killer_name: String, victim_name: String, weapon_name: String, icon_path: String, is_headshot: bool, is_backshot: bool) -> void:
	_add_entry(killer_name, victim_name, weapon_name, icon_path, is_headshot, is_backshot)


func _add_entry(killer_name: String, victim_name: String, weapon_name: String, icon_path: String, is_headshot: bool, is_backshot: bool) -> void:
	var entry := Control.new()
	entry.name = "KillEntry"
	entry.custom_minimum_size = Vector2(0.0, ENTRY_HEIGHT)
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var hbox := HBoxContainer.new()
	hbox.name = "MainHBox"
	hbox.add_theme_constant_override("separation", 0)
	hbox.anchor_left = 0.0
	hbox.anchor_right = 1.0
	hbox.anchor_top = 0.0
	hbox.anchor_bottom = 1.0
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Killer section: solid colour from the killer's relation.
	var killer_sec := _make_section(_section_color(_relationship(killer_name), false))
	hbox.add_child(killer_sec)
	var killer_hbox: HBoxContainer = killer_sec.get_node("HBox")
	var killer_portrait := _make_portrait(_player_portrait(killer_name))
	if killer_portrait:
		killer_hbox.add_child(killer_portrait)
	killer_hbox.add_child(_make_label(_player_display(killer_name), NAME_FONT_SIZE))
	var weapon_icon := _make_weapon_icon(icon_path)
	if weapon_icon:
		killer_hbox.add_child(weapon_icon)
	else:
		killer_hbox.add_child(_make_label(" " + weapon_name + " ", TAG_FONT_SIZE))
	var hsbs := _hsbs_text(is_headshot, is_backshot)
	if not hsbs.is_empty():
		killer_hbox.add_child(_make_label(hsbs, TAG_FONT_SIZE))

	# Killee section: light colour from the killee's relation.
	var victim_sec := _make_section(_section_color(_relationship(victim_name), true))
	hbox.add_child(victim_sec)
	var victim_hbox: HBoxContainer = victim_sec.get_node("HBox")
	victim_hbox.add_child(_make_label(_player_display(victim_name), NAME_FONT_SIZE))
	var victim_portrait := _make_portrait(_player_portrait(victim_name))
	if victim_portrait:
		victim_hbox.add_child(victim_portrait)

	entry.add_child(hbox)
	_vbox.add_child(entry)  # Append → newest at the bottom, feeding up.
	_reposition()

	# --- Slide-in animation ---
	entry.modulate = Color(1, 1, 1, 0)
	var tween := create_tween()
	tween.tween_property(entry, "modulate", Color(1, 1, 1, 1), SLIDE_DURATION)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)

	# --- Fade-out timer ---
	var timer := get_tree().create_timer(ENTRY_LIFETIME)
	timer.timeout.connect(_fade_entry.bind(entry))


func _hsbs_text(is_headshot: bool, is_backshot: bool) -> String:
	var parts: Array[String] = []
	if is_headshot:
		parts.append("HS")
	if is_backshot:
		parts.append("BS")
	return " ".join(parts)


func _fade_entry(entry: Control) -> void:
	if not is_instance_valid(entry):
		return
	var tween := create_tween()
	tween.tween_property(entry, "modulate", Color(1, 1, 1, 0), FADE_DURATION)
	tween.set_ease(Tween.EASE_IN)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_callback(_remove_entry.bind(entry))


func _remove_entry(entry: Control) -> void:
	if not is_instance_valid(entry):
		return
	entry.queue_free()
	# Delay reposition slightly so queue_free processes.
	await get_tree().process_frame
	_reposition()
	# Clean up old entries beyond max.
	_prune()


func _prune() -> void:
	var children := _vbox.get_children()
	while children.size() > MAX_VISIBLE:
		var oldest := children[0]
		if is_instance_valid(oldest):
			oldest.queue_free()
		children = _vbox.get_children()
	_reposition()


# ─────────────────────────────────────────────
#  Section / label builders
# ─────────────────────────────────────────────

## A tinted PanelContainer holding an HBox of content, sized to its content.
func _make_section(bg_color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.add_theme_constant_override("separation", 4)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(hbox)
	return panel


## White label, no outline.
func _make_label(text: String, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


# ─────────────────────────────────────────────
#  Weapon Icon (pre-rendered PNG)
# ─────────────────────────────────────────────

## Returns a TextureRect displaying the pre-rendered kill-feed icon, scaled
## uniformly so its height matches ENTRY_HEIGHT (no non-uniform stretch), or null
## if the icon path is empty or the PNG can't be loaded.
func _make_weapon_icon(icon_path: String) -> TextureRect:
	if icon_path.is_empty():
		return null

	var tex: Texture2D = load(icon_path) as Texture2D
	if not tex:
		return null

	var w: float = float(tex.get_width()) * ENTRY_HEIGHT / float(tex.get_height())

	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(w, ENTRY_HEIGHT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


# ─────────────────────────────────────────────
#  Character Portrait (pre-rendered PNG)
# ─────────────────────────────────────────────

## Returns a TextureRect displaying the character's pre-rendered square
## portrait, or null if the player has no portrait assigned.
func _make_portrait(tex: Texture2D) -> TextureRect:
	if not tex:
		return null

	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(PORTRAIT_SIZE, PORTRAIT_SIZE)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## Resolves a player's character portrait from their name/id, or null when the
## player (or their character/portrait) isn't available on this peer.
func _player_portrait(player_name: String) -> Texture2D:
	if player_name.is_empty():
		return null
	var p: Player = GameManager.find_player(player_name)
	if p and p._character and p._character.portrait:
		return p._character.portrait
	return null


func _player_display(player_name: String) -> String:
	# Show the player ID (str(network_id) for humans, "bot_N" for bots),
	# not the character name.
	if player_name.is_empty():
		return "???"
	return player_name


func _player_team(player_name: String) -> int:
	if player_name.is_empty():
		return Player.Team.FFA
	var p: Player = GameManager.find_player(player_name)
	if p:
		return p.team
	return Player.Team.FFA


## Classifies a player's relation to the local player.
func _relationship(player_name: String) -> int:
	if player_name == str(multiplayer.get_unique_id()):
		return Relationship.YOU
	var player_team := _player_team(player_name)
	var my_team := _player_team(str(multiplayer.get_unique_id()))
	if player_team != Player.Team.FFA and player_team == my_team:
		return Relationship.TEAMMATE
	return Relationship.ENEMY


## Solid colour for the killer section, light colour for the killee section.
func _section_color(rel: int, light: bool) -> Color:
	match rel:
		Relationship.YOU:
			return COLOR_YOU_LIGHT if light else COLOR_YOU
		Relationship.TEAMMATE:
			return COLOR_TEAMMATE_LIGHT if light else COLOR_TEAMMATE
		_:
			return COLOR_ENEMY_LIGHT if light else COLOR_ENEMY
