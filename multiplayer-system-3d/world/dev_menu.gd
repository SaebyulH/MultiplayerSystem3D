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
var _meters_check: CheckButton
var _noclip_check: CheckButton
var _ignore_bots_check: CheckButton
var _spectate_check: CheckButton
var _player_hud_check: CheckButton
var _world_hud_check: CheckButton
var _model_check: CheckButton
# Bots-tab widgets (server only).
var _freeze_bots_check: CheckButton
var _show_paths_check: CheckButton
var _randomize_skills_button: Button
var _remove_all_button: Button
var _team_buttons: Dictionary = {}   # Player.Team -> Button
var _team: Player.Team = Player.Team.FFA
## God mode is now mirrored to every peer (Player._sync_dev_god_mode), so this
## is only a fallback for a player without an AttributeComponent.
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
		_update_remove_all_enabled()
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

	# The panel is a fixed 780x560; the full toggle list no longer fits, so the
	# content scrolls rather than clipping the bottom rows.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 10)
	scroll.add_child(vb)

	vb.add_child(_section_header("HEALTH"))
	var health_row := HBoxContainer.new()
	health_row.add_theme_constant_override("separation", 8)
	vb.add_child(health_row)
	health_row.add_child(_dev_button("No Health", _set_health.bind(0.0)))
	health_row.add_child(_dev_button("Half Health", _set_health.bind(0.5)))
	health_row.add_child(_dev_button("Full Health", _set_health.bind(1.0)))
	health_row.add_child(_dev_button("Respawn now", _on_respawn))

	_god_check = _make_check("God mode (no damage taken)", _on_god_toggled)
	vb.add_child(_god_check)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_header("GAMEPLAY TOGGLES"))

	# Two columns keep the taller list inside the panel without scrolling for
	# most window sizes (the ScrollContainer is the safety net).
	var gameplay_grid := GridContainer.new()
	gameplay_grid.columns = 2
	gameplay_grid.add_theme_constant_override("h_separation", 18)
	vb.add_child(gameplay_grid)
	_cooldowns_check = _make_check("No ability cooldowns", _on_cooldowns_toggled)
	gameplay_grid.add_child(_cooldowns_check)
	_stamina_check = _make_check("No stamina cooldowns", _on_stamina_toggled)
	gameplay_grid.add_child(_stamina_check)
	_ammo_check = _make_check("Infinite ammo (all weapons)", _on_ammo_toggled)
	gameplay_grid.add_child(_ammo_check)
	_meters_check = _make_check("Infinite ability meters", _on_meters_toggled)
	gameplay_grid.add_child(_meters_check)
	_noclip_check = _make_check("Dev noclip (fly through walls)", _on_noclip_toggled)
	gameplay_grid.add_child(_noclip_check)
	_ignore_bots_check = _make_check("Bots ignore me", _on_ignore_bots_toggled)
	gameplay_grid.add_child(_ignore_bots_check)
	_spectate_check = _make_check("Spectator mode (not spawned)", _on_spectate_toggled)
	gameplay_grid.add_child(_spectate_check)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_header("DISPLAY (local only)"))

	var display_grid := GridContainer.new()
	display_grid.columns = 2
	display_grid.add_theme_constant_override("h_separation", 18)
	vb.add_child(display_grid)
	_player_hud_check = _make_check("Hide player HUD", _on_player_hud_toggled)
	display_grid.add_child(_player_hud_check)
	_world_hud_check = _make_check("Hide other HUD", _on_world_hud_toggled)
	display_grid.add_child(_world_hud_check)
	_model_check = _make_check("Hide my model (weapon stays)", _on_model_toggled)
	display_grid.add_child(_model_check)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_header("TEAM"))

	var team_row := HBoxContainer.new()
	team_row.add_theme_constant_override("separation", 8)
	vb.add_child(team_row)
	team_row.add_child(_make_team_button(Player.Team.SPI, "SPI"))
	team_row.add_child(_make_team_button(Player.Team.SCI, "SCI"))
	team_row.add_child(_make_team_button(Player.Team.FFA, "FFA"))

	var reset_btn := _dev_button("Reset all dev flags", _on_reset_dev_flags)
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(reset_btn)

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

	# Server-only world controls above the per-bot list.
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 8)
	tab.add_child(vb)

	var tools_row := HBoxContainer.new()
	tools_row.add_theme_constant_override("separation", 12)
	vb.add_child(tools_row)
	_freeze_bots_check = _make_check("Freeze all bots", _on_freeze_bots_toggled)
	tools_row.add_child(_freeze_bots_check)
	_show_paths_check = _make_check("Show nav paths", _on_show_bot_paths_toggled)
	_show_paths_check.tooltip_text = "Draw each bot's remaining route: green navmesh, orange partial, blue TravelGraph, red direct"
	tools_row.add_child(_show_paths_check)
	_randomize_skills_button = _dev_button(
		"Randomize bot skills", _on_randomize_bot_skills
	)
	_randomize_skills_button.tooltip_text = "Roll a new general skill and trait variance for every bot"
	tools_row.add_child(_randomize_skills_button)
	_remove_all_button = _dev_button("Remove all bots", _on_remove_all_bots)
	_remove_all_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tools_row.add_child(_remove_all_button)

	# build_into() adds a full-rect MarginContainer; this non-container host
	# gives it the space the VBox has left over.
	var panel_host := Control.new()
	panel_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(panel_host)

	_bot_panel = BOT_PANEL_SCENE.instantiate() as SpawnBotMenu
	add_child(_bot_panel)
	_bot_panel.build_into(panel_host)
	_bot_panel.edit_bot_requested.connect(_on_edit_bot_requested)
	_bot_panel.bots_changed.connect(_update_remove_all_enabled)
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
		# God mode is mirrored to every peer (see Player._sync_dev_god_mode), so
		# the client's copy is readable too; the cached value is only a fallback
		# for a player without an AttributeComponent.
		if p.attribute_component:
			_god_mode = p.attribute_component.dev_god_mode
		_team = p.team
		if p.ability_manager:
			_cooldowns_check.button_pressed = p.ability_manager.dev_no_cooldowns
			_meters_check.button_pressed = p.ability_manager.dev_no_meter_drain
		_stamina_check.button_pressed = p.dev_infinite_stamina
		if p.weapon_controller:
			_ammo_check.button_pressed = p.weapon_controller.is_dev_infinite_ammo()
		_noclip_check.button_pressed = p.dev_noclip
		_ignore_bots_check.button_pressed = p.dev_hidden_from_bots
		_spectate_check.button_pressed = p.is_spectating
		_model_check.button_pressed = p.dev_hide_model
	_player_hud_check.button_pressed = GameManager.dev_hide_player_hud
	_world_hud_check.button_pressed = GameManager.dev_hide_world_hud
	if _freeze_bots_check:
		_freeze_bots_check.button_pressed = GameManager.dev_freeze_bots
	if _show_paths_check:
		_show_paths_check.button_pressed = GameManager.dev_show_bot_paths
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


func _on_meters_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_no_meter_drain(on)


func _on_noclip_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_noclip(on)


func _on_ignore_bots_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_hidden_from_bots(on)


func _on_respawn() -> void:
	var p := _local_player()
	if p:
		p.dev_respawn()


func _on_player_hud_toggled(on: bool) -> void:
	if _syncing:
		return
	GameManager.dev_hide_player_hud = on
	# PlayerUI re-reads the flag in its next _process and repaints itself; no
	# direct call is needed (and the dev menu is a separate CanvasLayer, so it
	# stays visible either way).


func _on_world_hud_toggled(on: bool) -> void:
	if _syncing:
		return
	GameManager.dev_hide_world_hud = on
	_apply_world_hud_visibility()


func _on_spectate_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_spectating(on)
	# Close so the camera switch is visible immediately; close() restores mouse
	# capture (the spectator controller needs the cursor captured).
	if on:
		close()


func _on_model_toggled(on: bool) -> void:
	if _syncing:
		return
	var p := _local_player()
	if p:
		p.dev_set_hide_model(on)


func _apply_world_hud_visibility() -> void:
	var world := get_parent()
	if world and world.has_method("apply_dev_world_hud_visibility"):
		world.apply_dev_world_hud_visibility()


## Turn every cheat back off.  Recovery path for a hidden HUD/model, and a
## quicker reset than opening each tab and clicking.
func _on_reset_dev_flags() -> void:
	var p := _local_player()
	if p:
		p.dev_set_god_mode(false)
		p.dev_set_no_cooldowns(false)
		p.dev_set_infinite_stamina(false)
		p.dev_set_infinite_ammo(false)
		p.dev_set_no_meter_drain(false)
		p.dev_set_noclip(false)
		p.dev_set_hidden_from_bots(false)
		p.dev_set_spectating(false)
		p.dev_set_hide_model(false)
	GameManager.dev_hide_player_hud = false
	GameManager.dev_hide_world_hud = false
	GameManager.dev_freeze_bots = false
	GameManager.dev_show_bot_paths = false
	_apply_world_hud_visibility()
	_refresh_state()


# ─────────────────────────────────────────────────────────────
#  Bots tab: world controls
# ─────────────────────────────────────────────────────────────

func _on_freeze_bots_toggled(on: bool) -> void:
	if _syncing:
		return
	GameManager.dev_freeze_bots = on


func _on_show_bot_paths_toggled(on: bool) -> void:
	if _syncing:
		return
	GameManager.dev_show_bot_paths = on


func _on_randomize_bot_skills() -> void:
	if not multiplayer.is_server() or _bot_panel == null:
		return
	_bot_panel.randomize_bot_skills()


func _on_remove_all_bots() -> void:
	if not multiplayer.is_server():
		return
	var sm := GameManager.spawn_manager
	if sm:
		sm.remove_all_bots()
	if _bot_panel:
		_bot_panel.refresh()
	_update_remove_all_enabled()


func _has_bots() -> bool:
	if not is_instance_valid(GameManager.spawn_parent):
		return false
	for child in GameManager.spawn_parent.get_children():
		if child is Player and (child as Player).is_bot and not child.is_queued_for_deletion():
			return true
	return false


func _update_remove_all_enabled() -> void:
	var has_bots := _has_bots()
	if _remove_all_button:
		_remove_all_button.disabled = not has_bots
	if _randomize_skills_button:
		_randomize_skills_button.disabled = not has_bots


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
