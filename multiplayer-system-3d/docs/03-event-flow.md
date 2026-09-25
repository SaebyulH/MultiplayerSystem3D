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

## Consequence 1 — A synchronous teardown + re-host is invisible to `NetworkEvents`

If you close the peer and immediately `create_server()` again **in the same frame**, `NetworkEvents` never sees the intermediate "stopped" state (the peer is null only between two `_process` ticks). So:
- `on_server_stop` never fires, and
- `on_server_start` never **re-fires**, so `NetworkTime.start()` never runs on the re-host — even though `_terminate_connection` manually stopped it.

Result: the rollback tick loop is dead and movement stops, while look/shoot (non-rollback) keep working.

**This is why `return_to_lobby()` defers the re-host** with `call_deferred("boot_to_lobby")` (`network_manager.gd:114`) — it gives `NetworkEvents` one frame to observe the stop transition before the re-host re-triggers `on_server_start`.

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

1. The joiner is already their own host (offline or real server). They walk into `JoinParty` and press `E`.
2. `join_party(ip)` → `_remove_game_scene()` (free the solo world) → `create_client(ip)` (`network_manager.gd:96-100`).
3. `create_client()` → `_terminate_connection()` (stop `NetworkTime`, close + null the old peer) → create an ENet client → set `multiplayer_peer` (`46-55`).
4. On connect, `NetworkManager._on_connected_to_server()` → `enter_existing_game_scene()` (a fresh client `world1.tscn` with **no** map; the map replicates from the host) (`159-161`, `62-66`).
5. In parallel, `NetworkEvents._handle_connected_to_server()` → `on_client_start` → `NetworkTime.start()` (the client awaits `on_initial_sync`, then ticks).
6. The host's `SpawnManager._peer_connected()` → `_add_player_to_game(client_id)` adds the joiner's `Player`; the `MultiplayerSpawner` replicates the map + existing players to the joiner.

---

## Leave / disconnect

`return_to_lobby()` is the single exit path (called by the "Leave Party" buttons, `_on_connection_failed()`, `_server_disconnected()`), `network_manager.gd:104-114`:

1. `Input.set_mouse_mode(VISIBLE)`.
2. `_terminate_connection()` — full `NetworkTime.stop()`, then close + null the peer (frees port 8080 for re-host).
3. `_remove_game_scene()`.
4. `call_deferred("boot_to_lobby")` — deferred so `NetworkEvents` sees the server-stop transition (see Consequence 1), then re-hosts and reloads the lobby.

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

## Full fragile / order-dependent list

1. **Deferred re-host is load-bearing** (`network_manager.gd:return_to_lobby`). Any synchronous teardown + re-`create_server()` kills `NetworkTime` and thus movement.
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
