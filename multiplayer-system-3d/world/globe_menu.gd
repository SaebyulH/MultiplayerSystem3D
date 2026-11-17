extends CanvasLayer

## Menu opened by the HostServer globe in the 3D lobby.
##
## This is the first implementation of the tabbed flow: START MATCH creates a
## match, FIND MATCH merges LAN and lobbyd entries, and PARTY is an explicit
## unavailable state until the party service lands.  No 3D content is changed.

const BLUE := Color(0.35, 0.65, 1.0, 1.0)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.97)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const DIM := Color(0.0, 0.02, 0.06, 0.82)

var _tabs: TabContainer
var _map_picker: OptionButton
var _match_name: LineEdit
var _lan_list: ItemList
var _status: Label
var _address: LineEdit
var _map_datas: Array[MapData] = []
var _busy := false


func _ready() -> void:
	layer = 3
	visible = false
	_load_maps()
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(960, 620)
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
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "MATCH MENU"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(title)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_tabs)
	_tabs.add_child(_build_start_tab())
	_tabs.add_child(_build_find_tab())
	_tabs.add_child(_build_party_tab())

	var close := Button.new()
	close.text = "CLOSE (Esc)"
	close.pressed.connect(close_menu)
	vb.add_child(close)


func _build_start_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Start Match"
	tab.add_theme_constant_override("separation", 12)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	tab.add_child(row)
	var lbl := Label.new()
	lbl.text = "MAP"
	lbl.add_theme_font_size_override("font_size", 16)
	row.add_child(lbl)
	_map_picker = OptionButton.new()
	_map_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for md in _map_datas:
		if md:
			var idx := _map_picker.item_count
			_map_picker.add_item("%s  -  %s" % [md.display_name, _mode_name(md.game_mode)])
			_map_picker.set_item_metadata(idx, md.map_scene_path)
	row.add_child(_map_picker)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	tab.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "MATCH NAME"
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_row.add_child(name_lbl)
	_match_name = LineEdit.new()
	_match_name.placeholder_text = "My Match"
	_match_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_match_name)

	var hint := Label.new()
	hint.text = ("Team assignment, bots, and START GAME are in the staging room. "
		+ "With no external lobby service this creates an in-process listen server.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	tab.add_child(hint)

	var create := Button.new()
	create.text = "CREATE MATCH"
	create.add_theme_font_size_override("font_size", 18)
	create.pressed.connect(_on_create_match)
	tab.add_child(create)
	return tab


func _build_find_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Find Match"
	tab.add_theme_constant_override("separation", 10)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	tab.add_child(row)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(_refresh_servers)
	row.add_child(refresh)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	row.add_child(_status)

	_lan_list = ItemList.new()
	_lan_list.custom_minimum_size = Vector2(0, 300)
	_lan_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(_lan_list)

	var join_btn := Button.new()
	join_btn.text = "JOIN SELECTED"
	join_btn.pressed.connect(_on_join_selected)
	tab.add_child(join_btn)

	var direct_row := HBoxContainer.new()
	direct_row.add_theme_constant_override("separation", 8)
	tab.add_child(direct_row)
	_address = LineEdit.new()
	_address.placeholder_text = "IP[:port]  or  IP code"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	direct_row.add_child(_address)
	var join_ip := Button.new()
	join_ip.text = "JOIN IP"
	join_ip.pressed.connect(_on_join_ip)
	direct_row.add_child(join_ip)
	var local_btn := Button.new()
	local_btn.text = "JOIN LOCAL"
	local_btn.pressed.connect(func(): NetworkManager.join_party("127.0.0.1", ConnectionUtils.SERVER_PORT, true))
	direct_row.add_child(local_btn)
	return tab


func _build_party_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Party"
	var lbl := Label.new()
	lbl.text = ("Party service is not available in this build.\n\n"
		+ "The party lobby/registry requires the lobbyd party API (see "
		+ "ref/NEW_EVENT_FLOW.txt, phase 6). Solo and LAN/Direct play are unaffected.")
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	tab.add_child(lbl)
	return tab


func _load_maps() -> void:
	_map_datas = ConnectionUtils.scan_map_data()


func _mode_name(mode: int) -> String:
	match mode:
		GameModeComponent.GameMode.ESCORT: return "ESCORT"
		GameModeComponent.GameMode.DOMINATION: return "DOMINATION"
		GameModeComponent.GameMode.KOTH: return "KOTH"
		GameModeComponent.GameMode.HYBRID: return "HYBRID"
		GameModeComponent.GameMode.CONTROL: return "CONTROL"
		GameModeComponent.GameMode.DEATHMATCH: return "DEATHMATCH"
		_: return ""


func open_menu() -> void:
	if PlayerInput.ui_open:
		return
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_tabs.current_tab = 0
	if _map_picker.item_count > 0 and _map_picker.selected < 0:
		_map_picker.select(0)


func close_menu() -> void:
	visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
		close_menu()
		get_viewport().set_input_as_handled()


func _on_create_match() -> void:
	if not MatchSession.local_is_host():
		_status.text = "Only the party leader can start a match."
		return
	if LobbyClient.is_enabled():
		_create_via_lobby()
		return
	var path := ""
	if _map_picker.selected >= 0:
		path = str(_map_picker.get_item_metadata(_map_picker.selected))
	if path == "":
		return
	GameManager.pending_match_map = path
	GameManager.pending_host_setup = {
		"host_team": int(Player.Team.FFA),
		"autofill": false,
		"ffa": true,
		"ffa_target": 8,
		"team_size": 5,
	}
	close_menu()
	NetworkManager.host_local_match(NetworkManager.SERVER_PORT, NetworkManager.LOBBY_MAP_PATH)


func _create_via_lobby() -> void:
	if _busy:
		return
	_busy = true
	_status.text = "Creating match..."
	var result: Dictionary = await LobbyClient.create_match()
	_busy = false
	if not result.has("endpoint") or not result.has("grant"):
		_status.text = "Create failed: %s" % result.get("error", "unknown")
		return
	close_menu()
	await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))


func _refresh_servers() -> void:
	if _busy:
		return
	_busy = true
	_lan_list.clear()
	_status.text = "Refreshing..."
	if not LobbyClient.is_enabled() and not LanDiscovery.is_enabled():
		_status.text = "No discovery sources enabled."
		_busy = false
		return
	if LobbyClient.is_enabled():
		var matches: Array = await LobbyClient.list_matches()
		for entry in matches:
			if not entry is Dictionary:
				continue
			var m := entry as Dictionary
			var code := str(m.get("code", ""))
			if code == "":
				continue
			var idx := _lan_list.add_item("[ONLINE] %s   %d/%d   %s" % [
				code, int(m.get("players", 0)), int(m.get("max_players", 0)),
				str(m.get("state", "?"))])
			_lan_list.set_item_metadata(idx, {"source": "lobbyd", "code": code})
	if LanDiscovery.is_enabled():
		var entries: Array[Dictionary] = await LanDiscovery.discover(0.7)
		for entry in entries:
			var idx := _lan_list.add_item("[LAN] %s   %d/%d   %s   %s:%d" % [
				str(entry.get("map", "?")).to_upper(), int(entry.get("players", 0)),
				int(entry.get("max_players", 0)), str(entry.get("state", "?")),
				str(entry.get("ip", "?")), int(entry.get("port", 0))])
			_lan_list.set_item_metadata(idx, {
				"source": "lan", "ip": str(entry.get("ip", "")),
				"port": int(entry.get("port", 0)),
			})
	_status.text = "%d server(s)." % _lan_list.item_count
	_busy = false


func _on_join_selected() -> void:
	var selected := _lan_list.get_selected_items()
	if selected.is_empty():
		_status.text = "Select a server first."
		return
	var meta: Dictionary = _lan_list.get_item_metadata(selected[0])
	if str(meta.get("source", "")) == "lobbyd":
		_status.text = "Joining %s..." % meta.get("code", "")
		var result: Dictionary = await LobbyClient.join_by_code(str(meta.get("code", "")))
		if not result.has("endpoint") or not result.has("grant"):
			_status.text = "Join failed: %s" % result.get("error", "unknown")
			return
		close_menu()
		await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))
	elif str(meta.get("source", "")) == "lan":
		close_menu()
		NetworkManager.join_party(str(meta.get("ip", "")), int(meta.get("port", 0)), true)


func _on_join_ip() -> void:
	var raw := _address.text.strip_edges()
	if raw == "":
		raw = "127.0.0.1"
	var address := raw
	var port := ConnectionUtils.SERVER_PORT
	if ConnectionUtils.looks_like_code(raw):
		address = ConnectionUtils.code_to_ip(raw)
		if address == "":
			_status.text = "Invalid IP code."
			return
	elif raw.contains(":"):
		address = raw.get_slice(":", 0)
		port = int(raw.get_slice(":", 1))
		if port <= 0 or port > 65535:
			_status.text = "Invalid port."
			return
	close_menu()
	NetworkManager.join_party(address, port, NetworkManager.role == NetworkManager.Role.OFFLINE)
