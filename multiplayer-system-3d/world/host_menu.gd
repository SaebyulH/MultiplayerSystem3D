extends Node
class_name HostMenu
## Full-screen host-server menu (party leader only).
##
## Left: map select — a thumbnail + caps name/mode, click to open an in-place
## browser of maps grouped by game mode (blue dividers).  Right: team assignment
## (two drag-and-drop columns for team modes, or a single player list for FFA
## deathmatch).  Bottom: auto-fill toggle, add-bot buttons, start/close.
##
## Built in code onto a CanvasLayer (layer 2) so it is never replicated by the
## MultiplayerSpawner.  Mirrors the loadout menu / leaderboard styling: flat dark
## panels, no rounded corners, white text, blue section headers.

const TEAM_SIZE := 5
const FFA_TARGET := 8

# ── style tokens (match loadout_menu / game_menu / HUD) ───────────────
const BLUE := Color(0.35, 0.65, 1.0, 1)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const CARD_BG := Color(0.10, 0.11, 0.15, 1)
const CARD_BORDER := Color(0.30, 0.32, 0.38, 1)
const TEAM_SPI := Color(0.88, 0.24, 0.24)
const TEAM_SCI := Color(0.2, 0.6, 0.86)
const TEXT := Color(0.9, 0.9, 0.9)
const DIM := Color(0.0, 0.02, 0.06, 0.78)


var _canvas: CanvasLayer

var _map_datas: Array[MapData] = []
var _selected_map: MapData = null

var _map_image: TextureButton
var _map_name_label: Label
var _map_mode_label: Label
var _browser: PanelContainer
var _browser_list: VBoxContainer

var _assignment: Dictionary = {}   # player_id -> Player.Team
var _team_area: VBoxContainer

var _auto_fill: CheckBox


func _ready() -> void:
	_load_maps()
	_build()
	if _selected_map:
		_apply_selected_map()


# ─────────────────────────────────────────────────────────────
#  Public API (called by host_server_area.gd)
# ─────────────────────────────────────────────────────────────

func is_open() -> bool:
	return _canvas != null and _canvas.visible


func open() -> void:
	_auto_assign()
	_refresh_assignment_area()
	_canvas.visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func close() -> void:
	_canvas.visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


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
	panel.custom_minimum_size = Vector2(1120, 640)
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)

	var title := Label.new()
	title.text = "HOST SERVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color.WHITE)
	root.add_child(title)

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 16)
	root.add_child(row)

	row.add_child(_build_map_panel())
	row.add_child(_build_assignment_panel())

	root.add_child(_build_bottom_bar())


func _build_map_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.add_theme_constant_override("separation", 0)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	vb.add_child(_make_header("MAP SELECT"))

	# Fixed-size map view with an in-place browser overlay.
	var map_view := Control.new()
	map_view.custom_minimum_size = Vector2(400, 280)
	map_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_view.clip_contents = true
	vb.add_child(map_view)

	var content := VBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_theme_constant_override("separation", 8)
	map_view.add_child(content)

	_map_image = TextureButton.new()
	_map_image.custom_minimum_size = Vector2(0, 200)
	_map_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_image.ignore_texture_size = true
	_map_image.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_map_image.pressed.connect(_toggle_browser)
	content.add_child(_map_image)

	_map_name_label = Label.new()
	_map_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_name_label.add_theme_font_size_override("font_size", 22)
	_map_name_label.add_theme_color_override("font_color", Color.WHITE)
	content.add_child(_map_name_label)

	_map_mode_label = Label.new()
	_map_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_mode_label.add_theme_font_size_override("font_size", 16)
	_map_mode_label.add_theme_color_override("font_color", BLUE)
	content.add_child(_map_mode_label)

	# Browser overlay (hidden) — replaces the map view while open.
	_browser = PanelContainer.new()
	_browser.visible = false
	_browser.set_anchors_preset(Control.PRESET_FULL_RECT)
	_browser.add_theme_stylebox_override("panel", _panel_style())
	map_view.add_child(_browser)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_browser.add_child(scroll)

	_browser_list = VBoxContainer.new()
	_browser_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_browser_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_browser_list)

	_build_browser()

	return panel


func _build_assignment_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(600, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style())

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	vb.add_child(_make_header("TEAM ASSIGNMENT"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_team_area = VBoxContainer.new()
	_team_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_team_area.add_theme_constant_override("separation", 10)
	scroll.add_child(_team_area)

	return panel


func _build_bottom_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_auto_fill = CheckBox.new()
	_auto_fill.text = "AUTO-FILL WITH BOTS"
	_auto_fill.add_theme_font_size_override("font_size", 16)
	_auto_fill.add_theme_color_override("font_color", TEXT)
	bar.add_child(_auto_fill)

	var add_bot := Button.new()
	add_bot.text = "ADD BOT"
	add_bot.pressed.connect(_on_add_bot_pressed)
	bar.add_child(add_bot)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var start := Button.new()
	start.text = "START SERVER"
	start.add_theme_font_size_override("font_size", 18)
	start.pressed.connect(_on_start_pressed)
	bar.add_child(start)

	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.pressed.connect(close)
	bar.add_child(close_btn)

	return bar


# ─────────────────────────────────────────────────────────────
#  Map data & selection
# ─────────────────────────────────────────────────────────────

func _load_maps() -> void:
	_map_datas = ConnectionUtils.scan_map_data()
	_selected_map = null
	for m in _map_datas:
		if m.game_mode == GameModeComponent.GameMode.DEATHMATCH:
			_selected_map = m
			break
	if _selected_map == null and not _map_datas.is_empty():
		_selected_map = _map_datas[0]


func _apply_selected_map() -> void:
	_map_image.texture_normal = _selected_map.map_image
	_map_name_label.text = _selected_map.display_name.to_upper()
	_map_mode_label.text = _mode_name(_selected_map.game_mode)


func _select_map(data: MapData) -> void:
	var mode_changed := _selected_map == null or _selected_map.game_mode != data.game_mode
	_selected_map = data
	_apply_selected_map()
	_browser.visible = false
	if mode_changed:
		_auto_assign()
	_refresh_assignment_area()


func _toggle_browser() -> void:
	_browser.visible = not _browser.visible


func _mode_name(mode: int) -> String:
	match mode:
		GameModeComponent.GameMode.ESCORT: return "ESCORT"
		GameModeComponent.GameMode.DOMINATION: return "DOMINATION"
		GameModeComponent.GameMode.KOTH: return "KOTH"
		GameModeComponent.GameMode.HYBRID: return "HYBRID"
		GameModeComponent.GameMode.CONTROL: return "CONTROL"
		GameModeComponent.GameMode.DEATHMATCH: return "DEATHMATCH"
		_: return "UNKNOWN"


func _is_ffa(mode: int) -> bool:
	return mode == GameModeComponent.GameMode.DEATHMATCH


func _mode_order() -> Array:
	return [
		GameModeComponent.GameMode.DEATHMATCH,
		GameModeComponent.GameMode.ESCORT,
		GameModeComponent.GameMode.DOMINATION,
		GameModeComponent.GameMode.KOTH,
		GameModeComponent.GameMode.HYBRID,
		GameModeComponent.GameMode.CONTROL,
	]


func _build_browser() -> void:
	for child in _browser_list.get_children():
		child.queue_free()
	for mode in _mode_order():
		var maps: Array[MapData] = []
		for m in _map_datas:
			if m.game_mode == mode:
				maps.append(m)
		if maps.is_empty():
			continue
		_browser_list.add_child(_make_header(_mode_name(mode)))
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		for m in maps:
			grid.add_child(_make_map_card(m))
		_browser_list.add_child(grid)


func _make_map_card(m: MapData) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(180, 120)
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_select_map.bind(m))
	btn.add_theme_stylebox_override("normal", _card_style(CARD_BG, CARD_BORDER))
	btn.add_theme_stylebox_override("hover", _card_style(CARD_BG, BLUE))
	btn.add_theme_stylebox_override("pressed", _card_style(Color(0.15, 0.25, 0.35, 1), BLUE))

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 6.0
	vb.offset_top = 6.0
	vb.offset_right = -6.0
	vb.offset_bottom = -6.0
	vb.add_theme_constant_override("separation", 4)
	btn.add_child(vb)

	var img := TextureRect.new()
	img.texture = m.map_image
	img.custom_minimum_size = Vector2(0, 88)
	img.size_flags_vertical = Control.SIZE_EXPAND_FILL
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(img)

	var lbl := Label.new()
	lbl.text = m.display_name.to_upper()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", TEXT)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(lbl)

	return btn


# ─────────────────────────────────────────────────────────────
#  Roster & assignment
# ─────────────────────────────────────────────────────────────

func _get_players() -> Array:
	var out: Array = []
	if GameManager.spawn_parent == null:
		return out
	for child in GameManager.spawn_parent.get_children():
		if child is Player:
			out.append(child)
	return out


func _auto_assign() -> void:
	_assignment.clear()
	var players := _get_players()
	if _selected_map == null or _is_ffa(_selected_map.game_mode):
		for p in players:
			_assignment[p.name] = Player.Team.FFA
		return
	var sci := 0
	var spi := 0
	for p in players:
		if sci <= spi:
			_assignment[p.name] = Player.Team.SCI
			sci += 1
		else:
			_assignment[p.name] = Player.Team.SPI
			spi += 1


func _assign_player(player_id: String, team: Player.Team) -> void:
	_assignment[player_id] = team
	_refresh_assignment_area()


func _refresh_assignment_area() -> void:
	for child in _team_area.get_children():
		_team_area.remove_child(child)
		child.queue_free()

	# Safety net: cover any player added since last refresh.
	for p in _get_players():
		if not _assignment.has(p.name):
			_assignment[p.name] = Player.Team.FFA if (_selected_map == null or _is_ffa(_selected_map.game_mode)) else Player.Team.SCI

	if _selected_map == null or _is_ffa(_selected_map.game_mode):
		_team_area.add_child(_build_players_list())
		return

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	_team_area.add_child(row)

	var sci := _make_team_column(Player.Team.SCI, "TEAM SCI")
	var spi := _make_team_column(Player.Team.SPI, "TEAM SPI")
	row.add_child(sci)
	row.add_child(spi)

	for id in _assignment:
		var p := GameManager.find_player(id)
		if p == null:
			continue
		var team: Player.Team = _assignment[id]
		var card := _make_player_card(p, team)
		if team == Player.Team.SCI:
			sci.add_child(card)
		else:
			spi.add_child(card)


func _build_players_list() -> Control:
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	list.add_child(_make_team_header("FFA", Player.Team.FFA))
	for id in _assignment:
		var p := GameManager.find_player(id)
		if p == null:
			continue
		list.add_child(_make_player_card(p, Player.Team.FFA))
	return list


func _make_team_column(team: Player.Team, header: String) -> TeamColumn:
	var col := TeamColumn.new()
	col.team = team
	col.host_menu = self
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_STOP
	col.add_theme_constant_override("separation", 6)
	col.add_child(_make_team_header(header, team))
	return col


func _make_player_card(p: Player, team: Player.Team) -> PlayerCard:
	var card := PlayerCard.new()
	card.player_id = p.name
	card.team = team
	card.host_menu = self
	card.custom_minimum_size = Vector2(0, 36)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", _card_style(CARD_BG, CARD_BORDER))

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	card.add_child(hb)

	var portrait := TextureRect.new()
	if p._character:
		portrait.texture = p._character.portrait
	portrait.custom_minimum_size = Vector2(22, 22)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(portrait)

	var name_lbl := Label.new()
	name_lbl.text = p.name
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", TEXT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(name_lbl)

	return card


# ─────────────────────────────────────────────────────────────
#  Start / auto-fill / add bots
# ─────────────────────────────────────────────────────────────

func _on_start_pressed() -> void:
	if _selected_map == null or _selected_map.map_scene == null or not multiplayer.is_server():
		return

	# 1. Apply teams (replicated via the .:team MultiplayerSynchronizer).
	for id in _assignment:
		var p := GameManager.find_player(id)
		if p:
			p.team = _assignment[id]

	# 2. Auto-fill bots (ephemeral — not recorded to lobby_bots).
	if _auto_fill.button_pressed:
		_autofill_bots()

	close()
	NetworkManager.load_match_map(_selected_map.map_scene.resource_path)


func _autofill_bots() -> void:
	var sm := GameManager.spawn_manager
	if sm == null:
		return
	if _selected_map == null or _is_ffa(_selected_map.game_mode):
		for i in range(_count_team(Player.Team.FFA), FFA_TARGET):
			sm.add_autofill_bot(Player.Team.FFA)
	else:
		for i in range(_count_team(Player.Team.SCI), TEAM_SIZE):
			sm.add_autofill_bot(Player.Team.SCI)
		for i in range(_count_team(Player.Team.SPI), TEAM_SIZE):
			sm.add_autofill_bot(Player.Team.SPI)


func _count_team(team: Player.Team) -> int:
	var c := 0
	for id in _assignment:
		if _assignment[id] == team:
			c += 1
	return c


func _add_manual_bot(team: Player.Team) -> void:
	var sm := GameManager.spawn_manager
	if sm:
		var id := sm.add_bot(team)
		if id != "":
			_assignment[id] = team
	_refresh_assignment_area()


func _on_add_bot_pressed() -> void:
	var team := Player.Team.FFA
	if _selected_map and not _is_ffa(_selected_map.game_mode):
		team = Player.Team.SCI if _count_team(Player.Team.SCI) <= _count_team(Player.Team.SPI) else Player.Team.SPI
	_add_manual_bot(team)


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
	sb.content_margin_left = 6.0
	sb.content_margin_top = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_bottom = 6.0
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


func _make_team_header(text: String, team: Player.Team) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _header_style()
	style.bg_color = TEAM_SCI if team == Player.Team.SCI else (TEAM_SPI if team == Player.Team.SPI else Color(0.45, 0.45, 0.45))
	panel.add_theme_stylebox_override("panel", style)
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


# ─────────────────────────────────────────────────────────────
#  Drag-and-drop widgets
# ─────────────────────────────────────────────────────────────

class PlayerCard extends PanelContainer:
	var player_id: String = ""
	var team: int = Player.Team.FFA
	var host_menu: HostMenu = null

	func _get_drag_data(_position: Vector2) -> Variant:
		var preview := Label.new()
		preview.text = player_id
		set_drag_preview(preview)
		return { "player_id": player_id }

	func _can_drop_data(_position: Vector2, data: Variant) -> bool:
		return data is Dictionary and data.has("player_id")

	func _drop_data(_position: Vector2, data: Variant) -> void:
		host_menu._assign_player(data["player_id"], team)


class TeamColumn extends VBoxContainer:
	var team: int = Player.Team.SCI
	var host_menu: HostMenu = null

	func _can_drop_data(_position: Vector2, data: Variant) -> bool:
		return data is Dictionary and data.has("player_id")

	func _drop_data(_position: Vector2, data: Variant) -> void:
		host_menu._assign_player(data["player_id"], team)
