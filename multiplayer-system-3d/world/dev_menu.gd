extends Node
class_name DevMenu

## Developer hacks menu (bound to the `0` key).  Two tabs:
##   General — self-targeted health/god/cooldown/stamina/ammo/team hacks.
##   Bots    — the old spawn-bot menu, plus per-bot loadout editing.  Server
##             (party leader) only; shown disabled on clients.
##
## Created by world_1.gd and parented to the world (never under SpawnParent, so
## it is not replicated).  Built in code, matching the rest of the menus.
##
## Authority split (see docs/02-netcode.md):
##   health / team / god  -> server-authoritative, requested via Player RPCs
##   cooldowns / ammo     -> per-peer; the local copy plus the server's copy
##   stamina              -> rollback state, broadcast to every peer
## The menu only ever targets the local player; bots are edited on the server.

const BOT_PANEL_SCENE := preload("res://world/spawn_bot_menu.tscn")

const BLUE := Color(0.35, 0.65, 1.0, 1)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const CARD_BG := Color(0.10, 0.11, 0.15, 1)
const CARD_BORDER := Color(0.30, 0.32, 0.38, 1)
const TEXT := Color(0.9, 0.9, 0.9)
const DIM := Color(0.0, 0.02, 0.06, 0.78)

var _canvas: CanvasLayer
var _tabs: TabContainer
var _loadout_menu: LoadoutMenuUI
var _bot_panel: SpawnBotMenu
var _is_open := false

# General-tab widgets.
var _god_check: CheckButton
var _cooldowns_check: CheckButton
var _stamina_check: CheckButton
var _ammo_check: CheckButton
var _team_buttons: Dictionary = {}   # Player.Team -> Button
var _team: Player.Team = Player.Team.FFA
## God mode is a server-only flag that is not mirrored to clients, so the menu
## keeps its own copy of the UI state (the other toggles are readable locally).
var _god_mode := false
## Suppresses the CheckButton.toggled handlers while the UI is being synced.
var _syncing := false


func _ready() -> void:
	_build()


## Called once by world_1.gd after the world's LoadoutMenu exists.
func setup(loadout_menu: LoadoutMenuUI) -> void:
	_loadout_menu = loadout_menu
	if _loadout_menu and not _loadout_menu.bot_edit_finished.is_connected(_on_bot_edit_finished):
		_loadout_menu.bot_edit_finished.connect(_on_bot_edit_finished)


func is_open() -> bool:
	return _is_open


func toggle() -> void:
	if _is_open:
		close()
	elif not PlayerInput.ui_open:
		open()


func open() -> void:
	if _is_open or PlayerInput.ui_open:
		return
	_is_open = true
	_refresh_state()
	if _bot_panel and multiplayer.is_server():
		_bot_panel.refresh()
	_canvas.visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func close() -> void:
	if not _is_open:
		return
	# The loadout screen is editing a bot: cancel that first and come back to
	# the Bots tab (bot_edit_finished re-shows this menu).  A second press
	# closes the dev menu.
	if _loadout_menu and _loadout_menu.bot_edit_mode:
		_loadout_menu.visible = false
		return
	_is_open = false
	_canvas.visible = false
	var other_menu_open := _loadout_menu != null and _loadout_menu.visible
	PlayerInput.ui_open = other_menu_open
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if other_menu_open else Input.MOUSE_MODE_CAPTURED)


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
	panel.custom_minimum_size = Vector2(780, 560)
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "DEV HACKS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(title)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	vb.add_child(_tabs)

	_tabs.add_child(_build_general_tab())
	_tabs.add_child(_build_bots_tab())

	if not multiplayer.is_server():
		_tabs.set_tab_title(1, "Bots (leader only)")
		_tabs.set_tab_disabled(1, true)

	var hint := Label.new()
	hint.text = "0 / Esc to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	vb.add_child(hint)


func _build_general_tab() -> Control:
	var margin := MarginContainer.new()
	margin.name = "General"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	vb.add_child(_section_header("HEALTH"))
	var health_row := HBoxContainer.new()
	health_row.add_theme_constant_override("separation", 8)
	vb.add_child(health_row)
	health_row.add_child(_dev_button("No Health", _set_health.bind(0.0)))
	health_row.add_child(_dev_button("Half Health", _set_health.bind(0.5)))
	health_row.add_child(_dev_button("Full Health", _set_health.bind(1.0)))

	_god_check = _make_check("God mode (no damage taken)", _on_god_toggled)
	vb.add_child(_god_check)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_header("TOGGLES"))

	_cooldowns_check = _make_check("No ability cooldowns", _on_cooldowns_toggled)
	vb.add_child(_cooldowns_check)
	_stamina_check = _make_check("No stamina cooldowns", _on_stamina_toggled)
	vb.add_child(_stamina_check)
	_ammo_check = _make_check("Infinite ammo (all weapons)", _on_ammo_toggled)
	vb.add_child(_ammo_check)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_header("TEAM"))

	var team_row := HBoxContainer.new()
	team_row.add_theme_constant_override("separation", 8)
	vb.add_child(team_row)
	team_row.add_child(_make_team_button(Player.Team.SPI, "SPI"))
	team_row.add_child(_make_team_button(Player.Team.SCI, "SCI"))
	team_row.add_child(_make_team_button(Player.Team.FFA, "FFA"))

	return margin


func _build_bots_tab() -> Control:
	var tab := Control.new()
	tab.name = "Bots"

	if not multiplayer.is_server():
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		tab.add_child(center)
		var lbl := Label.new()
		lbl.text = "Only the party leader can manage bots."
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		center.add_child(lbl)
		return tab

	_bot_panel = BOT_PANEL_SCENE.instantiate() as SpawnBotMenu
	add_child(_bot_panel)
	_bot_panel.build_into(tab)
	_bot_panel.edit_bot_requested.connect(_on_edit_bot_requested)
	return tab


# ─────────────────────────────────────────────────────────────
#  General-tab actions
# ─────────────────────────────────────────────────────────────

func _local_player() -> Player:
	return GameManager.find_player(str(multiplayer.get_unique_id()))


func _refresh_state() -> void:
	var p := _local_player()
	_syncing = true
	if p:
		# On the host the real god flag is readable; on a client it lives only on
		# the server's copy, so keep the menu's remembered value.
		if multiplayer.is_server() and p.attribute_component:
			_god_mode = p.attribute_component.dev_god_mode
		_team = p.team
		if p.ability_manager:
			_cooldowns_check.button_pressed = p.ability_manager.dev_no_cooldowns
		_stamina_check.button_pressed = p.dev_infinite_stamina
		if p.weapon_controller:
			_ammo_check.button_pressed = p.weapon_controller.is_dev_infinite_ammo()
	_god_check.button_pressed = _god_mode
	_syncing = false
	_update_team_buttons()


func _set_health(frac: float) -> void:
	var p := _local_player()
	if p:
		p.dev_set_health_fraction(frac)


func _on_god_toggled(on: bool) -> void:
	if _syncing:
		return
	_god_mode = on
	var p := _local_player()
	if p:
		p.dev_set_god_mode(on)


func _on_cooldowns_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_no_cooldowns(on)


func _on_stamina_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_infinite_stamina(on)


func _on_ammo_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_infinite_ammo(on)


func _make_team_button(team: Player.Team, text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 16)
	btn.pressed.connect(_set_team.bind(team))
	_team_buttons[team] = btn
	return btn


func _set_team(team: Player.Team) -> void:
	_team = team
	_update_team_buttons()
	var p := _local_player()
	if p:
		p.dev_set_team(team)


func _update_team_buttons() -> void:
	for team in _team_buttons:
		var btn: Button = _team_buttons[team]
		var selected: bool = team == _team
		var bg := Color(0.15, 0.25, 0.35, 1) if selected else CARD_BG
		var border := BLUE if selected else CARD_BORDER
		btn.add_theme_stylebox_override("normal", _box(bg, border))
		btn.add_theme_stylebox_override("hover", _box(bg, BLUE))
		btn.add_theme_stylebox_override("pressed", _box(bg, border))


# ─────────────────────────────────────────────────────────────
#  Bots tab
# ─────────────────────────────────────────────────────────────

func _on_tab_changed(index: int) -> void:
	if index == 1 and _bot_panel:
		_bot_panel.refresh()


func _on_edit_bot_requested(bot_name: String) -> void:
	if not multiplayer.is_server() or _loadout_menu == null:
		return
	# Open first: if the bot vanished between the row click and here, the
	# loadout screen refuses and this menu must stay visible.
	if not _loadout_menu.open_for_bot(bot_name):
		if _bot_panel:
			_bot_panel.refresh()
		return
	# Hide (don't close): ui_open stays true for the loadout screen, and
	# bot_edit_finished brings this menu back.
	_canvas.visible = false


func _on_bot_edit_finished() -> void:
	if not _is_open:
		return
	_tabs.current_tab = 1
	_canvas.visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if _bot_panel:
		_bot_panel.refresh()


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


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.content_margin_left = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_right = 8.0
	sb.content_margin_bottom = 6.0
	return sb


func _section_header(text: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = BLUE
	sb.content_margin_left = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_right = 8.0
	sb.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_font_size_override("font_size", 15)
	panel.add_child(lbl)
	return panel


func _dev_button(text: String, handler: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 16)
	btn.pressed.connect(handler)
	return btn


func _make_check(text: String, handler: Callable) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = text
	cb.add_theme_font_size_override("font_size", 16)
	cb.toggled.connect(handler)
	return cb
