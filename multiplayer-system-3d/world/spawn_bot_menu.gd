extends Node
class_name SpawnBotMenu
## Small host-only menu for spawning a bot with a chosen character + team.
##
## Opened/closed with B (replaces the old V/B/N add-bot keys).  Built in code onto
## a CanvasLayer (layer 2) and pre-instantiated by SpawnManager at lobby load so
## opening it has no lag.  Style matches the loadout / host menus: flat dark
## panels, no rounded corners, white text, blue accents.

const BLUE := Color(0.35, 0.65, 1.0, 1)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const CARD_BG := Color(0.10, 0.11, 0.15, 1)
const CARD_BORDER := Color(0.30, 0.32, 0.38, 1)
const TEAM_SPI := Color(0.88, 0.24, 0.24)
const TEAM_SCI := Color(0.2, 0.6, 0.86)
const TEXT := Color(0.9, 0.9, 0.9)
const DIM := Color(0.0, 0.02, 0.06, 0.78)

const CLASS_PATHS: Array[String] = [
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assistance.tres",
]


var _canvas: CanvasLayer
var _classes: Array[Class] = []
var _char_to_class: Dictionary = {}   # character.resource_path -> Class
var _all_characters: Array[Character] = []
var _selected_character: Character = null
var _selected_class: Class = null
var _team: Player.Team = Player.Team.FFA

var _portrait_button: TextureButton
var _char_name_label: Label
var _picker: PanelContainer
var _picker_vbox: VBoxContainer
var _team_buttons: Dictionary = {}   # Player.Team -> Button
var _bot_list: VBoxContainer


func _ready() -> void:
	_load_characters()
	_build()


func is_open() -> bool:
	return _canvas != null and _canvas.visible


func open() -> void:
	_pick_random_character()
	_update_team_buttons()
	_refresh_bot_list()
	_picker.visible = false
	_canvas.visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func close() -> void:
	_canvas.visible = false
	_picker.visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if not is_open():
		return
	if event.is_action_pressed("ui_accept"):
		_confirm()


# ─────────────────────────────────────────────────────────────
#  Build
# ─────────────────────────────────────────────────────────────

func _build() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 2
	_canvas.visible = false
	add_child(_canvas)

	var dim := ColorRect.new()
	dim.color = DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "SPAWN BOT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	vb.add_child(row)

	# ── Left: character + team + confirm ──
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(260, 0)
	left.add_theme_constant_override("separation", 12)
	row.add_child(left)

	# Portrait view with an in-place picker overlay.
	var view := Control.new()
	view.custom_minimum_size = Vector2(0, 160)
	view.clip_contents = true
	left.add_child(view)

	_portrait_button = TextureButton.new()
	_portrait_button.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait_button.focus_mode = Control.FOCUS_NONE
	_portrait_button.ignore_texture_size = true
	_portrait_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_portrait_button.pressed.connect(_toggle_picker)
	view.add_child(_portrait_button)

	_char_name_label = Label.new()
	_char_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_char_name_label.add_theme_font_size_override("font_size", 16)
	_char_name_label.add_theme_color_override("font_color", TEXT)
	left.add_child(_char_name_label)

	_picker = PanelContainer.new()
	_picker.visible = false
	_picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_picker.add_theme_stylebox_override("panel", _panel_style())
	view.add_child(_picker)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_picker.add_child(scroll)

	_picker_vbox = VBoxContainer.new()
	_picker_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(_picker_vbox)

	_build_picker()

	# Team assignment.
	var team_label := Label.new()
	team_label.text = "TEAM"
	team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	team_label.add_theme_font_size_override("font_size", 14)
	team_label.add_theme_color_override("font_color", TEXT)
	left.add_child(team_label)

	var team_row := HBoxContainer.new()
	team_row.add_theme_constant_override("separation", 8)
	left.add_child(team_row)

	team_row.add_child(_make_team_button(Player.Team.SCI, "SCI"))
	team_row.add_child(_make_team_button(Player.Team.SPI, "SPI"))
	team_row.add_child(_make_team_button(Player.Team.FFA, "FFA"))

	var confirm := Button.new()
	confirm.text = "CONFIRM  (Enter)"
	confirm.add_theme_font_size_override("font_size", 18)
	confirm.pressed.connect(_confirm)
	left.add_child(confirm)

	# ── Right: existing bots list ──
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(240, 0)
	right.add_theme_constant_override("separation", 8)
	row.add_child(right)

	right.add_child(_make_header("BOTS"))

	var bot_scroll := ScrollContainer.new()
	bot_scroll.custom_minimum_size = Vector2(0, 320)
	bot_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bot_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(bot_scroll)

	_bot_list = VBoxContainer.new()
	_bot_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bot_list.add_theme_constant_override("separation", 6)
	bot_scroll.add_child(_bot_list)


# ─────────────────────────────────────────────────────────────
#  Characters
# ─────────────────────────────────────────────────────────────

func _load_characters() -> void:
	_classes.clear()
	_char_to_class.clear()
	_all_characters.clear()
	for path in CLASS_PATHS:
		var c := load(path) as Class
		if c:
			_classes.append(c)
			for ch in c.characters:
				if ch:
					_char_to_class[ch.resource_path] = c
					_all_characters.append(ch)


func _build_picker() -> void:
	for cls in _classes:
		if cls.characters.is_empty():
			continue
		_picker_vbox.add_child(_make_header(cls.class_display_name.to_upper()))
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		_picker_vbox.add_child(flow)
		for ch in cls.characters:
			if ch:
				flow.add_child(_make_portrait_button(ch))


func _make_portrait_button(ch: Character) -> Button:
	var btn := Button.new()
	btn.icon = ch.portrait
	btn.expand_icon = true
	btn.custom_minimum_size = Vector2(56, 56)
	btn.tooltip_text = ch.character_name
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_select_character.bind(ch))
	return btn


func _pick_random_character() -> void:
	if _all_characters.is_empty():
		return
	randomize()
	_select_character(_all_characters[randi() % _all_characters.size()])


func _select_character(ch: Character) -> void:
	_selected_character = ch
	_selected_class = _char_to_class.get(ch.resource_path, null) as Class
	_apply_selected()
	_picker.visible = false


func _apply_selected() -> void:
	if _selected_character:
		_portrait_button.texture_normal = _selected_character.portrait
		_char_name_label.text = _selected_character.character_name.to_upper()


func _toggle_picker() -> void:
	_picker.visible = not _picker.visible


# ─────────────────────────────────────────────────────────────
#  Team + confirm
# ─────────────────────────────────────────────────────────────

func _make_team_button(team: Player.Team, text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_set_team.bind(team))
	_team_buttons[team] = btn
	return btn


func _set_team(team: Player.Team) -> void:
	_team = team
	_update_team_buttons()


func _update_team_buttons() -> void:
	for team in _team_buttons:
		var btn: Button = _team_buttons[team]
		var selected: bool = team == _team
		var bg := Color(0.15, 0.25, 0.35, 1) if selected else CARD_BG
		var border := BLUE if selected else CARD_BORDER
		btn.add_theme_stylebox_override("normal", _card_style(bg, border))
		btn.add_theme_stylebox_override("hover", _card_style(bg, BLUE))
		btn.add_theme_stylebox_override("pressed", _card_style(bg, border))


func _confirm() -> void:
	if _selected_character == null or _selected_class == null:
		return
	var sm := GameManager.spawn_manager
	if sm:
		sm.add_bot_with_character(_team, _selected_character, _selected_class)
	_refresh_bot_list()


# ─────────────────────────────────────────────────────────────
#  Bot list
# ─────────────────────────────────────────────────────────────

func _get_bots() -> Array:
	var out: Array = []
	if GameManager.spawn_parent == null:
		return out
	for child in GameManager.spawn_parent.get_children():
		if child is Player and child.is_bot and not child.is_queued_for_deletion():
			out.append(child)
	return out


func _refresh_bot_list() -> void:
	for child in _bot_list.get_children():
		_bot_list.remove_child(child)
		child.queue_free()
	var bots := _get_bots()
	if bots.is_empty():
		var empty := Label.new()
		empty.text = "No bots"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_bot_list.add_child(empty)
		return
	for bot in bots:
		_bot_list.add_child(_make_bot_entry(bot))


func _make_bot_entry(bot: Player) -> Control:
	var entry := PanelContainer.new()
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry.add_theme_stylebox_override("panel", _card_style(CARD_BG, CARD_BORDER))

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	entry.add_child(hb)

	var portrait := TextureRect.new()
	if bot._character:
		portrait.texture = bot._character.portrait
	portrait.custom_minimum_size = Vector2(28, 28)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hb.add_child(portrait)

	var name_lbl := Label.new()
	name_lbl.text = bot.name
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", TEXT)
	hb.add_child(name_lbl)

	var x_btn := Button.new()
	x_btn.text = "✕"
	x_btn.flat = true
	x_btn.focus_mode = Control.FOCUS_NONE
	x_btn.custom_minimum_size = Vector2(28, 28)
	x_btn.pressed.connect(_remove_bot.bind(bot.name))
	hb.add_child(x_btn)

	return entry


func _remove_bot(entity_id: String) -> void:
	var sm := GameManager.spawn_manager
	if sm:
		sm.remove_bot(entity_id)
	_refresh_bot_list()


# ─────────────────────────────────────────────────────────────
#  Style helpers
# ─────────────────────────────────────────────────────────────

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = PANEL_BORDER
	sb.set_border_width_all(2)
	sb.content_margin_left = 16.0
	sb.content_margin_top = 14.0
	sb.content_margin_right = 16.0
	sb.content_margin_bottom = 14.0
	return sb


func _card_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.content_margin_left = 4.0
	sb.content_margin_top = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_bottom = 4.0
	return sb


func _make_header(text: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _header_style())
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_font_size_override("font_size", 16)
	panel.add_child(lbl)
	return panel


func _header_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BLUE
	sb.content_margin_left = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_right = 6.0
	sb.content_margin_bottom = 4.0
	return sb
