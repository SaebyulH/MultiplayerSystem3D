extends CanvasLayer
class_name KillFeed

## Overwatch / TF2 style kill feed in the top-right corner.
## Format:  KILLER  [weapon] >  KILLEE
##
## Names are team-coloured.  The local player's own kills are highlighted
## with a brighter background and gold accent.

const MAX_VISIBLE := 5
const ENTRY_LIFETIME: float = 8.0
const FADE_DURATION: float = 1.5
const SLIDE_DURATION: float = 0.25
const ENTRY_HEIGHT: float = 26.0
const ENTRY_SEPARATION: float = 2.0

# Layout
const PANEL_RIGHT: float = 16.0
const PANEL_TOP: float = 48.0
const PANEL_MAX_WIDTH: float = 420.0

# Team colours (match the HUD / player_ui convention).
const COLOR_SPI := Color(0.88, 0.24, 0.24)   # red
const COLOR_SCI := Color(0.25, 0.65, 0.90)   # blue
const COLOR_FFA := Color(0.038, 0.038, 0.038, 1.0)   # gray

var _panel: Control = null
var _vbox: VBoxContainer = null


func _ready() -> void:
	layer = 4
	name = "KillFeedCanvas"

	_panel = Control.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	# Semi-transparent dark backdrop behind the feed.
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.0, 0.0, 0.0, 0.45)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bg)

	_vbox = VBoxContainer.new()
	_vbox.name = "EntryList"
	_vbox.add_theme_constant_override("separation", ENTRY_SEPARATION)
	_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
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
	var padding: float = 8.0
	var total_w: float = PANEL_MAX_WIDTH
	var total_h: float = content_h + padding * 2.0

	_panel.offset_left = -(total_w + PANEL_RIGHT)
	_panel.offset_top = PANEL_TOP
	_panel.offset_right = -PANEL_RIGHT
	_panel.offset_bottom = PANEL_TOP + max(total_h, 0.0)

	var bg := _panel.get_node_or_null("Background") as ColorRect
	if bg:
		bg.anchor_left = 0.0
		bg.anchor_right = 1.0
		bg.anchor_top = 0.0
		bg.anchor_bottom = 1.0


func _on_kill_event(killer_name: String, victim_name: String, weapon_name: String) -> void:
	_add_entry(killer_name, victim_name, weapon_name)


func _add_entry(killer_name: String, victim_name: String, weapon_name: String) -> void:
	var my_id := str(multiplayer.get_unique_id())
	var is_my_kill := (killer_name == my_id)

	var killer_display := _player_display(killer_name)
	var victim_display := _player_display(victim_name)
	var killer_team := _player_team(killer_name)
	var victim_team := _player_team(victim_name)

	# --- Build entry widget ---
	var entry := Control.new()
	entry.name = "KillEntry"
	entry.custom_minimum_size = Vector2(0.0, ENTRY_HEIGHT)
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Background highlight for own kills.
	if is_my_kill:
		var hl := ColorRect.new()
		hl.name = "Highlight"
		hl.color = Color(1.0, 0.84, 0.0, 0.22)
		hl.anchor_left = 0.0
		hl.anchor_right = 1.0
		hl.anchor_top = 0.0
		hl.anchor_bottom = 1.0
		entry.add_child(hl)

	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.add_theme_constant_override("separation", 4)
	hbox.anchor_left = 0.0
	hbox.anchor_right = 1.0
	hbox.anchor_top = 0.0
	hbox.anchor_bottom = 1.0
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Edge padding
	var spacer_l := Control.new()
	spacer_l.custom_minimum_size = Vector2(8.0, 0.0)
	spacer_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(spacer_l)

	# Killer name
	var kl := _make_name_label(killer_display, killer_team, is_my_kill)
	hbox.add_child(kl)

	# Weapon name
	var wl := Label.new()
	wl.text = " " + weapon_name + " "
	wl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.60))
	wl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	wl.add_theme_constant_override("outline_size", 2)
	wl.add_theme_font_size_override("font_size", 13)
	wl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(wl)

	# Separator arrow
	var arrow := Label.new()
	arrow.text = "▸"
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	arrow.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	arrow.add_theme_constant_override("outline_size", 2)
	arrow.add_theme_font_size_override("font_size", 13)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(arrow)

	# Victim name
	var vl := _make_name_label(victim_display, victim_team, false)
	hbox.add_child(vl)

	# Right padding (stretch to fill)
	var spacer_r := Control.new()
	spacer_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer_r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(spacer_r)

	entry.add_child(hbox)
	_vbox.add_child(entry)
	_vbox.move_child(entry, 0)  # Newest entry at the top.
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


func _make_name_label(display_name: String, team: int, is_own_kill: bool) -> Label:
	var lbl := Label.new()
	lbl.text = display_name
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Team colour
	var c: Color
	match team:
		Player.Team.SPI:  c = COLOR_SPI
		Player.Team.SCI:  c = COLOR_SCI
		_:                c = COLOR_FFA

	if is_own_kill:
		# Make your own name pop a bit brighter.
		c = c.lightened(0.25)
		lbl.add_theme_color_override("font_color", c)
	else:
		lbl.add_theme_color_override("font_color", c)

	return lbl


func _player_display(player_name: String) -> String:
	if player_name.is_empty():
		return "???"
	var p: Player = GameManager.find_player(player_name)
	if p and p._character:
		# Use character name for a cleaner look when available.
		return p._character.character_name
	# Fall back to a short numeric label.
	if player_name.is_valid_int():
		var num := player_name.to_int()
		if num == 1:
			return "Host"
		return "P" + player_name
	return player_name


func _player_team(player_name: String) -> int:
	if player_name.is_empty():
		return Player.Team.FFA
	var p: Player = GameManager.find_player(player_name)
	if p:
		return p.team
	return Player.Team.FFA
