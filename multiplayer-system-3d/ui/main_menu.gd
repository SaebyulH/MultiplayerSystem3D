extends Control

@onready var address_input: LineEdit = $VBoxContainer/AddressInput
@onready var ip_label: Label = $VBoxContainer/IPLabel
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var option_button: OptionButton = $VBoxContainer/OptionButton

var _detected_ips: Array[String] = []
var _shown_ip_index: int = 0
const SERVER_PORT: int = 8080


# ─────────────────────────────────────────────
#  Base-62 Join Code  (0-9 A-Z a-z)
# ─────────────────────────────────────────────
#  62^6 ≈ 56.8 billion > 2^32 (IPv4 address space),
#  so every IP fits in exactly 6 characters.

const B62: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
const CODE_LENGTH: int = 6


func ip_to_code(ip: String) -> String:
	var parts := ip.split(".")
	if parts.size() != 4:
		return ""
	var value: int = 0
	for i in range(4):
		value = (value << 8) | clampi(parts[i].to_int(), 0, 255)
	return _b62_encode(value)


func code_to_ip(code: String) -> String:
	if code.length() != CODE_LENGTH:
		return ""
	var value := _b62_decode(code)
	if value < 0:
		return ""
	var a := (value >> 24) & 0xFF
	var b := (value >> 16) & 0xFF
	var c := (value >>  8) & 0xFF
	var d :=  value        & 0xFF
	return "%d.%d.%d.%d" % [a, b, c, d]


func _b62_encode(value: int) -> String:
	var result := ""
	var v := value
	for _i in range(CODE_LENGTH):
		result = B62[v % 62] + result
		v /= 62
	return result


func _b62_decode(code: String) -> int:
	var value: int = 0
	for ch in code:
		var idx := B62.find(ch)
		if idx == -1:
			return -1
		value = value * 62 + idx
	return value


## True if text looks like a join code (6 B62 chars, no dots/colons).
func _looks_like_code(text: String) -> bool:
	if text.length() != CODE_LENGTH:
		return false
	if "." in text or ":" in text:
		return false
	for ch in text:
		if B62.find(ch) == -1:
			return false
	return true


# ─────────────────────────────────────────────
#  Ready
# ─────────────────────────────────────────────

func _ready() -> void:
	_detect_ips()
	_update_ip_display()
	address_input.placeholder_text = "IP address  or  join code"

	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ─────────────────────────────────────────────
#  IP Detection
# ─────────────────────────────────────────────

func _detect_ips() -> void:
	_detected_ips.clear()
	var all := IP.get_local_addresses()

	var scored: Array[Dictionary] = []
	for addr in all:
		if addr.begins_with("127."):     continue
		if addr.begins_with("169.254."): continue
		if addr.begins_with("0."):       continue
		var s := _score_ip(addr)
		if s >= 0:
			scored.append({"ip": addr, "score": s})

	scored.sort_custom(_compare_ip_scores)

	_detected_ips = []
	for entry in scored:
		_detected_ips.append(entry["ip"])

	if not "127.0.0.1" in _detected_ips:
		_detected_ips.append("127.0.0.1")


func _compare_ip_scores(a: Dictionary, b: Dictionary) -> bool:
	return a["score"] > b["score"]


func _score_ip(addr: String) -> int:
	var parts := addr.split(".")
	if parts.size() != 4:
		return -1

	var a := parts[0].to_int()
	var b := parts[1].to_int()
	var c := parts[2].to_int()

	# Known virtual / VPN adapters — negative scores
	if a == 192 and b == 168 and c == 56:                   return -100  # VirtualBox Host-Only
	if a == 192 and b == 168 and c == 0:                    return -80   # VMware Host-Only
	if a == 192 and b == 168 and c in [40, 137, 220, 221, 222]: return -70   # VMware NAT
	if a == 172 and b >= 17 and b <= 31:                    return -50   # Docker bridges
	if a == 25:                                             return -60   # Hamachi VPN
	if a == 100 and b >= 64 and b <= 127:                   return -60   # Tailscale / CGN

	# Real LAN adapters — positive scores
	if a == 192 and b == 168:                                return 100   # Home / office LAN
	if a == 10:                                             return 80    # Corporate LAN
	if a == 172 and b >= 16 and b <= 31:                    return 60    # Sometimes LAN

	if a >= 1 and a <= 223:                                 return 40    # Public IP
	return 0


# ─────────────────────────────────────────────
#  IP / Join-code display
# ─────────────────────────────────────────────

func _update_ip_display() -> void:
	if _detected_ips.is_empty():
		ip_label.text = "No IP detected"
		return

	var ip := _detected_ips[_shown_ip_index]
	var code := ip_to_code(ip)
	var port := SERVER_PORT

	var line1 := "Your IP:  %s:%d" % [ip, port]
	var line2 := ""
	if code != "":
		line2 = "Join Code:  %s" % code

	if _detected_ips.size() > 1:
		line2 += "    [click to cycle IP]"

	# Stack the two lines; blank line2 is harmless.
	ip_label.text = line1
	if line2 != "":
		ip_label.text += "\n" + line2

	address_input.text = ip


func _on_ip_label_clicked() -> void:
	if _detected_ips.is_empty():
		return
	_shown_ip_index = (_shown_ip_index + 1) % _detected_ips.size()
	_update_ip_display()


# ─────────────────────────────────────────────
#  Click-on-label detection
# ─────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if ip_label.get_global_rect().has_point(get_global_mouse_position()):
		_on_ip_label_clicked()


# ─────────────────────────────────────────────
#  Host / Join
# ─────────────────────────────────────────────

func _get_selected_map() -> String:
	if option_button.selected < 0:
		return ""
	return option_button.get_item_text(option_button.selected)


func _on_host_game_pressed() -> void:
	var map_path := _get_selected_map()
	if map_path == "":
		_set_status("Select a map first!", Color(1, 0.4, 0.4))
		return

	_set_status("Creating server...", Color(0.9, 0.9, 0.4))
	NetworkManager.create_server()
	NetworkManager.load_game_scene(map_path)


func _on_join_game_pressed() -> void:
	var raw := address_input.text.strip_edges()
	if raw == "":
		raw = "127.0.0.1"

	var address: String
	if _looks_like_code(raw):
		address = code_to_ip(raw)
		if address == "":
			_set_status("Invalid join code.", Color(1, 0.4, 0.4))
			return
		_set_status("Code -> %s:%d   Connecting..." % [address, SERVER_PORT], Color(0.9, 0.9, 0.4))
	else:
		address = raw
		_set_status("Connecting to %s:%d..." % [address, SERVER_PORT], Color(0.9, 0.9, 0.4))

	NetworkManager.create_client(address)


func _on_join_local_pressed() -> void:
	_set_status("Connecting to localhost...", Color(0.9, 0.9, 0.4))
	NetworkManager.create_client("127.0.0.1")


# ─────────────────────────────────────────────
#  Callbacks
# ─────────────────────────────────────────────

func _on_connected_to_server() -> void:
	_set_status("Connected!  (ID: %d)" % multiplayer.get_unique_id(), Color(0.4, 1, 0.4))
	NetworkManager.enter_existing_game_scene()


func _on_connection_failed() -> void:
	_set_status("Connection failed — check the address and try again.", Color(1, 0.4, 0.4))


func _on_server_disconnected() -> void:
	_set_status("Disconnected from server.", Color(1, 0.6, 0.4))


func _on_peer_connected(id: int) -> void:
	if OS.is_debug_build():
		print("Peer connected: ", id)


# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

func _set_status(text: String, color: Color = Color(0.7, 0.7, 0.7)) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", color)


# Legacy test-message RPC kept for debugging.
func _on_send_test_message_pressed() -> void:
	_send_test_message.rpc("I am connected to you")


@rpc("any_peer", "call_remote")
func _send_test_message(message: String) -> void:
	if OS.is_debug_build():
		print("Peer [%s] received message [%s] from peer [%s]"
			% [get_tree().get_multiplayer().get_unique_id(),
				message,
				get_tree().get_multiplayer().get_remote_sender_id()])
