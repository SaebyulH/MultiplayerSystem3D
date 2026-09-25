extends Area3D
## JoinParty interaction zone in the 3D lobby.
##
## Inside the zone a player sees "Press E to join"; E opens a popup for entering
## the host's IP (or a 6-char join code) plus a "Join Local" button.  Any player
## (leader or not) can join someone else's party.

@onready var prompt_label: Label3D = $PromptLabel

var _players_inside: Array[Player] = []
var _popup_layer: CanvasLayer = null
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
	_build_popup()
	_detected_ips = ConnectionUtils.detect_ips()


func _exit_tree() -> void:
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
	var my_id := str(multiplayer.get_unique_id())
	for p in _players_inside:
		if p.name == my_id:
			return true
	return false


func _refresh_prompt() -> void:
	prompt_label.visible = _local_player_inside()
	if prompt_label.visible:
		prompt_label.text = "Join Party (E)"


# ─────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _local_player_inside():
		return
	if _popup_layer and _popup_layer.visible:
		if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
			_close_popup()
		return
	if event.is_action_pressed("interact") and not event.is_echo():
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
	title.text = "JOIN PARTY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)

	_ip_button = Button.new()
	_ip_button.pressed.connect(_on_ip_button_pressed)
	vbox.add_child(_ip_button)

	_address_input = LineEdit.new()
	_address_input.placeholder_text = "IP address  or  join code"
	vbox.add_child(_address_input)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_status_label)

	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.pressed.connect(_on_join_pressed)
	vbox.add_child(join_btn)

	_join_local_btn = Button.new()
	_join_local_btn.text = "Join Local (This Computer)"
	_join_local_btn.pressed.connect(_on_join_local_pressed)
	vbox.add_child(_join_local_btn)

	var close_btn := Button.new()
	close_btn.text = "Close (Esc)"
	close_btn.pressed.connect(_close_popup)
	vbox.add_child(close_btn)


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


func _close_popup() -> void:
	if _popup_layer:
		_popup_layer.visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


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

	var address: String
	if ConnectionUtils.looks_like_code(raw):
		address = ConnectionUtils.code_to_ip(raw)
		if address == "":
			_status_label.text = "Invalid join code."
			return
	else:
		address = raw

	_close_popup()
	NetworkManager.join_party(address)


func _on_join_local_pressed() -> void:
	if NetworkManager.is_network_host():
		# Belt and braces alongside the disabled button: joining ourselves would
		# close the only listener on this machine.  See _open_popup().
		_status_label.text = "You are hosting here — run a second instance to test joining."
		return
	_close_popup()
	NetworkManager.join_party("127.0.0.1")
