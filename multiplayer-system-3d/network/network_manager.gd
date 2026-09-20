extends Node

const SERVER_PORT: int = 8080
const GAME_SCENE = "res://world/world1.tscn"
const LOBBY_MAP_PATH = "res://maps/main_menu_world.tscn"

var is_hosting_game = false
var game_scene


func _ready() -> void:
	# Connect the session-lifetime connection signals once.  These live on the
	# SceneMultiplayer, not the peer, so they survive peer teardown/rebind.
	var mp := get_tree().get_multiplayer()
	if not mp.connected_to_server.is_connected(_on_connected_to_server):
		mp.connected_to_server.connect(_on_connected_to_server)
	if not mp.connection_failed.is_connected(_on_connection_failed):
		mp.connection_failed.connect(_on_connection_failed)
	if not mp.server_disconnected.is_connected(_server_disconnected):
		mp.server_disconnected.connect(_server_disconnected)


# ─────────────────────────────────────────────
#  Peer creation
# ─────────────────────────────────────────────

func create_server() -> Error:
	is_hosting_game = true
	var enet_network_peer := ENetMultiplayerPeer.new()
	var err := enet_network_peer.create_server(SERVER_PORT)
	if err != OK:
		# Port already in use (e.g. a second local instance).  Fall back to an
		# offline peer so the player still gets a working local lobby they can
		# later "Join Local" out of.
		push_warning("Port %d in use — falling back to offline peer." % SERVER_PORT)
		get_tree().get_multiplayer().multiplayer_peer = OfflineMultiplayerPeer.new()
		# NetworkEvents won't auto-start NetworkTime for an offline peer, so the
		# rollback tick loop would never run (no movement).  Start it manually.
		NetworkTime.start()
		return err
	get_tree().get_multiplayer().multiplayer_peer = enet_network_peer
	if OS.is_debug_build(): print("Server created!")
	return OK


func create_client(host_ip: String = "localhost", host_port: int = SERVER_PORT) -> Error:
	is_hosting_game = false
	_terminate_connection()  # release our own server/offline peer before connecting
	var enet_network_peer := ENetMultiplayerPeer.new()
	var err := enet_network_peer.create_client(host_ip, host_port)
	if err != OK:
		return err
	get_tree().get_multiplayer().multiplayer_peer = enet_network_peer
	if OS.is_debug_build(): print("Client peer created!")
	return OK


# ─────────────────────────────────────────────
#  Scene entry
# ─────────────────────────────────────────────

func enter_existing_game_scene():
	if OS.is_debug_build(): print("Entering game scene")
	game_scene = preload(GAME_SCENE).instantiate()
	get_tree().current_scene.add_child(game_scene)
	get_tree().current_scene.hide_main_menu()


func load_game_scene(map_path: String):
	if OS.is_debug_build(): print("Loading game scene")
	game_scene = preload(GAME_SCENE).instantiate()
	game_scene.map_path = map_path
	get_tree().current_scene.add_child(game_scene)
	get_tree().current_scene.hide_main_menu()


# ─────────────────────────────────────────────
#  Lobby / party flow
# ─────────────────────────────────────────────

## Boot-time entry: become the host (peer 1 / party leader) and load the lobby.
func boot_to_lobby() -> void:
	if game_scene != null:
		return  # already booted (guards against double-scheduled boots)
	create_server()  # offline fallback handled inside
	load_game_scene(LOBBY_MAP_PATH)


## A player already in their own lobby connects to a host's lobby/match.
func join_party(host_ip: String, host_port: int = SERVER_PORT) -> void:
	_remove_game_scene()
	var err := create_client(host_ip, host_port)
	if err != OK:
		return_to_lobby()


## Leave the current match/party and return to a fresh solo lobby.
func return_to_lobby() -> void:
	if OS.is_debug_build(): print("Returning to lobby...")
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_terminate_connection()  # close peer FIRST so port 8080 frees for re-host
	_remove_game_scene()
	# Re-host on a deferred call.  A synchronous teardown+rehost is invisible to
	# NetworkEvents' per-frame is_server() polling, so it would never re-emit
	# on_server_start -> NetworkTime.start(), leaving the rollback tick loop dead
	# (movement stops while look/shoot still work).  Deferring lets NetworkEvents
	# observe the server-stop transition first, then the re-host re-triggers it.
	call_deferred("boot_to_lobby")


## Server-authoritative map swap (lobby -> match).  The MultiplayerSpawner
## replicates the Map removal/addition to every connected peer.
func load_match_map(map_path: String) -> void:
	if not multiplayer.is_server():
		return
	var sp: Node3D = GameManager.spawn_parent
	if sp == null:
		return

	# Fresh match: clear scores and the disconnected list.
	Leaderboard.reset()

	var old_map: Node = sp.get_node_or_null("Map")
	GameManager.game_mode_component = null  # clear dangling ref before removal
	if old_map:
		sp.remove_child(old_map)
		old_map.queue_free()  # do NOT free() — spawner needs the removal event

	var new_map: Node = load(map_path).instantiate()
	new_map.name = "Map"
	sp.add_child(new_map)

	# Respawn existing players on the new map (after it exists so
	# _get_spawn_position() finds it).
	for child in sp.get_children():
		if child is Player:
			child.rpc_reset.rpc(child._get_spawn_position())


func _remove_game_scene() -> void:
	if game_scene == null:
		return
	if game_scene.get_parent() != null:
		game_scene.get_parent().remove_child(game_scene)
	game_scene.queue_free()
	game_scene = null


# ─────────────────────────────────────────────
#  Connection callbacks
# ─────────────────────────────────────────────

func _on_connected_to_server() -> void:
	if OS.is_debug_build(): print("Connected (id %d)" % multiplayer.get_unique_id())
	enter_existing_game_scene()


func _on_connection_failed() -> void:
	if OS.is_debug_build(): print("Connection failed")
	return_to_lobby()


func _server_disconnected() -> void:
	if OS.is_debug_build(): print("Server has disconnected!")
	return_to_lobby()


func _terminate_connection() -> void:
	if OS.is_debug_build(): print("terminate connection")
	var mp = get_tree().get_multiplayer()
	if mp.multiplayer_peer != null:
		NetworkTime.stop()  # full stop: resets state so a re-host/re-join re-syncs
		mp.multiplayer_peer.close()
		mp.multiplayer_peer = null
