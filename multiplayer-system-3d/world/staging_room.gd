extends CanvasLayer

const Protocol := preload("res://network/session_protocol.gd")

## Pre-match staging screen.
##
## This is a local CanvasLayer (never replicated) shown by world_1 while the
## match session is in STAGING/COUNTDOWN/LOADING, or while a client is waiting
## to JOIN IN PROGRESS.  The staging map itself remains main_menu_world.tscn.

const BLUE := Color(0.35, 0.65, 1.0, 1.0)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.97)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const TEXT := Color(0.9, 0.9, 0.9)
const DIM := Color(0.0, 0.02, 0.06, 0.82)

var world: Node = null
var _join_mode := false
var _title: Label
var _subtitle: Label
var _roster: Label
var _phase_label: Label
var _start_btn: Button
var _join_btn: Button
var _add_bot_btn: Button
var _ready_btn: Button
var _team_btn: Button
var _map_picker: OptionButton
var _map_datas: Array[MapData] = []
var _timer: Timer
var _selected_map_path := ""


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


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(900, 620)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(2)
	style.content_margin_left = 24
	style.content_margin_top = 18
	style.content_margin_right = 24
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	_title = Label.new()
	_title.text = "STAGING ROOM"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(_title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 18)
	_subtitle.add_theme_color_override("font_color", BLUE)
	vb.add_child(_subtitle)

	_phase_label = Label.new()
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_label.add_theme_font_size_override("font_size", 16)
	_phase_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.3))
	vb.add_child(_phase_label)

	var roster_header := Label.new()
	roster_header.text = "PLAYERS"
	roster_header.add_theme_font_size_override("font_size", 16)
	roster_header.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(roster_header)

	_roster = Label.new()
	_roster.custom_minimum_size = Vector2(0, 300)
	_roster.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_roster.add_theme_font_size_override("font_size", 16)
	_roster.add_theme_color_override("font_color", TEXT)
	vb.add_child(_roster)

	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 8)
	vb.add_child(map_row)
	var map_lbl := Label.new()
	map_lbl.text = "MAP"
	map_lbl.add_theme_font_size_override("font_size", 14)
	map_row.add_child(map_lbl)
	_map_picker = OptionButton.new()
	_map_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_picker.item_selected.connect(_on_map_selected)
	map_row.add_child(_map_picker)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	vb.add_child(bottom)

	_add_bot_btn = Button.new()
	_add_bot_btn.text = "ADD BOT"
	_add_bot_btn.pressed.connect(_on_add_bot)
	bottom.add_child(_add_bot_btn)

	_ready_btn = Button.new()
	_ready_btn.text = "READY"
	_ready_btn.pressed.connect(_on_ready)
	bottom.add_child(_ready_btn)

	_team_btn = Button.new()
	_team_btn.text = "SWITCH TEAM"
	_team_btn.pressed.connect(_on_switch_team)
	bottom.add_child(_team_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)

	_join_btn = Button.new()
	_join_btn.text = "JOIN IN PROGRESS"
	_join_btn.pressed.connect(_on_join_in_progress)
	bottom.add_child(_join_btn)

	var leave_btn := Button.new()
	leave_btn.text = "LEAVE MATCH"
	leave_btn.pressed.connect(_on_leave)
	bottom.add_child(leave_btn)

	_start_btn = Button.new()
	_start_btn.text = "START GAME"
	_start_btn.add_theme_font_size_override("font_size", 18)
	_start_btn.pressed.connect(_on_start)
	bottom.add_child(_start_btn)


func open(world_node: Node, join_mode: bool) -> void:
	world = world_node
	_join_mode = join_mode
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_load_maps()
	_refresh()


func close() -> void:
	visible = false
	if not PlayerInput.ui_open:
		return
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_open() -> bool:
	return visible


func _load_maps() -> void:
	if not _map_datas.is_empty():
		return
	_map_datas = ConnectionUtils.scan_map_data()
	_map_picker.clear()
	for md in _map_datas:
		if md:
			var idx := _map_picker.item_count
			_map_picker.add_item("%s  -  %s" % [md.display_name, _mode_name(md.game_mode)])
			_map_picker.set_item_metadata(idx, md.map_scene_path)


func _mode_name(mode: int) -> String:
	match mode:
		GameModeComponent.GameMode.ESCORT: return "ESCORT"
		GameModeComponent.GameMode.DOMINATION: return "DOMINATION"
		GameModeComponent.GameMode.KOTH: return "KOTH"
		GameModeComponent.GameMode.HYBRID: return "HYBRID"
		GameModeComponent.GameMode.CONTROL: return "CONTROL"
		GameModeComponent.GameMode.DEATHMATCH: return "DEATHMATCH"
		_: return ""


func _refresh() -> void:
	if not visible:
		return
	var host := MatchSession.local_is_host()
	var path := MatchSession.target_map_path
	if path == "":
		path = GameManager.pending_match_map
	_selected_map_path = path
	_title.text = "MATCH IN PROGRESS" if _join_mode else "STAGING ROOM"
	_subtitle.text = _map_title(path)
	_phase_label.text = _phase_text()
	_roster.text = _roster_text(host)
	_start_btn.visible = host and not _join_mode
	_start_btn.disabled = MatchSession.phase != Protocol.Phase.STAGING
	_join_btn.visible = _join_mode and MatchSession.phase == Protocol.Phase.ACTIVE
	_add_bot_btn.visible = host and not _join_mode
	_add_bot_btn.disabled = MatchSession.phase != Protocol.Phase.STAGING
	_ready_btn.visible = not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
	_ready_btn.text = "UNREADY" if MatchSession.local_ready else "READY"
	_team_btn.visible = not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
	_map_picker.visible = host and not _join_mode and MatchSession.phase == Protocol.Phase.STAGING
	_map_picker.disabled = MatchSession.phase != Protocol.Phase.STAGING
	_sync_map_picker(path)


func _phase_text() -> String:
	match MatchSession.phase:
		Protocol.Phase.STAGING: return "Waiting for the host to start."
		Protocol.Phase.COUNTDOWN: return "Match starting in 5..."
		Protocol.Phase.LOADING: return "Loading map..."
		Protocol.Phase.ACTIVE: return "Match in progress."
		Protocol.Phase.RESULTS: return "Match over."
		_: return ""


func _map_title(path: String) -> String:
	for md in _map_datas:
		if md and md.map_scene_path == path:
			return "%s  -  %s" % [md.display_name, _mode_name(md.game_mode)]
	if path != "":
		return path.get_file().get_basename()
	return "No map selected"


func _roster_text(host: bool) -> String:
	var lines: PackedStringArray = []
	if not is_instance_valid(GameManager.spawn_parent):
		return "No players."
	for child in GameManager.spawn_parent.get_children():
		if not child is Player:
			continue
		var p := child as Player
		var tag := "BOT" if p.is_bot else ""
		var crown := " [HOST]" if MatchSession.is_player_host(str(p.name).to_int()) else ""
		var ready := " [READY]" if MatchSession.is_ready(str(p.name).to_int()) else ""
		lines.append("%s   %s   %s%s%s" % [p.name, _team_name(p.team), tag, crown, ready])
	return "\n".join(lines) if not lines.is_empty() else "No players."


func _team_name(team: int) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return "FFA"


func _sync_map_picker(path: String) -> void:
	if path == "":
		return
	for i in _map_picker.item_count:
		if str(_map_picker.get_item_metadata(i)) == path:
			if _map_picker.selected != i:
				_map_picker.select(i)
			return


func _on_map_selected(index: int) -> void:
	var path := str(_map_picker.get_item_metadata(index))
	if path == "":
		return
	if multiplayer.is_server():
		MatchSession.set_staging_map(path)
	else:
		MatchSession.request_set_staging_map.rpc_id(1, path)


func _on_add_bot() -> void:
	if multiplayer.is_server():
		if GameManager.spawn_manager:
			GameManager.spawn_manager.add_bot(Player.Team.FFA)
	else:
		MatchSession.request_add_bot.rpc_id(1, Player.Team.FFA)
	_refresh()


func _on_ready() -> void:
	MatchSession.set_local_ready(not MatchSession.local_ready)
	_refresh()


func _on_switch_team() -> void:
	if multiplayer.is_server():
		var p := GameManager.find_player(MatchSession.local_id_string())
		if p:
			match p.team:
				Player.Team.SPI: p.team = Player.Team.SCI
				Player.Team.SCI: p.team = Player.Team.SPI
				_: pass
	else:
		MatchSession.request_switch_team.rpc_id(1, MatchSession.local_player_id)
	_refresh()


func _on_start() -> void:
	var path := MatchSession.target_map_path
	if path == "":
		path = GameManager.pending_match_map
	if path == "":
		_phase_label.text = "Select a map first."
		return
	if multiplayer.is_server():
		NetworkManager.start_staging_match(path)
	else:
		MatchSession.request_start_match.rpc_id(1, path)


func _on_join_in_progress() -> void:
	if multiplayer.is_server():
		return
	MatchSession.request_join_in_progress.rpc_id(1, MatchSession.local_player_id)


func _on_leave() -> void:
	NetworkManager.return_to_lobby()
