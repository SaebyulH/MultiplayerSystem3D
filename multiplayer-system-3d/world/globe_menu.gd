extends CanvasLayer

## Match Menu opened by the HostServer globe in the 3D lobby.
##
## START MATCH creates a match (map grid -> preview -> CREATE), FIND MATCH
## merges LAN and lobbyd entries, and PARTY is an explicit unavailable state
## until the party service lands.  No 3D content is changed.

const PREVIEW_HEIGHT := 250

var _tabs: TabContainer
var _match_name: LineEdit
var _lan_list: VBoxContainer
var _status: Label
var _address: LineEdit
var _map_datas: Array[MapData] = []
var _map_buttons: Dictionary = {}          # map_scene_path -> Button
var _selected_map_path := ""
var _preview_image: TextureRect
var _preview_name: Label
var _preview_mode: Label
var _preview_desc: Label
var _create_btn: Button
var _busy := false


func _ready() -> void:
	layer = 3
	visible = false
	_load_maps()
	_build()


# ─────────────────────────────────────────────
#  Frame
# ─────────────────────────────────────────────

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = UITheme.SCRIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("margin_left", 56)
	frame.add_theme_constant_override("margin_right", 56)
	frame.add_theme_constant_override("margin_top", 28)
	frame.add_theme_constant_override("margin_bottom", 28)
	add_child(frame)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	frame.add_child(vb)

	# Header
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	vb.add_child(header)
	var title := UITheme.display_label("MATCH MENU", UITheme.FS_TITLE, UITheme.TEXT)
	header.add_child(title)
	var rule := ColorRect.new()
	rule.color = UITheme.RED
	rule.custom_minimum_size = Vector2(3, 26)
	header.add_child(rule)
	var sub := UITheme.section_label("HOST · JOIN · PARTY", UITheme.MUTED)
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(sub)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close := Button.new()
	close.text = "CLOSE  (Esc)"
	close.pressed.connect(close_menu)
	header.add_child(close)

	vb.add_child(UITheme.accent_bar(UITheme.LINE, 1))

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_tabs)
	_tabs.add_child(_build_start_tab())
	_tabs.add_child(_build_find_tab())
	_tabs.add_child(_build_party_tab())


# ─────────────────────────────────────────────
#  Start tab
# ─────────────────────────────────────────────

func _build_start_tab() -> Control:
	var tab := MarginContainer.new()
	tab.name = "START MATCH"
	tab.add_theme_constant_override("margin_top", 14)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	tab.add_child(row)

	# Left: map grid
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.55
	left.add_theme_constant_override("separation", 10)
	row.add_child(left)
	left.add_child(UITheme.section_label("SELECT MAP", UITheme.MUTED))
	left.add_child(UITheme.accent_bar(UITheme.RED, 2))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(grid)

	_map_buttons.clear()
	for md in _map_datas:
		if md == null:
			continue
		var card := UITheme.map_card(md, false)
		card.pressed.connect(_on_map_card_pressed.bind(md.map_scene_path))
		card.mouse_entered.connect(_on_map_card_hover.bind(md.map_scene_path))
		grid.add_child(card)
		_map_buttons[md.map_scene_path] = card

	# Right: preview + create
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	row.add_child(right)
	right.add_child(UITheme.section_label("BRIEFING", UITheme.MUTED))
	right.add_child(UITheme.accent_bar(UITheme.TEAL, 2))

	var preview := PanelContainer.new()
	preview.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 14))
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(preview)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 10)
	preview.add_child(pv)

	_preview_image = TextureRect.new()
	_preview_image.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT)
	_preview_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pv.add_child(_preview_image)

	_preview_name = UITheme.display_label("—", 30, UITheme.TEXT)
	pv.add_child(_preview_name)
	_preview_mode = UITheme.section_label("", UITheme.TEAL)
	pv.add_child(_preview_mode)
	_preview_desc = UITheme.body_label("", UITheme.FS_SMALL, UITheme.MUTED)
	_preview_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pv.add_child(_preview_desc)

	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pv.add_child(fill)

	pv.add_child(UITheme.section_label("MATCH NAME", UITheme.MUTED))
	_match_name = LineEdit.new()
	_match_name.placeholder_text = "My Match"
	pv.add_child(_match_name)

	var hint := UITheme.body_label(
		"Team assignment, bots and START are in the staging room.  With no external lobby service this creates an in-process listen server.",
		UITheme.FS_MICRO, UITheme.DIM_TEXT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pv.add_child(hint)

	_create_btn = Button.new()
	_create_btn.text = "CREATE MATCH"
	_create_btn.custom_minimum_size = Vector2(0, 52)
	_create_btn.add_theme_font_override("font", UITheme.FONT_EXTRABOLD)
	_create_btn.add_theme_font_size_override("font_size", 17)
	_create_btn.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.PRIMARY))
	_create_btn.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.PRIMARY, true))
	_create_btn.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.PRIMARY, false, true))
	_create_btn.pressed.connect(_on_create_match)
	pv.add_child(_create_btn)

	_select_map(_initial_map_path())
	return tab


func _on_map_card_hover(path: String) -> void:
	# Hover only previews the card; the committed map stays selected until click.
	var md := UITheme.map_data_for_path(path)
	if md:
		_preview_image.texture = md.map_image
		_preview_name.text = md.display_name.to_upper()
		_preview_mode.text = UITheme.mode_name(md.game_mode)
		_preview_desc.text = UITheme.mode_description(md.game_mode)


func _on_map_card_pressed(path: String) -> void:
	_select_map(path)


func _select_map(path: String) -> void:
	_selected_map_path = path
	for key in _map_buttons:
		var card: Button = _map_buttons[key]
		var selected: bool = key == path
		card.add_theme_stylebox_override("normal", UITheme.card_style(
			UITheme.State.SELECTED if selected else UITheme.State.NORMAL))
		card.add_theme_stylebox_override("hover", UITheme.card_style(
			UITheme.State.SELECTED if selected else UITheme.State.HOVER))
	_on_map_card_hover(path)
	_create_btn.disabled = path == ""


func _initial_map_path() -> String:
	var pending := GameManager.pending_match_map
	if pending != "" and _map_buttons.has(pending):
		return pending
	return _map_datas[0].map_scene_path if not _map_datas.is_empty() else ""


# ─────────────────────────────────────────────
#  Find tab
# ─────────────────────────────────────────────

func _build_find_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "FIND MATCH"
	tab.add_theme_constant_override("separation", 10)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	tab.add_child(row)
	var refresh := Button.new()
	refresh.text = "REFRESH"
	refresh.pressed.connect(_refresh_servers)
	row.add_child(refresh)
	_status = UITheme.body_label("", UITheme.FS_SMALL, UITheme.MUTED)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)
	_lan_list = VBoxContainer.new()
	_lan_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_lan_list)

	var direct_panel := PanelContainer.new()
	direct_panel.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 12))
	tab.add_child(direct_panel)
	var direct_row := HBoxContainer.new()
	direct_row.add_theme_constant_override("separation", 8)
	direct_panel.add_child(direct_row)
	var direct_lbl := UITheme.section_label("DIRECT", UITheme.MUTED)
	direct_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	direct_row.add_child(direct_lbl)
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


func _make_server_card(entry: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.State.NORMAL))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var map_name := str(entry.get("map", ""))
	var md := UITheme.map_data_for_name(map_name) if map_name != "" else null
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(128, 72)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.texture = md.map_image if md else null
	row.add_child(thumb)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	var name_label := UITheme.body_label(
		md.display_name if md else map_name.to_upper() if map_name != "" else "ONLINE MATCH",
		UITheme.FS_BODY, UITheme.TEXT)
	name_label.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	info.add_child(name_label)
	var source := str(entry.get("source", ""))
	var detail := ""
	if source == "lan":
		detail = "LAN  ·  %d/%d  ·  %s" % [
			int(entry.get("players", 0)), int(entry.get("max_players", 0)),
			str(entry.get("ip", ""))]
		if int(entry.get("port", 0)) > 0:
			detail += ":%d" % int(entry.get("port", 0))
	else:
		detail = "%s  ·  %d/%d" % [
			str(entry.get("code", "")), int(entry.get("players", 0)),
			int(entry.get("max_players", 0))]
	info.add_child(UITheme.body_label(detail, UITheme.FS_MICRO, UITheme.MUTED))

	var state_label := UITheme.section_label(str(entry.get("state", "")), UITheme.TEAL)
	state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(state_label)

	var join := Button.new()
	join.text = "JOIN"
	join.pressed.connect(_on_join_entry.bind(entry))
	row.add_child(join)
	return panel


# ─────────────────────────────────────────────
#  Party tab
# ─────────────────────────────────────────────

func _build_party_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "PARTY"
	tab.alignment = BoxContainer.ALIGNMENT_CENTER
	tab.add_theme_constant_override("separation", 12)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 28))
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tab.add_child(card)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)
	var title := UITheme.display_label("PARTY OFFLINE", 26, UITheme.MUTED)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var lbl := UITheme.body_label(
		"The party service is not available in this build.\n"
		+ "It needs the lobbyd party API (ref/NEW_EVENT_FLOW.txt, phase 6).\n"
		+ "Solo and LAN/Direct play are unaffected.",
		UITheme.FS_SMALL, UITheme.MUTED)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(lbl)
	return tab


# ─────────────────────────────────────────────
#  Data
# ─────────────────────────────────────────────

func _load_maps() -> void:
	_map_datas = ConnectionUtils.scan_map_data()


func open_menu() -> void:
	if PlayerInput.ui_open:
		return
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_tabs.current_tab = 0
	if _selected_map_path == "" or not _map_buttons.has(_selected_map_path):
		_select_map(_initial_map_path())
	_create_btn.disabled = not MatchSession.local_is_host()


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
	if _selected_map_path == "":
		return
	GameManager.pending_match_map = _selected_map_path
	# Deathmatch is free-for-all; every other mode is SPI vs SCI.  The staging
	# room normalizes any stragglers, but starting the host on a sensible team
	# avoids a visible flip on the first frame.
	var md := UITheme.map_data_for_path(_selected_map_path)
	var ffa_mode := md != null and md.game_mode == GameModeComponent.GameMode.DEATHMATCH
	GameManager.pending_host_setup = {
		"host_team": int(Player.Team.FFA) if ffa_mode else int(Player.Team.SPI),
		"autofill": false,
		"ffa": ffa_mode,
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
	for child in _lan_list.get_children():
		_lan_list.remove_child(child)
		child.queue_free()
	_status.text = "Refreshing..."
	if not LobbyClient.is_enabled() and not LanDiscovery.is_enabled():
		_status.text = "No discovery sources enabled."
		_busy = false
		return
	var count := 0
	if LobbyClient.is_enabled():
		var matches: Array = await LobbyClient.list_matches()
		for entry in matches:
			if not entry is Dictionary:
				continue
			var m := entry as Dictionary
			var code := str(m.get("code", ""))
			if code == "":
				continue
			m["source"] = "lobbyd"
			_lan_list.add_child(_make_server_card(m))
			count += 1
	if LanDiscovery.is_enabled():
		var entries: Array[Dictionary] = await LanDiscovery.discover(0.7)
		for entry in entries:
			var copy: Dictionary = entry.duplicate()
			copy["source"] = "lan"
			_lan_list.add_child(_make_server_card(copy))
			count += 1
	_status.text = "%d server(s)." % count
	_busy = false


func _on_join_entry(entry: Dictionary) -> void:
	if str(entry.get("source", "")) == "lobbyd":
		_status.text = "Joining %s..." % entry.get("code", "")
		var result: Dictionary = await LobbyClient.join_by_code(str(entry.get("code", "")))
		if not result.has("endpoint") or not result.has("grant"):
			_status.text = "Join failed: %s" % result.get("error", "unknown")
			return
		close_menu()
		await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))
	elif str(entry.get("source", "")) == "lan":
		close_menu()
		NetworkManager.join_party(str(entry.get("ip", "")), int(entry.get("port", 0)), true)


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
