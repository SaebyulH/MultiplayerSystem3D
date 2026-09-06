extends Control
class_name LoadoutMenuUI

## Clean, professional loadout-selection screen.
## Mirrors ClassSelectUI: a CanvasLayer added to the root viewport renders
## above all other UI.  Class is inferred from the selected character, so
## there is no separate class-selection step.

@onready var world := $"../../.."

var player_id: String
var available_classes: Array[Class] = []
var _char_to_class: Dictionary = {}      # character.resource_path -> Class
var _all_characters: Array[Dictionary] = []  # [{ "char": Character, "class": Class }]

# ── Selection state ─────────────────────────
var selected_class: Class = null
var selected_character: Character = null
var selected_primary: Weapon = null
var selected_secondary: Weapon = null
var selected_melee: Weapon = null

# ── Built nodes ──────────────────────────────

var _canvas: CanvasLayer
var _team_option: OptionButton
var _confirm_button: Button
var _randomize_once_button: Button
var _randomize_on_death_check: CheckBox
var _mode_label: Label
var _info_label: RichTextLabel

# Character panel
var _character_viewport: SubViewport
var _character_preview_root: Node3D = null
var _character_dragging: bool = false
var _character_drag_moved: bool = false
var _character_wrap_style: StyleBoxFlat = null
var _change_agent_overlay: Label
var _character_name_label: Label
var _loadout_class_label: Label
var _loadout_class_label_title: Label
var _character_picker: PopupPanel

# Loadout columns  (SECONDARY | PRIMARY | MELEE)
var _secondary_column: VBoxContainer
var _primary_column: VBoxContainer
var _melee_column: VBoxContainer
var _column_lists: Dictionary = {}       # column key -> inner card VBoxContainer
var _card_style: Dictionary = {}         # card -> StyleBoxFlat
var _selected_card: Dictionary = {}      # column key -> selected card

# Ability strip
var _ability_slots_hbox: HBoxContainer
var _ability_style: Dictionary = {}      # slot -> StyleBoxFlat

# ── Card style colours ───────────────────────
const CARD_BG_NORMAL := Color(0.10, 0.11, 0.15, 1)
const CARD_BG_HOVER := Color(0.16, 0.18, 0.24, 1)
const CARD_BG_SELECTED := Color(0.15, 0.20, 0.22, 1)
const CARD_BORDER_NORMAL := Color(0.30, 0.32, 0.38, 1)
const CARD_BORDER_HOVER := Color(0.65, 0.85, 1.0, 1)
const CARD_BORDER_SELECTED := Color(1.0, 0.80, 0.25, 1)

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())

	# Nuke ALL old scene children so the host Control shows nothing.
	for child in get_children():
		child.queue_free()

	# Build everything in a dedicated CanvasLayer attached to the root window.
	_canvas = CanvasLayer.new()
	_canvas.layer = 2
	_canvas.name = "LoadoutMenuCanvas"
	get_tree().root.add_child(_canvas)
	_build_ui_in(_canvas)

	# Sync canvas visibility immediately (menu starts visible, matching self.visible).
	_canvas.visible = visible

	# Load classes
	var loaded_classes: Array[Class] = []
	for path in [
		"res://player/player_classes/assault.tres",
		"res://player/player_classes/assassin.tres",
		"res://player/player_classes/assistance.tres",
	]:
		var c := load(path) as Class
		if c:
			loaded_classes.append(c)
	load_classes(loaded_classes)

	_build_character_picker()

	_confirm_button.pressed.connect(_on_confirm_pressed)
	_randomize_once_button.pressed.connect(_on_randomize_once_pressed)

	# Default to the first available character so the menu opens populated.
	if not _all_characters.is_empty():
		_select_character(_all_characters[0]["char"])


func _process(_delta: float) -> void:
	# world_1.gd toggles self.visible to show/hide the loadout menu.  Free the
	# character preview while hidden so its animation/jigglebones stop consuming
	# CPU during gameplay; re-spawn it when the menu reopens.
	if not _canvas:
		return
	if _canvas.visible == visible:
		return
	_canvas.visible = visible
	if visible:
		_refresh_character_preview()
	else:
		_spawn_character_preview(null)

# ─────────────────────────────────────────────
#  UI Building  (target: a CanvasLayer)
# ─────────────────────────────────────────────

func _build_ui_in(cl: CanvasLayer) -> void:
	# Dim backdrop
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.06, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.add_child(dim)

	# Root margin container filling the viewport.
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 24)
	root.add_theme_constant_override("margin_top", 16)
	root.add_theme_constant_override("margin_right", 24)
	root.add_theme_constant_override("margin_bottom", 16)
	cl.add_child(root)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	root.add_child(col)

	# ── Title ────────────────────────────────
	col.add_child(_title())
	col.add_child(_sep())

	# Game-mode info
	_mode_label = Label.new()
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_mode_label.add_theme_constant_override("outline_size", 4)
	_mode_label.add_theme_font_size_override("font_size", 15)
	_mode_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.5))
	_mode_label.text = ""
	col.add_child(_mode_label)
	col.add_child(_sep())
	_populate_mode_info.call_deferred()

	# ── Main 3-panel row  (25% / 50% / 25%) ──
	var main_row := HBoxContainer.new()
	main_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_theme_constant_override("separation", 12)
	col.add_child(main_row)

	main_row.add_child(_build_character_panel())
	main_row.add_child(_build_loadout_panel())
	main_row.add_child(_build_info_panel())

	col.add_child(_sep())

	# ── Ability section ──────────────────────
	col.add_child(_build_ability_section())

	col.add_child(_sep())

	# ── Action bar ───────────────────────────
	col.add_child(_build_action_bar())

# ─────────────────────────────────────────────
#  Panels
# ─────────────────────────────────────────────

func _build_character_panel() -> Control:
	var panel := _panel_container()
	panel.size_flags_stretch_ratio = 1.0

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	vb.add_child(_header("AGENT"))

	# Preview wrap — the hover/click/drag target.  A plain Panel (not a
	# container) so the SubViewport and the hover overlay can be freely anchored.
	var wrap := Panel.new()
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	_character_wrap_style = StyleBoxFlat.new()
	_character_wrap_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	_character_wrap_style.border_color = Color(0.35, 0.4, 0.5, 1)
	_character_wrap_style.set_border_width_all(2)
	_character_wrap_style.set_corner_radius_all(6)
	wrap.add_theme_stylebox_override("panel", _character_wrap_style)
	vb.add_child(wrap)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_STOP
	svc.gui_input.connect(_on_character_gui_input)
	svc.mouse_entered.connect(_on_character_hover_enter)
	svc.mouse_exited.connect(_on_character_hover_exit)
	_character_viewport = _character_vp()
	svc.add_child(_character_viewport)
	wrap.add_child(svc)

	# "Change Agent" overlay — on top of the preview, only shown on hover.
	_change_agent_overlay = Label.new()
	_change_agent_overlay.text = "CHANGE AGENT"
	_change_agent_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_change_agent_overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_change_agent_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_change_agent_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_change_agent_overlay.visible = false
	_change_agent_overlay.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_change_agent_overlay.add_theme_constant_override("outline_size", 8)
	_change_agent_overlay.add_theme_font_size_override("font_size", 24)
	_change_agent_overlay.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	wrap.add_child(_change_agent_overlay)

	# Name + inferred class labels
	_character_name_label = Label.new()
	_character_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_character_name_label.add_theme_font_size_override("font_size", 18)
	_character_name_label.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	vb.add_child(_character_name_label)

	_loadout_class_label = Label.new()
	_loadout_class_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loadout_class_label.add_theme_font_size_override("font_size", 14)
	_loadout_class_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.5))
	vb.add_child(_loadout_class_label)

	return panel


func _build_loadout_panel() -> Control:
	var panel := _panel_container()
	panel.size_flags_stretch_ratio = 2.0

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	_loadout_class_label_title = Label.new()
	_loadout_class_label_title.text = "LOADOUT"
	_loadout_class_label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loadout_class_label_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_loadout_class_label_title.add_theme_constant_override("outline_size", 4)
	_loadout_class_label_title.add_theme_font_size_override("font_size", 16)
	_loadout_class_label_title.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	vb.add_child(_loadout_class_label_title)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 10)
	vb.add_child(cols)

	# Order per spec: SECONDARY, PRIMARY, MELEE.
	_secondary_column = _build_weapon_column("SECONDARY", "secondary")
	_primary_column = _build_weapon_column("PRIMARY", "primary")
	_melee_column = _build_weapon_column("MELEE", "melee")
	cols.add_child(_secondary_column)
	cols.add_child(_primary_column)
	cols.add_child(_melee_column)

	return panel


func _build_info_panel() -> Control:
	var panel := _panel_container()
	panel.size_flags_stretch_ratio = 1.0

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	vb.add_child(_header("INFO"))

	_info_label = _stat_label()
	_info_label.visible = true
	_info_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_info_label)

	return panel


func _build_ability_section() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	vb.add_child(_header("ABILITIES"))

	_ability_slots_hbox = HBoxContainer.new()
	_ability_slots_hbox.add_theme_constant_override("separation", 8)
	vb.add_child(_ability_slots_hbox)

	return vb


func _build_action_bar() -> Control:
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 16)

	_team_option = _opt()
	_team_option.add_item("FFA", 0)
	_team_option.add_item("SPI", 1)
	_team_option.add_item("SCI", 2)
	hbox.add_child(_labeled("TEAM", _team_option))

	_randomize_once_button = Button.new()
	_randomize_once_button.text = "  RANDOMIZE  "
	_randomize_once_button.add_theme_font_size_override("font_size", 16)
	hbox.add_child(_randomize_once_button)

	_randomize_on_death_check = CheckBox.new()
	_randomize_on_death_check.text = "Randomize on every death"
	_randomize_on_death_check.add_theme_font_size_override("font_size", 16)
	_randomize_on_death_check.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	hbox.add_child(_randomize_on_death_check)

	_confirm_button = Button.new()
	_confirm_button.text = "  CONFIRM BUILD  "
	_confirm_button.add_theme_font_size_override("font_size", 22)
	_confirm_button.disabled = true
	hbox.add_child(_confirm_button)

	var menu_btn := Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.add_theme_font_size_override("font_size", 18)
	menu_btn.pressed.connect(func():
		_canvas.queue_free()
		NetworkManager.terminate_connection_load_main_menu()
	)
	hbox.add_child(menu_btn)

	return hbox


# ─────────────────────────────────────────────
#  Character picker
# ─────────────────────────────────────────────

func _build_character_picker() -> void:
	_character_picker = PopupPanel.new()
	_character_picker.name = "CharacterPicker"
	_canvas.add_child(_character_picker)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.custom_minimum_size = Vector2(540, 0)
	_character_picker.add_child(vb)

	var title := Label.new()
	title.text = "SELECT AGENT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	vb.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	vb.add_child(grid)

	for entry in _all_characters:
		var char: Character = entry["char"]
		var cls: Class = entry["class"]
		var btn := Button.new()
		btn.text = "%s\n%s" % [char.character_name, cls.class_display_name]
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.custom_minimum_size = Vector2(260, 56)
		btn.add_theme_font_size_override("font_size", 16)
		btn.pressed.connect(_on_pick_character.bind(char))
		grid.add_child(btn)


func _on_pick_character(char: Character) -> void:
	_select_character(char)
	_character_picker.hide()


# ─────────────────────────────────────────────
#  Weapon cards
# ─────────────────────────────────────────────

func _build_weapon_column(title: String, key: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)

	col.add_child(_header(title))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	_column_lists[key] = list

	return col


func _make_card_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


func _make_weapon_card(weapon: Weapon, key: String) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(170, 150)
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.set_meta("weapon", weapon)
	card.set_meta("column", key)
	card.set_meta("selected", false)

	var normal := _make_card_stylebox(CARD_BG_NORMAL, CARD_BORDER_NORMAL)
	card.add_theme_stylebox_override("normal", normal)
	card.add_theme_stylebox_override("hover", _make_card_stylebox(CARD_BG_HOVER, CARD_BORDER_HOVER))
	card.add_theme_stylebox_override("pressed", _make_card_stylebox(CARD_BG_SELECTED, CARD_BORDER_SELECTED))
	card.add_theme_stylebox_override("hover_pressed", _make_card_stylebox(CARD_BG_SELECTED, CARD_BORDER_SELECTED))
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_card_style[card] = normal

	# A Button is not a container, so anchor a margin box inside it to lay the
	# content out while keeping it inset from the card border.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	if weapon.killfeed_icon:
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(158, 88)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture = weapon.killfeed_icon
		vb.add_child(icon)
	else:
		var placeholder := ColorRect.new()
		placeholder.color = Color(0.12, 0.12, 0.16, 1)
		placeholder.custom_minimum_size = Vector2(158, 88)
		placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(placeholder)

	var name_label := Label.new()
	name_label.text = weapon.display_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vb.add_child(name_label)

	card.mouse_entered.connect(_on_card_hover.bind(card))
	card.pressed.connect(_on_card_pressed.bind(card))

	return card


func _apply_card_state(card: Button) -> void:
	var style: StyleBoxFlat = _card_style.get(card)
	if style == null:
		return
	var selected: bool = card.get_meta("selected", false)
	style.bg_color = CARD_BG_SELECTED if selected else CARD_BG_NORMAL
	style.border_color = CARD_BORDER_SELECTED if selected else CARD_BORDER_NORMAL


func _on_card_hover(card: Button) -> void:
	var weapon: Weapon = card.get_meta("weapon")
	_show_weapon_info(weapon)


func _on_card_pressed(card: Button) -> void:
	_select_card(card)


func _select_card(card: Button) -> void:
	var weapon: Weapon = card.get_meta("weapon")
	var key: String = card.get_meta("column")

	var prev: Button = _selected_card.get(key)
	if prev and prev != card:
		prev.set_meta("selected", false)
		_apply_card_state(prev)

	card.set_meta("selected", true)
	_selected_card[key] = card

	match key:
		"primary":
			selected_primary = weapon
		"secondary":
			selected_secondary = weapon
		"melee":
			selected_melee = weapon

	_apply_card_state(card)
	_show_weapon_info(weapon)

# ─────────────────────────────────────────────
#  Ability slots
# ─────────────────────────────────────────────

func _make_ability_slot(index: int, ability: Ability) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(200, 64)
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.15, 1)
	style.border_color = Color(0.30, 0.32, 0.38, 1)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	slot.add_theme_stylebox_override("panel", style)
	_ability_style[slot] = style

	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 15)
	if ability:
		lbl.text = ability.ability_name
		lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	else:
		lbl.text = "UNASSIGNED"
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	slot.add_child(lbl)

	slot.set_meta("ability", ability)
	slot.set_meta("index", index)
	slot.mouse_entered.connect(_on_ability_hover.bind(slot))
	slot.mouse_exited.connect(_on_ability_unhover.bind(slot))

	return slot


func _on_ability_hover(slot: PanelContainer) -> void:
	var style: StyleBoxFlat = _ability_style.get(slot)
	if style:
		var tw := slot.create_tween()
		tw.tween_property(style, "border_color", Color(0.65, 0.85, 1.0, 1), 0.12)
		tw.parallel().tween_property(style, "bg_color", Color(0.16, 0.18, 0.24, 1), 0.12)
	var ability: Ability = slot.get_meta("ability")
	if ability:
		_show_ability_info(ability)
	else:
		_show_info("Unassigned", "No ability is assigned to this slot.")


func _on_ability_unhover(slot: PanelContainer) -> void:
	var style: StyleBoxFlat = _ability_style.get(slot)
	if style:
		var tw := slot.create_tween()
		tw.tween_property(style, "border_color", Color(0.30, 0.32, 0.38, 1), 0.12)
		tw.parallel().tween_property(style, "bg_color", Color(0.10, 0.11, 0.15, 1), 0.12)

# ─────────────────────────────────────────────
#  Info panel
# ─────────────────────────────────────────────

func _show_info(title: String, body: String) -> void:
	if _info_label == null:
		return
	if title == "":
		_info_label.text = body
	else:
		_info_label.text = "[b][size=18]%s[/size][/b]\n\n%s" % [title, body]


func _show_weapon_info(weapon: Weapon) -> void:
	if weapon == null:
		return
	_show_info(weapon.display_name, _weapon_stats(weapon))


func _show_ability_info(ability: Ability) -> void:
	var parts: PackedStringArray = []
	if not ability.description.is_empty():
		parts.append(ability.description)
	parts.append("Cooldown %.1fs" % ability.cooldown)
	var cast := "Instant" if ability.cast_type == Ability.CastType.INSTANT else "Equip"
	parts.append("Cast: %s" % cast)
	_show_info(ability.ability_name, "  • %s" % "\n  • ".join(parts))


func _show_character_info(char: Character) -> void:
	if char == null:
		return
	var parts: PackedStringArray = []
	if not char.description.is_empty():
		parts.append("[i]%s[/i]" % char.description)
	var stat_lines: PackedStringArray = _char_stat_lines(char)
	if stat_lines.size() > 0:
		parts.append("")
		parts.append_array(stat_lines)
	if char.abilities.size() > 0:
		parts.append("")
		parts.append("[b]Abilities[/b]")
		for a in char.abilities:
			if a:
				parts.append("  %s" % a.ability_name)
	_show_info(char.character_name, "\n".join(parts))

# ─────────────────────────────────────────────
#  Selection
# ─────────────────────────────────────────────

func _select_character(char: Character) -> void:
	selected_character = char
	selected_class = null
	if char:
		selected_class = _char_to_class.get(char.resource_path) as Class

	_refresh_character_preview()

	if _character_name_label:
		_character_name_label.text = char.character_name if char else ""
	if _loadout_class_label:
		_loadout_class_label.text = selected_class.class_display_name if selected_class else ""
	if _loadout_class_label_title:
		_loadout_class_label_title.text = "LOADOUT — %s" % (selected_class.class_display_name if selected_class else "")

	_rebuild_weapon_columns()
	_refresh_abilities()

	_confirm_button.disabled = selected_class == null
	if selected_class == null:
		_show_info("", "No class found for this character.")
	else:
		_show_character_info(char)


func _rebuild_weapon_columns() -> void:
	_selected_card.clear()
	_card_style.clear()
	selected_primary = null
	selected_secondary = null
	selected_melee = null

	var primaries: Array[Weapon] = []
	var secondaries: Array[Weapon] = []
	var melees: Array[Weapon] = []
	if selected_class:
		primaries = selected_class.primary_weapons
		secondaries = selected_class.secondary_weapons
		melees = selected_class.melee_weapons

	_populate_column("primary", primaries)
	_populate_column("secondary", secondaries)
	_populate_column("melee", melees)

	if selected_class:
		_auto_select_first("primary", primaries)
		_auto_select_first("secondary", secondaries)
		_auto_select_first("melee", melees)


func _populate_column(key: String, weapons: Array[Weapon]) -> void:
	var list: VBoxContainer = _column_lists.get(key)
	if list == null:
		return
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	if weapons.is_empty():
		var empty := Label.new()
		empty.text = "—"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		list.add_child(empty)
		return
	for w in weapons:
		list.add_child(_make_weapon_card(w, key))


func _auto_select_first(key: String, weapons: Array[Weapon]) -> void:
	if weapons.is_empty():
		return
	var list: VBoxContainer = _column_lists.get(key)
	if list == null or list.get_child_count() == 0:
		return
	var first_card: Button = list.get_child(0) as Button
	_select_card(first_card)


func _refresh_abilities() -> void:
	if _ability_slots_hbox == null:
		return
	for c in _ability_slots_hbox.get_children():
		_ability_slots_hbox.remove_child(c)
		c.queue_free()
	_ability_style.clear()
	for i in 4:
		var ability: Ability = null
		if selected_character and i < selected_character.abilities.size():
			ability = selected_character.abilities[i]
		_ability_slots_hbox.add_child(_make_ability_slot(i, ability))


# ─────────────────────────────────────────────
#  Character preview
# ─────────────────────────────────────────────

func _on_character_hover_enter() -> void:
	if _character_wrap_style:
		var tw := create_tween()
		tw.tween_property(_character_wrap_style, "border_color", Color(1.0, 0.85, 0.4, 1), 0.15)
	_change_agent_overlay.visible = true


func _on_character_hover_exit() -> void:
	if _character_wrap_style:
		var tw := create_tween()
		tw.tween_property(_character_wrap_style, "border_color", Color(0.35, 0.4, 0.5, 1), 0.15)
	_change_agent_overlay.visible = false


## Drag to spin the character; click (press+release without dragging) opens the picker.
func _on_character_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_character_dragging = true
				_character_drag_moved = false
			else:
				_character_dragging = false
				if not _character_drag_moved:
					_character_picker.popup_centered()
	elif event is InputEventMouseMotion and _character_dragging:
		var mm := event as InputEventMouseMotion
		if absf(mm.relative.x) > 0.01:
			_character_drag_moved = true
		if _character_preview_root:
			_character_preview_root.rotation.y += mm.relative.x * 0.01
			_character_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _refresh_character_preview() -> void:
	_spawn_character_preview(selected_character)


func _spawn_character_preview(char: Character) -> void:
	if _character_viewport == null:
		return
	_clear_viewport(_character_viewport)
	if char == null or char.character_scene == null:
		return
	var pr := _character_viewport.get_node_or_null("Node3D/PreviewRoot") as Node3D
	if pr == null:
		return
	_character_preview_root = pr
	var model := char.character_scene.instantiate() as Node3D
	pr.add_child(model)

	var box := _visual_aabb(model)
	if box.size.length_squared() <= 0.0001:
		box = AABB(Vector3(-0.5, -0.9, -0.5), Vector3(1.0, 1.8, 1.0))
	model.position = -box.get_center()

	var anims := model.find_children("*", "AnimationPlayer", true, false)
	var anim: AnimationPlayer = anims[0] if not anims.is_empty() else null
	if anim:
		if anim.has_animation("walk/idle"):
			anim.play("walk/idle")
		elif anim.has_animation("walk/walk_w"):
			anim.play("walk/walk_w")

	var camera := _character_viewport.get_node_or_null("Node3D/Camera3D") as Camera3D
	if camera:
		var radius := box.size.length() * 0.5
		var fov := deg_to_rad(camera.fov)
		var distance := radius / tan(fov * 0.5)
		distance = maxf(distance * 1.15, radius + 0.5)
		camera.position = Vector3(0, 0, -distance)
		camera.look_at(Vector3.ZERO)
	_character_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

# ─────────────────────────────────────────────
#  Preview helpers (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

func _clear_viewport(vp: SubViewport) -> void:
	var pr: Node = vp.get_node_or_null("Node3D/PreviewRoot")
	if not pr:
		return
	for child in pr.get_children():
		child.queue_free()


func _character_vp() -> SubViewport:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.handle_input_locally = false
	vp.size = Vector2i(360, 520)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var preview_scene := preload("res://world/character_subviewport_preview.tscn")
	if preview_scene:
		vp.add_child(preview_scene.instantiate())
	return vp


func _visual_aabb(root: Node3D) -> AABB:
	var box := AABB()
	if root is VisualInstance3D:
		var aabb := (root as VisualInstance3D).get_aabb()
		if aabb.size.length_squared() > 0.0:
			box = box.merge(aabb)
	for child in root.get_children():
		if not child is Node3D:
			continue
		var child_box := _visual_aabb(child as Node3D)
		if child_box.size.length_squared() > 0.0:
			box = box.merge(_aabb_transformed(child_box, (child as Node3D).transform))
	return box


func _aabb_transformed(aabb: AABB, xform: Transform3D) -> AABB:
	var out := AABB()
	out = out.expand(xform * aabb.position)
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, 0, 0)))
	out = out.expand(xform * (aabb.position + Vector3(0, aabb.size.y, 0)))
	out = out.expand(xform * (aabb.position + Vector3(0, 0, aabb.size.z)))
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, aabb.size.y, 0)))
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, 0, aabb.size.z)))
	out = out.expand(xform * (aabb.position + Vector3(0, aabb.size.y, aabb.size.z)))
	out = out.expand(xform * (aabb.position + aabb.size))
	return out

# ─────────────────────────────────────────────
#  Classes
# ─────────────────────────────────────────────

func load_classes(classes: Array[Class]) -> void:
	available_classes = classes
	_char_to_class.clear()
	_all_characters.clear()
	for cls in classes:
		if not cls:
			continue
		for char in cls.characters:
			if char:
				_char_to_class[char.resource_path] = cls
				_all_characters.append({"char": char, "class": cls})

# ─────────────────────────────────────────────
#  Stats (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

func _weapon_stats(weapon: Weapon) -> String:
	var parts: PackedStringArray = []

	if not weapon.has_infinite_ammo:
		parts.append("Mag %d" % weapon.mag_size)
		parts.append("Reload %.1fs%s" % [weapon.reload_time,
			" per shell" if weapon.reload_individually else ""])

	for fire in weapon.weapon_fires:
		if fire.action_type != WeaponFire.ActionType.SHOOT:
			continue

		if fire.bullet_type == WeaponFire.BulletType.HITSCAN:
			parts.append("Hitscan · DMG %d" % fire.hitscan_damage)
			if fire.headshot_multiplier != 1.0:
				parts.append("Head ×%.1f" % fire.headshot_multiplier)
			if fire.has_damage_falloff:
				parts.append("Falloff %.0f–%.0f" % [fire.falloff_start, fire.falloff_end])
		else:
			parts.append("Projectile")
			if fire.projectile_scene != null:
				var proj := fire.projectile_scene.instantiate()
				var hb_node: Node = proj.get_node_or_null("HitboxComponent")
				if hb_node and hb_node is HitboxComponent:
					var hb := hb_node as HitboxComponent
					parts.append("DMG %d" % abs(hb.health_delta))
					if hb.headshot_multiplier != 1.0:
						parts.append("Head ×%.1f" % hb.headshot_multiplier)
				proj.queue_free()

		if fire.post_shoot_delay > 0.0:
			parts.append("%.1f/s" % (1.0 / fire.post_shoot_delay))
		else:
			parts.append("Semi")

		if fire.automatic:
			parts.append("Auto")

		if fire.ammo_cost > 1:
			parts.append("Cost %d" % fire.ammo_cost)

		if fire.multishot_data.size() > 1:
			match fire.multishot_mode:
				WeaponFire.MultishotMode.SHOTGUN:
					parts.append("×%d pellets" % fire.multishot_data.size())
				WeaponFire.MultishotMode.BURST:
					parts.append("Burst %d" % fire.multishot_data.size())
				WeaponFire.MultishotMode.SHAPE:
					parts.append("Melee ×%d" % fire.multishot_data.size())

	if not is_equal_approx(weapon.player_speed_multiplier, 1.0):
		var pct := int((weapon.player_speed_multiplier - 1.0) * 100.0)
		parts.append("Speed %s%d%%" % ["+" if pct > 0 else "", pct])

	return "  • %s" % "\n  • ".join(parts)


func _char_stat_lines(char: Character) -> PackedStringArray:
	var lines: PackedStringArray = []
	_add_stat_group(lines, "Movement", [
		["Speed", char.speed_mult, false],
		["Acceleration", char.acceleration_mult, false],
		["Friction", char.friction_mult, false],
		["Crouch Speed", char.crouch_speed_mult, false],
	])
	_add_stat_group(lines, "Air", [
		["Air Accel", char.air_accel_mult, false],
		["Air Speed Cap", char.air_speed_cap_mult, false],
		["Jump", char.jump_mult, false],
	])
	_add_stat_group(lines, "Slide", [
		["Slide Friction", char.slide_friction_mult, false],
		["Entry Boost", char.slide_entry_boost_mult, false],
		["Slope Gravity", char.slope_gravity_mult, false],
	])
	_add_stat_group(lines, "Combat", [
		["Damage", char.damage_amp_mult, false],
		["Reload Speed", char.reload_speed_mult, false],
		["Fire Rate", char.shoot_delay_mult, true],
	])
	_add_stat_group(lines, "Defense", [
		["Health", char.health_mult, false, false],
		["Lifesteal", char.lifesteal_percent, false],
		["Regen / sec", char.regen_per_sec, false, true],
		["Regen Delay", char.regen_delay, false, true],
		["Heal on Kill", char.heal_on_kill, false, true],
	])
	return lines


func _add_stat_group(lines: PackedStringArray, title: String, stats: Array) -> void:
	var group_lines: PackedStringArray = []
	for stat in stats:
		var label: String = stat[0]
		var value: float = stat[1]
		var invert: bool = stat[2] if stat.size() > 2 else false
		var additive: bool = stat[3] if stat.size() > 3 else false
		if additive:
			if is_equal_approx(value, 0.0):
				continue
			var sign: String = "+" if value >= 0.0 else ""
			group_lines.append("  %s %s%.1f" % [label, sign, value])
		elif label == "Lifesteal":
			if is_equal_approx(value, 0.0):
				continue
			group_lines.append("  %s +%.0f%%" % [label, value * 100.0])
		else:
			if is_equal_approx(value, 1.0):
				continue
			if invert:
				var effective: float = 1.0 / maxf(value, 0.01)
				var pct: int = int(round((effective - 1.0) * 100.0))
				var sign: String = "+" if pct >= 0 else ""
				group_lines.append("  %s %s%d%%" % [label, sign, pct])
			else:
				var pct: int = int(round((value - 1.0) * 100.0))
				var sign: String = "+" if pct >= 0 else ""
				group_lines.append("  %s %s%d%%" % [label, sign, pct])
	if group_lines.size() > 0:
		lines.append("[b]%s[/b]" % title)
		lines.append_array(group_lines)

# ─────────────────────────────────────────────
#  Randomize / Confirm
# ─────────────────────────────────────────────

func _get_selected_team() -> Player.Team:
	match _team_option.selected:
		0:  return Player.Team.FFA
		1:  return Player.Team.SPI
		2:  return Player.Team.SCI
	return Player.Team.FFA


func _on_randomize_once_pressed() -> void:
	if selected_class == null:
		return
	_randomize_column("primary", selected_class.primary_weapons)
	_randomize_column("secondary", selected_class.secondary_weapons)
	_randomize_column("melee", selected_class.melee_weapons)


func _randomize_column(key: String, weapons: Array[Weapon]) -> void:
	if weapons.is_empty():
		return
	var list: VBoxContainer = _column_lists.get(key)
	if list == null or list.get_child_count() == 0:
		return
	var idx := randi() % weapons.size()
	if idx >= 0 and idx < list.get_child_count():
		var card: Button = list.get_child(idx) as Button
		_select_card(card)


func _on_confirm_pressed() -> void:
	if selected_class == null or selected_character == null:
		return
	if selected_primary == null or selected_secondary == null or selected_melee == null:
		return

	var team := _get_selected_team()
	var rand_on_death := _randomize_on_death_check.button_pressed
	var character_path := selected_character.resource_path

	# Hide our canvas (don't free — user can re-open with H later).
	visible = false  # triggers _process() → _canvas.visible = false

	world.class_selected = true
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if multiplayer.is_server():
		_request_loadout(player_id, selected_primary.resource_path, selected_secondary.resource_path, selected_melee.resource_path, team, character_path, selected_class.resource_path, rand_on_death)
	else:
		_request_loadout.rpc_id(1, player_id, selected_primary.resource_path, selected_secondary.resource_path, selected_melee.resource_path, team, character_path, selected_class.resource_path, rand_on_death)

# ─────────────────────────────────────────────
#  RPCs (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _request_loadout(tpid: String, pp: String, sp: String, mp: String, team: Player.Team, cp: String = "", class_path := "", rand_on_death := false) -> void:
	if not multiplayer.is_server():
		return
	var sid := multiplayer.get_remote_sender_id()
	if sid != 0 and str(sid) != tpid and not tpid.begins_with("bot_"):
		return
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if primary == null or secondary == null or melee == null:
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	ctrl.set_weapons(nw)
	ctrl.current_weapon_index = 0
	player.team = team
	# Apply character.
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			player.set_character(char_res)
			player._loadout_character_path = cp
	# Store paths so late-joining peers can be synced.
	player._loadout_primary_path = pp
	player._loadout_secondary_path = sp
	player._loadout_melee_path = mp
	player._loadout_class_path = class_path
	player.set_randomize_on_death(rand_on_death)
	_apply_loadout.rpc(tpid, pp, sp, mp, team, cp)
	player.rpc_reset.rpc(player._get_spawn_position())

@rpc("authority", "call_remote", "reliable")
func _apply_loadout(tpid: String, pp: String, sp: String, mp: String, team: Player.Team, cp: String = "") -> void:
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if primary == null or secondary == null or melee == null:
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	ctrl.set_weapons(nw)
	ctrl.current_weapon_index = 0
	player.team = team
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			player.set_character(char_res)
			player._loadout_character_path = cp

# ─────────────────────────────────────────────
#  Tiny helpers (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

func _panel_container() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.85)
	style.border_color = Color(0.30, 0.32, 0.38, 1)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	return l


func _title() -> Label:
	var l := Label.new()
	l.text = "—  LOADOUT  —"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_font_size_override("font_size", 30)
	l.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	return l


func _sep() -> ColorRect:
	var c := ColorRect.new()
	c.custom_minimum_size = Vector2(0, 2)
	c.color = Color(0.35, 0.35, 0.35, 0.5)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _opt() -> OptionButton:
	var o := OptionButton.new()
	o.add_theme_font_size_override("font_size", 18)
	o.custom_minimum_size = Vector2(120, 32)
	return o


func _labeled(text: String, child: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = text
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl.custom_minimum_size = Vector2(52, 0)
	row.add_child(lbl)
	row.add_child(child)
	return row


func _stat_label() -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.add_theme_font_size_override("normal_font_size", 13)
	rtl.add_theme_color_override("default_color", Color(0.82, 0.82, 0.82))
	return rtl


func _populate_mode_info() -> void:
	if not _mode_label:
		return
	_mode_label.text = _get_mode_description()


func _get_mode_description() -> String:
	var gmc: GameModeComponent = GameManager.game_mode_component
	if not gmc:
		return ""
	match gmc.game_mode:
		GameModeComponent.GameMode.KOTH:
			return "King of the Hill -- Hold the point to win"
		GameModeComponent.GameMode.CONTROL:
			return "Control -- Best of 3, hold the point"
		GameModeComponent.GameMode.DOMINATION:
			return "Domination -- Hold the most points to score"
		GameModeComponent.GameMode.ESCORT:
			return "Escort -- Push the payload to the end"
		GameModeComponent.GameMode.HYBRID:
			return "Hybrid -- Capture the point, then escort"
		GameModeComponent.GameMode.DEATHMATCH:
			return "Deathmatch -- First to 20 kills wins"
		_:
			return ""
