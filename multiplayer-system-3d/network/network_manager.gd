extends Node

## Owns the connection lifecycle and the session's network tick domain.
##
## Two things beyond the original scene/peer plumbing live here:
##
## - **The tick rate**, as a per-session property a server chooses and clients
##   adopt (like CS:GO's `sv_tickrate`), instead of a build-time constant.  See
##   [method apply_tick_rate].
## - **When the client's `NetworkTime` starts.**  netfox would start it itself
##   from its own `on_client_start` listener at connect time.  That is the wrong
##   moment here, and it is the cause of the `past the history limit` rollback
##   spam.  See [method _take_over_client_time].

const Protocol := preload("res://network/session_protocol.gd")

const SERVER_PORT: int = 8080
const GAME_SCENE = "res://world/world1.tscn"
const LOBBY_MAP_PATH = "res://maps/main_menu_world.tscn"

# ─────────────────────────────────────────────
#  Process role
# ─────────────────────────────────────────────

## What this process is.  The P2P topology is still the default so the game
## keeps running during the dedicated-server migration; `--server`,
## `--offline`, `--listen-server` and `--connect=` select the new modes.
## See `docs/07-dedicated-server.md`.
enum Role {
	LEGACY_P2P,      ## Current auto-host: peer 1 is server AND local player.
	OFFLINE,         ## Local shell: OfflineMultiplayerPeer, no network.
	CLIENT,          ## Connected to a dedicated/listen server.
	DEDICATED_SERVER,## Headless match server; peer 1 is NOT a player.
	LISTEN_SERVER,   ## Host + play in one process (dev/LAN).
}

var role: Role = Role.LEGACY_P2P


## True only for a headless match server.  Use this to skip local-player UI,
## cameras, dev menus and visual-only setup.  Do NOT use it for simulation
## authority — keep `multiplayer.is_server()` for that.
func is_dedicated_server() -> bool:
	return role == Role.DEDICATED_SERVER

# ─────────────────────────────────────────────
#  Tick rate
# ─────────────────────────────────────────────

## The session's network tick rate.  A server picks it; a client adopts the
## host's before it starts `NetworkTime`.
var server_tick_rate: int = ProjectSettings.get_setting(&"netfox/time/tickrate", 90)

## netfox's rollback-history and tick catch-up limits are counts of *ticks*, so
## their wall-clock meaning scales with the rate: netfox's default of 64 history
## ticks is 2.13 s at 30 Hz but only 0.71 s at 90 Hz.  Expressing them in seconds
## and deriving the counts keeps the rollback window -- and the tick loop's
## catch-up budget -- the same length in *time* at every rate.  The values below
## reproduce today's behaviour at the current 90 Hz.  They are the single source
## of truth for these two limits; do not also set them in project.godot.
const HISTORY_SECONDS := 0.7    # 63 ticks at 90 Hz (was a flat 64)
const CATCHUP_SECONDS := 0.7    # 63 ticks at 90 Hz (was a flat 60)
const MIN_TICK_RATE := 30
const MAX_TICK_RATE := 240

# ─────────────────────────────────────────────
#  Tick-domain watchdog
# ─────────────────────────────────────────────

const DEBUG_INTERVAL := 1.0         # how often the [NTSYNC] line prints
const CHECK_INTERVAL := 0.25        # how often a client evaluates the offset
const CONFIRM_SECONDS := 1.5        # offset must stay bad this long before firing
const COOLDOWN_SECONDS := 5.0       # minimum gap between re-seeds
## Margin added to NetworkTimeSynchronizer.sync_interval for the drain, which
## must outlast that synchronizer's in-flight ping loop.
const DRAIN_MARGIN_SECONDS := 0.05
const RESYNC_TIMEOUT_SECONDS := 2.0
const SETTLE_FRAME_SECONDS := 0.1   # a frame slower than this counts as still stalling
const SETTLE_FRAMES := 2
## These bound how long a join can sit on the loading screen waiting.  They are
## deliberately short: every one of them is a *fallback*, and the healthy path
## completes in a frame or two.  A long budget here turns any hiccup into a
## visibly hung join.  Worst case before the client's tick loop starts is
## roughly their sum.
const SETTLE_TIMEOUT_SECONDS := 1.5
const TICK_RATE_TIMEOUT_SECONDS := 1.5

var is_hosting_game = false
var game_scene

var _resyncing := false
var _resync_count := 0
var _last_resync_ms := -1000000
var _bad_since := -1.0
var _resync_warned := false
var _sync_to_physics_warned := false
var _tick_rate_logged := false
## True once this client's tick loop is up under the *current* connection.  The
## watchdog stays silent until then: between sessions `NetworkTime.tick` and the
## reference clock still hold the previous session's values, which read as an
## enormous bogus offset and would trigger a re-seed during the join.
var _client_time_ready := false
## The tick rate the host has told us about, or -1 if it hasn't yet.
##
## Deliberately persistent rather than a one-shot flag the waiter clears: the host
## sends it more than once (a push on peer_connected plus the reply to our
## request) and it can arrive at any point relative to the join, including before
## the waiter starts.  Clearing it on entry to the wait threw away an already
## delivered value and made the join time out while holding it.
var _host_tick_rate := -1
var _check_accum := 0.0
var _debug_accum := 0.0
## True when this join targets a match server that speaks the MatchSession
## handshake.  Direct `--connect` joins and the Match Menu's FIND MATCH both
## set it; a caller that passes false keeps the old replication flow.
var _use_match_session := false
## Resume state.  The endpoint and the server-issued token let a dropped client
## rejoin the same slot instead of being sent back to the lobby.
var _match_host := ""
var _match_port := SERVER_PORT
var _reconnecting := false
## Test hook: drop without trying to resume, so the server-side grace expiry can
## be exercised.
var _test_no_reconnect := false
## Monotonic id of the latest lifecycle takeover (leave, join, host).
##
## Coroutines that outlive the frame that started them capture this and abort
## when it moves, so a superseded `return_to_lobby()` re-host or staging
## countdown cannot act on a session that no longer exists.
var _lifecycle_epoch: int = 0


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
	if not mp.peer_connected.is_connected(_on_peer_connected):
		mp.peer_connected.connect(_on_peer_connected)
	if not MatchSession.session_error.is_connected(_on_match_session_error):
		MatchSession.session_error.connect(_on_match_session_error)

	_test_no_reconnect = "--test-no-reconnect" in OS.get_cmdline_user_args()

	# Deferred: autoloads are added (and _ready'd) in order, so the Console
	# autoload does not exist yet while this one is running.
	_register_console_commands.call_deferred()


# ─────────────────────────────────────────────
#  Tick rate
# ─────────────────────────────────────────────

## Apply a tick rate to netfox's latched state.  Callable on any peer; every
## peer must end up with the same value.
##
## netfox latches its rate from ProjectSettings when the autoload is constructed
## (`network-time.gd:368`) and its `tickrate` setter is a `push_error` no-op
## (`network-time.gd:17-18`), so the backing fields are the only way in.  Nothing
## caches a rate at `_ready` -- `ticktime`, `tick_factor` and `physics_factor`
## are all derived per use -- so these writes are complete.
##
## [b]Must run before `NetworkTime.start()` unless a restart follows.[/b]  A
## client seeds its entire tick origin with `seconds_to_ticks(...)`
## (`network-time.gd:440`), and `NetworkTime.tick` is monotonic, so a wrong rate
## at seed time is unrecoverable except by a full re-seed.
##
## Only call this after boot: `NetworkRollback` is autoload 6 and this is
## autoload 1.
func apply_tick_rate(rate: int) -> void:
	var clamped := clampi(rate, MIN_TICK_RATE, MAX_TICK_RATE)
	var changed := clamped != server_tick_rate
	server_tick_rate = clamped

	# The tick-COUNT limits are derived unconditionally, and from whatever rate is
	# actually in effect.  Doing this below the sync_to_physics guard would leave
	# them at netfox's defaults (8 ticks/frame, 64 ticks of history) whenever that
	# path is taken -- and 8 ticks/frame is precisely the condition
	# docs/05-known-issues.md #18 documents as ending in "the client can be kicked
	# back to its own lobby".  There is no longer a project.godot value to fall
	# back on: these fields are the single source of truth.
	var effective: int = Engine.physics_ticks_per_second if NetworkTime.sync_to_physics else server_tick_rate
	NetworkTime._max_ticks_per_frame = int(ceil(CATCHUP_SECONDS * effective))
	NetworkRollback._history_limit = maxi(1, roundi(HISTORY_SECONDS * effective))

	if NetworkTime.sync_to_physics:
		# The rate is Engine.physics_ticks_per_second; only the derived counts
		# above are ours to set.
		if not _sync_to_physics_warned:
			_sync_to_physics_warned = true
			push_warning("netfox/time/sync_to_physics is on, so the session tick rate is " +
				"Engine.physics_ticks_per_second (%d Hz) and cannot be set per session." % effective)
		return

	NetworkTime._tickrate = server_tick_rate
	# The host repeats its rate (a push plus the reply to our request), so log the
	# first application and any actual change, not every duplicate.
	if OS.is_debug_build() and (changed or not _tick_rate_logged):
		_tick_rate_logged = true
		print("[NTSYNC] tick rate %d Hz (history %d ticks, catch-up %d ticks/frame)" % [
			server_tick_rate, NetworkRollback.history_limit, NetworkTime.max_ticks_per_frame])


## Change the session tick rate.  Server-only; broadcasts to every client.
##
## Every peer re-initialises `NetworkTime` together, because
## [RollbackSynchronizer] feeds `NetworkTime.ticktime` in as the re-simulation
## delta (`rollback-synchronizer.gd:422`) -- replaying across a rate change would
## integrate old ticks with the wrong step.
##
## Expect a brief movement freeze on each peer while its tick loop is stopped.
func set_tick_rate(rate: int) -> void:
	if not _is_tick_reference():
		push_warning("Only the host can change the session tick rate.")
		return
	rate = clampi(rate, MIN_TICK_RATE, MAX_TICK_RATE)
	# Reliable, and sent before the host restarts, so every client is already
	# stopping its own loop by the time the host's new domain appears.
	_rpc_set_tick_rate.rpc(rate, true)
	_reinit_time(rate)


## Stop the tick loop, optionally re-rate it, start it again, and drop the
## now-stale rollback history.  Returns false if another re-init was already in
## flight, in which case nothing happened.
##
## The ordering matters twice over:
##
## - The drain must outlast the clock synchronizer's in-flight ping loop.
##   `NetworkTimeSynchronizer._loop()` is a `while _active` coroutine that
##   `stop()` does not kill (`network-time-synchronizer.gd:164`), so restarting
##   inside one `sync_interval` leaves the old loop running alongside the new one,
##   sharing `_sample_idx` and leaking `_awaiting_samples` entries.
## - The history reset must come [b]after[/b] `start()`, because the recorder
##   seeds its tick cursors from `NetworkTime.tick`.  Resetting first would stamp
##   them with the dying domain's tick -- a host restarts at 0, so the cursors
##   would sit `old_tick` ticks in the future and nothing would simulate for that
##   long.
func _reinit_time(rate: int) -> bool:
	if _resyncing:
		return false
	_resyncing = true

	NetworkTime.stop()
	if rate > 0:
		apply_tick_rate(rate)

	if not _is_tick_reference():
		await get_tree().create_timer(_drain_seconds()).timeout
		# return_to_lobby() is reachable from five call sites and can run under
		# us, turning us back into a host; start() would then be refused.
		if not _can_resync():
			_resyncing = false
			return false

	NetworkTime.start()
	# A client's start() suspends until the initial sync lands; a host's has
	# already completed.  Poll rather than await after_sync, which would hang
	# forever if start() bailed out on one of its own guards.
	var deadline := Time.get_ticks_msec() + int(RESYNC_TIMEOUT_SECONDS * 1000.0)
	while not NetworkTime.is_initial_sync_done() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_resyncing = false
	if not NetworkTime.is_initial_sync_done():
		push_error("[NTSYNC] tick loop restart timed out; the initial time sync never completed.")
		return false

	_reset_rollback_history()
	if _can_resync():
		_client_time_ready = true
	return true


## Apply a tick rate that arrives from the host, restarting the tick loop if it
## is already running.  A re-seed may be in flight; retry once behind it.
func _restart_with_rate(rate: int) -> void:
	var restarted := await _reinit_time(rate)
	if restarted:
		return
	await get_tree().create_timer(_drain_seconds()).timeout
	await _reinit_time(rate)


## Drop every tick-keyed history buffer after a tick-domain change.
##
## Without this the transmitters keep cursors (`_latest_state_tick`,
## `_earliest_input_tick`) from the old domain; `_resim_from` stays pinned to
## them and `NetworkRollback` clamps every replay to `history_limit` -- which is
## the `Trying to run rollback for ticks X to Y` warning.
##
## `process_settings()` is netfox's public reconfigure entry point
## (`rollback-synchronizer.gd:101-120`); it clears the state/input buffers and
## re-runs the transmitter's `reset()`.
func _reset_rollback_history() -> void:
	for node in get_tree().root.find_children("*", "RollbackSynchronizer", true, false):
		var rb := node as RollbackSynchronizer
		if rb != null:
			rb.process_settings()
	for node in get_tree().root.find_children("*", "TickInterpolator", true, false):
		var ti := node as TickInterpolator
		if ti != null:
			ti.teleport()  # hide the one-frame interpolation smear from the jump


func _drain_seconds() -> float:
	return NetworkTimeSynchronizer.sync_interval + DRAIN_MARGIN_SECONDS


# ─────────────────────────────────────────────
#  Peer creation
# ─────────────────────────────────────────────

## [param tick_rate] of -1 keeps the current session rate.
##
## `allow_offline_fallback` exists for the legacy auto-host path, where a second
## local instance must still get a usable lobby.  A dedicated match server must
## never silently become an offline peer: pass `false` and fail loudly.
func create_server(tick_rate: int = -1, port: int = SERVER_PORT, max_clients: int = 32, allow_offline_fallback: bool = true) -> Error:
	is_hosting_game = true
	# Always applied, even when the rate is unchanged: this is also what derives
	# the tick-count settings, and the offline fallback peer below needs those
	# just as much as a real server does.
	apply_tick_rate(tick_rate if tick_rate > 0 else server_tick_rate)
	var enet_network_peer := ENetMultiplayerPeer.new()
	var err := enet_network_peer.create_server(port, max_clients)
	if err != OK:
		if not allow_offline_fallback:
			push_error("Could not bind UDP port %d (error %d)." % [port, err])
			return err
		# Port already in use (e.g. a second local instance).  Fall back to an
		# offline peer so the player still gets a working local lobby they can
		# later "Join Local" out of.
		push_warning("Port %d in use — falling back to offline peer." % port)
		get_tree().get_multiplayer().multiplayer_peer = OfflineMultiplayerPeer.new()
		# NetworkEvents won't auto-start NetworkTime for an offline peer, so the
		# rollback tick loop would never run (no movement).  Start it manually.
		NetworkTime.start()
		return err
	get_tree().get_multiplayer().multiplayer_peer = enet_network_peer
	if OS.is_debug_build(): print("Server created on UDP %d!" % port)
	return OK


## Local-only peer for the 3D lobby shell and single-player/dev.  NetworkEvents
## ignores `OfflineMultiplayerPeer`, so the rollback loop must be started here.
func create_offline_peer() -> void:
	role = Role.OFFLINE
	is_hosting_game = true
	apply_tick_rate(server_tick_rate)
	get_tree().get_multiplayer().multiplayer_peer = OfflineMultiplayerPeer.new()
	if OS.is_debug_build():
		print("[LOCAL] offline peer id=%d server=%s" % [
			multiplayer.get_unique_id(), multiplayer.is_server()])
	NetworkTime.start()


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

func enter_existing_game_scene() -> void:
	if OS.is_debug_build(): print("Entering game scene")
	LoadingScreen.report(0.6, "Loading world...")
	game_scene = preload(GAME_SCENE).instantiate()
	get_tree().current_scene.add_child(game_scene)
	get_tree().current_scene.hide_main_menu()
	LoadingScreen.report(0.9, "Spawning players...")
	# Keep the loading screen up through the first rendered frames so the
	# connect-time map/player replication and D3D12 shader compilation happen
	# behind it (same rationale as boot in world/main.gd).  The screen is hidden
	# by _on_connected_to_server once the tick loop is up.
	await get_tree().process_frame
	await get_tree().process_frame


func load_game_scene(map_path: String):
	if OS.is_debug_build(): print("Loading game scene")
	LoadingScreen.report(0.8, "Loading world...")
	await get_tree().process_frame
	game_scene = preload(GAME_SCENE).instantiate()
	game_scene.map_path = map_path
	get_tree().current_scene.add_child(game_scene)
	get_tree().current_scene.hide_main_menu()
	LoadingScreen.report(0.9, "Spawning players...")


# ─────────────────────────────────────────────
#  Lobby / party flow
# ─────────────────────────────────────────────

## Boot-time entry: become the host (peer 1 / party leader) and load the lobby.
## This is the legacy P2P path; it is what the default boot still uses until the
## dedicated-server lobby replaces it.
func boot_to_lobby() -> void:
	if game_scene != null:
		return  # already booted (guards against double-scheduled boots)
	role = Role.LEGACY_P2P
	MatchSession.reset()
	create_server()  # offline fallback handled inside
	Leaderboard.reset()
	LoadingScreen.report(0.75, "Starting server...")
	await get_tree().process_frame
	await load_game_scene(LOBBY_MAP_PATH)


## Local shell: the 3D lobby with no network peer.  The player picks a class,
## then creates or joins a match from the lobby zones.
func boot_offline_lobby() -> void:
	if game_scene != null:
		return
	role = Role.OFFLINE
	MatchSession.reset()
	create_offline_peer()
	Leaderboard.reset()
	LoadingScreen.report(0.75, "Starting local lobby...")
	await get_tree().process_frame
	await load_game_scene(LOBBY_MAP_PATH)


## Dev/LAN host + play in one process.  Picks the first free UDP port in
## [8080, 8080 + LAN_DISCOVERY_PORT_RANGE) so a second host on one machine works;
## the chosen port is advertised through LAN discovery.  Never exits the process:
## a local host failure returns to the shell, unlike `--server`.
func boot_listen_server(port: int = SERVER_PORT, map_path: String = LOBBY_MAP_PATH) -> void:
	if game_scene != null:
		return
	role = Role.LISTEN_SERVER
	MatchSession.begin_server(map_path, "", "")
	# Hosting straight into a match map means the match is already active; the
	# lobby map stays in staging (used by the listen/--server dev paths).
	MatchSession.phase = Protocol.Phase.STAGING if map_path == LOBBY_MAP_PATH \
		else Protocol.Phase.ACTIVE
	var chosen := -1
	for candidate in range(port, port + Protocol.LAN_DISCOVERY_PORT_RANGE):
		if create_server(-1, candidate, 32, false) == OK:
			chosen = candidate
			break
	if chosen < 0:
		push_error("No free UDP port in [%d, %d)." % [
			port, port + Protocol.LAN_DISCOVERY_PORT_RANGE])
		MatchSession.reset()
		GameManager.pending_host_setup = {}
		role = Role.OFFLINE
		LoadingScreen.hide_screen()
		call_deferred("boot_offline_lobby")
		return
	MatchSession.server_port = chosen
	Leaderboard.reset()
	LoadingScreen.report(0.75, "Starting listen server on %d..." % chosen)
	await get_tree().process_frame
	await load_game_scene(map_path)
	LanDiscovery.start_announcing(chosen)
	if OS.is_debug_build():
		print("[server] listen ready on UDP %d map=%s" % [chosen, map_path])
	# `host_local_match()` showed the loading screen before tearing down the
	# shell.  The startup `--listen-server` route is hidden by `main.gd`, but the
	# in-lobby Host button has no other caller to hide it, so it stayed up.
	LoadingScreen.report(1.0, "")
	await get_tree().process_frame
	await get_tree().process_frame
	LoadingScreen.hide_screen()
	if OS.is_debug_build():
		print("[server] loading screen hidden")


## Start a listen server from the local 3D shell, replacing the offline peer.
## No lobbyd and no external process: this is the default local "host a match"
## path.  The deferred boot gives NetworkEvents a frame to observe the offline
## peer stopping before the ENet server starts.
func host_local_match(port: int = SERVER_PORT, map_path: String = LOBBY_MAP_PATH) -> void:
	if role == Role.LISTEN_SERVER:
		return
	_lifecycle_epoch += 1  # cancel a pending return_to_lobby() re-host
	LoadingScreen.show_screen(0.35, "Starting local server…")
	MatchSession.reset()
	_client_time_ready = false
	_host_tick_rate = -1
	# Stop the tick loop but KEEP the offline peer alive until create_server
	# replaces it.  Nulling the peer first made netfox's deferred synchronizer
	# re-processing call get_unique_id() on null.  The old peer is only an
	# OfflineMultiplayerPeer here; create_server installs the ENet server.
	NetworkTime.stop()
	_remove_game_scene()
	await get_tree().process_frame
	call_deferred("boot_listen_server", port, map_path)


## Headless dedicated match server.  Peer 1 is NOT a player: `SpawnManager`
## does not add a local player and the UI/visual setup is skipped in world_1.
## NetworkEvents starts NetworkTime when it observes the server on the next
## frame, so no manual start is needed here.
func boot_dedicated_server(port: int = SERVER_PORT, match_id: String = "") -> void:
	if game_scene != null:
		return
	role = Role.DEDICATED_SERVER
	MatchSession.begin_server(LOBBY_MAP_PATH, "", match_id)
	var err := create_server(-1, port, 80, false)
	if err != OK:
		push_error("Dedicated server could not bind UDP %d; exiting." % port)
		get_tree().quit(1)
		return
	MatchSession.server_port = port
	Leaderboard.reset()
	await get_tree().process_frame
	await load_game_scene(LOBBY_MAP_PATH)
	LanDiscovery.start_announcing(port)
	if OS.is_debug_build():
		print("[server] ready on UDP %d match=%s grant_secret=%s" % [
			port, match_id if match_id != "" else "<none>",
			"yes" if MatchSession.grant_secret_configured() else "NO"])


## A player already in their own lobby connects to a host's lobby/match.
##
## `use_match_session` selects the dedicated-server handshake.  The Match Menu's
## FIND MATCH and the direct `--connect` dev route both use it; a caller that
## passes false keeps the legacy replication path.
func join_party(host_ip: String, host_port: int = SERVER_PORT, use_match_session: bool = false, grant: String = "") -> void:
	LoadingScreen.show_screen(0.1, "Connecting...")
	_lifecycle_epoch += 1  # cancel a pending return_to_lobby() re-host
	role = Role.CLIENT
	_use_match_session = use_match_session
	_match_host = host_ip
	_match_port = host_port
	_reconnecting = false
	if use_match_session:
		MatchSession.begin_client(LOBBY_MAP_PATH, grant)
	else:
		MatchSession.reset()
	_take_over_client_time()
	_remove_game_scene()
	var err := create_client(host_ip, host_port)
	if err != OK:
		return_to_lobby()


## Connect to an endpoint returned by `lobbyd`, presenting its join grant.
func join_match(endpoint: String, grant: String) -> void:
	var host := endpoint
	var port := SERVER_PORT
	if endpoint.contains(":"):
		host = endpoint.get_slice(":", 0)
		port = int(endpoint.get_slice(":", 1))
	if host == "" or port <= 0:
		push_error("join_match: bad endpoint '%s'" % endpoint)
		return
	await join_party(host, port, true, grant)


## Leave the current match/party and return to a fresh solo lobby.
func return_to_lobby() -> void:
	if OS.is_debug_build(): print("Returning to lobby...")
	_lifecycle_epoch += 1
	var epoch := _lifecycle_epoch
	_reconnecting = false
	_match_host = ""
	_match_port = SERVER_PORT
	# A finished listen match must tell clients not to attempt a resume against
	# the server we are about to close.
	if multiplayer.is_server() and MatchSession.role == MatchSession.Role.SERVER \
			and MatchSession.phase == Protocol.Phase.RESULTS:
		MatchSession.set_phase(Protocol.Phase.CLOSED)
	MatchSession.stop_heartbeat()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	LoadingScreen.hide_screen()  # in case a join failed mid-connect and left it up
	_terminate_connection()  # close peer FIRST so the port frees for re-host
	_remove_game_scene()
	# Re-host only after NetworkEvents has observed the teardown -- see
	# _rehost_after_stop_observed().  A client leaving a dedicated match returns
	# to the local 3D shell, not to a self-hosted P2P lobby.
	match role:
		Role.DEDICATED_SERVER:
			get_tree().quit()
		Role.CLIENT, Role.OFFLINE, Role.LISTEN_SERVER:
			role = Role.OFFLINE
			_rehost_after_stop_observed(epoch, Role.OFFLINE)
		_:
			role = Role.LEGACY_P2P
			_rehost_after_stop_observed(epoch, Role.LEGACY_P2P)


## Re-host the lobby only after `NetworkEvents` has polled and seen the old
## server peer go away.
##
## `NetworkEvents._process` samples `is_server()` once per frame and emits
## `on_server_stop` -- wired to `NetworkTime.stop()` -- on the first frame it
## sees the server disappear.  The offline re-host starts its own tick loop
## (`create_offline_peer`), so if it installs the new peer before that sample,
## the stale sample stops the fresh loop one frame later and rollback dies
## (movement stops; look/shoot keep working).  That is exactly what happened
## when the results overlay auto-returned from `_process`: the teardown ran
## AFTER that frame's poll, and a single deferred boot still landed inside the
## next frame's poll.
##
## `SceneTree` emits `process_frame` before node `_process`, so one await still
## resumes before the poll.  Two full frames guarantee exactly one poll with no
## server peer present: its `on_server_stop` is a no-op (the loop is already
## stopped), and the new peer installs its loop afterwards.
##
## Do not wait on the `on_server_stop` signal instead: client returns never emit
## it, it may already have fired that frame, and it never fires at all when
## `NetworkEvents.enabled` is false.
func _rehost_after_stop_observed(epoch: int, target_role: Role) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if epoch != _lifecycle_epoch or role != target_role:
		return  # superseded by a newer leave/join/host
	if target_role == Role.OFFLINE:
		boot_offline_lobby()
	else:
		boot_to_lobby()


## Server-authoritative map swap (lobby -> match).  The MultiplayerSpawner
## replicates the Map removal/addition to every connected peer.
func load_match_map(map_path: String, set_active: bool = true, respawn_players: bool = true) -> void:
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
	if game_scene != null and game_scene.has_method("on_match_map_loaded"):
		game_scene.on_match_map_loaded()

	# Match sessions: every peer loads the map from its own build.  The server
	# announces path + hash; clients verify and build it locally (no map bytes
	# on the wire).  Legacy P2P keeps the spawner replication it has always used.
	if MatchSession.role == MatchSession.Role.SERVER:
		var hash := FileAccess.get_sha256(map_path)
		MatchSession.map_hash = hash
		if set_active:
			MatchSession.set_phase(Protocol.Phase.ACTIVE, map_path, hash)

	# Respawn existing players on the new map (after it exists so
	# _get_spawn_transform() finds it).
	if respawn_players:
		for child in sp.get_children():
			if child is Player:
				child.rpc_reset.rpc(child._get_spawn_transform())


## Server-side staging -> match transition.  The staging world remains the
## lobby map; this countdowns, announces the target map, swaps it locally, waits
## for every client's MAP_READY, then activates and respawns players.
func start_staging_match(map_path: String = "") -> void:
	if not multiplayer.is_server():
		return
	if MatchSession.role != MatchSession.Role.SERVER:
		return
	var epoch := _lifecycle_epoch
	var path := map_path
	if path == "":
		path = MatchSession.target_map_path
	if path == "":
		path = GameManager.pending_match_map
	if path == "" or not FileAccess.file_exists(path):
		push_error("start_staging_match: no valid target map.")
		return
	MatchSession.set_staging_map(path)
	MatchSession.set_phase(Protocol.Phase.COUNTDOWN)
	LoadingScreen.show_screen(0.2, "Match starting in 5...")
	await get_tree().create_timer(5.0).timeout
	# The next world repoints GameManager.spawn_parent, so is_instance_valid()
	# alone cannot reject a countdown whose session was already torn down.
	if epoch != _lifecycle_epoch or MatchSession.role != MatchSession.Role.SERVER \
			or not is_instance_valid(GameManager.spawn_parent):
		return

	var hash := FileAccess.get_sha256(path)
	LoadingScreen.report(0.55, "Loading map...")
	MatchSession.set_phase(Protocol.Phase.LOADING, path, hash)
	load_match_map(path, false, false)
	var ready := await MatchSession.await_map_ready(Protocol.MAP_MATCH_DEADLINE_SECONDS)
	if epoch != _lifecycle_epoch or MatchSession.role != MatchSession.Role.SERVER:
		return
	if not ready:
		push_warning("[MATCH] map-ready barrier timed out; activating anyway.")
	LoadingScreen.report(0.9, "Spawning players...")
	MatchSession.set_phase(Protocol.Phase.ACTIVE, path, hash)
	for child in GameManager.spawn_parent.get_children():
		if child is Player:
			child.rpc_reset.rpc(child._get_spawn_transform())
	LoadingScreen.hide_screen()


## End the current match from the server.  Clients receive RESULTS, show the
## local results overlay, then leave through the normal return path.
func end_match(result_text: String = "") -> void:
	if not multiplayer.is_server():
		return
	if MatchSession.role != MatchSession.Role.SERVER:
		return
	MatchSession.set_results(result_text)
	MatchSession.set_phase(Protocol.Phase.RESULTS)


# ─────────────────────────────────────────────
#  Who starts the client's NetworkTime
# ─────────────────────────────────────────────

## Take the client's `NetworkTime` start away from `NetworkEvents`.
##
## netfox calls `NetworkTime.start()` from its own `on_client_start` listener
## (`network-events.gd:84`), which fires the moment the ENet connection is up.
## At that point this class has already called `enter_existing_game_scene()`,
## which runs the heavy synchronous `preload(world1.tscn)` and then suspends for
## two frames of D3D12 shader compilation.  The clock-sync request goes out
## *before* that stall and its reply is applied *after* it, so the client seeds
## its whole tick origin from a clock reading that is seconds out of date:
##
## 1. `NetworkTimeSynchronizer`'s initial timestamp has no RTT or elapsed-time
##    compensation (`network-time-synchronizer.gd:267-276`), and
## 2. `_tick = seconds_to_ticks(...)` (`network-time.gd:440`) is monotonic, so the
##    error can only be dragged out at netfox's 25 %/s clock stretch limit
##    (`network-time.gd:523-537`) -- ~40 s for a 10 s stall.
##
## Until it heals, `history_start` has moved past the other peer's live inputs,
## so they are discarded, the host stops sending state for this player, and every
## rollback clamps to `history_limit`.  We start the loop ourselves at a moment
## when the round trip is actually short; see [method _on_connected_to_server].
##
## Only the client start is taken over -- `on_client_stop` still stops it, and
## the server paths are untouched.
##
## [b]Constraint:[/b] do not add another listener to `NetworkEvents.on_client_start`.
## This removes every listener on that signal; netfox's lambda is currently the
## only one.
func _take_over_client_time() -> void:
	for c in NetworkEvents.on_client_start.get_connections():
		NetworkEvents.on_client_start.disconnect(c.callable)
	_client_time_ready = false
	_host_tick_rate = -1


## Wait for the join-time stalls to clear so the clock-sync round trip is not
## measured across one.  Capped, so a pathological machine still joins.
func _await_settled() -> void:
	var deadline := Time.get_ticks_msec() + int(SETTLE_TIMEOUT_SECONDS * 1000.0)
	var calm := 0
	while calm < SETTLE_FRAMES and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if get_process_delta_time() < SETTLE_FRAME_SECONDS:
			calm += 1
		else:
			calm = 0
	if calm < SETTLE_FRAMES and OS.is_debug_build():
		push_warning("[NTSYNC] frames never settled below %.0f ms; starting the tick loop anyway." % [
			SETTLE_FRAME_SECONDS * 1000.0])


## Wait for the server's `welcome`.  Polled rather than signal-based so a lost
## session or a superseded join cannot leave this coroutine waiting forever.
func _await_welcome(timeout_seconds: float) -> bool:
	var before := MatchSession.welcome_count
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if MatchSession.welcome_count > before:
			return true
		if not _has_live_peer():
			return false
		await get_tree().process_frame
	return MatchSession.welcome_count > before


## Ask the host for its tick rate and apply it, so this client's seed is computed
## with the same multiplier the host used.  Falls back to the local default
## rather than hanging the join.
func _adopt_server_tick_rate() -> void:
	if _host_tick_rate < 0:
		# The host also pushes on peer_connected, so this is a backstop for the
		# case where that push was lost or arrived before we were listening.
		_rpc_request_tick_rate.rpc_id(1)
	var deadline := Time.get_ticks_msec() + int(TICK_RATE_TIMEOUT_SECONDS * 1000.0)
	while _host_tick_rate < 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if not _has_live_peer():
			return
	# Apply even on a miss, using the local default: apply_tick_rate() is also what
	# derives the tick-count limits, and skipping it would leave them at netfox's
	# defaults of 8 ticks/frame and 64 ticks of history -- the documented recipe for
	# "the client can be kicked back to its own lobby" (05-known-issues.md #18).
	if _host_tick_rate < 0:
		push_warning("[NTSYNC] no tick rate from the host; keeping the local default.")
	apply_tick_rate(_host_tick_rate if _host_tick_rate >= 0 else server_tick_rate)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_tick_rate(rate: int, restart: bool) -> void:
	_host_tick_rate = rate
	if restart:
		_restart_with_rate(rate)
		return
	if _client_time_ready and rate != server_tick_rate:
		# The loop is already up on a different rate -- the join gave up waiting
		# and used the local default.  Mutating the rate underneath a live tick
		# origin would leave the two peers disagreeing, so re-seed properly.
		_restart_with_rate(rate)
		return
	# Either we have not started yet (applying now is exactly right -- it is what
	# the start() will seed with), or we are already on this rate and the host is
	# just repeating itself.
	apply_tick_rate(rate)


## Push the session rate to a peer as soon as it connects, rather than waiting to
## be asked.
##
## The pull path (`_rpc_request_tick_rate`) alone is too slow to rely on: a joiner
## is loading the world right after connecting, so its frames are long and its
## reliable reply may not be polled until well after the wait window. Pushing
## means the value is already in the joiner's inbox — delivered on its first poll
## — before it needs it, and the wait becomes a no-op in the normal case.
func _on_peer_connected(peer_id: int) -> void:
	if not _is_tick_reference():
		return
	_rpc_set_tick_rate.rpc_id(peer_id, server_tick_rate, false)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_tick_rate() -> void:
	if not multiplayer.is_server():
		return
	# restart=false: a joiner applies the rate and then starts NetworkTime itself
	# in _on_connected_to_server; it must not be told to restart here.
	_rpc_set_tick_rate.rpc_id(multiplayer.get_remote_sender_id(), server_tick_rate, false)


# ─────────────────────────────────────────────
#  Tick-domain watchdog
# ─────────────────────────────────────────────

## Signed drift of our tick from the domain it was seeded into.  Positive means
## our tick is BEHIND the tick origin we were seeded with.
##
## [b]This is measured against the reference clock, not against the host's
## tick.[/b]  netfox seeds a client with `seconds_to_ticks(reference clock)` and
## the host counts from 0, and the host's clock-stretch servo does not repay what
## it loses -- measured on this project, a solo host settles ~20 ticks *below*
## `reference_time * tickrate` and stays there.  Comparing against the host's
## reported tick would therefore read a constant non-zero offset in a perfectly
## healthy session and re-seed forever.  What actually matters is whether our
## tick still matches the domain we were seeded into, and the reference clock is
## that domain.
##
## This still catches the failure it exists for: when the initial sync lands
## across a stall the reference clock is corrected afterwards (NTP nudge, or a
## panic jump past `recalibrate_threshold`) while the monotonic tick stays put,
## so the difference opens up and stays open.
func get_tick_offset_ticks() -> int:
	var ref_time := NetworkTimeSynchronizer.get_time()
	# netfox's reference clock can go non-finite: NetworkTimeSynchronizer.start()
	# zeroes it, and a ping still in flight from the previous epoch then resolves
	# with a negative RTT, which feeds log(<negative>) into the clock discipline
	# and poisons it with NaN.  seconds_to_ticks(NaN) is INT64_MAX, which would
	# drive the watchdog into a permanent re-seed loop -- so report "no drift"
	# rather than a number that cannot be acted on.  Observed 2026-09-24.
	if not is_finite(ref_time):
		return 0
	return NetworkTime.seconds_to_ticks(ref_time) - NetworkTime.tick


func _process(delta: float) -> void:
	_update_tick_watchdog(delta)
	if OS.is_debug_build():
		_debug_accum += delta
		if _debug_accum >= DEBUG_INTERVAL:
			_debug_accum = 0.0
			_print_status()


func _update_tick_watchdog(delta: float) -> void:
	if _is_tick_reference():
		return  # the host IS the reference; there is nothing to compare against

	_check_accum += delta
	if _check_accum < CHECK_INTERVAL:
		return
	_check_accum = 0.0
	_evaluate_resync()


func _evaluate_resync() -> void:
	if _resyncing or not _can_resync():
		_bad_since = -1.0
		return
	# Stay silent until this connection's tick loop is actually up: between
	# sessions tick still holds the previous session's value, which reads as an
	# enormous offset.
	if not _client_time_ready or NetworkTime.tick <= 0:
		return
	# Re-seeding stops and restarts the clock synchroniser, which is exactly what
	# poisons it if a ping is still in flight (see get_tick_offset_ticks).  Never
	# act on a measurement taken while the main thread is stalled.
	if get_process_delta_time() >= SETTLE_FRAME_SECONDS:
		return
	if Time.get_ticks_msec() - _last_resync_ms < int(COOLDOWN_SECONDS * 1000.0):
		return

	# A quarter of the rollback window: well inside it, so this fires long before
	# any input is actually discarded, while the jitter term keeps ordinary RTT
	# wobble from triggering a re-seed.
	var offset := get_tick_offset_ticks()
	var threshold := maxi(16, NetworkRollback.history_limit / 4)
	var noise := NetworkTime.seconds_to_ticks(NetworkTimeSynchronizer.rtt_jitter * 0.5)
	if absi(offset) > threshold + noise:
		var now := Time.get_ticks_msec() / 1000.0
		if _bad_since < 0.0:
			_bad_since = now
		elif now - _bad_since >= CONFIRM_SECONDS:
			# DETECT ONLY -- see the note on request_resync().  Automatically
			# re-seeding here was observed to poison the clock synchroniser
			# (2026-09-24), turning a recoverable divergence into a frozen tick
			# loop, so the automatic heal is disabled until it can be done without
			# stop()/start().  `netcode_resync` is the manual escape hatch.
			if not _resync_warned:
				_resync_warned = true
				push_warning("[NTSYNC] tick drift of %+d ticks (threshold %d) — " +
					"run `netcode_resync` to re-seed." % [offset, threshold])
	else:
		_bad_since = -1.0
		_resync_warned = false


## Re-seed our own `NetworkTime` so its tick domain matches the host's.
##
## This is the only way to move `NetworkTime.tick`: it is monotonic, and
## netfox's clock-stretch servo closes a gap at 25 %/s, so a large offset would
## otherwise take tens of seconds to heal.  Clients only -- the host *is* the
## reference, and jumping it would invalidate every client at once.
func request_resync(reason: String) -> void:
	if _resyncing or not _can_resync():
		return
	var before_tick := NetworkTime.tick
	var before_offset := get_tick_offset_ticks()

	# Wait for the frames to settle before stopping the clock synchroniser; an
	# in-flight ping resolving against the reset clock is what produces NaN.
	await _await_settled()

	var restarted := await _reinit_time(-1)
	if not restarted:
		return  # either it failed, or another re-init owns the loop now

	_bad_since = -1.0
	_resync_count += 1
	_last_resync_ms = Time.get_ticks_msec()
	if OS.is_debug_build():
		print("[NTSYNC] re-seeded ticks (%s): %d -> %d, offset was %+d, rtt %.0fms, %d this session" % [
			reason, before_tick, NetworkTime.tick, before_offset,
			NetworkTimeSynchronizer.rtt * 1000.0, _resync_count])


# ─────────────────────────────────────────────
#  Diagnostics
# ─────────────────────────────────────────────

func _print_status() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if not NetworkTime.is_initial_sync_done():
		# Before NetworkTime has started, the synchronizer's clock still holds raw
		# Unix time and the tick is 0, so every field here would be garbage.
		return
	var role := "host" if _is_tick_reference() else "client"
	var net_ticks := -1
	var resim_ticks := -1
	var resim_ms := -1.0
	if NetworkPerformance.is_enabled():
		net_ticks = NetworkPerformance.get_network_ticks()
		resim_ticks = NetworkPerformance.get_rollback_ticks()
		resim_ms = NetworkPerformance.get_rollback_loop_duration_ms()

	# Local player's rollback cursors.  find_player() derefs spawn_parent, which
	# is a freed node between _remove_game_scene() and the next world's _ready --
	# and a freed Object still compares != null, hence is_instance_valid().
	var last_input := -1
	var last_state := -1
	var predicting := false
	var input_age := -1
	if is_instance_valid(GameManager.spawn_parent):
		var p: Player = GameManager.find_player(MatchSession.local_id_string())
		if p != null and p.rollback_sync != null:
			var rb := p.rollback_sync as RollbackSynchronizer
			if rb != null:
				last_state = rb.get_last_known_state()
				predicting = rb.is_predicting()
				# Derived from the input's age rather than through
				# RollbackSynchronizer.get_last_known_input(), which is broken in
				# netfox 1.35.3 -- it calls _inputs.keys(), but the property
				# history buffer exposes ticks().  See 05-known-issues.md #24.
				if rb.has_input():
					input_age = rb.get_input_age()
					last_input = NetworkRollback.tick - input_age

	# Before the tick loop is up, tick is 0 and the reference clock is unset, so
	# the offset would read as a huge bogus number.
	var offset := get_tick_offset_ticks() if NetworkTime.tick > 0 else 0

	var pos_text := ""
	if "--test-move" in OS.get_cmdline_user_args() and is_instance_valid(GameManager.spawn_parent):
		var test_player: Player = GameManager.find_player(MatchSession.local_id_string())
		if test_player != null:
			pos_text = " pos=(%.1f,%.1f,%.1f)" % [
				test_player.global_position.x, test_player.global_position.y, test_player.global_position.z]

	print("[NTSYNC] %s#%d rate=%d tick=%d ref=%.2fs offset=%+d " % [
			role, multiplayer.get_unique_id(), NetworkTime.tickrate, NetworkTime.tick,
			NetworkTimeSynchronizer.get_time(), offset] +
		"stretch=%.3f clock_off=%+.3fs rtt=%.0fms jit=%.0fms " % [
			NetworkTime.clock_stretch_factor, NetworkTime.clock_offset,
			NetworkTimeSynchronizer.rtt * 1000.0, NetworkTimeSynchronizer.rtt_jitter * 1000.0] +
		"history=%d/%d netTicks=%d resim=%d(%.1fms) " % [
			NetworkRollback.history_start, NetworkRollback.history_limit,
			net_ticks, resim_ticks, resim_ms] +
		"inp=%d state=%d pred=%s age=%d%s" % [
			last_input, last_state, predicting, input_age, pos_text])


func _register_console_commands() -> void:
	if not OS.is_debug_build():
		return
	Console.add_command("tickrate", _console_tick_rate, ["ticks per second"], 0,
		"Set the session tick rate (host only). With no argument, print the current rate.")
	Console.add_command("netcode_status", _console_status, 0, 0,
		"Print the network tick-domain state.")
	Console.add_command("netcode_resync", _console_resync, 0, 0,
		"Force a client NetworkTime tick re-seed (the recovery path).")


func _console_tick_rate(rate_text: String) -> void:
	var rate := int(rate_text.strip_edges())
	if rate <= 0:
		print("[NTSYNC] tick rate is %d Hz" % server_tick_rate)
		return
	set_tick_rate(rate)


func _console_status() -> void:
	_print_status()


func _console_resync() -> void:
	if not _can_resync():
		print("[NTSYNC] %s — nothing to re-seed." % [
			"the host is the tick reference" if _is_tick_reference() else "no live connection"])
		return
	request_resync("manual")


# ─────────────────────────────────────────────
#  Connection callbacks
# ─────────────────────────────────────────────

func _on_connected_to_server() -> void:
	if OS.is_debug_build(): print("Connected (id %d)" % multiplayer.get_unique_id())
	if _reconnecting:
		# The reconnect loop owns the resume handshake and the tick restart.
		return
	await enter_existing_game_scene()  # the big join stall is now behind us
	await _await_settled()
	# The dedicated-server handshake is sent only after the world exists, so the
	# server never addresses a Player node the client has not built yet (#124).
	if _use_match_session:
		MatchSession.request_hello()
		var welcomed := await _await_welcome(5.0)
		if not welcomed:
			push_error("Match session handshake timed out; leaving the server.")
			LoadingScreen.hide_screen()
			return_to_lobby()
			return
	await _adopt_server_tick_rate()
	# The connection may have died (or been replaced by a re-host) while we were
	# waiting; this coroutine cannot be cancelled, so re-check before starting a
	# tick loop that no longer belongs to anyone.
	if not _can_resync():
		# Do NOT leave the loading screen up here.  return_to_lobby() hides it on
		# the disconnect path, but this coroutine can also resume after a re-join
		# has already re-shown it, and an early return with the screen still up is
		# an unrecoverable hang.
		if OS.is_debug_build():
			print("[NTSYNC] join abandoned before NetworkTime.start(); no live client peer.")
		LoadingScreen.hide_screen()
		return
	# Starts the tick loop deliberately, at a moment when the clock-sync round
	# trip is short -- see _take_over_client_time().
	NetworkTime.start()
	# On a client, start() *suspends* while it awaits the initial sync, so it
	# returns before the loop is actually ticking.  Marking ourselves ready here
	# without waiting would let a late tick-rate reply see "already running" and
	# try to restart a start that has not finished -- which aborts the in-flight
	# sync and then collides with the zombie continuation.  Poll instead.
	var deadline := Time.get_ticks_msec() + int(RESYNC_TIMEOUT_SECONDS * 1000.0)
	while not NetworkTime.is_initial_sync_done() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_client_time_ready = NetworkTime.is_initial_sync_done()
	if not _client_time_ready:
		push_error("[NTSYNC] client tick loop never synced; the initial time sync did not complete.")
	LoadingScreen.hide_screen()


func _on_match_session_error(code: int, text: String) -> void:
	push_error("[SESSION] error %d: %s" % [code, text])
	LoadingScreen.hide_screen()
	if _reconnecting and code in [Protocol.ErrorCode.SESSION_EXPIRED, Protocol.ErrorCode.BAD_TOKEN]:
		_reconnecting = false
		return_to_lobby()


func _on_connection_failed() -> void:
	if OS.is_debug_build(): print("Connection failed")
	if _reconnecting:
		return  # the reconnect loop decides whether to retry
	return_to_lobby()


func _server_disconnected() -> void:
	if OS.is_debug_build(): print("Server has disconnected!")
	if _reconnecting:
		return
	if _use_match_session and MatchSession.resume_token != "" and not _test_no_reconnect \
			and MatchSession.phase != Protocol.Phase.CLOSED:
		_begin_reconnect()
		return
	return_to_lobby()


## Forced transport drop for tests, and the same path a real disconnect takes.
func debug_force_drop() -> void:
	if not _use_match_session:
		return
	_terminate_connection()
	_server_disconnected()


## Retry the connection until the server's resume grace expires.  On success the
## same stable player id is rebound; score/team/loadout live on the server-side
## Player node that was kept reserved.
func _begin_reconnect() -> void:
	if _reconnecting:
		return
	_reconnecting = true
	MatchSession.stop_heartbeat()
	LoadingScreen.show_screen(0.25, "Connection lost — reconnecting…")
	var deadline := Time.get_ticks_msec() + int(Protocol.RESUME_GRACE_SECONDS * 1000.0)
	while _reconnecting and Time.get_ticks_msec() < deadline:
		LoadingScreen.report(0.4, "Reconnecting…")
		var err := create_client(_match_host, _match_port)
		if err == OK:
			if await _await_connected(4.0):
				MatchSession.local_peer_id = multiplayer.get_unique_id()
				MatchSession.request_hello()
				if await _await_welcome(5.0):
					await _adopt_server_tick_rate()
					if _can_resync():
						NetworkTime.start()
						# The world was not rebuilt across the drop, so the existing
						# synchronizers still hold the old tick domain's cursors.
						# Reset them after start (same rule as _reinit_time).
						_reset_rollback_history()
						var sync_deadline := Time.get_ticks_msec() + int(RESYNC_TIMEOUT_SECONDS * 1000.0)
						while not NetworkTime.is_initial_sync_done() \
								and Time.get_ticks_msec() < sync_deadline:
							await get_tree().process_frame
						_client_time_ready = NetworkTime.is_initial_sync_done()
						_reconnecting = false
						LoadingScreen.hide_screen()
						if OS.is_debug_build():
							print("[MATCH] resumed as player %d" % MatchSession.local_player_id)
						return
		_terminate_connection()
		await get_tree().create_timer(2.0).timeout
	_reconnecting = false
	LoadingScreen.hide_screen()
	push_error("Reconnect window expired; leaving the match.")
	return_to_lobby()


func _await_connected(timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var saw_connecting := false
	while Time.get_ticks_msec() < deadline:
		var peer := multiplayer.multiplayer_peer
		if peer != null:
			var status := peer.get_connection_status()
			if status == MultiplayerPeer.CONNECTION_CONNECTED:
				return true
			if status == MultiplayerPeer.CONNECTION_CONNECTING:
				saw_connecting = true
			elif status == MultiplayerPeer.CONNECTION_DISCONNECTED and saw_connecting:
				return false
		await get_tree().process_frame
	return false


func _terminate_connection() -> void:
	if OS.is_debug_build(): print("terminate connection")
	_client_time_ready = false
	_host_tick_rate = -1
	MatchSession.stop_heartbeat()
	LanDiscovery.stop_announcing()
	var mp = get_tree().get_multiplayer()
	if mp.multiplayer_peer != null:
		NetworkTime.stop()  # full stop: resets state so a re-host/re-join re-syncs
		mp.multiplayer_peer.close()
		mp.multiplayer_peer = null


# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

func _remove_game_scene() -> void:
	if game_scene == null:
		return
	# queue_free WITHOUT remove_child.  Removing first makes Node.multiplayer
	# null while netfox's deferred synchronizer re-processing is still queued,
	# which throws "get_unique_id on a null value".  Keeping the node in the
	# tree until the end of the frame gives those defers a valid tree.
	game_scene.queue_free()
	game_scene = null


## True when this peer is a real ENet server -- i.e. the instance that owns UDP
## 8080 and can actually be joined.
##
## [b]Do not use [code]multiplayer.is_server()[/code] for this.[/b]  It reports
## true for [OfflineMultiplayerPeer], which is what a second local instance falls
## back to when the port is already taken (see `create_server`).  That makes both
## instances claim to be the host.  [NetworkEvents].is_server() special-cases it
## (`network-events.gd:56-73`), and this wraps that so the trap is named once.
func is_network_host() -> bool:
	return NetworkEvents.is_server()


## True when this peer is the tick-domain reference: a real ENet server.  Same
## condition as [method is_network_host], named for the watchdog's context.
func _is_tick_reference() -> bool:
	return is_network_host()


func _has_live_peer() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _can_resync() -> bool:
	return _has_live_peer() and not multiplayer.is_server()
