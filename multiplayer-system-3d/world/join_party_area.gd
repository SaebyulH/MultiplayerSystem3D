extends Area3D
## JoinParty interaction zone in the 3D lobby.
##
## Inside the zone a player sees "Press E to join"; E opens a popup for entering
## the host's IP (or a 6-char join code) plus a "Join Local" button.  Any player
## (leader or not) can join someone else's party.

const MATCH_BROWSER_SCRIPT := preload("res://world/match_browser.gd")

@onready var prompt_label: Label3D = $PromptLabel

var _players_inside: Array[Player] = []
var _browser: CanvasLayer = null
var _popup_layer: CanvasLayer = null
var _tabs: TabContainer
var _lan_list: ItemList
var _lan_status: Label
var _lan_timer: Timer
var _lan_busy := false
var _address_input: LineEdit
var _ip_button: Button
var _status_label: Label
var _join_local_btn: Button

var _detected_ips: Array[String] = []
var _shown_ip_index: int = 0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	prompt_label.visible = false
	if LobbyClient.is_enabled():
		# Dedicated-server lobby: browse lobbyd's match list.  Built on root so it
		# is not part of the replicated map.
		_browser = MATCH_BROWSER_SCRIPT.new()
		get_tree().root.add_child(_browser)
	else:
		_build_popup()
		_detected_ips = ConnectionUtils.detect_ips()


func _exit_tree() -> void:
	if _browser and is_instance_valid(_browser):
		_browser.queue_free()
		_browser = null
	if _popup_layer and is_instance_valid(_popup_layer):
		_popup_layer.queue_free()
		_popup_layer = null


# ─────────────────────────────────────────────
#  Body tracking
# ─────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if body is Player and body not in _players_inside:
		_players_inside.append(body)
		_refresh_prompt()


func _on_body_exited(body: Node3D) -> void:
	_players_inside.erase(body)
	_refresh_prompt()


func _local_player_inside() -> bool:
	var my_id := MatchSession.local_id_string()
	for p in _players_inside:
		# `body_exited` is not guaranteed for a Player that is freed outright.
		if is_instance_valid(p) and p.name == my_id:
			return true
	return false


func _refresh_prompt() -> void:
	prompt_label.visible = _local_player_inside()
	if not prompt_label.visible:
		return
	if LobbyClient.is_enabled():
		prompt_label.text = "Find Match (E)"
	elif NetworkManager.role == NetworkManager.Role.OFFLINE:
		prompt_label.text = "Join Match (E)"
	else:
		prompt_label.text = "Join Party (E)"


# ─────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _local_player_inside():
		return
	if LobbyClient.is_enabled():
		if _browser and is_instance_valid(_browser) and _browser.visible:
			return  # the browser owns its own close input
		if event.is_action_pressed("interact") and not event.is_echo():
			if PlayerInput.ui_open:
				return
			if _browser:
				_browser.open()
		return
	if _popup_layer and _popup_layer.visible:
		if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
			_close_popup()
		return
	if event.is_action_pressed("interact") and not event.is_echo():
		# Another menu (loadout, dev hacks, …) owns input.  Without this, the
		# popup opens on top of it and its close clears ui_open underneath.
		if PlayerInput.ui_open:
			return
		_open_popup()


# ─────────────────────────────────────────────
#  Popup
# ─────────────────────────────────────────────

func _build_popup() -> void:
	_popup_layer = CanvasLayer.new()
	_popup_layer.layer = 2
	_popup_layer.visible = false
	get_tree().root.add_child(_popup_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup_layer.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(460, 0)
	_popup_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "JOIN MATCH" if NetworkManager.role == NetworkManager.Role.OFFLINE else "JOIN PARTY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.custom_minimum_size = Vector2(460, 260)
	vbox.add_child(_tabs)

	# ── LAN tab ─────────────────────────────────────────────
	var lan := VBoxContainer.new()
	lan.name = "LAN"
	lan.add_theme_constant_override("separation", 8)
	_tabs.add_child(lan)

	_lan_list = ItemList.new()
	_lan_list.custom_minimum_size = Vector2(440, 170)
	_lan_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lan.add_child(_lan_list)

	_lan_status = Label.new()
	_lan_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lan_status.add_theme_font_size_override("font_size", 14)
	lan.add_child(_lan_status)

	var lan_row := HBoxContainer.new()
	lan_row.add_theme_constant_override("separation", 8)
	lan.add_child(lan_row)
	var lan_join := Button.new()
	lan_join.text = "Join Selected"
	lan_join.pressed.connect(_on_lan_join_pressed)
	lan_row.add_child(lan_join)
	var lan_refresh := Button.new()
	lan_refresh.text = "Refresh"
	lan_refresh.pressed.connect(_refresh_lan)
	lan_row.add_child(lan_refresh)

	# ── Direct IP tab ───────────────────────────────────────
	var direct := VBoxContainer.new()
	direct.name = "Direct IP"
	direct.add_theme_constant_override("separation", 10)
	_tabs.add_child(direct)

	_ip_button = Button.new()
	_ip_button.pressed.connect(_on_ip_button_pressed)
	direct.add_child(_ip_button)

	_address_input = LineEdit.new()
	_address_input.placeholder_text = "IP[:port]  or  join code"
	direct.add_child(_address_input)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	direct.add_child(_status_label)

	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.pressed.connect(_on_join_pressed)
	direct.add_child(join_btn)

	_join_local_btn = Button.new()
	_join_local_btn.text = "Join Local (This Computer)"
	_join_local_btn.pressed.connect(_on_join_local_pressed)
	direct.add_child(_join_local_btn)

	var close_btn := Button.new()
	close_btn.text = "Close (Esc)"
	close_btn.pressed.connect(_close_popup)
	vbox.add_child(close_btn)

	_lan_timer = Timer.new()
	_lan_timer.wait_time = 2.0
	_lan_timer.one_shot = false
	_lan_timer.timeout.connect(_refresh_lan)
	add_child(_lan_timer)


func _open_popup() -> void:
	_shown_ip_index = 0
	_update_ip_display()

	# "Join Local" is for a SECOND instance.  On the instance that owns UDP 8080,
	# join_party() -> create_client() -> _terminate_connection() closes that very
	# peer before dialling the port it just released, so the connect can never
	# succeed: the loading screen parks at 10% ("Connecting...") until the connect
	# times out, then the player is dumped back into their own lobby.  Disable it
	# rather than let them walk into that.
	# NetworkManager.is_network_host(), NOT multiplayer.is_server(): the latter is
	# also true for the OfflineMultiplayerPeer a second local instance falls back
	# to, which would wrongly disable Join Local on the one instance that needs it.
	var hosting_here := NetworkManager.is_network_host()
	_join_local_btn.disabled = hosting_here
	_join_local_btn.tooltip_text = "Already hosting on this computer." if hosting_here else ""
	_status_label.text = "You are hosting here — run a second instance to test joining." if hosting_here else ""

	_popup_layer.visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_address_input.release_focus()
	_tabs.current_tab = 0
	_refresh_lan()
	_lan_timer.start()


func _close_popup() -> void:
	if _popup_layer:
		_popup_layer.visible = false
	if _lan_timer:
		_lan_timer.stop()
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _refresh_lan() -> void:
	if _popup_layer == null or not _popup_layer.visible or _lan_busy:
		return
	if not LanDiscovery.is_enabled():
		_lan_status.text = "LAN discovery disabled (--no-discovery)."
		return
	_lan_busy = true
	_lan_status.text = "Searching…"
	var entries: Array[Dictionary] = await LanDiscovery.discover(0.7)
	_lan_busy = false
	if _popup_layer == null or not _popup_layer.visible:
		return
	_lan_list.clear()
	for entry in entries:
		var index := _lan_list.add_item("%s    %d/%d    %s    %s:%d" % [
			str(entry.get("map", "?")).to_upper(),
			int(entry.get("players", 0)), int(entry.get("max_players", 0)),
			str(entry.get("state", "?")),
			str(entry.get("ip", "?")), int(entry.get("port", 0))])
		_lan_list.set_item_metadata(index, entry)
	_lan_status.text = "No servers found on the LAN." if entries.is_empty() \
		else "%d server(s) found." % entries.size()


func _on_lan_join_pressed() -> void:
	var selected := _lan_list.get_selected_items()
	if selected.is_empty():
		_lan_status.text = "Select a server first."
		return
	var entry: Dictionary = _lan_list.get_item_metadata(selected[0])
	var ip := str(entry.get("ip", ""))
	var port := int(entry.get("port", 0))
	if ip == "" or port <= 0:
		_lan_status.text = "That server entry is incomplete."
		return
	_close_popup()
	NetworkManager.join_party(ip, port, true)


func _update_ip_display() -> void:
	if _detected_ips.is_empty():
		_ip_button.text = "No IP detected"
		return
	var ip := _detected_ips[_shown_ip_index]
	var code := ConnectionUtils.ip_to_code(ip)
	var text := "Your IP:  %s:%d" % [ip, ConnectionUtils.SERVER_PORT]
	if code != "":
		text += "\nJoin Code:  %s" % code
	if _detected_ips.size() > 1:
		text += "   (click to cycle)"
	_ip_button.text = text
	_address_input.text = ip


func _on_ip_button_pressed() -> void:
	if _detected_ips.is_empty():
		return
	_shown_ip_index = (_shown_ip_index + 1) % _detected_ips.size()
	_update_ip_display()


func _on_join_pressed() -> void:
	var raw := _address_input.text.strip_edges()
	if raw == "":
		raw = "127.0.0.1"

	var address := raw
	var port := ConnectionUtils.SERVER_PORT
	if ConnectionUtils.looks_like_code(raw):
		address = ConnectionUtils.code_to_ip(raw)
		if address == "":
			_status_label.text = "Invalid join code."
			return
	elif raw.contains(":"):
		address = raw.get_slice(":", 0)
		port = int(raw.get_slice(":", 1))
		if port <= 0 or port > 65535:
			_status_label.text = "Invalid port."
			return

	_close_popup()
	# The default local flow hosts in-process listen servers, so a shell join
	# uses the match-session handshake.  Legacy P2P joins keep their old path.
	var use_session := NetworkManager.role == NetworkManager.Role.OFFLINE
	NetworkManager.join_party(address, port, use_session)


func _on_join_local_pressed() -> void:
	if NetworkManager.is_network_host():
		# Belt and braces alongside the disabled button: joining ourselves would
		# close the only listener on this machine.  See _open_popup().
		_status_label.text = "You are hosting here — run a second instance to test joining."
		return
	_close_popup()
	var use_session := NetworkManager.role == NetworkManager.Role.OFFLINE
	NetworkManager.join_party("127.0.0.1", ConnectionUtils.SERVER_PORT, use_session)
