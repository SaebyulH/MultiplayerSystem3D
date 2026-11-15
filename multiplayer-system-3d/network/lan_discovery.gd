extends Node

## LAN discovery for local match servers, so players can find each other with no
## central service.
##
## Host: binds a UDP socket on `LAN_DISCOVERY_PORT_BASE + (game_port - 8080) mod
## range` and answers probes with a JSON announce.
## Client: sends probes to 127.0.0.1, the /24 broadcast of every local IPv4
## interface, and 255.255.255.255 across the discovery port range, then collects
## replies for a short window.
##
## The announce is metadata only and is unauthenticated; the join itself still
## uses the MatchSession handshake.  Disable with `--no-discovery`.

const Protocol := preload("res://network/session_protocol.gd")

var _udp: PacketPeerUDP
var _announcing := false
var _disabled := false
var _announce_port := 0
## Random per process.  A host reachable at both 127.0.0.1 and its LAN address
## would otherwise appear twice in the browser.
var _instance_id := ""


func _ready() -> void:
	_disabled = "--no-discovery" in OS.get_cmdline_user_args()
	_instance_id = "%d-%d" % [Time.get_ticks_usec(), randi()]
	set_process(false)


func is_enabled() -> bool:
	return not _disabled


func start_announcing(game_port: int) -> void:
	if _disabled:
		return
	stop_announcing()
	var offset := posmod(game_port - 8080, Protocol.LAN_DISCOVERY_PORT_RANGE)
	var discovery_port := Protocol.LAN_DISCOVERY_PORT_BASE + offset
	var udp := PacketPeerUDP.new()
	var err := udp.bind(discovery_port, "0.0.0.0")
	if err != OK:
		push_warning("[LAN] discovery bind %d failed (%d)" % [discovery_port, err])
		return
	_udp = udp
	_announce_port = game_port
	_announcing = true
	set_process(true)
	if OS.is_debug_build():
		print("[LAN] announcing on udp %d for game port %d" % [discovery_port, game_port])


func stop_announcing() -> void:
	_announcing = false
	_udp = null
	_announce_port = 0
	set_process(false)


func _process(_delta: float) -> void:
	if not _announcing or _udp == null:
		return
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		var text := packet.get_string_from_utf8()
		if not text.begins_with(Protocol.LAN_PROBE_MAGIC):
			continue
		var sender_ip := _udp.get_packet_ip()
		var sender_port := _udp.get_packet_port()
		var body := _announce_json()
		if body == "":
			continue
		_udp.set_dest_address(sender_ip, sender_port)
		_udp.put_packet((Protocol.LAN_ANNOUNCE_MAGIC + "\n" + body).to_utf8_buffer())


func _announce_json() -> String:
	if not multiplayer.is_server():
		return ""
	var role := NetworkManager.role
	if role != NetworkManager.Role.LISTEN_SERVER and role != NetworkManager.Role.DEDICATED_SERVER:
		return ""
	var map_name := MatchSession.map_path.get_file().get_basename()
	var state := "active" if int(MatchSession.phase) == Protocol.Phase.ACTIVE else "staging"
	return JSON.stringify({
		"instance": _instance_id,
		"match_id": MatchSession.match_id,
		"map_path": MatchSession.map_path,
		"map": map_name,
		"players": MatchSession.player_count(),
		"max_players": Protocol.DEFAULT_MAX_PLAYERS,
		"phase": int(MatchSession.phase),
		"state": state,
		"port": MatchSession.server_port if MatchSession.server_port > 0 else _announce_port,
	})


## Returns discovered servers: [{ip, port, map, players, max_players, state,
## match_id, phase, map_path}].  Caller must `await`.
func discover(timeout_seconds: float = 0.8) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if _disabled:
		return results

	var udp := PacketPeerUDP.new()
	if udp.bind(0, "0.0.0.0") != OK:
		# Fallback for platforms that reject port 0.
		var bound := false
		for attempt in range(8):
			if udp.bind(40000 + (randi() % 10000), "0.0.0.0") == OK:
				bound = true
				break
		if not bound:
			push_warning("[LAN] could not bind a probe socket")
			return results
	udp.set_broadcast_enabled(true)

	var probe := Protocol.LAN_PROBE_MAGIC.to_utf8_buffer()
	var targets: Array[String] = ["127.0.0.1", "255.255.255.255"]
	for address in IP.get_local_addresses():
		if not address.contains(".") or address.begins_with("127.") \
				or address.begins_with("169.254.") or address.begins_with("0."):
			continue
		var parts := address.split(".")
		if parts.size() == 4:
			var broadcast := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
			if not targets.has(broadcast):
				targets.append(broadcast)

	for offset in range(Protocol.LAN_DISCOVERY_PORT_RANGE):
		var port := Protocol.LAN_DISCOVERY_PORT_BASE + offset
		for target in targets:
			udp.set_dest_address(target, port)
			udp.put_packet(probe)

	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var seen: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		while udp.get_available_packet_count() > 0:
			var text := udp.get_packet().get_string_from_utf8()
			if not text.begins_with(Protocol.LAN_ANNOUNCE_MAGIC):
				continue
			var body := text.substr(Protocol.LAN_ANNOUNCE_MAGIC.length()).strip_edges()
			var parsed: Variant = JSON.parse_string(body)
			if not parsed is Dictionary:
				continue
			var entry := parsed as Dictionary
			var ip := udp.get_packet_ip()
			var game_port := int(entry.get("port", 0))
			if game_port <= 0:
				continue
			var key := str(entry.get("instance", ""))
			if key == "":
				key = "%s:%d:%s:%s" % [str(entry.get("match_id", "")), game_port,
					str(entry.get("map", "")), ip]
			if seen.has(key):
				continue
			seen[key] = true
			entry["ip"] = ip
			results.append(entry)
		await get_tree().process_frame

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("map", "")) + str(a.get("ip", "")) < str(b.get("map", "")) + str(b.get("ip", "")))
	return results
