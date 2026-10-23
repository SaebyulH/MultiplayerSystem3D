extends Node
class_name SpawnBotMenu
## Embeddable bot-spawn + bot-list panel, hosted by the dev menu's Bots tab.
##
## The old standalone B menu (own CanvasLayer, dim, open/close) is gone: the
## dev menu owns visibility and input.  This node only builds its content into a
## host Control and refreshes the list on demand.
##
## Style matches the rest of the menus: flat dark panels, no rounded corners,
## white text, blue accents.

signal edit_bot_requested(bot_name: String)

const BLUE := Color(0.35, 0.65, 1.0, 1)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const CARD_BG := Color(0.10, 0.11, 0.15, 1)
const CARD_BORDER := Color(0.30, 0.32, 0.38, 1)
const TEAM_SPI := Color(0.88, 0.24, 0.24)
const TEAM_SCI := Color(0.2, 0.6, 0.86)
const TEXT := Color(0.9, 0.9, 0.9)

const CLASS_PATHS: Array[String] = [
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assistance.tres",
]


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

## Hover preview (a top-level Control, so it is not clipped by the tab layout).
var _preview: PanelContainer
var _preview_vbox: VBoxContainer


func _ready() -> void:
	_load_characters()


## Build the panel into [param host].  Called once by the dev menu.
func build_into(host: Control) -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	host.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)

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
	confirm.text = "SPAWN BOT"
	confirm.add_theme_font_size_override("font_size", 18)
	confirm.pressed.connect(_confirm)
	left.add_child(confirm)

	# ── Right: existing bots list ──
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	row.add_child(right)

	right.add_child(_make_header("BOTS"))

	var bot_scroll := ScrollContainer.new()
	bot_scroll.custom_minimum_size = Vector2(0, 280)
	bot_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bot_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(bot_scroll)

	_bot_list = VBoxContainer.new()
	_bot_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bot_list.add_theme_constant_override("separation", 6)
	bot_scroll.add_child(_bot_list)

	_build_preview(host)
	_pick_random_character()
	_update_team_buttons()
	_refresh_bot_list()


## Rebuild the bot rows.  Called when the tab is opened and after spawn/remove.
func refresh() -> void:
	_hide_preview()
	_refresh_bot_list()


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
	if not multiplayer.is_server():
		return
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
	if not is_instance_valid(GameManager.spawn_parent):
		return out
	for child in GameManager.spawn_parent.get_children():
		if child is Player and child.is_bot and not child.is_queued_for_deletion():
			out.append(child)
	return out


func _refresh_bot_list() -> void:
	if _bot_list == null:
		return
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
	entry.mouse_filter = Control.MOUSE_FILTER_STOP
	entry.add_theme_stylebox_override("panel", _card_style(CARD_BG, CARD_BORDER))
	entry.mouse_entered.connect(_on_bot_hover.bind(entry, str(bot.name)))
	entry.mouse_exited.connect(_on_bot_row_exited.bind(entry))

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	entry.add_child(hb)

	var portrait := TextureRect.new()
	if bot._character:
		portrait.texture = bot._character.portrait
	portrait.custom_minimum_size = Vector2(28, 28)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(portrait)

	var name_lbl := Label.new()
	name_lbl.text = bot.name
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", TEXT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(name_lbl)

	var edit_btn := Button.new()
	edit_btn.text = "EDIT"
	edit_btn.focus_mode = Control.FOCUS_NONE
	edit_btn.custom_minimum_size = Vector2(48, 28)
	edit_btn.tooltip_text = "Change this bot's character and loadout"
	edit_btn.pressed.connect(_request_edit.bind(str(bot.name)))
	edit_btn.mouse_entered.connect(_on_bot_hover.bind(entry, str(bot.name)))
	edit_btn.mouse_exited.connect(_on_bot_row_exited.bind(entry))
	hb.add_child(edit_btn)

	var x_btn := Button.new()
	x_btn.text = "✕"
	x_btn.flat = true
	x_btn.focus_mode = Control.FOCUS_NONE
	x_btn.custom_minimum_size = Vector2(28, 28)
	x_btn.pressed.connect(_remove_bot.bind(str(bot.name)))
	x_btn.mouse_entered.connect(_on_bot_hover.bind(entry, str(bot.name)))
	x_btn.mouse_exited.connect(_on_bot_row_exited.bind(entry))
	hb.add_child(x_btn)

	return entry


func _request_edit(bot_name: String) -> void:
	if not multiplayer.is_server():
		return
	_hide_preview()
	edit_bot_requested.emit(bot_name)


func _remove_bot(entity_id: String) -> void:
	var sm := GameManager.spawn_manager
	if sm:
		sm.remove_bot(entity_id)
	_refresh_bot_list()


# ─────────────────────────────────────────────────────────────
#  Hover loadout preview
# ─────────────────────────────────────────────────────────────

func _build_preview(host: Control) -> void:
	_preview = PanelContainer.new()
	_preview.top_level = true
	_preview.visible = false
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.z_index = 100
	_preview.add_theme_stylebox_override("panel", _panel_style())
	host.add_child(_preview)

	_preview_vbox = VBoxContainer.new()
	_preview_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_vbox.add_theme_constant_override("separation", 4)
	_preview.add_child(_preview_vbox)


func _on_bot_hover(entry: Control, bot_name: String) -> void:
	if _preview == null or not is_instance_valid(entry):
		return
	# Resolve by name: the row can outlive the bot by a frame, and a name
	# lookup fails gracefully where a cached node reference would error.
	var bot := GameManager.find_player(bot_name)
	if bot == null or not bot.is_bot:
		_hide_preview()
		return

	for child in _preview_vbox.get_children():
		_preview_vbox.remove_child(child)
		child.queue_free()

	_preview_vbox.add_child(_preview_label("BOT LOADOUT", 13, BLUE))

	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 8)
	_preview_vbox.add_child(top)

	var char := bot.get_character()
	if char:
		var portrait := TextureRect.new()
		portrait.texture = char.portrait
		portrait.custom_minimum_size = Vector2(48, 48)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
		top.add_child(portrait)

	var info := VBoxContainer.new()
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_theme_constant_override("separation", 1)
	top.add_child(info)

	var class_res := _class_for_character(char)
	var cls_name := class_res.class_display_name if class_res else "?"
	info.add_child(_preview_label(char.character_name if char else "No character", 15, TEXT))
	info.add_child(_preview_label("%s  ·  %s" % [cls_name, _team_name(bot.team)], 12, Color(0.65, 0.68, 0.75)))

	var weapons: Array[Weapon] = []
	if bot.weapon_controller:
		weapons = bot.weapon_controller.get_weapons()
	var slots := ["Primary", "Secondary", "Melee"]
	for i in mini(weapons.size(), slots.size()):
		info.add_child(_preview_label("%s: %s" % [slots[i], weapons[i].display_name], 13, TEXT))

	_preview.visible = true
	_preview.reset_size()
	var vp := get_viewport().get_visible_rect().size
	var pos := entry.global_position + Vector2(entry.size.x + 8, 0)
	pos.x = clampf(pos.x, 8.0, maxf(8.0, vp.x - _preview.size.x - 8.0))
	pos.y = clampf(pos.y, 8.0, maxf(8.0, vp.y - _preview.size.y - 8.0))
	_preview.global_position = pos


func _on_bot_row_exited(entry: Control) -> void:
	if not is_instance_valid(entry):
		_hide_preview()
		return
	# Moving onto a child button fires the row's mouse_exited; keep the preview
	# while the pointer is still inside the row.
	if entry.get_global_rect().has_point(entry.get_global_mouse_position()):
		return
	_hide_preview()


func _hide_preview() -> void:
	if _preview and is_instance_valid(_preview):
		_preview.visible = false


func _preview_label(text: String, size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _class_for_character(ch: Character) -> Class:
	if ch == null:
		return null
	for cls in _classes:
		for c in cls.characters:
			if c and c.resource_path == ch.resource_path:
				return cls
	return null


func _team_name(team: int) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return "FFA"


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
