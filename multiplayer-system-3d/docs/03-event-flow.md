# 03 — Event Flow: Connection Lifecycle & Ordering Invariants

This documents the subtle, order-dependent parts of the connection lifecycle. **Most "movement stops working but I can still look/shoot" bugs are caused by violating one of these invariants.** Read this before touching `network_manager.gd`.

---

## The core relationship: `NetworkEvents` drives `NetworkTime`

`NetworkTime` (which drives the rollback tick loop) is **not** started/stopped by `NetworkManager` directly. It is managed by netfox's **`NetworkEvents`** autoload (`addons/netfox/network-events.gd`):

| Event | Effect |
|---|---|
| `on_server_start` | `NetworkTime.start()` |
| `on_client_start` | ~~`NetworkTime.start()`~~ — **taken over by `NetworkManager`**, see below |
| `on_server_stop` | `NetworkTime.stop()` |
| `on_client_stop` | `NetworkTime.stop()` |

**Exception: the client start is project-owned.** `NetworkEvents` wires `on_client_start → NetworkTime.start()` in its `_ready` (`network-events.gd:84`), but that fires the instant the ENet connection is up — across the join's own stall. `NetworkManager._take_over_client_time()`, called from `join_party()`, disconnects that listener, and `_on_connected_to_server()` starts the loop itself once the join has settled. The other three wires are untouched. **Do not add another listener to `NetworkEvents.on_client_start`** — `_take_over_client_time()` removes every listener on that signal.

`NetworkEvents` detects server start/stop by **polling `is_server()` once per frame in `_process`** (`network-events.gd:93-107`), tracking a private `_is_server` boolean. It also explicitly treats `OfflineMultiplayerPeer` as "not a server" (`network-events.gd:64-65`).

### Movement only works while the rollback tick loop runs

The rollback tick loop is driven by `NetworkTime` (started by `NetworkEvents`). If you see "can look + shoot but not move", the rollback tick loop is dead — usually a `NetworkTime` start/stop bug. See the two consequences below.

---

## Consequence 1 — A re-host must not start its tick loop before `NetworkEvents` has observed the stop

`return_to_lobby()` must not complete a teardown + re-host inside one `NetworkEvents`
poll window. Two distinct failures live here, and the second is the one the
default shell hits:

- **Synchronous teardown + `create_server()` in one frame.** The peer is null only between two polls, so `NetworkEvents` never sees the intermediate "stopped" state: `on_server_stop` never fires, `on_server_start` never **re-fires**, and `NetworkTime.start()` never runs on the re-host — even though `_terminate_connection` manually stopped it.
- **The offline/lobby re-host starts its own loop.** `boot_offline_lobby()` → `create_offline_peer()` installs an `OfflineMultiplayerPeer` and calls `NetworkTime.start()` manually (Consequence 2). If that happens while `NetworkEvents._is_server` is still `true` from the match, the next poll sees a non-server peer (null / offline), emits `on_server_stop` → `NetworkTime.stop()`, and kills the fresh loop. Nothing restarts it: movement stops while look/shoot keep working (`05-known-issues.md` #154).

Either way the result is a dead rollback loop.

**`return_to_lobby()` re-hosts through `_rehost_after_stop_observed()`**, which awaits **two** `get_tree().process_frame` emissions before booting. `SceneTree` emits `process_frame` before node `_process`, so one await would still resume before that frame's poll — the *old* `call_deferred("boot_to_lobby")` rule had exactly this hole for the results overlay, whose auto-leave runs from `post_match._process` **after** the autoload's poll. Two full frames guarantee one complete poll with no server peer present, so its `on_server_stop` is a no-op before the new peer installs its loop.

The helper also captures a monotonic `_lifecycle_epoch`, bumped by `return_to_lobby()`, `join_party()` and `host_local_match()`, and aborts if it moved — a double `return_to_lobby()` (results auto-leave plus a disconnect callback) must not build two lobbies.

## Consequence 2 — The offline fallback won't auto-start `NetworkTime`

Because `NetworkEvents` ignores `OfflineMultiplayerPeer`, `create_server()` must call `NetworkTime.start()` **manually** when it falls back to an offline peer (`network_manager.gd:39`). Otherwise the second local instance's lobby can't move. If someone refactors `create_server` and drops that line, the "Join Local (This Computer)" testing loop silently breaks.

## `_terminate_connection()` must do the full stop

`NetworkManager._terminate_connection()` (`network_manager.gd:174-180`) calls the **full `NetworkTime.stop()`** (not the low-level `NetworkTimeSynchronizer.stop()`) before nulling the peer. This resets `NetworkTime`'s internal `_state` to INACTIVE so a subsequent `NetworkTime.start()` (via `NetworkEvents`) succeeds cleanly on re-host/re-join.

---

## Boot (become host)

1. `world/main.gd:_ready()` → `_boot()` (`world/main.gd:22-23`).
2. `_boot()` → `await _preload_resources(...)` (parallel threaded load) → `await NetworkManager.boot_to_lobby()`.
3. `boot_to_lobby()` → `create_server()` (ENet server, `is_hosting_game = true`) then `load_game_scene("res://maps/main_menu_world.tscn")` (`network_manager.gd:93-100`).
4. `load_game_scene()` instantiates `world1.tscn`, sets `game_scene.map_path`, adds it as child of `current_scene` (`77-83`).
5. `world_1.gd:_ready()`: sets `GameManager.spawn_parent`, opens loadout (`PlayerInput.ui_open = true`), and — because `is_hosting_game` — loads the lobby map into `SpawnParent` (named `"Map"`) and creates a `SpawnManager` (which adds player 1).
6. `NetworkEvents._process` sees the server → `on_server_start` → `NetworkTime.start()` → rollback loop runs → movement works after the player confirms a loadout and spawns.

---

## Join a party (become client)

1. The joiner is already their own host (offline or real server). They walk into `HostServer`, press `E`, and open the Match Menu's FIND MATCH tab.
2. `join_party(ip)` → `_remove_game_scene()` (free the solo world) → `create_client(ip)` (`network_manager.gd:96-100`).
3. `create_client()` → `_terminate_connection()` (stop `NetworkTime`, close + null the old peer) → create an ENet client → set `multiplayer_peer` (`46-55`).
4. On connect, `NetworkManager._on_connected_to_server()` → `enter_existing_game_scene()` (a fresh client `world1.tscn` with **no** map; the map replicates from the host) (`159-161`, `62-66`).
5. In parallel, `NetworkEvents._handle_connected_to_server()` → `on_client_start` → `NetworkTime.start()` (the client awaits `on_initial_sync`, then ticks).
6. The host's `SpawnManager._peer_connected()` → `_add_player_to_game(client_id)` adds the joiner's `Player`; the `MultiplayerSpawner` replicates the map + existing players to the joiner.

---

## Leave / disconnect

`return_to_lobby()` is the single exit path (called by the "Leave Party" buttons, `pause_menu`, `staging_room`, the results overlay's **auto countdown** at `post_match.gd:177-190`, `_on_connection_failed()`, `_server_disconnected()`), `network_manager.gd:return_to_lobby`:

1. Bump `_lifecycle_epoch` and capture it — cancels a superseded rehost.
2. `Input.set_mouse_mode(VISIBLE)`.
3. `_terminate_connection()` — full `NetworkTime.stop()`, then close + null the peer (frees port 8080 for re-host).
4. `_remove_game_scene()`.
5. `_rehost_after_stop_observed(epoch, role)` — awaits two process frames so `NetworkEvents` observes the stop transition (see Consequence 1), then boots the offline shell or the legacy P2P lobby.

---

## Lobby → match map swap

`NetworkManager.load_match_map(map_path)` is server-authoritative (guards `multiplayer.is_server()`) and needs **no RPC** (`network_manager.gd:119-143`):

1. Clear `GameManager.game_mode_component = null` (avoid dangling ref while the old map is freed).
2. `remove_child(old_map)` + `queue_free()` the current `"Map"` node (the `MultiplayerSpawner` propagates removal to clients). **Use `queue_free`, never `free()`** — the spawner needs the removal event.
3. `load(map_path).instantiate()`, name `"Map"`, `add_child` to `spawn_parent` (the spawner replicates it; `map.gd:_enter_tree` re-points `game_mode_component` and calls the HUD's `setup_gmc()`).
4. Respawn existing players: `for child in spawn_parent: if child is Player: child.rpc_reset.rpc(child._get_spawn_position())` (after the new map exists so `_get_spawn_position()` finds it).

---

## Ordering invariant: when the client starts its clock

`NetworkManager._on_connected_to_server` (autoload 1's `_ready`) runs **before** `NetworkEvents._handle_connected_to_server` (autoload 7's `_ready`) — Godot emits in connection order. The first builds the client world synchronously (`preload(world1.tscn)`) and then suspends for two frames, where the renderer still has D3D12 shader compilation ahead of it.

netfox used to start `NetworkTime` during that suspension. The clock-sync request went out *before* the stall and its reply was applied *after* it, and because that initial timestamp has no RTT compensation (`network-time-synchronizer.gd:267-276`) while `NetworkTime.tick` is monotonic, the joiner's entire tick origin was seeded from a clock reading seconds out of date. That is `05-known-issues.md` #18.

**The fix is timing, not ordering.** The scene build still happens first — deferring it even one frame risks `MultiplayerSpawner` spawn messages arriving before the spawner exists — but the clock sync now happens on the **far side** of the stall:

```
_on_connected_to_server()                        # coroutine; cannot be cancelled
  await enter_existing_game_scene()              # world built; the big stall is behind us
  await _await_settled()                         # 2 consecutive frames under SETTLE_FRAME_SECONDS
  await _adopt_server_tick_rate()                # host-pushed; see below
  if not _can_resync():                          # re-check: return_to_lobby() may have run
      LoadingScreen.hide_screen(); return
  NetworkTime.start()                            # short round trip -> a correct seed
  while not NetworkTime.is_initial_sync_done() and <deadline>: await process_frame
  _client_time_ready = NetworkTime.is_initial_sync_done()
  LoadingScreen.hide_screen()
```

Invariants that follow, and are easy to break:

- **`NetworkTime.start()` suspends on a client** — it awaits the initial sync and returns before the loop is actually ticking. Do not set `_client_time_ready` (or anything else meaning "the loop is up") on the line after it; poll `is_initial_sync_done()`, or a late tick-rate reply will see "already running" and try to restart a start that has not finished, aborting the in-flight sync and colliding with its continuation.
- **`LoadingScreen.hide_screen()` must not be skippable.** It now runs on the `_can_resync()` bail-out too. Before #18 it lived inside `enter_existing_game_scene()` and always ran; moving it into the tail means every early return has to hide the screen itself, and one that doesn't is an unrecoverable hang.
- **The waits are bounded and deliberately short** — `SETTLE_TIMEOUT_SECONDS` 1.5 s, `TICK_RATE_TIMEOUT_SECONDS` 1.5 s, and `RESYNC_TIMEOUT_SECONDS` (also the post-start sync poll) 2 s. Each is a fallback; the healthy path finishes in a frame or two. A generous budget turns any hiccup into a visibly hung join.
- **The tick rate is pushed by the host on `peer_connected`, not only pulled.** A joiner's frames are long right after connecting, so a pull-only round trip can miss the wait window entirely and time the join out. The reply arriving after the loop is up is handled by restarting it, not by mutating the rate underneath it (see `02-netcode.md` §8).
- **Applying *no* tick rate is worse than applying the wrong one.** `apply_tick_rate()` also derives netfox's tick-count limits; skipping it on the timeout path leaves `max_ticks_per_frame` at netfox's default of 8, which is the documented route to "the client can be kicked back to its own lobby" (`05-known-issues.md` #18). `_adopt_server_tick_rate()` applies the local default on a miss for exactly this reason.
- The watchdog (`_evaluate_resync`) stays silent until `_client_time_ready`. Between sessions `NetworkTime.tick` still holds the previous session's value, and comparing it against a fresh host sample reads as an enormous offset.

---

## Match-session join (dedicated server)

The default boot still uses the P2P flow above. A direct `--connect=host[:port]`
join (and, later, every lobby join) uses `MatchSession` instead. The ordering
there is different and deliberately later than the P2P one:

```
join_party(host, port, use_match_session=true)
  MatchSession.begin_client(LOBBY_MAP_PATH)      # staging map path known before the world
  create_client(...)
_on_connected_to_server()
  await enter_existing_game_scene()              # client loads the staging map locally
  await _await_settled()
  MatchSession.request_hello()                   # only now: the world exists
  await _await_welcome(5.0)                      # stable player id + map path/hash
  await _adopt_server_tick_rate()
  NetworkTime.start()
  ...
MatchSession (client, _process)
  wait for GameManager.find_player(local_player_id)
  bind owner_peer_id + PlayerUI, send client_node_ready
```

Server side:

```
hello(peer)
  validate protocol/build, allocate stable player_id
  hide existing players' synchronizers from this peer
  add the Player node (stable id as name), wait one frame
  send welcome
client_node_ready(player_id)
  verify the sender owns that id
  mark the peer ready, enable player sync visibility,
  then sync existing-player state
```

Invariants:

- **`hello` is sent after the world is built.** The server must not add a Player
  or send node-addressed RPCs before that. This is the fix for
  `05-known-issues.md` #124.
- **The client binds its own owner peer after `welcome`.** The spawn payload
  carries the stable id as the node name but not the owning peer, so the client
  re-applies input authority (`Player.bind_owner_peer`) and rebuilds the HUD.
  **The two are not atomic.** The replicated `owner_peer_id` setter flips
  authority first, so `PlayerBodyUI._should_show()` turns true while the HUD is
  still unbuilt (its `_ready` ran under the pre-sync fallback authority); every
  built widget is null until `on_owner_bound()` → `_ensure_built()`. `_process`
  therefore guards on `_built` as well as `visible` (`player_ui.gd`), or a
  joining client crashes in `_update_scope_charge_ui` on a null
  `_scope_charge_bar`.
- **Maps are local files.** Both sides load the same path; the server sends
  only path + SHA-256. A mismatch rejects the join (`MAP_MISMATCH`).
- **Player sync visibility is explicit.** In a match session every
  `MultiplayerSynchronizer` on a Player starts with `public_visibility = false`;
  peers are opted in on `client_node_ready`. A public synchronizer ignores a
  per-peer `false` override, which is why the flag must be off.
- **A new Player's sync is hidden for three frames** so existing peers receive
  the spawner packet before state sync. This is a heuristic, not a barrier; see
  `05-known-issues.md` #126 for the map case and the planned chunked join state.
- **Map swaps are not yet barrier-safe.** The server broadcasts
  `phase_changed(ACTIVE, path, hash)` and respawns immediately; clients load
  locally after receiving it. `#126` tracks the missing `map_ready` handshake.

## Local host transition (default, no service)

The default launch boots the offline shell. Pressing Host Match opens the host
menu; Start (map/teams/bots) then converts the process into a listen server:

```
host_menu._on_start_pressed()
  capture host team + autofill, write manual-bot teams to lobby_bots
  GameManager.pending_host_setup = {...}
  NetworkManager.host_local_match(8080, selected_map)
    NetworkTime.stop()                 # old offline tick loop
    _remove_game_scene()               # queue_free only, keep the node in-tree
    await process_frame
    call_deferred boot_listen_server(port, map)
      try create_server on 8080, 8081, ...
      load world1 with the chosen map
      world_1 applies pending_host_setup, then LanDiscovery.start_announcing(port)
```

A busy port is not fatal: the listen server tries the next port in the 16-port
range and advertises the one it got. Only `--server` exits on a bind failure.
No loading screen appears before Start.

**`boot_listen_server()` hides the loading screen after the world load.**
`host_local_match()` shows it before tearing down the shell, and the startup
`--listen-server` route is separately hidden by `main.gd`; without the hide in
`boot_listen_server` the in-lobby Host button leaves the screen up forever
(logs still show `listen ready`, so headless tests do not notice).

Invariants:

- **Free the world before the peer is replaced/null.** The old shell's netfox
  synchronizers can run deferred `process_settings`; a detached node has
  `multiplayer == null` and throws (known-issue #132). `_remove_game_scene` now
  only calls `queue_free()`.
- **Keep the offline peer until `create_server()` installs the ENet peer.** No
  null window.
- **The deferred boot lets `NetworkEvents` observe the server transition.**
  `NetworkTime.stop()` leaves the state INACTIVE, then `create_server()` makes
  `is_server()` true and `on_server_start` starts the loop.
- **The host is player 1; joiners are 2+.** `SpawnManager` registers the host
  player on a listen server; `register_host_player(1)` sets `host_player_id`.

The resulting session uses the same match-session handshake, stable ids, local
maps, heartbeat/reaper, and resume as a dedicated server.

The Match Menu's FIND MATCH tab is the join UI. Its LAN list calls
`LanDiscovery.discover()`: it probes UDP `7355-7370` on localhost, each /24
broadcast and `255.255.255.255`; each host answers on `7355 + (port - 8080)`
with a JSON announce and an instance id. The DIRECT row accepts `ip[:port]` or a
join code. Both call `join_party(..., use_match_session=true)`. The LAN announce
is unauthenticated metadata; the join is still validated by the handshake.

## C lobby join

`lobbyd` (`server/lobbyd/lobbyd.c`) is metadata only; gameplay still uses the
match-session flow above. The additional hop is:

```
client                          lobbyd                       match server
POST /v1/matches        ->  allocate id/port, fork/exec  ->  [server] ready
   <- endpoint + grant
POST /v1/matches/{code}/join
   <- endpoint + grant
join_match(endpoint, grant)
   -> hello(..., grant)
                                server validates HMAC + match id
   <- welcome / session_error(BAD_TOKEN)
```

Invariants:

- **The grant check is temporarily advisory** (known issue #149). `MatchSession.hello`
  still runs the HMAC/expiry/match-id validation, but a missing or invalid grant
  only logs a warning and the player is added anyway. Before #149 it produced
  `BAD_TOKEN` and no Player node, which blocked every direct-IP join to a server
  with `MATCH_SECRET` set. Restore the refusal once lobbyd admission is the only
  join path.
- **The client sends `hello` only after its world exists**, as above. The grant
  changes nothing about that ordering.
- **Maps still load locally.** The lobby never carries map bytes.
- **`lobbyd` is not a gameplay relay.** It spawns one headless Godot per match
  and supervises the process; all UDP traffic is direct.
- **Starting a map is a server request.** In staging the room host is a client;
  `world/host_menu.gd` sends `MatchSession.request_start_match(path)`, the
  server re-checks host identity and the map path, then calls
  `load_match_map`.

Known P3 limits: lobbyd's browser count is issued grants, not live players; the
phase is always `staging`; there is no control channel or child re-adoption
(#129). The HMAC secret is passed on argv for the WSL/Windows dev path (#128).

## Reconnect / resume (match sessions)

A dropped client does not rebuild the world. The same `MatchSession` and
`world1.tscn` stay alive; only the ENet peer is replaced.

```
server                          client
peer_disconnected
  entry.state = RESERVED
  set_reserved.rpc(true)   ->   despawn body (+ every other peer)
  reserve Player node
                              _server_disconnected()
                                _begin_reconnect()  (2 s retries, 90 s cap)
                                create_client(host, port)
  <- hello(resume_token)
  validate HMAC + match id
  find RESERVED entry
  bind_peer.rpc(id, new_peer)
  show_players_to_peer
  rpc_reset (reliable)    ->   despawn + 1 s respawn at a team spawn
  welcome(resumed=true, rotated token)
                          ->   rebind local player/HUD, node_ready
                                NetworkTime.start()
                                _reset_rollback_history()
                                hide loading screen
```

Invariants:

- **The Player node is not freed on a drop.** Score, team, and loadout live on
  it; only the owner peer is rebound. The slot expires after the grace period,
  at which point the node is freed and the leaderboard entry removed.
- **`rpc_reset` is reliable now.** It was `any_peer` + `call_local` +
  unreliable; a dropped resume RPC left the client despawned forever.
- **Reset rollback history after `NetworkTime.start()`, not before.** The
  synchronizers still hold the old tick domain's cursors because the world was
  not rebuilt. Resetting before start stamps them with the dying tick.
- **Input authority is rebound on both sides.** `bind_peer` is
  `call_local`; the server and every client (including the resumed one) call
  `Player.bind_owner_peer(new_peer)`. Skipping it leaves input gathering on the
  old peer id: the client looks alive but cannot move.
- **Sync visibility is per peer.** The resumed peer needs
  `show_players_to_peer(new_peer)`; without it state freezes at the pre-drop
  tick even though input resumes.
- **Heartbeats are independent of ENet.** A frozen client's UDP socket stays
  open, so the server reaps on 10 s of silence and takes the same reserve path.
- **The map can change while disconnected.** `welcome` carries the current map
  path/hash and emits `phase_changed` if it differs; `world_1` loads it locally
  before the respawn settles.

Test hooks: `--test-drop-after=N`, `--test-silent-after=N`,
`--test-no-reconnect`, and the server-side `--test-resume-grace=N`.

## Full fragile / order-dependent list

1. **The re-host must wait for `NetworkEvents` to observe the stop** (`network_manager.gd:return_to_lobby` → `_rehost_after_stop_observed`). Any synchronous teardown + rehost, or a single deferred/awaited frame, lets the stale `on_server_stop` kill the new loop and thus movement.
2. **Offline fallback needs manual `NetworkTime.start()`** (`network_manager.gd:create_server`).
3. **Peer-1 hardcoding is everywhere** — `spawn_manager.gd:15` (adds player 1), `spawn_manager.gd:131` (bot authority 1), `leaderboard_singleton.gd:236-258` (`rpc_id(1)`), `loadout_menu.gd:869` (`rpc_id(1)`), `host_server_area.gd:53-54` (`get_unique_id() == 1`). The whole "party leader = peer 1 = server" model collapses if the server is ever not peer 1.
4. **`NetworkManager` owns the client's `NetworkTime.start()`** — netfox's `on_client_start` listener is disconnected in `join_party()`, and the replacement lives at the end of the `_on_connected_to_server()` coroutine (see above). Both halves are required: reconnecting the netfox listener, or starting before `_adopt_server_tick_rate()`, reintroduces #18.
5. **`_reinit_time()` must reset rollback history *after* `start()`, not before** — the recorder seeds its tick cursors from `NetworkTime.tick`, so resetting first stamps them with the dying domain's tick (a host restarts at 0, so they would sit `old_tick` ticks in the future).
6. **Tick-rate changes are all-peers-at-once** — `_reinit_time()` stops, re-rates and restarts the loop. A peer that applies a rate without restarting has a tick origin seeded with a different multiplier and no way to fix it.
7. **`_sync_existing_players_to_peer` one-frame defer** (`spawn_manager.gd:37`) — late joiners rely on a single `await process_frame` before full-state RPCs. If the spawner's tree sync isn't settled in one frame (slow connection, large map), existing players replicate despawned/invisible.
8. **`map_path` only set on the host path** (`network_manager.gd:load_game_scene`) — `world_1.gd:27` does `load(map_path)` guarded by `is_hosting_game`; a client's `map_path` is empty and harmless, but it's an implicit assumption the client never hits the map-loading branch.
9. **`_request_loadout` sender validation** (`loadout_menu.gd:879-881`) — `if sid != 0 and str(sid) != tpid and not tpid.begins_with("bot_"): return`. The `sid != 0` branch is only reachable on the server via `rpc_id(1)`; the server's own direct call has `sid == 0`. Depends on the server validating, and on human ids always being `str(network_id)`.
10. **First spawn is delayed ~1 s** (`player.gd:17` `respawn_time = 1.0` applied in `rpc_reset` at `503`) — "confirm loadout → visible player" is not instant.
11. **`loadout_menu.gd:859-860` comment drift** — the comment says `visible = false` triggers `_process()` → `_canvas.visible = false`, but the sync is via the `visibility_changed` signal (`loadout_menu.gd:101`, `143-157`), not `_process`. Cosmetic but means the mechanism is one degree more indirect than the comment suggests.
12. **`_terminate_connection` must do the full `NetworkTime.stop()`** — not the low-level synchronizer stop — or a subsequent `start()` won't cleanly reset. It also clears `_client_time_ready` / `_host_tick_valid`, so the watchdog stays quiet across the transition.
13. **`ui/main_menu.gd` still calls `create_client()` / `enter_existing_game_scene()` directly** — dead today (the 2D menu is bypassed), but those entry points no longer start a tick loop or hide the loading screen on their own. Anything that revives them must go through `join_party()` instead.

---

## Staging, countdown and the map-ready barrier (2026-11-17)

The new local/match-session flow adds room phases on top of the existing
connection lifecycle. The ordering rules above still apply unchanged.

```
host Globe START / staging START GAME
  NetworkManager.start_staging_match(path)
    MatchSession.set_phase(COUNTDOWN)
    await 5 s
    MatchSession.set_phase(LOADING, path, SHA256)
    load_match_map(path, set_active=false, respawn_players=false)
    await MatchSession.await_map_ready(MAP_MATCH_DEADLINE_SECONDS)
      clients receive phase_changed(LOADING) -> world_1 installs local map
      -> MatchSession.notify_map_ready() -> client_map_ready RPC
    MatchSession.set_phase(ACTIVE)
    rpc_reset all players
```

Invariants:

- **`MatchSession.set_phase()` must update the server's own `phase` before the
  `broadcast_phase` RPC.** That RPC is `call_remote`, so without the explicit
  assignment the host remained in STAGING while every client was told ACTIVE;
  the next client `welcome` then carried the stale STAGING phase.
- **`load_match_map(..., set_active=false, respawn_players=false)` is for the
  barrier path.** The default call still sets ACTIVE and respawns immediately
  for legacy callers.
- **The staging map is still `main_menu_world.tscn`.** Staging is a local
  CanvasLayer; `MatchSession.target_map_path` is only the map START GAME will
  load.
- **Join in progress is explicit.** A client joining an ACTIVE match sits in
  the staging overlay and sends `MatchSession.request_join_in_progress`; the
  server assigns a team and `rpc_reset`s it. The handshake no longer relies on
  accidentally accepting an ACTIVE join.
- **`return_to_lobby()` sets CLOSED before closing a RESULTS listen server.**
  This prevents clients from spending the 90 s resume grace reconnecting to a
  server that is intentionally going away.
- **`MatchSession.reset()` clears target map, READY flags and map-ready ACKs.**
  A re-used process must not carry those into the next room.
- **A countdown coroutine must validate session identity, not node liveness.**
  `start_staging_match()` waits 5 s (and then the map-ready barrier). The next
  world repoints `GameManager.spawn_parent`, so `is_instance_valid()` alone let a
  countdown from a torn-down session swap the returned lobby to the match map.
  It now captures `NetworkManager._lifecycle_epoch` after its entry guards and
  re-checks it (plus `MatchSession.role == SERVER`) after both awaits
  (`05-known-issues.md` #155).

Known gaps: there is no server-side ready gate (READY is advisory), no party
lobby service, and host migration is still the existing reserved-slot expiry
path rather than immediate promotion.
