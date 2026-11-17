extends CanvasLayer

const Protocol := preload("res://network/session_protocol.gd")

## Pre-match staging screen ("agent select").
##
## This is a local CanvasLayer (never replicated) shown by world_1 while the
## match session is in STAGING/COUNTDOWN/LOADING, or while a client is waiting
## to JOIN IN PROGRESS.  The staging map itself remains main_menu_world.tscn.
##
## Layout: current map thumbnail as a full-screen backdrop, the map picker and
## briefing on top, three team columns with portrait roster cards, and a
## character strip at the bottom.  Picking a character applies the loadout
## immediately; LOCK IN is the READY flag.

const COLUMN_WIDTH := 300
const AGENT_CARD_SIZE := Vector2(92, 124)
const MAP_CARD_SIZE := Vector2(176, 128)

var world: Node = null
var _join_mode := false

var _bg_art: TextureRect
var _map_name: Label
var _map_meta: Label
var _phase_label: Label
var _match_info: Label
var _leave_btn: Button
var _start_btn: Button
var _join_btn: Button
var _lock_btn: Button
var _edit_loadout_btn: Button
var _map_preview: TextureRect
var _map_grid: HBoxContainer
var _map_scroll: ScrollContainer
var _map_grid_panel: PanelContainer
var _agent_panel: PanelContainer
var _agent_strip: HBoxContainer
var _agent_strip_scroll: ScrollContainer

var _team_columns: Dictionary = {}      # ["team"] -> { "root": PanelContainer, "list": VBoxContainer,
										#   "count": Label, "join": Button, "add": Button }
var _roster_signature := ""
var _map_buttons: Dictionary = {}       # map_scene_path -> Button
var _selected_map_path := ""
var _selected_character_path := ""
var _char_buttons: Dictionary = {}      # character path -> Button
var _char_classes: Dictionary = {}      # character path -> Class
var _agent_signature := ""

var _map_datas: Array[MapData] = []
var _timer: Timer


func _ready() -> void:
	layer = 5
	visible = false
	_build()
	_timer = Timer.new()
	_timer.wait_time = 0.25
	_timer.one_shot = false
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_timer.start()


# ─────────────────────────────────────────────
#  Build
# ─────────────────────────────────────────────

func _build() -> void:
	# Opaque base first: the staging screen is a 2D UI.  The player's 3D body
	# and the current staging map must never show through the gaps between
	# panels.  The thumbnail is then drawn over the base and dimmed by the scrim.
	var base := ColorRect.new()
	base.color = UITheme.INK
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(base)

	_bg_art = TextureRect.new()
	_bg_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_art.modulate = Color(1, 1, 1, 0.5)
	_bg_art.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg_art)

	var scrim := ColorRect.new()
	scrim.color = Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.72)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)

	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("margin_left", 40)
	frame.add_theme_constant_override("margin_right", 40)
	frame.add_theme_constant_override("margin_top", 20)
	frame.add_theme_constant_override("margin_bottom", 18)
	add_child(frame)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	frame.add_child(vb)

	vb.add_child(_build_header())
	vb.add_child(UITheme.accent_bar(UITheme.RED, 2))
	vb.add_child(_build_map_row())
	vb.add_child(_build_roster_row())
	_agent_panel = _build_agent_panel()
	vb.add_child(_agent_panel)
	vb.add_child(_build_actions())


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(left)
	_map_name = UITheme.display_label("STAGING", 38, UITheme.TEXT)
	left.add_child(_map_name)
	_map_meta = UITheme.section_label("", UITheme.TEAL)
	left.add_child(_map_meta)

	var mid := VBoxContainer.new()
	mid.add_theme_constant_override("separation", 0)
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_child(mid)
	_match_info = UITheme.body_label("", UITheme.FS_SMALL, UITheme.MUTED)
	_match_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(_match_info)
	_phase_label = UITheme.section_label("", UITheme.AMBER)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(_phase_label)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_child(right)
	_leave_btn = Button.new()
	_leave_btn.text = "LEAVE"
	_leave_btn.pressed.connect(_on_leave)
	right.add_child(_leave_btn)
	return header


func _build_map_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var preview_panel := PanelContainer.new()
	preview_panel.add_theme_stylebox_override("panel",
		UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 8))
	preview_panel.custom_minimum_size = Vector2(300, 0)
	row.add_child(preview_panel)
	_map_preview = TextureRect.new()
	_map_preview.custom_minimum_size = Vector2(284, 158)
	_map_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	preview_panel.add_child(_map_preview)

	_map_grid_panel = PanelContainer.new()
	_map_grid_panel.add_theme_stylebox_override("panel",
		UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 8))
	_map_grid_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_map_grid_panel)
	var grid_vb := VBoxContainer.new()
	grid_vb.add_theme_constant_override("separation", 4)
	_map_grid_panel.add_child(grid_vb)
	var grid_header := HBoxContainer.new()
	grid_vb.add_child(grid_header)
	grid_header.add_child(UITheme.section_label("MAP SELECTION", UITheme.MUTED))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_header.add_child(fill)
	grid_header.add_child(UITheme.body_label("HOST ONLY", UITheme.FS_MICRO, UITheme.DIM_TEXT))

	_map_scroll = ScrollContainer.new()
	_map_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_map_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_map_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_vb.add_child(_map_scroll)
	_map_grid = HBoxContainer.new()
	_map_grid.add_theme_constant_override("separation", 8)
	_map_scroll.add_child(_map_grid)
	return row


func _build_roster_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for team in [Player.Team.SPI, Player.Team.SCI, Player.Team.FFA]:
		row.add_child(_build_team_column(team))
	return row


func _build_team_column(team: int) -> Control:
	var color := UITheme.team_color(team)
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(COLUMN_WIDTH, 170)
	panel.add_theme_stylebox_override("panel",
		UITheme.panel_style(Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.86), color, 1, 10))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vb.add_child(header)
	var title := UITheme.display_label(UITheme.team_name(team), 20, color)
	header.add_child(title)
	var count := UITheme.body_label("0", UITheme.FS_SMALL, UITheme.MUTED)
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(count)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(fill)

	var add := Button.new()
	add.text = "+ BOT"
	add.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	add.pressed.connect(_on_add_bot.bind(team))
	header.add_child(add)

	var join := Button.new()
	join.text = "JOIN"
	join.custom_minimum_size = Vector2(86, 0)
	join.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	join.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	join.add_theme_stylebox_override("normal", _team_join_style(false, color))
	join.add_theme_stylebox_override("hover", _team_join_style(true, color))
	join.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.SECONDARY, false, true))
	join.add_theme_stylebox_override("disabled", UITheme.button_style(UITheme.Kind.DISABLED))
	join.pressed.connect(_on_join_team.bind(team))
	header.add_child(join)

	vb.add_child(UITheme.accent_bar(color, 2))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	_team_columns[team] = {
		"root": panel, "list": list, "count": count, "join": join, "add": add,
		"header": title,
	}
	return panel


## Team-coloured outline for the JOIN button; the hover fill is the same accent
## at low alpha so the action reads even against the dark header.
func _team_join_style(hover: bool, color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	s.bg_color = Color(color.r, color.g, color.b, 0.18) if hover else Color(0, 0, 0, 0)
	s.border_color = color
	s.set_border_width_all(1)
	return s


func _build_agent_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.panel_style(Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.9), UITheme.LINE, 1, 10))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vb.add_child(header)
	header.add_child(UITheme.section_label("SELECT AGENT", UITheme.MUTED))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(fill)
	_edit_loadout_btn = Button.new()
	_edit_loadout_btn.text = "EDIT LOADOUT"
	_edit_loadout_btn.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_edit_loadout_btn.pressed.connect(_on_edit_loadout)
	header.add_child(_edit_loadout_btn)
	_lock_btn = Button.new()
	_lock_btn.text = "LOCK IN"
	_lock_btn.custom_minimum_size = Vector2(150, 34)
	_lock_btn.add_theme_font_override("font", UITheme.FONT_EXTRABOLD)
	_lock_btn.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.PRIMARY))
	_lock_btn.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.PRIMARY, true))
	_lock_btn.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.PRIMARY, false, true))
	_lock_btn.pressed.connect(_on_lock_in)
	header.add_child(_lock_btn)

	_agent_strip_scroll = ScrollContainer.new()
	_agent_strip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_agent_strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_agent_strip_scroll.custom_minimum_size = Vector2(0, AGENT_CARD_SIZE.y + 22)
	vb.add_child(_agent_strip_scroll)
	_agent_strip = HBoxContainer.new()
	_agent_strip.add_theme_constant_override("separation", 12)
	_agent_strip_scroll.add_child(_agent_strip)
	return panel


func _build_actions() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	_join_btn = Button.new()
	_join_btn.text = "JOIN IN PROGRESS"
	_join_btn.pressed.connect(_on_join_in_progress)
	row.add_child(_join_btn)

	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(fill)

	var hint := UITheme.body_label("Pick your agent, then LOCK IN.  The host starts the match.",
		UITheme.FS_MICRO, UITheme.DIM_TEXT)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(hint)

	_start_btn = Button.new()
	_start_btn.text = "START GAME"
	_start_btn.custom_minimum_size = Vector2(240, 46)
	_start_btn.add_theme_font_override("font", UITheme.FONT_EXTRABOLD)
	_start_btn.add_theme_font_size_override("font_size", 16)
	_start_btn.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.PRIMARY))
	_start_btn.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.PRIMARY, true))
	_start_btn.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.PRIMARY, false, true))
	_start_btn.pressed.connect(_on_start)
	row.add_child(_start_btn)
	return row


# ─────────────────────────────────────────────
#  Open / close
# ─────────────────────────────────────────────

func open(world_node: Node, join_mode: bool) -> void:
	world = world_node
	_join_mode = join_mode
	# The gameplay HUD and mode panel would otherwise show through the scrim.
	GameManager.suppress_gameplay_hud = true
	if world != null and world.has_method("apply_dev_world_hud_visibility"):
		world.apply_dev_world_hud_visibility()
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_load_maps()
	_build_map_grid()
	_rebuild_agent_strip()
	_roster_signature = ""
	refresh_now()


func close() -> void:
	visible = false
	GameManager.suppress_gameplay_hud = false
	if world != null and world.has_method("apply_dev_world_hud_visibility"):
		world.apply_dev_world_hud_visibility()
	if not PlayerInput.ui_open:
		return
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_open() -> bool:
	return visible


## The overlay can be freed with the world (return_to_lobby) without close()
## running.  GameManager outlives the scene, so clear the suppression here too.
func _exit_tree() -> void:
	GameManager.suppress_gameplay_hud = false


func refresh_now() -> void:
	_refresh()


# ─────────────────────────────────────────────
#  Maps
# ─────────────────────────────────────────────

func _load_maps() -> void:
	if not _map_datas.is_empty():
		return
	_map_datas = ConnectionUtils.scan_map_data()


func _build_map_grid() -> void:
	for child in _map_grid.get_children():
		_map_grid.remove_child(child)
		child.queue_free()
	_map_buttons.clear()
	for md in _map_datas:
		if md == null:
			continue
		var card := UITheme.map_card(md, false, MAP_CARD_SIZE)
		card.pressed.connect(_on_map_selected.bind(md.map_scene_path))
		_map_grid.add_child(card)
		_map_buttons[md.map_scene_path] = card


func _on_map_selected(path: String) -> void:
	if path == "":
		return
	if multiplayer.is_server():
		MatchSession.set_staging_map(path)
	else:
		MatchSession.request_set_staging_map.rpc_id(1, path)
	refresh_now()


func _highlight_selected_map(path: String) -> void:
	if path == _selected_map_path and not _map_preview.texture == null:
		return
	_selected_map_path = path
	for key in _map_buttons:
		var card: Button = _map_buttons[key]
		var selected: bool = key == path
		card.add_theme_stylebox_override("normal", UITheme.card_style(
			UITheme.State.SELECTED if selected else UITheme.State.NORMAL))
		card.add_theme_stylebox_override("hover", UITheme.card_style(
			UITheme.State.SELECTED if selected else UITheme.State.HOVER))
	var md := UITheme.map_data_for_path(path)
	if md:
		_map_preview.texture = md.map_image
		_bg_art.texture = md.map_image
		_map_name.text = md.display_name.to_upper()
		_map_meta.text = "%s  ·  %s" % [UITheme.mode_name(md.game_mode),
			UITheme.mode_description(md.game_mode)]
	elif path != "":
		_map_name.text = path.get_file().get_basename().to_upper()
		_map_meta.text = ""
	else:
		_map_name.text = "STAGING"
		_map_meta.text = "NO MAP SELECTED"


# ─────────────────────────────────────────────
#  Agents
# ─────────────────────────────────────────────

func _rebuild_agent_strip() -> void:
	for child in _agent_strip.get_children():
		_agent_strip.remove_child(child)
		child.queue_free()
	_char_buttons.clear()
	_char_classes.clear()

	var selected_path := _local_character_path()
	for entry in UITheme.characters_by_class():
		var cls: Class = entry["class"]
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 2)
		_agent_strip.add_child(group)
		var role := UITheme.section_label(cls.class_display_name, UITheme.TEAL)
		role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		group.add_child(role)
		var flow := HBoxContainer.new()
		flow.add_theme_constant_override("separation", 6)
		group.add_child(flow)
		for char_res in entry["characters"]:
			if char_res == null:
				continue
			var state := "selected" if char_res.resource_path == selected_path else "normal"
			var card := UITheme.character_card(char_res, cls, state, AGENT_CARD_SIZE)
			card.pressed.connect(_on_pick_character.bind(char_res, cls))
			flow.add_child(card)
			_char_buttons[char_res.resource_path] = card
			_char_classes[char_res.resource_path] = cls
		_selected_character_path = selected_path
		_agent_signature = selected_path


func _local_character_path() -> String:
	var player := GameManager.find_player(MatchSession.local_id_string())
	var char_res := UITheme.player_character(player)
	if char_res:
		return char_res.resource_path
	return str(GameManager.local_loadout.get("character_path", ""))


func _on_pick_character(char_res: Character, cls: Class) -> void:
	if _join_mode:
		return
	var build := LoadoutProfile.build_for_character(char_res, cls, GameManager.local_loadout)
	if build.is_empty():
		_phase_label.text = "That character's class has no complete weapon set."
		return
	if world != null and world.has_method("apply_local_loadout"):
		world.apply_local_loadout(build, false)
	elif multiplayer.is_server():
		LoadoutProfile.apply_to_player(
			GameManager.find_player(MatchSession.local_id_string()), build)
	_selected_character_path = char_res.resource_path
	_rebuild_agent_strip()
	_roster_signature = ""
	refresh_now()


func _on_edit_loadout() -> void:
	if world != null and world.has_method("open_loadout"):
		world.open_loadout(true)


func _on_lock_in() -> void:
	MatchSession.set_local_ready(not MatchSession.local_ready)
	refresh_now()


# ─────────────────────────────────────────────
#  Teams / bots
# ─────────────────────────────────────────────

func _on_join_team(team: int) -> void:
	if not _visible_teams(_target_map_path()).has(team):
		return
	if multiplayer.is_server():
		var player := GameManager.find_player(MatchSession.local_id_string())
		if player:
			player.team = team
	else:
		MatchSession.request_set_team.rpc_id(1, MatchSession.local_player_id, team)
	refresh_now()


func _on_add_bot(team: int) -> void:
	if not _visible_teams(_target_map_path()).has(team):
		return
	if multiplayer.is_server():
		if GameManager.spawn_manager:
			GameManager.spawn_manager.add_bot(team)
	else:
		MatchSession.request_add_bot.rpc_id(1, team)
	_roster_signature = ""
	refresh_now()


# ─────────────────────────────────────────────
#  Refresh
# ─────────────────────────────────────────────

func _refresh() -> void:
	if not visible:
		return
	var host := MatchSession.local_is_host()
	var path := _target_map_path()
	_normalize_teams_if_needed(path)
	_match_info.text = "%d PLAYER(S)  ·  %s" % [_player_count(), _map_title(path)]
	_phase_label.text = _phase_text()
	_start_btn.visible = host and not _join_mode
	_start_btn.disabled = MatchSession.phase != Protocol.Phase.STAGING or path == ""
	_join_btn.visible = _join_mode and MatchSession.phase == Protocol.Phase.ACTIVE
	_lock_btn.visible = not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
	_lock_btn.text = "UNLOCK" if MatchSession.local_ready else "LOCK IN"
	_edit_loadout_btn.visible = _lock_btn.visible
	_agent_panel.visible = not _join_mode
	_map_grid_panel.visible = host and not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
	_map_preview.visible = not _join_mode

	_highlight_selected_map(path)
	_refresh_teams(path)
	_refresh_roster(path)

	var local_path := _local_character_path()
	if local_path != _agent_signature:
		_rebuild_agent_strip()


func _player_count() -> int:
	if not is_instance_valid(GameManager.spawn_parent):
		return 0
	var count := 0
	for child in GameManager.spawn_parent.get_children():
		if child is Player:
			count += 1
	return count


func _phase_text() -> String:
	match MatchSession.phase:
		Protocol.Phase.STAGING:
			return "WAITING FOR HOST" if not MatchSession.local_is_host() else "READY WHEN YOU ARE"
		Protocol.Phase.COUNTDOWN: return "MATCH STARTING IN 5…"
		Protocol.Phase.LOADING: return "LOADING MAP…"
		Protocol.Phase.ACTIVE: return "MATCH IN PROGRESS"
		Protocol.Phase.RESULTS: return "MATCH OVER"
		_: return ""


func _target_map_path() -> String:
	var path := MatchSession.target_map_path
	if path == "":
		path = GameManager.pending_match_map
	return path


## Deathmatch is the only free-for-all mode; every other playable mode is
## SPI vs SCI.  With no map selected yet, default to the team layout — a
## three-team screen is never correct for a real match, and a deathmatch map
## switches the columns as soon as it is picked.
func _visible_teams(path: String) -> Array[int]:
	var md := UITheme.map_data_for_path(path) if path != "" else null
	if md != null and md.game_mode == GameModeComponent.GameMode.DEATHMATCH:
		return [int(Player.Team.FFA)]
	return [int(Player.Team.SPI), int(Player.Team.SCI)]


## Server-only: move anyone on a team the current mode does not use onto a valid
## team, balancing ties toward the first entry.  Runs every refresh but only
## writes when something is actually off, so it never fights a player's choice.
func _normalize_teams_if_needed(path: String) -> void:
	if not multiplayer.is_server() or not is_instance_valid(GameManager.spawn_parent):
		return
	var visible := _visible_teams(path)
	if visible.is_empty():
		return
	var counts: Dictionary = {}
	for team in visible:
		counts[team] = 0
	var invalid: Array[Player] = []
	for child in GameManager.spawn_parent.get_children():
		if not child is Player:
			continue
		var p := child as Player
		if counts.has(int(p.team)):
			counts[int(p.team)] += 1
		else:
			invalid.append(p)
	for p in invalid:
		var best: int = visible[0]
		for team in visible:
			if int(counts[team]) < int(counts[best]):
				best = team
		p.team = best
		counts[best] = int(counts[best]) + 1


func _map_title(path: String) -> String:
	var md := UITheme.map_data_for_path(path)
	if md:
		return md.display_name.to_upper()
	if path != "":
		return path.get_file().get_basename().to_upper()
	return "NO MAP SELECTED"


func _refresh_teams(path: String) -> void:
	var host := MatchSession.local_is_host() and not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
	var local := GameManager.find_player(MatchSession.local_id_string())
	var visible := _visible_teams(path)
	for team in _team_columns:
		var column: Dictionary = _team_columns[team]
		var used: bool = visible.has(int(team))
		(column["root"] as Control).visible = used
		(column["add"] as Button).visible = used and host
		var join: Button = column["join"]
		join.visible = used and not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
		join.disabled = local == null or local.team == team
		join.text = "CURRENT" if local != null and local.team == team else "JOIN"


func _refresh_roster(path: String) -> void:
	if not is_instance_valid(GameManager.spawn_parent):
		return
	var visible := _visible_teams(path)
	var by_team := {Player.Team.SPI: [], Player.Team.SCI: [], Player.Team.FFA: []}
	var signature_parts: PackedStringArray = []
	for child in GameManager.spawn_parent.get_children():
		if not child is Player:
			continue
		var p := child as Player
		var pid := str(p.name).to_int()
		var raw_team := p.team if by_team.has(p.team) else Player.Team.FFA
		# A player still on a mode-invalid team (first frame before the server
		# normalizes, or an old client) is shown in the first valid column rather
		# than vanishing.
		var display_team := raw_team if visible.has(int(raw_team)) else int(visible[0])
		by_team[display_team].append(p)
		signature_parts.append("%s|%d|%s|%s|%s" % [p.name, display_team,
			MatchSession.is_ready(pid), MatchSession.is_player_host(pid),
			p._loadout_character_path])
	var signature := "\n".join(signature_parts)
	if signature == _roster_signature:
		return
	_roster_signature = signature

	for team in _team_columns:
		var column: Dictionary = _team_columns[team]
		if not visible.has(int(team)):
			continue
		var list: VBoxContainer = column["list"]
		for child in list.get_children():
			list.remove_child(child)
			child.queue_free()
		var players: Array = by_team[team]
		(column["count"] as Label).text = str(players.size())
		if players.is_empty():
			var empty := UITheme.body_label("— NO PLAYERS —", UITheme.FS_MICRO, UITheme.DIM_TEXT)
			empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			empty.custom_minimum_size = Vector2(0, 30)
			list.add_child(empty)
			continue
		for p in players:
			var pid := str(p.name).to_int()
			list.add_child(UITheme.roster_card(p, MatchSession.is_player_host(pid),
				MatchSession.is_ready(pid), p.name == MatchSession.local_id_string(), team))


# ─────────────────────────────────────────────
#  Actions
# ─────────────────────────────────────────────

func _on_ready_toggle() -> void:
	_on_lock_in()


func _on_start() -> void:
	var path := _target_map_path()
	if path == "":
		_phase_label.text = "Select a map first."
		return
	if multiplayer.is_server():
		_normalize_teams_if_needed(path)
		NetworkManager.start_staging_match(path)
	else:
		MatchSession.request_start_match.rpc_id(1, path)


func _on_join_in_progress() -> void:
	if multiplayer.is_server():
		return
	MatchSession.request_join_in_progress.rpc_id(1, MatchSession.local_player_id)


func _on_leave() -> void:
	NetworkManager.return_to_lobby()
