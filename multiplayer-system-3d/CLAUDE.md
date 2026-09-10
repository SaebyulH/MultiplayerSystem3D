# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Class-based team FPS (TF2-style hero shooter) built in **Godot 4.7** (Forward Plus renderer) using the **netfox 1.35.3** addon for rollback netcode. There are no tests or linter — validation is done by running the game.

The game now boots into a **3D lobby** (`maps/main_menu_world.tscn`) instead of a 2D menu. Launching auto-hosts a server (the player is peer 1 / "party leader") and drops them into the lobby, where they can move/shoot/select a character "just like a normal server". Two in-world interaction zones — **HostServer** and **JoinParty** — replace the old 2D menu buttons and implement a **party system** (friends connect to your lobby, meet up, then the leader loads a match).

## Running the game

There is no build step, test suite, or lint command. The project is opened and run in the Godot editor, or launched headless/from the CLI:

```sh
# Launch the game (main scene is res://world/main.tscn)
godot --path .

# Headless server (for dedicated-server testing)
godot --path . --headless
```

On boot the game **auto-hosts**: it creates an ENet server on port `8080` (`NetworkManager.SERVER_PORT`) and loads the lobby map. The old 2D menu (`ui/main_menu.tscn`) still exists on disk but is **bypassed** — `world/main.tscn` no longer instances it.

Multiplayer is tested by running multiple instances:

- **Host**: launch once — you are already hosting and standing in the lobby. Walk into the **HostServer** zone, press `E`, pick a map, "Start server".
- **Join**: launch a second instance. Its `create_server()` will fail (port 8080 already in use) and it falls back to an **offline peer** — it still gets a local lobby. Walk into **JoinParty**, press `E`, then either "Join Local (This Computer)" or enter the host's IP / 6-char join code.

Bots can be added at runtime via the `add_bot_spi` / `add_bot_sci` / `add_bot_ffa` input actions (server only).

## Autoloads (singletons)

Defined in `project.godot` under `[autoload]`:

- **NetworkManager** (`network/network_manager.gd`) — owns the whole connection lifecycle and scene transitions. Now exposes `boot_to_lobby()`, `join_party(ip)`, `return_to_lobby()`, and `load_match_map(path)` in addition to the peer primitives `create_server()` / `create_client()`. It connects the session-lifetime `multiplayer` signals once in `_ready()`.
- **Leaderboard** (`ui/leaderboard_singleton.gd`) — server-authoritative score tracking (kills/deaths/damage/heals/killstreaks). Clients never write directly; they call `request_*()` which sends an RPC to peer 1.
- **GameManager** (`singletons/game_manager.gd`) — a tiny global holder: `spawn_parent` (node all Players live under) and `game_mode_component`. `Map` populates these on `_enter_tree`.
- **NetworkTime, NetworkTimeSynchronizer, NetworkRollback, NetworkEvents, NetworkPerformance** — provided by netfox (see `addons/netfox/`). Do not edit. **NetworkEvents is what auto-starts/stops `NetworkTime`** on server/client start/stop (see the event-flow section below).
- **Console** — in-game console addon (`addons/console/`).

Note: **`ConnectionUtils`** (`network/connection_utils.gd`, `class_name ConnectionUtils`) is **not** an autoload — it is a stateless `static` class shared by the interaction popups (and, conceptually, the bypassed 2D menu).

## Networking model: rollback + server-authoritative split

The project deliberately splits simulation responsibility:

- **Movement, jumping, crouch, dash, shoulder-charge** are **rollback-simulated**. Inputs (`input_dir`, `jump_input`, `crouch`, `dash_input`, `charge_trigger_dir`) are rollback-synced through the `RollbackSynchronizer` on the Player; `Player._rollback_tick()` re-simulates deterministically. `PlayerInput._gather()` is connected to `NetworkTime.before_tick_loop` and fills these once per tick.
- **Firing, reload, weapon switching, damage, status effects** are **server-authoritative RPC**. The owning client polls `primary/secondary/tertiary_fire_held` in `_physics_process` (NOT in the rollback tick) and sends `fire_intent` to the server; the server re-validates and is the only place ammo is deducted.

Consequence: fire-held flags must **never** be added to the `RollbackSynchronizer` input properties — netfox stomps them on re-simulation ticks. See the header comments in `player/player_input.gd` and `player/weapon_controller.gd`.

**Movement only works while the netfox rollback tick loop is running.** That loop is driven by `NetworkTime` (started by `NetworkEvents`). If you see "can look + shoot but not move", the rollback tick loop is dead — usually a `NetworkTime` start/stop bug (see "Connection lifecycle & event flow" below).

Other conventions:

- **Player name == `str(network_id)`** for human players (`entity_id` == `name`), and `"bot_N"` for bots. `GameManager.find_player(id)` looks up by node name.
- **Server is peer 1**, and the host is also a player. Bots are fully server-authoritative (`is_bot` set before `add_child`).
- Player authority is wired in `Player._enter_tree`: humans get authority over their `player_input`/`body`, the server keeps authority on the rest.

## The 3D lobby & party system

### The lobby is "just another map"

`maps/main_menu_world.tscn` is an ordinary `Map` node (script `maps/map.gd`) whose `GameModeComponent.game_mode` is the new **`MAIN_MENU`** mode (enum value 6). Its scene uid `uid://cgnm6fpurb2b2` is **already** in `world/world1.tscn`'s `MultiplayerSpawner._spawnable_scenes`, so it replicates to clients exactly like any gameplay map.

The `MultiplayerSpawner` in `world/world1.tscn` (`spawn_path = NodePath("../SpawnParent")`) replicates whatever single node named `"Map"` lives in `SpawnParent`. That means the party semantics come for free:

- A joiner connecting to a host who is still in the lobby receives the lobby map.
- A joiner connecting to a host who already loaded a match receives the match map.

There is **no** map-selection special case — the spawner replicates whatever the host currently has loaded.

### Interaction zones

`main_menu_world.tscn` contains two `Area3D` children of the map root:

| Node | Script | Purpose |
|---|---|---|
| `HostServer` | `world/host_server_area.gd` | Party-leader-only: pick a map and load it |
| `JoinParty` | `world/join_party_area.gd` | Enter host IP / join code, or Join Local |

Both follow the `world/control_point.gd` body-tracking pattern: `body_entered` / `body_exited` append/erase `Player`s, and `_unhandled_input` consumes the existing **`interact`** action (bound to physical `E`, keycode 69). Area3D inspector values: `collision_layer = 0`, `collision_mask = 2` (PLAYER_COLLISION), `monitoring = true`, `monitorable = false`. Each has a `CollisionShape3D` (BoxShape3D) and a billboard `Label3D` prompt.

- **HostServer** shows "Press E to host" only when the **local** player is inside *and* is peer 1 (`multiplayer.get_unique_id() == 1`); everyone else sees "MUST BE PARTY LEADER TO HOST SERVER". Pressing `E` opens a map-list popup populated from `ConnectionUtils.scan_maps()`; "Start server" calls `NetworkManager.load_match_map(selected_path)` (re-checks `is_server()`).
- **JoinParty** shows "Press E to join" to anyone. `E` opens a popup with an IP/join-code `LineEdit` (prefilled with the detected LAN IP), a click-to-cycle detected-IP button, a "Join" button, and "Join Local (This Computer)". Handlers call `NetworkManager.join_party(address)` / `join_party("127.0.0.1")`.

The popups are built **in code** onto a `CanvasLayer` (added to `get_tree().root`, layer 2 — same approach as `world/loadout_menu.gd`), so they are not children of the replicated map and won't be duplicated by the spawner. Opening a popup sets `PlayerInput.ui_open = true` and shows the mouse; closing (Esc / E / Close button) reverses it. The scripts also free their popup in `_exit_tree` (the map is freed on map-swap).

### The party-leader model

There is no explicit "party leader" state — it is implied by peer id: **peer 1 is always the leader** (and always the server). The HostServer gate (`get_unique_id() == 1`) plus the `is_server()` guard in `load_match_map` enforce "only the leader can host". Every booting player becomes peer 1 of *their own* server, so everyone starts as a leader of a solo lobby; joining someone else switches them to client mode.

## Connection lifecycle & event flow

This is the subtle part — read carefully before touching `network_manager.gd`.

### netfox time management (why movement can break)

`NetworkTime` (which drives the rollback tick loop) is **not** started/stopped by `NetworkManager` directly. It is managed by netfox's **`NetworkEvents`** autoload (`addons/netfox/network-events.gd`):

- `on_server_start`  → `NetworkTime.start()`  (emitted when `is_server()` becomes true)
- `on_client_start`  → `NetworkTime.start()`  (emitted directly on `connected_to_server`)
- `on_server_stop` / `on_client_stop` → `NetworkTime.stop()`

`NetworkEvents` detects server start/stop by **polling `is_server()` once per frame in `_process`**. It also explicitly treats `OfflineMultiplayerPeer` as "not a server" (its `is_server()` returns false for it). Two consequences for our code:

1. **A synchronous teardown + re-host is invisible to `NetworkEvents`.** If you close the peer and immediately `create_server()` again *in the same frame*, `NetworkEvents` never sees the intermediate "stopped" state, so `on_server_start` never re-fires and `NetworkTime.start()` never runs — the rollback tick loop dies and movement stops (while look/shoot, which don't use rollback, keep working). **This is why `return_to_lobby()` defers the re-host with `call_deferred("boot_to_lobby")`** — giving `NetworkEvents` one frame to observe the stop transition before the re-host re-triggers `on_server_start`.
2. **The offline fallback won't auto-start `NetworkTime`.** Because `NetworkEvents` ignores `OfflineMultiplayerPeer`, `create_server()` must call `NetworkTime.start()` **manually** when it falls back to an offline peer (otherwise the second local instance's lobby can't move).

`NetworkManager._terminate_connection()` calls the **full `NetworkTime.stop()`** (not the low-level `NetworkTimeSynchronizer.stop()`) before nulling the peer — this resets `NetworkTime`'s internal `_state` to INACTIVE so a subsequent `NetworkTime.start()` (via `NetworkEvents`) succeeds cleanly on re-host/re-join.

### Boot (become host)

1. `world/main.gd._ready()` → `NetworkManager.call_deferred("boot_to_lobby")`.
2. `boot_to_lobby()` → `create_server()` (ENet server, `is_hosting_game = true`) then `load_game_scene("res://maps/main_menu_world.tscn")`.
3. `load_game_scene()` instantiates `world/world1.tscn`, sets `game_scene.map_path`, and adds it as a child of `get_tree().current_scene` (the `Main` Control root).
4. `world_1.gd._ready()`: sets `GameManager.spawn_parent = %SpawnParent`, opens the loadout menu (`PlayerInput.ui_open = true`), and — because `is_hosting_game` — loads the lobby map into `SpawnParent` (named `"Map"`) and creates a `SpawnManager` (which adds player id 1).
5. `NetworkEvents._process` sees the server → `on_server_start` → `NetworkTime.start()` → rollback tick loop runs → movement works after the player confirms a loadout and spawns.

### Join a party (become client)

1. The joiner is already their own host (offline or real server). They walk into `JoinParty` and press `E`.
2. `join_party(ip)` → `_remove_game_scene()` (free the solo world) → `create_client(ip)`.
3. `create_client()` → `_terminate_connection()` (stop `NetworkTime`, close + null the old peer) → create an ENet client → set `multiplayer_peer`.
4. On connect, `NetworkManager._on_connected_to_server()` → `enter_existing_game_scene()` (a fresh client `world1.tscn` with **no** map; the map replicates from the host).
5. In parallel, `NetworkEvents._handle_connected_to_server()` → `on_client_start` → `NetworkTime.start()` (the client awaits `on_initial_sync`, then ticks).
6. The host's `SpawnManager._peer_connected()` → `_add_player_to_game(client_id)` adds the joiner's `Player` node; the `MultiplayerSpawner` replicates the map + existing players to the joiner.

### Leave / disconnect

`return_to_lobby()` is the single exit path, called by the "Leave Party" buttons (`world_1.gd`, `loadout_menu.gd`, `class_select.gd`), `_on_connection_failed()`, and `_server_disconnected()`:

1. `Input.set_mouse_mode(VISIBLE)`.
2. `_terminate_connection()` — full `NetworkTime.stop()`, then close + null the peer (frees port 8080 for the re-host).
3. `_remove_game_scene()`.
4. `call_deferred("boot_to_lobby")` — deferred so `NetworkEvents` sees the server-stop transition (see above), then re-hosts and reloads the lobby.

### Lobby → match map swap

`NetworkManager.load_match_map(map_path)` is **server-authoritative** (guards `multiplayer.is_server()`) and needs **no RPC** — the `HostServer` prompt/button is already gated to peer 1:

1. Clear `GameManager.game_mode_component = null` (avoid a dangling ref while the old map is freed).
2. `remove_child(old_map)` + `queue_free()` the current `"Map"` node (the `MultiplayerSpawner` propagates the removal to clients). **Use `queue_free`, never `free()`** — the spawner needs the removal event.
3. `load(map_path).instantiate()`, name it `"Map"`, `add_child` to `spawn_parent` (the spawner replicates it; `map.gd._enter_tree()` re-points `GameManager.game_mode_component` and calls the HUD's `setup_gmc()`).
4. Respawn existing players: `for child in spawn_parent: if child is Player: child.rpc_reset.rpc(child._get_spawn_position())` (after the new map exists so `_get_spawn_position()` finds it).

## Player & character architecture

- `player/player.gd` (`class_name Player`) is a `CharacterBody3D`. Movement is Quake/Source-style (ground friction vs. `_air_accelerate`), with stamina, dash/dash-jump, crouch/slide, double-jump, and a server-driven shoulder-charge carry/stun.
- `Player.Team` enum is `{ SPI, SCI, FFA }` (FFA = damage anyone). `TEAM_COLORS`: SCI blue, SPI red.
- **Characters vs. Classes** are both `Resource`s:
  - `Class` (`player/class.gd`) lists `primary_weapons` / `secondary_weapons` / `melee_weapons` and `characters`.
  - `Character` (`player/character.gd`) carries stat multipliers (health, speed, regen, etc.), an `abilities` list, and a `character_scene` world model.
- Character models are cosmetic: the built-in mannequin always drives animation via `AnimationTree`; a spawned character model copies its pose per-bone by name (`_copy_mannequin_pose`).
- Team tinting / wallhack outlines / health-bar reveal are **purely client-side** (`Player._update_visibility`), driven by status-effect flags, and never networked.

## Weapon architecture

- `Weapon` (`weapon/weapon.gd`) is a `Resource` containing an `Array[WeaponFire]`. Each `WeaponFire` has an `ActionType`: `SHOOT`, `ADS`, `SHIELD`, or `SIGNAL`.
- `WeaponController` (`player/weapon_controller.gd`) owns the active loadout and all fire/reload/switch state. `set_weapons()` is the only correct runtime entry point; it deep-copies resources and resets state.
- Weapons live in `weapon/` grouped by role (`assault_weapons/`, `assassin_weapons/`, `assistance_weapons/`, `tf2/`, etc.). Projectiles are in `weapon/projectiles/`.

## Game modes

`components/game_mode_component.gd` (`GameModeComponent`) is a server-side state machine:

- `GameMode` enum: `ESCORT`, `DOMINATION`, `KOTH`, `HYBRID`, `CONTROL`, `DEATHMATCH`, `MAIN_MENU`.
- `PhaseState` enum: `WAITING_FOR_PLAYERS → SETUP → OBJECTIVE_LOCKED → ACTIVE → OVERTIME → ROUND_END → MATCH_END`.
- Mode logic is delegated to sub-nodes created in `_create_mode_nodes()`: `EscortMode`, `HybridMode`, `KothMode`, `DominationMode`, `DeathmatchMode`, and `MainMenuMode` (`components/*_mode.gd`). Each exposes `get_sync_state()` / `apply_sync_state()` / `tick()` (some omit state if the mode drives itself).
- State is pushed to clients at 10 Hz via `_rpc_sync_state` (`SYNC_INTERVAL`). Objective nodes (`ControlPoint`, `PayloadNode`) self-register with the component via `register_control_point` / `register_payload`.
- `DeathmatchMode` polls the `Leaderboard` singleton rather than tracking kills itself.

**`MAIN_MENU` mode** (`components/main_menu_mode.gd`, `class_name MainMenuMode`) is deliberately inert — the lobby has no objective, no round timer, no win condition. It has empty `tick()`/`reset()` and no sync state (EscortMode-shaped). `GameModeComponent` special-cases it: `_ready()` returns before `_transition_phase(SETUP)` (no countdown), and `_process()` early-returns (no time broadcast / state sync). The HUD hides entirely for this mode (see below).

## Status effects

`components/status_effect/status_effect_manager.gd` (`StatusEffectManager`) is server-authoritative: effects tick only on the server, remaining times are pushed to clients via RPC. Effect types (`bleed`, `burn`, `stun`, `slow`, `gravity_flip`, `invincible`, `pinned`, `poison`, `enlarge`, etc.) are subclasses of `StatusEffect` under `components/status_effect/effects/`.

## Maps

`maps/` contains map scenes. Each has a `Map` node (`maps/map.gd`) that auto-discovers spawn `Marker3D`s by name (contains `spawn`, plus `spi`/`sci` team label; unlabeled spawns are added to both pools for FFA) and holds a `GameModeComponent` child. `despawn_location` is where dead players are parked.

- `maps/main_menu_world.tscn` is the **lobby**: a normal map with `game_mode = MAIN_MENU`, plus the `HostServer` / `JoinParty` `Area3D` zones. It has only `"SCI Spawn Location"` markers (a SPI/FFA player falls back to `Vector3(0,12,0)` in `map.gd`), a `ProjectilesParent`/`ProjectileSpawner` (so players can shoot), and a standalone `Camera3D` (not `current`).
- **`maps/bind.tscn`** (uid `uid://tvv5xjtm8fwk`) was added to `world/world1.tscn`'s `MultiplayerSpawner._spawnable_scenes`. **Any map the scanner can return must be in that list** or selecting it won't replicate to clients.

## ConnectionUtils (`network/connection_utils.gd`)

`class_name ConnectionUtils`, a stateless `static` helper (no autoload):

- **Base-62 join code**: `ip_to_code(ip)`, `code_to_ip(code)`, `looks_like_code(text)` (6 chars, `0-9A-Za-z`, encodes an IPv4 quad; port is always `8080`). Originally in `ui/main_menu.gd`.
- **`detect_ips()`**: returns local IPv4 addresses ordered best-first (scores LAN ranges up, virtual/VPN adapters down), with `127.0.0.1` appended last.
- **`scan_maps()`**: returns `[{ "display_name": ..., "path": ... }]` for every `*.tscn` under `res://maps` **excluding `main_menu_world.tscn`**, sorted by display name. This is the HostServer map list source (replaces the old hardcoded `OptionButton` list).

## Key conventions & gotchas

- **Godot shares `Resource`/sub-resource instances across scene instances.** Per-player state that mutates must be duplicated per instance — the code does this for weapons (`duplicate(true)` in `set_weapons`), collider `Shape3D`s, `AnimationTree.tree_root`, and team-tint materials. Follow the same pattern when adding new per-instance mutable state.
- **The server (peer 1) is the authority for score, ammo, damage, effects, and game-mode state.** Client code should gate mutations behind `multiplayer.is_server()` or go through a `request_*`/`fire_intent`-style RPC.
- Sound effects go through `AudioPool` (`effects/audio_pool.gd`), a pooled one-shot player — use it instead of spawning a fresh `AudioStreamPlayer` per event (footsteps, hits, muzzle blasts).
- **Never use `:=` on a value with an untyped `Variant` source.** `%UniqueName` node references (e.g. `@onready var camera := %Camera3D`) are typed `Node`, so any property access off them (`camera.global_position`, `camera.fov`) yields `Variant` and `var x := camera.global_position` fails with "Cannot infer the type". Cast first (`var cam := camera as Camera3D`) or use an explicit type (`var pos: Vector3 = camera.global_position`).
- **Defer re-hosts across a frame.** Any teardown + re-`create_server()` must not happen synchronously in one frame, or `NetworkEvents` misses the transition and movement (rollback) dies. `return_to_lobby()` uses `call_deferred("boot_to_lobby")`.
- **The offline fallback needs a manual `NetworkTime.start()`.** `NetworkEvents` ignores `OfflineMultiplayerPeer`, so `create_server()` starts `NetworkTime` itself when it falls back.
- **Use `queue_free`, not `free()`, when swapping maps** — the `MultiplayerSpawner` must receive the node-removal event to despawn it on peers.
- **HUD must tolerate `MAIN_MENU` and map swaps.** `hud_controller.gd` has a `_menu_mode` flag (hides the whole HUD in the lobby), an idempotent `_create_panel_registry()` (it re-runs when the match map replaces the lobby), and an `is_instance_valid(gmc)` guard in `_on_hud_tick` (the `GameModeComponent` is freed during a map swap).
- `.claude/Strafing.txt` contains the original design note for the Quake/Source air-strafe movement math.
