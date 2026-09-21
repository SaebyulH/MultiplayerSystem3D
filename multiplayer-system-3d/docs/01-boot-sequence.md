# 01 — Boot Sequence: Press Play → Playing

A precise, ordered walkthrough of everything that happens from pressing Play to standing in a playable lobby/match, plus the join / leave / map-swap transitions. This is the highest-traffic part of the codebase: most "it won't start / can't move / players invisible" bugs live here.

> File names: the world script is `world/world_1.gd` (scene `world/world1.tscn`). The loadout menu is `world/loadout_menu.gd`. `class_select.gd` exists only under `backup/` — its role was merged into `loadout_menu.gd`.

---

## Stage 0 — Engine boot + autoload `_ready` order

`project.godot:22-32` instantiates 9 autoloads **in order**; `_ready` runs in the same order, which matters:

1. `NetworkManager` (`network/network_manager.gd:11-20`) — connects the three session-lifetime `SceneMultiplayer` signals **once** (`connected_to_server`, `server_disconnected`, `connection_failed`), guarded by `is_connected()` so they survive peer teardown.
2. `Console`
3. `Leaderboard` — server-authoritative score autoload.
4. `NetworkTime` / 5. `NetworkTimeSynchronizer` / 6. `NetworkRollback` — netfox core.
7. `NetworkEvents` (`addons/netfox/network-events.gd:75-85`) — connects `on_server_start → NetworkTime.start`, `on_server_stop → NetworkTime.stop`, `on_client_start → NetworkTime.start`, `on_client_stop → NetworkTime.stop`, then `_set_enabled(true)` which wires `mp.connected_to_server → _handle_connected_to_server` and starts `_process`.
8. `NetworkPerformance`
9. `GameManager` — tiny holder (`spawn_parent`, `game_mode_component`, `spawn_manager`, `lobby_bots`).

The engine then loads the main scene `res://world/main.tscn` (a `Control` root `"Main"` + a `LoadingScreen` instance, `world/main.tscn:6-16`).

**Key invariant:** `NetworkEvents` (autoload 7) loads *after* `NetworkTime` (autoload 4), so its `_ready` can safely `connect(NetworkTime.start)`.

---

## Stage 1 — `world/main.gd` boot

`world/main.gd:22-23` — `_ready()` → `_boot()`.

`world/main.gd:26-41` — `_boot()`:
1. `$LoadingScreen` shown.
2. `await _preload_resources(...)` — threaded-loads 6 heavy paths (`main_menu_world.tscn`, `spawn_manager.tscn`, `spawn_bot_menu.tscn`, the 3 `.tres` class resources) so later `load()` calls are cache hits (`world/main.gd:44-75`).
3. **`await NetworkManager.boot_to_lobby()`** (line 33). Note: this is a **direct `await`**, *not* `call_deferred` — older `CLAUDE.md` text describing a deferred call is stale.
4. Sets progress 1.0, waits two `process_frame`s (lines 39-40, to let D3D12 shaders compile behind the screen), hides the loading screen.

`LoadingScreen.report()` no-ops unless `LoadingScreen.current` is set (which happens in `ui/loading_screen.gd:36-39`).

---

## Stage 2 — `boot_to_lobby()`: become host (or offline fallback)

`network/network_manager.gd:85-92` — `boot_to_lobby()`:
- Guard `if game_scene != null: return` (anti-double-boot).
- `create_server()`, `Leaderboard.reset()`, `LoadingScreen.report(0.75)`.
- `await get_tree().process_frame` (line 91) — **this frame lets `NetworkEvents._process` observe the server** (see Stage 2b).
- `await load_game_scene(LOBBY_MAP_PATH)`.

`network/network_manager.gd:27-43` — `create_server()`:
- `is_hosting_game = true`.
- `ENetMultiplayerPeer.create_server(8080)`; on success set `multiplayer_peer`.
- On failure (port 8080 already taken by another local instance) it sets an **`OfflineMultiplayerPeer`** and **manually calls `NetworkTime.start()`** (line 39). This is required because `NetworkEvents.is_server()` returns `false` for `OfflineMultiplayerPeer` (`network-events.gd:64-65`), so `on_server_start` never fires and the rollback loop would never run — the second local instance's lobby would be unable to move without this manual start.

### Stage 2b — where `NetworkTime` actually starts (ENet path)

`NetworkEvents._process` (`addons/netfox/network-events.gd:93-107`) polls `is_server()` **once per frame**. The first frame after `create_server()` sets the peer, it sees the `false → true` transition and emits `on_server_start` → `NetworkTime.start()`.

`NetworkTime.start()` (`addons/netfox/network-time.gd:409-461`) resets `_tick`, marks peer 1 synced (`_synced_peers[1] = true`), starts `NetworkTimeSynchronizer`, and — because we are the server — goes straight to active state without awaiting initial sync. This runs during the `await process_frame` at line 91, i.e. **before** `world1.tscn` is instantiated.

---

## Stage 3 — `load_game_scene()` → `world1.tscn` `_ready` (host/client split)

`network/network_manager.gd:69-77` — `load_game_scene(map_path)`:
- `LoadingScreen.report(0.8)`, `await process_frame`.
- `game_scene = preload(GAME_SCENE).instantiate()`, set `game_scene.map_path = map_path`.
- `get_tree().current_scene.add_child(game_scene)`, `hide_main_menu()`.

`world/world_1.gd:12-45` — `_ready()`:
- line 13: `GameManager.spawn_parent = %SpawnParent`.
- lines 16-17: adds a `KillFeed` node.
- lines 21-22: `PlayerInput.ui_open = true`, `Input.set_mouse_mode(MOUSE_MODE_VISIBLE)`.
- **line 24: `if NetworkManager.is_hosting_game:`** — the branch that separates host from client:
  - **Host:** `load(map_path).instantiate()` named `"Map"` added to `spawn_parent` (27-29); `load("res://world/spawn_manager.tscn").instantiate()` with `player_scene` set, `add_child` (34-38); `GameManager.spawn_manager = sm`; re-adds `GameManager.lobby_bots` (40-45).
  - **Client** (`is_hosting_game == false`): **none of this runs** — no map, no `SpawnManager`; everything replicates from the host.

`world/world1.tscn:95-97` defines the `MultiplayerSpawner` (`spawn_path = "../SpawnParent"`) with 13 `_spawnable_scenes` uids (player + all maps, including lobby `uid://cgnm6fpurb2b2`).

---

## Stage 4 — `SpawnManager._ready` → local player (still despawned)

`world/spawn_manager.gd:12-18` — `_ready()`:
- connects `peer_connected`/`peer_disconnected`.
- `_add_player_to_game(1)` (line 15) — **hardcoded peer 1**; the host is also a player.
- `randomize()`, instantiates the bot menu onto `root`.

`world/spawn_manager.gd:54-62` — `_add_player_to_game(1)`: `entity_id = str(1)`, instantiate `player_scene`, `name = "1"`, `set_multiplayer_authority(1)`, `spawn_manager = self`, `add_child` to `spawn_parent`, position `(0,100,0)`, `Leaderboard.request_add_player`.

`player/player.gd:417-489` — `Player._ready()`: sets up skins/mannequin/animation-tree/collider duplication, `add_to_group("players")`, then **`despawn()` at line 489**. `despawn()` (`player/player.gd:743-761`) hides the body, disables the collider, parks at `GameManager.get_despawn_position()`, sets `spawned = false`.

**So the player exists but is invisible and inert** until a loadout is confirmed.

---

## Stage 5 — loadout menu

`world/loadout_menu.gd:82-140` — `_ready()`:
- `player_id = str(multiplayer.get_unique_id())`.
- Loads the 3 `Class` `.tres` (104-113), builds the character picker.
- On first load (`_initial_selection_done` static, lines 16, 134-138) picks a random character + weapons; on later loads selects `character[0]` to avoid re-randomizing on return-to-lobby.

The menu's `CanvasLayer` starts visible, so the loadout screen covers the world on boot.

---

## Stage 6 — confirm loadout → first spawn

`world/loadout_menu.gd:850-869` — `_on_confirm_pressed()`:
- validates selections; sets `visible = false` (via `visibility_changed` signal → `_on_visibility_changed` at 143-157 syncs `_canvas.visible`).
- `world.class_selected = true` (`world` = `$"../../.."` = World1).
- `PlayerInput.ui_open = false`, `Input.set_mouse_mode(MOUSE_MODE_CAPTURED)` (863-864).
- Server: `_request_loadout(...)` directly (867); client: `_request_loadout.rpc_id(1, ...)` (869).

`world/loadout_menu.gd:875-909` — `_request_loadout()` (server):
- validates sender id vs `tpid`; `GameManager.find_player(tpid)`; `WeaponController.set_weapons(...)`; `player.set_character(...)`; stores loadout paths.
- **`player.rpc_reset.rpc(player._get_spawn_position())`** (909).

`player/player.gd:501-534` — `rpc_reset(pos)`: `despawn()`, `respawn_timer = respawn_time` (**default 1.0 s**, `player/player.gd:17`), `_spawn_pending_position = pos`, resets health/weapons/effects.

`player/player.gd:854-867` — `_physics_process`: decrements `respawn_timer`; when it hits 0 and `_spawn_pending_position != ZERO`, applies the position and calls `spawn()`. `spawn()` (`765-804`) shows the body, re-enables collider, applies the camera for the local peer, plays the weapon pull-out.

**First real spawn happens ~1 s after confirm** (the `respawn_timer` window).

---

## Stage 7 — Join flow: `join_party(ip)` → client

`world/join_party_area.gd:20-25` — `_ready()` builds the popup `CanvasLayer` (layer 2, on `root`) and `ConnectionUtils.detect_ips()`. `_unhandled_input` (67-75) opens it on `interact` (E) when the local player is inside.

`world/join_party_area.gd:137-151` — open/close popup sets `PlayerInput.ui_open` and mouse mode.

`world/join_party_area.gd:176-196` — `_on_join_pressed()` (IP or 6-char code via `ConnectionUtils.code_to_ip`) and `_on_join_local_pressed()` (`127.0.0.1`) → `NetworkManager.join_party(address)`.

`network/network_manager.gd:96-100` — `join_party(host_ip, port)`:
- `_remove_game_scene()` **first** (frees the joiner's solo world1, SpawnManager, players, lobby map + its spawner).
- `create_client(host_ip, port)`; on error, `return_to_lobby()`.

`network/network_manager.gd:46-55` — `create_client()`: `is_hosting_game = false`, `_terminate_connection()` (stop NetworkTime + close/null old peer), `ENetMultiplayerPeer.create_client`, set peer.

`network/network_manager.gd:159-161` — `_on_connected_to_server()` → `enter_existing_game_scene()`.

---

## Stage 8 — `enter_existing_game_scene()` + map replication

`network/network_manager.gd:62-66` — `enter_existing_game_scene()`: instantiate `world1.tscn`, add as child of `current_scene`, `hide_main_menu()`. **No `map_path`, no map load, no SpawnManager** — because `world_1.gd:24`'s `if is_hosting_game:` is false on a client.

The client's own `MultiplayerSpawner` (`world1.tscn:95-97`) then receives the host's replicated `"Map"` node and existing `Player` nodes into its `SpawnParent`.

`maps/map.gd:12-33` — `Map._enter_tree()` (runs on the client when the replicated map arrives, and on the host at initial load): sets `GameManager.game_mode_component = $GameModeComponent`, finds the HUD and calls `setup_gmc()`, discovers spawn markers.

`world/hud/hud_controller.gd:127-139` — `setup_gmc()`: awaits a frame, grabs `game_mode_component`, wires signals, builds the panel registry, `_switch_to_mode`. In the lobby `game_mode == MAIN_MENU` (enum 6) → `_menu_mode = true` (210-222) so no mode HUD shows.

### Client `NetworkTime.start()` ordering (implicit, fragile)

`NetworkManager._on_connected_to_server` (connected in autoload 1's `_ready`) fires **before** `NetworkEvents._handle_connected_to_server` (connected in autoload 7's `_ready`) — Godot emits in connection order. So `enter_existing_game_scene()` builds the client world1 *before* `on_client_start → NetworkTime.start()` (`network-events.gd:127-128`). The client's `NetworkTime.start()` then awaits `NetworkTimeSynchronizer.on_initial_sync` before emitting ticks — replicated players arrive but don't tick until the clock syncs.

---

## Stage 9 — Host side: late-joiner spawn + state sync

`world/spawn_manager.gd:26-33` — `_peer_connected(network_id)`: `_add_player_to_game(network_id)` (creates the joiner's Player under SpawnParent, authority = their id), then `_sync_existing_players_to_peer(network_id)`.

`world/spawn_manager.gd:36-45` — `_sync_existing_players_to_peer()`: **awaits one frame** (line 37, so the MultiplayerSpawner tree sync settles), then for each already-spawned player not equal to the joiner, `rpc_sync_full_state.rpc_id(peer_id, ...)` + pushes permanent status-effect markers. `rpc_sync_full_state` (`player/player.gd:539-573`) applies weapons/character first, then `spawn()`.

The one-frame defer is fragile: existing players' `rpc_reset` already fired before the joiner connected, so without this defer they'd replicate despawned/invisible.

---

## Stage 10 — Leave flow: `return_to_lobby()` (full ordering)

Entry points: `world/world_1.gd:47-48` (Main Menu button), `world/loadout_menu.gd:160-162` (Leave Party), `network_manager.gd:164-166` (`_on_connection_failed`), `network_manager.gd:169-171` (`_server_disconnected`).

`network/network_manager.gd:104-114` — `return_to_lobby()`, in exact order:
1. line 106: `Input.set_mouse_mode(MOUSE_MODE_VISIBLE)`.
2. line 107: `_terminate_connection()` (`174-180`): `NetworkTime.stop()` (full stop, resets `_state` to INACTIVE), `mp.multiplayer_peer.close()`, `mp.multiplayer_peer = null`. Closing the peer first frees port 8080.
3. line 108: `_remove_game_scene()` (`146-152`): `remove_child` + `queue_free` + `game_scene = null`.
4. line 114: `call_deferred("boot_to_lobby")` — re-host + reload lobby.

**Why the deferred re-host is the crux:** `NetworkEvents._process` polls `is_server()` once per frame, tracking a `_is_server` boolean. Closing the peer and immediately `create_server()` again **in the same frame** means the peer is null only between two process ticks, so `NetworkEvents` never sees the `true → false` transition: `on_server_stop` never fires, and `on_server_start` never **re-fires**, so `NetworkTime.start()` never runs on the re-host — even though `_terminate_connection` manually stopped it. Result: rollback tick loop dead, movement stops while look/shoot keep working. Deferring one frame guarantees the stop transition is observed, then the re-host re-triggers `on_server_start`. See `03-event-flow.md`.

---

## Stage 11 — Lobby → match map swap: `load_match_map()`

`world/host_server_area.gd:16-21` — builds HostMenu; `_unhandled_input` (69-77) opens it only if the local player is inside **and** `_is_leader()` (`get_unique_id() == 1`, 53-54).

`world/host_menu.gd:509-524` — `_on_start_pressed()`: applies team assignments to each `Player.team`, `_autofill_bots()` if checked, `close()`, then `NetworkManager.load_match_map(_selected_map.map_scene.resource_path)`.

`network/network_manager.gd:119-143` — `load_match_map()`:
- guard `multiplayer.is_server()` (120).
- `Leaderboard.reset()`.
- `GameManager.game_mode_component = null` (130, clears dangling ref before free).
- `remove_child(old_map)` + **`queue_free()` (never `free()`)** (131-133, so the spawner receives the removal event).
- `load(map_path).instantiate()`, name `"Map"`, `add_child` to `spawn_parent` (135-137 — spawner replicates the addition; `map.gd._enter_tree` re-points `game_mode_component` + re-runs `setup_gmc()`).
- respawn players: `for child in spawn_parent: if child is Player: child.rpc_reset.rpc(child._get_spawn_position())` (141-143, after the new map exists).

---

## Stage 12 — `PlayerInput.ui_open` / mouse-mode inventory

`ui_open` gates rollback input (the player can't move in menus) and is consumed by `player_input.gd:73-83`, `hud_controller.gd:96`, `player_ui.gd:742`, `ability_manager.gd`, `spawn_bot_menu.gd`.

| Location | `ui_open` | Mouse mode |
|---|---|---|
| `world/world_1.gd:21-22` (world1 `_ready`) | `true` | `VISIBLE` |
| `world/world_1.gd:59-61` (H toggles loadout) | `= loadout_menu.visible` | `VISIBLE` if open else `CAPTURED` |
| `world/world_1.gd:62-68` (Esc closes loadout) | `false` | `CAPTURED` |
| `world/loadout_menu.gd:863-864` (confirm) | `false` | `CAPTURED` |
| `world/join_party_area.gd:142-143 / 150-151` | `true` / `false` | `VISIBLE` / `CAPTURED` |
| `world/host_menu.gd:65-66 / 71-72` | `true` / `false` | `VISIBLE` / `CAPTURED` |
| `network/network_manager.gd:106` (return_to_lobby) | (unchanged) | `VISIBLE` |
| `player/player_input.gd:123-132` (click-to-capture / Esc-to-release) | read-only gate | `CAPTURED` / `VISIBLE` |

---

## Fragile / order-dependent items (see `03-event-flow.md` for the full list)

1. **Deferred re-host is load-bearing** (`network_manager.gd:114`).
2. **Offline fallback needs the manual `NetworkTime.start()`** (`network_manager.gd:39`).
3. **`CLAUDE.md` was stale** — boot is now `await NetworkManager.boot_to_lobby()` (direct, `world/main.gd:33`), and `class_select.gd` no longer exists outside `backup/`.
4. **Peer-1 hardcoding everywhere** — `spawn_manager.gd:15`, `131`; `leaderboard_singleton.gd:236-258`; `loadout_menu.gd:869`; `host_server_area.gd:53-54`. Collapses if the server is ever not peer 1.
5. **`_on_connected_to_server` ordering vs `NetworkTime.start()`** — autoload order 1 vs 7.
6. **`_sync_existing_players_to_peer` one-frame defer** (`spawn_manager.gd:37`).
7. **`map_path` only set on the host path** (`network_manager.gd:74`).
8. **`_request_loadout` sender validation** (`loadout_menu.gd:879-881`) depends on human ids always being `str(network_id)`.
9. **First spawn ~1 s delay** (`player.gd:17`, `503`).
10. **`loadout_menu.gd:859-860` comment drift** — the sync is via `visibility_changed`, not `_process`.
