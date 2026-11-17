extends Node

## Process-wide match session state for the dedicated-server topology.
##
## Lives on the stable autoload path `/root/MatchSession`, so the handshake can
## arrive before the client has built `world1.tscn` and before any player node
## exists.  That is the point: the server must not address a client's player
## until the client's world is up (docs/05-known-issues.md #124).
##
## Two identities are kept apart:
##   * `player_id`   — stable, assigned by the server, used as the node name and
##                     the score key.  Survives a reconnect (P4).
##   * `peer_id`     — the ENet peer, transport-local and rebindable.
##
## Legacy P2P keeps working: `local_player_id` stays 0, so every lookup falls
## back to the peer id exactly as before.

const Protocol := preload("res://network/session_protocol.gd")
const Manifest := preload("res://network/match_manifest.gd")
const Grant := preload("res://network/join_grant.gd")

enum Role { NONE, CLIENT, SERVER }
enum SlotState { CONNECTED, RESERVED }

signal welcomed(info: Dictionary)
signal session_error(code: int, text: String)
signal player_left(player_id: int)
signal phase_changed(phase: int, map_path: String, map_hash: String)

var role: Role = Role.NONE

## Client identity.  `local_player_id == 0` means "legacy P2P: use peer id".
var local_player_id: int = 0
var local_peer_id: int = 0

## Match metadata, filled from `welcome` on the client and from the boot path on
## the server.
var match_id: String = ""
var map_path: String = ""
var map_hash: String = ""
## Map the staging room will load on START GAME.  The staging map itself stays
## the lobby map; this is only the selected match map path.
var target_map_path: String = ""
## Room-level result banner, set by the server when it enters RESULTS.
var result_text: String = ""
var phase: int = Protocol.Phase.STAGING
## Staging READY flags.  Server-authoritative; advisory only for the host.
var _ready_flags: Dictionary = {}
var local_ready := false
var host_player_id: int = 0
var server_tick_rate: int = 90
## The UDP port the match server actually bound (host side).  Used by LAN
## discovery and by the joiner.
var server_port: int = 8080

## Increments on every accepted `welcome`.  The reconnect path waits for the
## *next* welcome; `local_player_id` alone is already set from the old session.
var welcome_count: int = 0

## Client-side join grant issued by lobbyd; sent in `hello` and validated by the
## match server.  Empty on the direct `--connect` dev path.
var join_grant: String = ""

## Server-issued resume token.  The client keeps it across a dropped socket and
## presents it on the reconnect; the server rotates it on every welcome.
var resume_token: String = ""

## Server roster.  Client copies are only advisory; the server is authoritative.
## Entry: {peer_id, name, host, state: SlotState, reserved_at?}
var _players: Dictionary = {}          # player_id(int) -> {peer_id, name, host, state}
var _peer_to_player: Dictionary = {}   # peer_id(int) -> player_id(int)
var _pending_peers: Array[int] = []
var _server_ready: bool = false
var _spawn_manager: Node = null

## Peers whose client has confirmed it received its own Player node.  Player
## broadcasts (status effects first) must not be sent to a peer before this, or
## they address a node that has not replicated yet (#124).
var _ready_peers: Dictionary = {}
## Peers that have confirmed the match map exists in their world.  Used by the
## start sequence's map-ready barrier (docs/05-known-issues.md #126).
var _map_ready_peers: Dictionary = {}
var _node_ready_sent: bool = false
var _last_wait_log_ms: int = 0
var _test_start_sent: bool = false

## Liveness.  Client sends `heartbeat` every HEARTBEAT_INTERVAL; the server
## reaps a peer it has not heard from in PEER_TIMEOUT seconds.  Reserved slots
## expire after RESUME_GRACE_SECONDS.
var _last_heard: Dictionary = {}       # peer_id -> ms
var _reserved_since: Dictionary = {}   # player_id -> ms
## Connected peers that have not sent a valid `hello` yet.  Reaped after 5 s so
## a connection that never handshakes cannot sit open indefinitely.
var _preauth: Dictionary = {}          # peer_id -> ms
var _heartbeat_timer: Timer
var _heartbeat_seq: int = 0
var _server_tick_accum: float = 0.0
var _client_alive: float = 0.0
## Test override for the resume grace; production uses the protocol constant.
var _resume_grace_seconds: float = Protocol.RESUME_GRACE_SECONDS
var _test_drop_after: float = -1.0
var _test_silent_after: float = -1.0
var _test_silent_done: bool = false

var _next_player_id: int = Protocol.FIRST_PLAYER_ID


func _ready() -> void:
	set_process(false)
	var mp := get_tree().get_multiplayer()
	if not mp.peer_disconnected.is_connected(_on_peer_disconnected):
		mp.peer_disconnected.connect(_on_peer_disconnected)
	if not mp.connected_to_server.is_connected(_on_connected_to_server):
		mp.connected_to_server.connect(_on_connected_to_server)
	if not mp.peer_connected.is_connected(_on_session_peer_connected):
		mp.peer_connected.connect(_on_session_peer_connected)
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.wait_time = Protocol.HEARTBEAT_INTERVAL
	_heartbeat_timer.one_shot = false
	_heartbeat_timer.timeout.connect(_send_heartbeat)
	add_child(_heartbeat_timer)
	var drop_arg := _arg_value("--test-drop-after=")
	if drop_arg != "":
		_test_drop_after = float(drop_arg)
	var silent_arg := _arg_value("--test-silent-after=")
	if silent_arg != "":
		_test_silent_after = float(silent_arg)
	var grace_arg := _arg_value("--test-resume-grace=")
	if grace_arg != "":
		_resume_grace_seconds = float(grace_arg)


func _process(delta: float) -> void:
	if role == Role.SERVER:
		_server_tick(delta)
	elif role == Role.CLIENT:
		_client_tick(delta)


## Client-side: wait for the local Player node, bind it, then tell the server it
## is ready.  Also runs the forced-drop test hook.
func _client_tick(delta: float) -> void:
	_client_alive += delta
	if _test_drop_after >= 0.0 and _client_alive >= _test_drop_after:
		_test_drop_after = -1.0
		if OS.is_debug_build():
			print("[MATCH] test: forcing a transport drop")
		NetworkManager.debug_force_drop()
		return
	if _test_silent_after >= 0.0 and not _test_silent_done \
			and _client_alive >= _test_silent_after:
		_test_silent_done = true
		stop_heartbeat()
		if OS.is_debug_build():
			print("[MATCH] test: heartbeats stopped")
	if _node_ready_sent or local_player_id <= 0:
		return
	if not multiplayer.has_multiplayer_peer() or not is_instance_valid(GameManager.spawn_parent):
		return
	var local_player := GameManager.find_player(str(local_player_id))
	if local_player == null:
		# Diagnostic for a stuck join; prints at most once a second.
		var now := Time.get_ticks_msec()
		if now - _last_wait_log_ms > 1000 and OS.is_debug_build():
			_last_wait_log_ms = now
			var names: Array[String] = []
			if is_instance_valid(GameManager.spawn_parent):
				for child in GameManager.spawn_parent.get_children():
					names.append(str(child.name))
			print("[MATCH] waiting for player %d; SpawnParent=%s" % [local_player_id, names])
		return
	# The spawn payload carries the stable id as the node name, but not the
	# owning peer.  Bind it here so PlayerInput/Body are authoritative on this
	# client; otherwise no input is gathered and the player cannot move.
	local_player.player_id = local_player_id
	var local_peer := multiplayer.get_unique_id()
	# Always rebind.  With `owner_peer_id` replicated, the value can already
	# match this peer while the input authority is still the pre-sync fallback
	# (node name / server), so comparing first skipped the authority update.
	local_player.bind_owner_peer(local_peer)
	if OS.is_debug_build():
		print("[MATCH] rebound player %d: owner=%d input_auth=%s spawned=%s" % [
			local_player_id, local_player.owner_peer_id,
			local_player.player_input.is_multiplayer_authority(), local_player.spawned])
	client_node_ready.rpc_id(Protocol.SERVER_PEER_ID, local_player_id)
	_node_ready_sent = true
	if OS.is_debug_build():
		var names: Array[String] = []
		for child in GameManager.spawn_parent.get_children():
			names.append(str(child.name))
		print("[MATCH] node ready for player %d; SpawnParent=%s" % [local_player_id, names])

	# Test hook: a lobby-created client can start the map without walking to the
	# HostServer zone.  Only the host is allowed by the server.
	var start_path := _arg_value("--test-start-match=")
	if start_path != "" and not _test_start_sent and is_player_host(local_player_id):
		_test_start_sent = true
		if OS.is_debug_build():
			print("[MATCH] test: requesting start map %s" % start_path)
		request_start_match.rpc_id(Protocol.SERVER_PEER_ID, start_path)


## Server liveness: reap silent peers, expire reserved slots.  Runs at 2 Hz.
func _server_tick(delta: float) -> void:
	_server_tick_accum += delta
	if _server_tick_accum < 0.5:
		return
	_server_tick_accum = 0.0
	var now := Time.get_ticks_msec()

	for peer_key in _last_heard.keys():
		var peer_id := int(peer_key)
		if peer_id == Protocol.SERVER_PEER_ID:
			continue  # never reap ourselves
		if now - int(_last_heard[peer_key]) <= int(Protocol.PEER_TIMEOUT * 1000.0):
			continue
		if OS.is_debug_build():
			print("[MATCH] reaping silent peer %d" % peer_id)
		var peer := multiplayer.multiplayer_peer
		if peer is ENetMultiplayerPeer:
			(peer as ENetMultiplayerPeer).disconnect_peer(peer_id)
		_last_heard.erase(peer_key)

	# Pre-auth connections that never complete `hello`.
	for peer_key in _preauth.keys():
		var peer_id := int(peer_key)
		if now - int(_preauth[peer_key]) <= int(Protocol.PREAUTH_TIMEOUT_SECONDS * 1000.0):
			continue
		if OS.is_debug_build():
			print("[MATCH] reaping pre-auth peer %d" % peer_id)
		var peer := multiplayer.multiplayer_peer
		if peer is ENetMultiplayerPeer:
			(peer as ENetMultiplayerPeer).disconnect_peer(peer_id)
		_preauth.erase(peer_key)

	for player_key in _reserved_since.keys():
		var player_id := int(player_key)
		if now - int(_reserved_since[player_key]) <= int(_resume_grace_seconds * 1000.0):
			continue
		if OS.is_debug_build():
			print("[MATCH] reserved slot for player %d expired" % player_id)
		_expire_reserved(player_id)


func _expire_reserved(player_id: int) -> void:
	_reserved_since.erase(player_id)
	var was_host := player_id == host_player_id
	_players.erase(player_id)
	if _spawn_manager != null and _spawn_manager.has_method("remove_reserved_player"):
		_spawn_manager.remove_reserved_player(player_id)
	player_left.emit(player_id)

	# Host migration: the host's grace expired, so promote the lowest surviving
	# connected player.  A host that reconnects inside the grace keeps the role.
	if was_host:
		var next_host := 0
		var ids := _players.keys()
		ids.sort()
		for pid in ids:
			var entry: Dictionary = _players[pid]
			if int(entry.get("state", SlotState.CONNECTED)) == SlotState.CONNECTED:
				next_host = int(pid)
				break
		host_player_id = next_host
		broadcast_host.rpc(host_player_id)
		if OS.is_debug_build():
			print("[MATCH] host migrated to player %d" % next_host)


## Server → all peers: the room host changed (the previous host's slot expired).
@rpc("authority", "call_local", "reliable")
func broadcast_host(new_host_id: int) -> void:
	host_player_id = new_host_id
	if OS.is_debug_build():
		print("[MATCH] host is now player %d" % new_host_id)


func _arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


# ─────────────────────────────────────────────
#  Role / lifecycle
# ─────────────────────────────────────────────

## `staging_map` is the map the client should build *before* the handshake
## returns.  Maps are local assets on every peer; the server only confirms the
## path and hash in `welcome`.
func begin_client(staging_map: String = "", grant: String = "") -> void:
	reset()
	role = Role.CLIENT
	map_path = staging_map
	join_grant = grant
	local_peer_id = multiplayer.get_unique_id()
	_client_alive = 0.0
	_node_ready_sent = false
	set_process(true)


func begin_server(staging_map: String, staging_hash: String = "", new_match_id: String = "") -> void:
	reset()
	role = Role.SERVER
	map_path = staging_map
	map_hash = staging_hash
	match_id = new_match_id
	phase = Protocol.Phase.STAGING
	# The server itself is always "ready"; joining clients are added on ACK.
	_ready_peers[Protocol.SERVER_PEER_ID] = true
	_last_heard[Protocol.SERVER_PEER_ID] = Time.get_ticks_msec()
	set_process(true)


## Register the host's own player on a listen server (peer 1 is a participant
## there, unlike a dedicated server).  Player ids allocated to joining peers
## start at 2, so id 1 is always free for this.
func register_host_player(player_id: int = 1) -> void:
	if role != Role.SERVER:
		return
	_players[player_id] = {
		"peer_id": Protocol.SERVER_PEER_ID,
		"name": str(player_id),
		"host": true,
		"state": SlotState.CONNECTED,
	}
	_peer_to_player[Protocol.SERVER_PEER_ID] = player_id
	_last_heard[Protocol.SERVER_PEER_ID] = Time.get_ticks_msec()
	host_player_id = player_id


func grant_secret_configured() -> bool:
	return Grant.is_configured()


func mark_server_world_ready(spawn_manager: Node) -> void:
	_spawn_manager = spawn_manager
	_server_ready = true
	for peer_id in _pending_peers.duplicate():
		_accept_peer(peer_id)
	_pending_peers.clear()


func reset() -> void:
	role = Role.NONE
	local_player_id = 0
	local_peer_id = 0
	match_id = ""
	map_path = ""
	map_hash = ""
	target_map_path = ""
	result_text = ""
	join_grant = ""
	resume_token = ""
	welcome_count = 0
	phase = Protocol.Phase.STAGING
	host_player_id = 0
	server_tick_rate = 90
	_players.clear()
	_peer_to_player.clear()
	_pending_peers.clear()
	_ready_peers.clear()
	_map_ready_peers.clear()
	_ready_flags.clear()
	local_ready = false
	_last_heard.clear()
	_reserved_since.clear()
	_preauth.clear()
	_server_ready = false
	_spawn_manager = null
	_node_ready_sent = false
	_test_start_sent = false
	_heartbeat_seq = 0
	_server_tick_accum = 0.0
	_client_alive = 0.0
	if _heartbeat_timer != null:
		_heartbeat_timer.stop()
	set_process(false)
	_next_player_id = Protocol.FIRST_PLAYER_ID


func stop_heartbeat() -> void:
	if _heartbeat_timer != null:
		_heartbeat_timer.stop()


# ─────────────────────────────────────────────
#  Identity helpers
# ─────────────────────────────────────────────

## The local player's stable id as a string.  Falls back to the peer id for
## legacy P2P, which is what every pre-migration lookup used.
func local_id_string() -> String:
	if local_player_id > 0:
		return str(local_player_id)
	return str(multiplayer.get_unique_id())


## Map an ENet peer to a stable player id for RPC sender validation.
## Returns the peer id string when no mapping exists, matching legacy behaviour.
func player_id_string_for_peer(peer_id: int) -> String:
	if _peer_to_player.has(peer_id):
		return str(_peer_to_player[peer_id])
	return str(peer_id)


func player_id_for_peer(peer_id: int) -> int:
	return int(_peer_to_player.get(peer_id, 0))


func peer_for_player(player_id: int) -> int:
	var entry: Dictionary = _players.get(player_id, {})
	return int(entry.get("peer_id", 0))


func has_player(player_id: int) -> bool:
	return _players.has(player_id)


## Server roster size (connected + reserved).  Used by the LAN announce.
func player_count() -> int:
	return _players.size()


## Server-side broadcast gate.  Legacy P2P (role NONE) always returns true so
## the old replication path is unchanged.
func is_peer_ready(peer_id: int) -> bool:
	if role != Role.SERVER:
		return true
	return bool(_ready_peers.get(peer_id, false))


func local_is_host() -> bool:
	# A listen server has no client-side `welcome`; the process itself is the
	# host.  A dedicated server also answers true, but has no local player so the
	# in-world zones never see it.
	if role == Role.SERVER:
		return true
	if host_player_id == 0:
		return multiplayer.get_unique_id() == Protocol.SERVER_PEER_ID
	return local_player_id == host_player_id


func is_player_host(player_id: int) -> bool:
	return host_player_id != 0 and player_id == host_player_id


# ─────────────────────────────────────────────
#  Handshake — server
# ─────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func hello(version: int, build_id: String, display_name: String,
		join_grant_token: String = "", resume_token_in: String = "") -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		# A legacy P2P host ignores the handshake; its clients never send it.
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		return
	_preauth.erase(peer_id)
	if version != Protocol.VERSION:
		_send_error(peer_id, Protocol.ErrorCode.UNSUPPORTED_VERSION, "Protocol %d != %d" % [version, Protocol.VERSION])
		return
	if build_id != Protocol.BUILD_ID:
		_send_error(peer_id, Protocol.ErrorCode.BUILD_MISMATCH, "Build %s != %s" % [build_id, Protocol.BUILD_ID])
		return
	_last_heard[peer_id] = Time.get_ticks_msec()

	# Resume takes priority: it reuses an existing slot and preserves score,
	# team, and loadout.
	if resume_token_in != "":
		var resume_payload := Grant.resume_data(resume_token_in, match_id)
		var resumed_id := int(resume_payload.get("player_id", 0))
		if resumed_id == 0:
			_send_error(peer_id, Protocol.ErrorCode.SESSION_EXPIRED, "Invalid or expired resume token")
			return
		var resumed_entry: Dictionary = _players.get(resumed_id, {})
		if resumed_entry.is_empty() or int(resumed_entry.get("state", SlotState.CONNECTED)) != SlotState.RESERVED:
			_send_error(peer_id, Protocol.ErrorCode.SESSION_EXPIRED, "No reserved slot for this session")
			return
		# Single-use: only the token issued by the latest welcome is accepted.
		var expected_nonce := str(resumed_entry.get("resume_nonce", ""))
		if expected_nonce != "" and str(resume_payload.get("nonce", "")) != expected_nonce:
			_send_error(peer_id, Protocol.ErrorCode.SESSION_EXPIRED, "Resume token was already used")
			return
		_resume_player(resumed_id, peer_id)
		return

	if not Grant.validate(join_grant_token, match_id):
		_send_error(peer_id, Protocol.ErrorCode.BAD_TOKEN, "Invalid or expired join grant")
		return

	if _peer_to_player.has(peer_id):
		# Duplicate hello (the client retried, or both sides raced a reconnect).
		# Re-send the existing assignment instead of allocating a second player.
		if _server_ready:
			_accept_peer(peer_id)
		return

	if _players.size() >= Protocol.DEFAULT_MAX_PLAYERS:
		_send_error(peer_id, Protocol.ErrorCode.MATCH_FULL, "Match is full")
		return

	var player_id := _allocate_player_id()
	if player_id == 0:
		_send_error(peer_id, Protocol.ErrorCode.SERVER_BUSY, "No free player slot")
		return

	_players[player_id] = {
		"peer_id": peer_id,
		"name": display_name if display_name != "" else str(player_id),
		"host": host_player_id == 0,
		"state": SlotState.CONNECTED,
	}
	_peer_to_player[peer_id] = player_id
	if host_player_id == 0:
		host_player_id = player_id

	# Hide existing players' state sync from this peer until its own node is up.
	if _spawn_manager != null and _spawn_manager.has_method("hide_players_from_peer"):
		_spawn_manager.hide_players_from_peer(peer_id)

	if _server_ready:
		_accept_peer(peer_id)
	else:
		_pending_peers.append(peer_id)


## Rebind a reserved slot to a new ENet peer without creating a new Player.
func _resume_player(player_id: int, peer_id: int) -> void:
	var entry: Dictionary = _players[player_id]
	entry["peer_id"] = peer_id
	entry["state"] = SlotState.CONNECTED
	_peer_to_player[peer_id] = player_id
	_reserved_since.erase(player_id)
	_ready_peers[peer_id] = true
	_last_heard[peer_id] = Time.get_ticks_msec()
	if OS.is_debug_build():
		print("[MATCH] resuming player %d on peer %d" % [player_id, peer_id])
	if _spawn_manager != null and _spawn_manager.has_method("show_players_to_peer"):
		# Clear the per-peer sync suppression; otherwise the resumed client's
		# state freezes at the tick it disconnected.
		_spawn_manager.show_players_to_peer(peer_id)
	if _spawn_manager != null and _spawn_manager.has_method("resume_player"):
		_spawn_manager.resume_player(player_id, peer_id)
	bind_peer.rpc(player_id, peer_id)
	await get_tree().process_frame
	_send_welcome(peer_id, player_id, true)
	if _spawn_manager != null and _spawn_manager.has_method("sync_existing_players_to_peer"):
		_spawn_manager.sync_existing_players_to_peer(peer_id, player_id)


func _allocate_player_id() -> int:
	for player_id in range(Protocol.FIRST_PLAYER_ID, Protocol.MAX_PLAYER_ID + 1):
		if not _players.has(player_id):
			return player_id
	return 0


## Spawn the player and send the welcome.  The one-frame gap lets the reliably
## replicated Player node reach the client before the first RPC that addresses
## it, which is what #124 was.
func _accept_peer(peer_id: int) -> void:
	var player_id := player_id_for_peer(peer_id)
	if player_id == 0:
		return
	if OS.is_debug_build():
		print("[MATCH] accepting peer %d as player %d" % [peer_id, player_id])
	if _spawn_manager != null and _spawn_manager.has_method("add_remote_player"):
		if not _spawn_manager.has_remote_player(player_id):
			_spawn_manager.add_remote_player(player_id, peer_id)
	await get_tree().process_frame
	_send_welcome(peer_id, player_id)


## Called by the client once its own Player node exists.  Existing-player state
## is synced from here, not from `_accept_peer`, so the client is not addressed
## before its nodes have replicated (#124).
@rpc("any_peer", "call_remote", "reliable")
func client_node_ready(player_id: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0 or player_id_for_peer(peer_id) != player_id:
		return
	if is_peer_ready(peer_id):
		return
	_ready_peers[peer_id] = true
	if _spawn_manager != null and _spawn_manager.has_method("show_players_to_peer"):
		_spawn_manager.show_players_to_peer(peer_id)
	await get_tree().process_frame
	if _spawn_manager != null and _spawn_manager.has_method("sync_existing_players_to_peer"):
		_spawn_manager.sync_existing_players_to_peer(peer_id, player_id)


func _send_welcome(peer_id: int, player_id: int, resumed: bool = false) -> void:
	var token := Grant.issue_resume(match_id, player_id)
	# Remember the nonce this welcome issued; an older resume token is then
	# rejected on the next reconnect (single-use rotation).
	var entry: Dictionary = _players.get(player_id, {})
	if not entry.is_empty():
		entry["resume_nonce"] = str(Grant.resume_data(token, match_id).get("nonce", ""))
	if OS.is_debug_build():
		print("[MATCH] sending welcome to peer %d (player %d, map %s, resumed=%s)" % [
			peer_id, player_id, map_path, resumed])
	welcome.rpc_id(peer_id, Protocol.VERSION, player_id, peer_id, server_tick_rate,
		map_path, map_hash, phase, host_player_id, NetworkTime.tick, resumed, token)
	if target_map_path != "":
		_rpc_set_staging_map.rpc_id(peer_id, target_map_path)


func _send_error(peer_id: int, code: int, text: String) -> void:
	session_error_rpc.rpc_id(peer_id, code, text)


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var player_id := player_id_for_peer(peer_id)
	_peer_to_player.erase(peer_id)
	_pending_peers.erase(peer_id)
	_ready_peers.erase(peer_id)
	_last_heard.erase(peer_id)
	_map_ready_peers.erase(peer_id)
	if player_id == 0:
		return
	var entry: Dictionary = _players.get(player_id, {})
	if entry.is_empty():
		return
	# Keep the slot and the Player node for the resume grace period.  The node
	# is despawned, so it stops simulating and cannot be shot, but score, team,
	# and loadout stay on it.
	entry["peer_id"] = 0
	entry["state"] = SlotState.RESERVED
	_reserved_since[player_id] = Time.get_ticks_msec()
	if OS.is_debug_build():
		print("[MATCH] player %d reserved for %.0fs" % [player_id, _resume_grace_seconds])
	if _spawn_manager != null and _spawn_manager.has_method("reserve_player"):
		_spawn_manager.reserve_player(player_id)


## Server → every peer: the player's owning peer changed after a resume.
@rpc("authority", "call_local", "reliable")
func bind_peer(player_id: int, peer_id: int) -> void:
	var player := GameManager.find_player(str(player_id))
	if player != null:
		player.bind_owner_peer(peer_id)
	if role == Role.SERVER:
		var entry: Dictionary = _players.get(player_id, {})
		if not entry.is_empty():
			entry["peer_id"] = peer_id


@rpc("any_peer", "call_remote", "unreliable")
func heartbeat(_seq: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	_last_heard[multiplayer.get_remote_sender_id()] = Time.get_ticks_msec()


func _send_heartbeat() -> void:
	if role != Role.CLIENT:
		return
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return
	_heartbeat_seq += 1
	heartbeat.rpc_id(Protocol.SERVER_PEER_ID, _heartbeat_seq)


func _on_session_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server() and role == Role.SERVER:
		_preauth[peer_id] = Time.get_ticks_msec()


func _on_connected_to_server() -> void:
	local_peer_id = multiplayer.get_unique_id()


# ─────────────────────────────────────────────
#  Handshake — client
# ─────────────────────────────────────────────

## Called only after the client's world scene exists and has settled.
func request_hello(display_name: String = "") -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return
	hello.rpc_id(Protocol.SERVER_PEER_ID, Protocol.VERSION, Protocol.BUILD_ID,
		display_name, join_grant, resume_token)


@rpc("authority", "call_remote", "reliable")
func welcome(version: int, player_id: int, owner_peer_id: int, tick_rate: int,
		server_map_path: String, server_map_hash: String, server_phase: int,
		server_host_player_id: int, server_tick: int, resumed: bool,
		new_resume_token: String = "") -> void:
	if OS.is_debug_build():
		print("[MATCH] welcome received: player=%d owner=%d map=%s resumed=%s" % [
			player_id, owner_peer_id, server_map_path, resumed])
	if version != Protocol.VERSION:
		session_error.emit(Protocol.ErrorCode.UNSUPPORTED_VERSION, "Server protocol %d" % version)
		return
	# Maps are loaded locally; refuse a build whose map bytes differ from the
	# server's before joining gameplay.
	if server_map_path != "" and server_map_hash != "" \
			and not Manifest.verify_map(server_map_path, server_map_hash):
		session_error.emit(Protocol.ErrorCode.MAP_MISMATCH,
			"Map hash mismatch for %s" % server_map_path)
		return
	var previous_map := map_path
	welcome_count += 1
	local_player_id = player_id
	local_peer_id = owner_peer_id
	resume_token = new_resume_token
	_node_ready_sent = false
	set_process(true)
	server_tick_rate = tick_rate
	map_path = server_map_path
	map_hash = server_map_hash
	phase = server_phase
	host_player_id = server_host_player_id
	if _heartbeat_timer != null:
		_heartbeat_timer.start()
	# A resume after a map swap missed `phase_changed`; apply it now.  The
	# initial join already built the same map in `begin_client`.
	if server_map_path != "" and previous_map != "" and server_map_path != previous_map:
		phase_changed.emit(server_phase, server_map_path, server_map_hash)
	welcomed.emit({
		"player_id": player_id,
		"owner_peer_id": owner_peer_id,
		"tick_rate": tick_rate,
		"map_path": server_map_path,
		"map_hash": server_map_hash,
		"phase": server_phase,
		"host_player_id": server_host_player_id,
		"server_tick": server_tick,
		"resumed": resumed,
	})


@rpc("authority", "call_remote", "reliable")
func session_error_rpc(code: int, text: String) -> void:
	session_error.emit(code, text)


## The room leader (a client on a dedicated server) asks the server to load the
## match map.  The server re-checks that the sender is the host and that the
## path is a real map file under `res://maps/`.
@rpc("any_peer", "call_remote", "reliable")
func request_start_match(new_map_path: String) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var player_id := player_id_for_peer(peer_id)
	if not is_player_host(player_id):
		if OS.is_debug_build():
			print("[MATCH] start rejected: player %d is not host" % player_id)
		return
	if not new_map_path.begins_with("res://maps/") or not FileAccess.file_exists(new_map_path):
		if OS.is_debug_build():
			print("[MATCH] start rejected: bad map path '%s'" % new_map_path)
		return
	var allowed := false
	for map_entry in ConnectionUtils.scan_map_data():
		var map_data := map_entry as MapData
		if map_data != null and map_data.map_scene_path == new_map_path:
			allowed = true
			break
	if not allowed:
		if OS.is_debug_build():
			print("[MATCH] start rejected: %s is not a playable MapData" % new_map_path)
		return
	if OS.is_debug_build():
		print("[MATCH] start approved: %s" % new_map_path)
	NetworkManager.start_staging_match(new_map_path)


## Server-selected staging map.  The server keeps the lobby map loaded while
## players are in the staging room; this path is what START GAME will load.
func set_staging_map(new_path: String) -> void:
	if not multiplayer.is_server():
		return
	target_map_path = new_path
	_rpc_set_staging_map.rpc(new_path)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_staging_map(new_path: String) -> void:
	target_map_path = new_path


## Host-only staging map change, for a dedicated/lobbyd host who is a client.
@rpc("any_peer", "call_remote", "reliable")
func request_set_staging_map(new_path: String) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var pid := player_id_for_peer(multiplayer.get_remote_sender_id())
	if not is_player_host(pid):
		return
	if not new_path.begins_with("res://maps/") or not FileAccess.file_exists(new_path):
		return
	var allowed := false
	for entry in ConnectionUtils.scan_map_data():
		var md := entry as MapData
		if md != null and md.map_scene_path == new_path:
			allowed = true
			break
	if allowed:
		set_staging_map(new_path)


## Client confirmation that it finished loading the announced map.
func notify_map_ready() -> void:
	if multiplayer.is_server():
		_map_ready_peers[Protocol.SERVER_PEER_ID] = true
		return
	if local_player_id <= 0:
		return
	client_map_ready.rpc_id(Protocol.SERVER_PEER_ID, local_player_id)


@rpc("any_peer", "call_remote", "reliable")
func client_map_ready(player_id: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0 or player_id_for_peer(peer_id) != player_id:
		return
	_map_ready_peers[peer_id] = true


## Server-side map barrier.  The host/listen server is always considered ready;
## every other connected peer must ACK.  Returns false on timeout.
func await_map_ready(timeout_seconds: float) -> bool:
	if not multiplayer.is_server():
		return true
	_map_ready_peers[Protocol.SERVER_PEER_ID] = true
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var pending := false
		for pid_key in _players.keys():
			var entry: Dictionary = _players[pid_key]
			if int(entry.get("state", SlotState.CONNECTED)) != SlotState.CONNECTED:
				continue
			var peer_id := int(entry.get("peer_id", 0))
			if peer_id == 0 or peer_id == Protocol.SERVER_PEER_ID:
				continue
			if not _map_ready_peers.has(peer_id):
				pending = true
				break
		if not pending:
			return true
		await get_tree().process_frame
	return false


## Late join: spawn the player into an already-ACTIVE match.  The client's
## stored build was applied in world_1 before it asked for this.
@rpc("any_peer", "call_remote", "reliable")
func request_join_in_progress(player_id: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0 or player_id_for_peer(peer_id) != player_id:
		return
	if phase != Protocol.Phase.ACTIVE:
		return
	var player := GameManager.find_player(str(player_id))
	if player == null:
		return
	var frame := _choose_balanced_team()
	if frame != Player.Team.FFA or player.team == Player.Team.FFA:
		player.team = frame
	player.rpc_reset.rpc(player._get_spawn_transform())


func is_ready(player_id: int) -> bool:
	return bool(_ready_flags.get(player_id, false))


func set_local_ready(on: bool) -> void:
	if multiplayer.is_server():
		local_ready = on
		_ready_flags[local_player_id if local_player_id > 0 else 1] = on
		_rpc_ready.rpc(local_player_id if local_player_id > 0 else 1, on)
		return
	if local_player_id > 0:
		request_set_ready.rpc_id(Protocol.SERVER_PEER_ID, on)


@rpc("any_peer", "call_remote", "reliable")
func request_set_ready(on: bool) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	var pid := player_id_for_peer(multiplayer.get_remote_sender_id())
	if pid == 0:
		return
	_ready_flags[pid] = on
	_rpc_ready.rpc(pid, on)


@rpc("authority", "call_remote", "reliable")
func _rpc_ready(player_id: int, on: bool) -> void:
	_ready_flags[player_id] = on
	if player_id == local_player_id:
		local_ready = on


## Host-only staging bot spawn.  A dedicated/lobbyd host is a client and has no
## local SpawnManager, so this must cross the wire.
@rpc("any_peer", "call_remote", "reliable")
func request_add_bot(team: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	if not is_player_host(player_id_for_peer(multiplayer.get_remote_sender_id())):
		return
	if phase != Protocol.Phase.STAGING:
		return
	if GameManager.spawn_manager:
		GameManager.spawn_manager.add_bot(team)


## Staging self team switch.  Team modes only; the server applies the change.
@rpc("any_peer", "call_remote", "reliable")
func request_switch_team(player_id: int) -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	if phase != Protocol.Phase.STAGING:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id != 0 and player_id_for_peer(peer_id) != player_id:
		return
	var player := GameManager.find_player(str(player_id))
	if player == null:
		return
	match player.team:
		Player.Team.SPI: player.team = Player.Team.SCI
		Player.Team.SCI: player.team = Player.Team.SPI
		_: pass


## Host-only room end.  The match server validates the sender against
## host_player_id, then sets RESULTS for every room-level UI.
@rpc("any_peer", "call_remote", "reliable")
func request_end_match() -> void:
	if not multiplayer.is_server() or role != Role.SERVER:
		return
	if not is_player_host(player_id_for_peer(multiplayer.get_remote_sender_id())):
		return
	NetworkManager.end_match()


func _choose_balanced_team() -> Player.Team:
	if not is_instance_valid(GameManager.spawn_parent):
		return Player.Team.FFA
	var spi := 0
	var sci := 0
	for child in GameManager.spawn_parent.get_children():
		if child is Player:
			var p := child as Player
			if p.team == Player.Team.SPI:
				spi += 1
			elif p.team == Player.Team.SCI:
				sci += 1
	if spi == 0 and sci == 0:
		return Player.Team.FFA
	return Player.Team.SCI if sci <= spi else Player.Team.SPI


## Server → all peers.  Used by the map-start flow; P2 only needs the signal.
@rpc("authority", "call_remote", "reliable")
func broadcast_phase(new_phase: int, new_map_path: String, new_map_hash: String) -> void:
	phase = new_phase
	map_path = new_map_path
	map_hash = new_map_hash
	phase_changed.emit(new_phase, new_map_path, new_map_hash)


## Server → every peer: result banner for the RESULTS screen.
func set_results(text: String) -> void:
	if not multiplayer.is_server():
		return
	result_text = text
	_rpc_set_results.rpc(text)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_results(text: String) -> void:
	result_text = text


func set_phase(new_phase: int, new_map_path: String = "", new_map_hash: String = "") -> void:
	if not multiplayer.is_server():
		return
	# The server is authoritative and broadcast_phase is call_remote-only, so
	# the server's own copy must be updated explicitly.  Without this a host
	# stayed in STAGING while its clients were told ACTIVE.
	phase = new_phase
	if new_phase == Protocol.Phase.COUNTDOWN:
		_ready_flags.clear()
	if new_phase == Protocol.Phase.LOADING:
		_map_ready_peers.clear()
	if new_map_path != "":
		map_path = new_map_path
		map_hash = new_map_hash
	broadcast_phase.rpc(new_phase, map_path, map_hash)
