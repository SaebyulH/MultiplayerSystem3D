extends Control


## Heavy boot-time resources, preloaded on a background thread so the loading
## screen can show real progress.  Preloading them (with the default
## CACHE_MODE_REUSE) puts them in the resource cache, so the later load() calls
## in world_1.gd / loadout_menu.gd / spawn_manager.gd become instant cache hits.
const PRELOAD_PATHS: Array[String] = [
	"res://maps/main_menu_world.tscn",
	"res://world/spawn_manager.tscn",
	"res://world/spawn_bot_menu.tscn",
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assistance.tres",
]

## Fraction of the loading bar that the resource preload covers; the remaining
## span is filled by boot-time checkpoints (server start, world load, spawns).
const PRELOAD_FRACTION := 0.7

## Boot routes, passed after `--` on the command line:
##   --server                 headless dedicated match server (peer 1 is not a player)
##   --listen-server          host + play in one process (dev/LAN)
##   --offline                local 3D lobby shell, no network peer
##   --connect=host[:port]    connect to an existing server
##   --legacy-p2p             old auto-host P2P behaviour (no longer the default)
##   --port=N                 match server UDP port (default 8080)
##   --match-id=N             match id passed by lobbyd to a dedicated server
##   --lobby=http://host:port override the default VPS lobby URL
##   --no-lobby               disable the C lobby (LAN/direct only)
##   --lobby-create           create a match through the lobby, then connect
##   --lobby-join=CODE        join a lobby match by code, then connect
##   --test-host-local        boot the shell, then host a listen server (test)
const ARG_SERVER := "--server"
const ARG_LISTEN_SERVER := "--listen-server"
const ARG_OFFLINE := "--offline"
const ARG_LEGACY_P2P := "--legacy-p2p"
const ARG_CONNECT_PREFIX := "--connect="
const ARG_PORT_PREFIX := "--port="
const ARG_MATCH_ID_PREFIX := "--match-id="
const ARG_LOBBY_PREFIX := "--lobby="
const ARG_NO_LOBBY := "--no-lobby"
const ARG_LOBBY_CREATE := "--lobby-create"
const ARG_LOBBY_JOIN_PREFIX := "--lobby-join="
const ARG_TEST_HOST_LOCAL := "--test-host-local"
const ARG_TEST_HOST_MAP_PREFIX := "--test-host-map="
const ARG_TEST_LAN := "--test-lan"


func _ready() -> void:
	_boot()


func _boot() -> void:
	var loading: LoadingScreen = $LoadingScreen
	loading.visible = true

	var args := OS.get_cmdline_user_args()
	var port := _int_arg(args, ARG_PORT_PREFIX, NetworkManager.SERVER_PORT)
	var lobby_url := _arg_value(args, ARG_LOBBY_PREFIX)
	if args.has(ARG_NO_LOBBY):
		LobbyClient.configure("")
	elif lobby_url != "":
		LobbyClient.configure(lobby_url)
	else:
		LobbyClient.configure(LobbyClient.DEFAULT_BASE_URL)

	if args.has(ARG_SERVER):
		# The dedicated server still loads the player scene and staging map, so
		# keep the resource preload; it just never builds local-player UI.
		await _preload_resources(loading)
		await NetworkManager.boot_dedicated_server(port, _arg_value(args, ARG_MATCH_ID_PREFIX))
		loading.visible = false
		return

	await _preload_resources(loading)

	if args.has(ARG_LOBBY_CREATE):
		await _lobby_create_and_join()
		return
	if _arg_value(args, ARG_LOBBY_JOIN_PREFIX) != "":
		await _lobby_join_by_code(_arg_value(args, ARG_LOBBY_JOIN_PREFIX))
		return

	if args.has(ARG_OFFLINE):
		await NetworkManager.boot_offline_lobby()
	elif _arg_value(args, ARG_CONNECT_PREFIX) != "":
		var target := _arg_value(args, ARG_CONNECT_PREFIX)
		var host := target
		var connect_port := NetworkManager.SERVER_PORT
		if target.contains(":"):
			host = target.get_slice(":", 0)
			connect_port = int(target.get_slice(":", 1))
		# Direct-IP dev joins target a match server, so they use the handshake.
		await NetworkManager.join_party(host, connect_port, true)
		# join_party owns the loading screen and hides it once the tick loop is up.
		return
	elif args.has(ARG_LISTEN_SERVER):
		await NetworkManager.boot_listen_server(port)
	else:
		# Default shell: the lobby is configured by default, so the Match Menu can
		# create locally or through the VPS lobby.  Boot never blocks on HTTP.
		await NetworkManager.boot_offline_lobby()
		if args.has(ARG_TEST_HOST_LOCAL):
			var test_map := _arg_value(args, ARG_TEST_HOST_MAP_PREFIX)
			await NetworkManager.host_local_match(port, test_map if test_map != "" else NetworkManager.LOBBY_MAP_PATH)
		elif args.has(ARG_TEST_LAN):
			var entries: Array[Dictionary] = await LanDiscovery.discover(1.0)
			print("[LAN] discovered %d server(s)" % entries.size())
			for entry in entries:
				print("[LAN]   %s  %d/%d  %s  %s:%d" % [
					str(entry.get("map", "?")), int(entry.get("players", 0)),
					int(entry.get("max_players", 0)), str(entry.get("state", "?")),
					str(entry.get("ip", "?")), int(entry.get("port", 0))])
			get_tree().quit(0)
			return

	loading.set_progress(1.0)
	loading.set_status("")

	# Keep the loading screen up through the first rendered frames so the D3D12
	# shader compilation happens behind it, then hide.
	await get_tree().process_frame
	await get_tree().process_frame
	loading.visible = false


func _lobby_create_and_join() -> void:
	var result: Dictionary = await LobbyClient.create_match()
	if not result.has("endpoint") or not result.has("grant"):
		push_error("Lobby create failed: %s" % result.get("error", "unknown"))
		$LoadingScreen.hide_screen()
		return
	if OS.is_debug_build():
		print("[LOBBY] created %s at %s" % [result.get("code", "?"), result["endpoint"]])
	await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))


func _lobby_join_by_code(code: String) -> void:
	var result: Dictionary = await LobbyClient.join_by_code(code)
	if not result.has("endpoint") or not result.has("grant"):
		push_error("Lobby join failed: %s" % result.get("error", "unknown"))
		$LoadingScreen.hide_screen()
		return
	if OS.is_debug_build():
		print("[LOBBY] joining %s at %s" % [result.get("code", code), result["endpoint"]])
	await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))


func _arg_value(args: PackedStringArray, prefix: String) -> String:
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


func _int_arg(args: PackedStringArray, prefix: String, fallback: int) -> int:
	var value := _arg_value(args, prefix)
	return int(value) if value.is_valid_int() else fallback


func _preload_resources(loading: LoadingScreen) -> void:
	var count := PRELOAD_PATHS.size()
	loading.set_status("Loading resources…")
	# Kick off every threaded load up front so Godot's worker pool loads their
	# dependency trees concurrently (shared sub-resources are de-duplicated by the
	# resource cache).  Sequential loading made boot time the *sum* of these
	# loads; requesting them together makes it roughly the *max*.
	var pending: Array[String] = []
	for path in PRELOAD_PATHS:
		if ResourceLoader.load_threaded_request(path) == OK:
			pending.append(path)
		else:
			# Threaded load unavailable — fall back to a synchronous (still cached) load.
			load(path)

	while not pending.is_empty():
		var done: Array[String] = []
		# Sync-loaded (or previously-finished) resources count as complete.
		var completed_frac := float(count - pending.size())
		for path in pending:
			var progress: Array = []
			var status := ResourceLoader.load_threaded_get_status(path, progress)
			match status:
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					if progress.size() >= 2:
						var stages := int(progress[0])
						var stage := int(progress[1])
						if stages > 0:
							completed_frac += clampf(float(stage) / float(stages), 0.0, 1.0)
				ResourceLoader.THREAD_LOAD_LOADED:
					ResourceLoader.load_threaded_get(path)
					completed_frac += 1.0
					done.append(path)
				ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
					push_warning("Preload failed: %s" % path)
					completed_frac += 1.0
					done.append(path)
		for path in done:
			pending.erase(path)
		loading.set_progress(completed_frac / float(count) * PRELOAD_FRACTION)
		await get_tree().process_frame
	loading.set_status("")


# The 2D main menu is bypassed (kept on disk but no longer instanced).  These
# are kept as no-ops because NetworkManager still calls them on scene transitions.
func hide_main_menu():
	pass


func show_main_menu():
	pass
