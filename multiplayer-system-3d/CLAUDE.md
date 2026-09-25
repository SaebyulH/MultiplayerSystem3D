# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation (read first)

The authoritative technical documentation lives in [`docs/`](docs/README.md) — it is the source of truth for boot flow, netcode, event flow, optimization, and the known-issues backlog.

- **First action every session:** read `docs/README.md` (the index). It is injected at session start by a `SessionStart` hook, then read the parts relevant to your task before touching code.
- **Every code change must update the docs.** Update the matching `docs/*.md` part; if the change introduces a bug, fragility, or perf risk, add a TODO to `docs/05-known-issues.md` (file:line + symptom + suggested fix). A change without a docs update is incomplete.
- When `CLAUDE.md` and `docs/` disagree, **`docs/` wins** — fix `CLAUDE.md` to match.

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

- **NetworkManager** (`network/network_manager.gd`) — owns the whole connection lifecycle, scene transitions, **the session's tick rate**, and the health of the netfox tick domain. Exposes `boot_to_lobby()`, `join_party(ip)`, `return_to_lobby()`, `load_match_map(path)`, `apply_tick_rate(rate)` / `set_tick_rate(rate)`, and the peer primitives `create_server()` / `create_client()`. It connects the session-lifetime `multiplayer` signals once in `_ready()`, and **starts the client's `NetworkTime` itself** (see below).
- **Leaderboard** (`ui/leaderboard_singleton.gd`) — server-authoritative score tracking (kills/deaths/damage/heals/killstreaks). Clients never write directly; they call `request_*()` which sends an RPC to peer 1.
- **GameManager** (`singletons/game_manager.gd`) — a tiny global holder: `spawn_parent` (node all Players live under) and `game_mode_component`. `Map` populates these on `_enter_tree`.
- **NetworkTime, NetworkTimeSynchronizer, NetworkRollback, NetworkEvents, NetworkPerformance** — provided by netfox (see `addons/netfox/`). Do not edit. **`NetworkEvents` auto-starts/stops `NetworkTime` on server start/stop** — but the *client* start has been taken over by `NetworkManager` (see the event-flow section below).
- **Console** — in-game console addon (`addons/console/`).

Note: **`ConnectionUtils`** (`network/connection_utils.gd`, `class_name ConnectionUtils`) is **not** an autoload — it is a stateless `static` class shared by the interaction popups (and, conceptually, the bypassed 2D menu).

## Networking model: rollback + server-authoritative split

The project deliberately splits simulation responsibility:

- **Movement, jumping, crouch, dash, shoulder-charge** are **rollback-simulated**. Inputs (`input_dir`, `jump_input`, `crouch`, `dash_input`, `charge_trigger_dir`) are rollback-synced through the `RollbackSynchronizer` on the Player; `Player._rollback_tick()` re-simulates deterministically. `PlayerInput._gather()` is connected to `NetworkTime.before_tick_loop` and fills these once per tick.
- **Firing, reload, weapon switching, damage, status effects** are **server-authoritative RPC**. The owning client polls `primary/secondary/tertiary_fire_held` in `_physics_process` (NOT in the rollback tick) and sends `fire_intent` to the server; the server re-validates and is the only place ammo is deducted.

Consequence: fire-held flags must **never** be added to the `RollbackSynchronizer` input properties — netfox stomps them on re-simulation ticks. See the header comments in `player/player_input.gd` and `player/weapon_controller.gd`.

**Movement only works while the netfox rollback tick loop is running.** That loop is driven by `NetworkTime` (started by `NetworkEvents` on the server, and by `NetworkManager` on the client). If you see "can look + shoot but not move", the rollback tick loop is dead — usually a `NetworkTime` start/stop bug (see "Connection lifecycle & event flow" below).

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

`NetworkTime` (which drives the rollback tick loop) is managed by netfox's **`NetworkEvents`** autoload (`addons/netfox/network-events.gd`):

- `on_server_start`  → `NetworkTime.start()`  (emitted when `is_server()` becomes true)
- `on_client_start`  → ~~`NetworkTime.start()`~~ — **taken over by `NetworkManager`**, see below
- `on_server_stop` / `on_client_stop` → `NetworkTime.stop()`

**The client start is the exception.** netfox fires it the instant `connected_to_server` arrives, which is *across* this project's join stall (the synchronous `preload(world1.tscn)` plus two frames of D3D12 shader compilation). The clock-sync request goes out before the stall and its reply lands after it, and since that initial timestamp carries no RTT compensation while `NetworkTime.tick` is monotonic, the joiner seeds its **entire tick origin** from a reading seconds out of date — then heals at only 25 %/s, which is `05-known-issues.md` #18 (thousands of frames of `past the history limit`). So `NetworkManager._take_over_client_time()` (called from `join_party()`) disconnects that one listener, and `_on_connected_to_server()` starts the loop itself after the join settles. **Do not add another listener to `NetworkEvents.on_client_start`** — it removes every listener on that signal.

`NetworkEvents` detects server start/stop by **polling `is_server()` once per frame in `_process`**. It also explicitly treats `OfflineMultiplayerPeer` as "not a server" (its `is_server()` returns false for it). Two consequences for our code:

1. **A synchronous teardown + re-host is invisible to `NetworkEvents`.** If you close the peer and immediately `create_server()` again *in the same frame*, `NetworkEvents` never sees the intermediate "stopped" state, so `on_server_start` never re-fires and `NetworkTime.start()` never runs — the rollback tick loop dies and movement stops (while look/shoot, which don't use rollback, keep working). **This is why `return_to_lobby()` defers the re-host with `call_deferred("boot_to_lobby")`** — giving `NetworkEvents` one frame to observe the stop transition before the re-host re-triggers `on_server_start`.
2. **The offline fallback won't auto-start `NetworkTime`.** Because `NetworkEvents` ignores `OfflineMultiplayerPeer`, `create_server()` must call `NetworkTime.start()` **manually** when it falls back to an offline peer (otherwise the second local instance's lobby can't move).

`NetworkManager._terminate_connection()` calls the **full `NetworkTime.stop()`** (not the low-level `NetworkTimeSynchronizer.stop()`) before nulling the peer — this resets `NetworkTime`'s internal `_state` to INACTIVE so a subsequent `NetworkTime.start()` succeeds cleanly on re-host/re-join. Note it does **not** clear `_tick`, `_initial_sync_done` or the reference clock, which is why the tick-domain watchdog gates itself on `NetworkManager._client_time_ready` rather than on netfox's state (between sessions `_tick` still holds the previous session's value).

### Boot (become host)

1. `world/main.gd:_ready()` → `_boot()` → `await NetworkManager.boot_to_lobby()` (a **direct `await`**, not `call_deferred` — the deferred call lives in `return_to_lobby()`).
2. `boot_to_lobby()` → `create_server()` (ENet server, `is_hosting_game = true`) then `load_game_scene("res://maps/main_menu_world.tscn")`.
3. `load_game_scene()` instantiates `world/world1.tscn`, sets `game_scene.map_path`, and adds it as a child of `get_tree().current_scene` (the `Main` Control root).
4. `world_1.gd._ready()`: sets `GameManager.spawn_parent = %SpawnParent`, opens the loadout menu (`PlayerInput.ui_open = true`), and — because `is_hosting_game` — loads the lobby map into `SpawnParent` (named `"Map"`) and creates a `SpawnManager` (which adds player id 1).
5. `NetworkEvents._process` sees the server → `on_server_start` → `NetworkTime.start()` → rollback tick loop runs → movement works after the player confirms a loadout and spawns.

### Join a party (become client)

1. The joiner is already their own host (offline or real server). They walk into `JoinParty` and press `E`.
2. `join_party(ip)` → `_remove_game_scene()` (free the solo world) → `create_client(ip)`.
3. `create_client()` → `_terminate_connection()` (stop `NetworkTime`, close + null the old peer) → create an ENet client → set `multiplayer_peer`.
4. On connect, `NetworkManager._on_connected_to_server()` → `await enter_existing_game_scene()` (a fresh client `world1.tscn` with **no** map; the map replicates from the host).
5. Then, still inside that coroutine: `await _await_settled()` → `await _adopt_server_tick_rate()` → `NetworkTime.start()`. netfox's own client-start listener has been disconnected (see above), so this is the **only** thing that starts the client's tick loop — the ordering is load-bearing, not incidental.
6. The host's `SpawnManager._peer_connected()` → `_add_player_to_game(client_id)` adds the joiner's `Player` node; the `MultiplayerSpawner` replicates the map + existing players to the joiner.

### Leave / disconnect

`return_to_lobby()` is the single exit path, called by the "Leave Party" buttons (`world_1.gd`, `loadout_menu.gd`), `_on_connection_failed()`, and `_server_disconnected()`:

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

`components/status_effect/status_effect_manager.gd` (`StatusEffectManager`) is server-authoritative: effects tick only on the server, remaining times are pushed to clients via RPC. Effect types (`bleed`, `burn`, `stun`, `slow`, `gravity_flip`, `invincible`, `pinned`, `poison`, `size_change`, `heal_over_time`, etc.) are subclasses of `StatusEffect` under `components/status_effect/effects/`.

Effects that are applied by an **ability** rather than a weapon are usually just a `.tres` under `defaults/status_effects/` referenced from a generic `SelfEffectAbility` (`player/abilities/self_effect_ability.gd` — `effect`, plus an optional duration override). `SizeChangeEffect` is the worked example: `size_mult` / `health_mult` are `@export`s, so enlarging (`size_change.tres`, 2.0) and shrinking (`shrink.tres`, 0.5) are the same code path, and `health_mult = 1.0` means "size only, don't touch health". Its scale has to be re-derived every tick in `_rollback_tick` from `Player._size_scale` — see `02-netcode.md` §2. `is_negative` is per-`.tres` (the shrink is a debuff, the enlarge is a buff), not fixed on the class.

The **enemy**-applied counterpart is a `TargetedAbility` (`BurnAbility`'s shape — crosshair targeting, HUD preview, server validation): `ShrinkEnemyAbility` / `shrink_enemy.tres` halves an enemy's size and max health for 5 s, and the damage they take while shrunk is kept in proportion when it expires.

`TargetedAbility` picks its targets through a single shared predicate, `is_valid_target(caster, other)`, selected by its `target_team` export (`ENEMIES` default / `ALLIES` / `BOTH`). The client-side preview (`find_candidates`) and the server-side validation (`AbilityManager._resolve_targets`) must both go through it — inlining a team test at either site makes the HUD preview and the server disagree. `ALLIES` is built on `Player.is_teammate_of()`, so ally-only abilities have no valid targets in FFA. `HealAllyAbility` / `heal_ally.tres` (the field medic's ally heal) is the ally-side example.

`StatusEffect.blocks_actions` locks the player's input out for the effect's duration. It is **per-cast data**, not per-effect-type, so unlike `stun`/`pinned` it is mirrored to clients as a boolean alongside the remaining time and read via `StatusEffectManager.is_action_blocked()`. Consumers: `PlayerInput._gather`/`._input`, `BotController._physics_process` (client-side), and the server backstops in `AbilityManager._cast_ability` / `WeaponController.fire_intent`. Movement is **not** server-enforced — see `05-known-issues.md` #33.

The channeled heal is the only current user: `HealAbility` (`player/abilities/heal_ability.gd`) is instant by default and switches to a `HealOverTimeEffect` when `heal_over_time` is set, with `heal_duration`, `heal_tick_interval`, and `block_actions_during_heal`. Its `activate()` must stay `CastMode.SERVER`.

## Maps

`maps/` contains map scenes. Each has a `Map` node (`maps/map.gd`) that auto-discovers spawn `Marker3D`s by name (contains `spawn`, plus `spi`/`sci` team label; unlabeled spawns are added to both pools for FFA) and holds a `GameModeComponent` child. `despawn_location` is where dead players are parked.

- `maps/main_menu_world.tscn` is the **lobby**: a normal map with `game_mode = MAIN_MENU`, plus the `HostServer` / `JoinParty` `Area3D` zones. It has only `"SCI Spawn Location"` markers (a SPI/FFA player falls back to `Vector3(0,12,0)` in `map.gd`) and a standalone `Camera3D` (not `current`). It also still carries a `ProjectilesParent`/`ProjectileSpawner` pair, as every map does — **all of them are dead**; projectiles are parented to the world, not the map (`05-known-issues.md` #29).
- **`maps/bind.tscn`** (uid `uid://tvv5xjtm8fwk`) was added to `world/world1.tscn`'s `MultiplayerSpawner._spawnable_scenes`. **Any map the scanner can return must be in that list** or selecting it won't replicate to clients.
- **`_spawnable_scenes` is shared state — keep it deduped, minimal and deterministically ordered.** The receiver resolves a spawn against *its own* copy of the list, so duplicates or a build-order-dependent arrangement can make a peer instantiate a different scene than the one that was spawned. The list used to reach **96 entries for 17 scenes** in `player.tscn` because the scan appended every editor session. Generate it with `player/auto_projectile_spawner.gd` (idempotent, sorted, rebuilds from scratch) rather than appending. `world1.tscn` now holds both lists: the map/player spawner (13 uids) and the `ProjectileSpawner` (17 uids). Regenerate the latter with `scan_projectiles` on that node rather than editing the array by hand.
- **`MultiplayerSpawner` resolves scenes by *file path*, not by index.** It matches the spawned node's `scene_file_path` against each entry's `Resource.get_path()`. A scene that isn't a file on disk can never match — so **never store a `projectile_scene` (or any spawned scene) as an inline `SubResource` `PackedScene`**; use an `ExtResource` on a real `.tscn`. This was `05-known-issues.md` #28: `rocket_launcher.tres` and `syringe_gun.tres` held inline bundles whose base was the mesh-less `simple_projectile.tscn`, so every remote peer instantiated an invisible projectile.

## Projectiles

Projectiles and the tracer / decal / impact effects that ride the same parent are added to `GameManager.projectile_parent` — the world's `ProjectilesParent` in `world/world1.tscn`, resolved by `WeaponController._projectile_parent()`. **Do not parent them to the Player**: `Player.despawn()` calls `hide()` (which cascades to the whole subtree) and a disconnect frees the Player, either of which takes in-flight projectiles with it. The world's `ProjectileSpawner` replicates whatever lands there, so it must stay next to that parent.

## ConnectionUtils (`network/connection_utils.gd`)

`class_name ConnectionUtils`, a stateless `static` helper (no autoload):

- **Base-62 join code**: `ip_to_code(ip)`, `code_to_ip(code)`, `looks_like_code(text)` (6 chars, `0-9A-Za-z`, encodes an IPv4 quad; port is always `8080`). Originally in `ui/main_menu.gd`.
- **`detect_ips()`**: returns local IPv4 addresses ordered best-first (scores LAN ranges up, virtual/VPN adapters down), with `127.0.0.1` appended last.
- **`scan_maps()`**: legacy — returns `[{ "display_name": ..., "path": ... }]` for every `*.tscn` under `res://maps` **excluding `main_menu_world.tscn`**, sorted by display name. Nothing calls it; the host menu uses `scan_map_data()`.
- **`scan_map_data()`**: loads every `MapData` `.tres` under `res://maps/map_data` and returns them sorted by display name. **This is the live HostServer map list source** (`world/host_menu.gd:_load_maps`). It loads the resources eagerly, so anything they reference inherits that cost — see the `MapData` gotcha above.

## Key conventions & gotchas

- **Godot shares `Resource`/sub-resource instances across scene instances.** Per-player state that mutates must be duplicated per instance — the code does this for weapons (`duplicate(true)` in `set_weapons`), collider `Shape3D`s, `AnimationTree.tree_root`, and team-tint materials. Follow the same pattern when adding new per-instance mutable state.
- **The server (peer 1) is the authority for score, ammo, damage, effects, and game-mode state.** Client code should gate mutations behind `multiplayer.is_server()` or go through a `request_*`/`fire_intent`-style RPC.
- Sound effects go through `AudioPool` (`effects/audio_pool.gd`), a pooled one-shot player — use it instead of spawning a fresh `AudioStreamPlayer` per event (footsteps, hits, muzzle blasts).
- **Never use `:=` on a value with an untyped `Variant` source.** `%UniqueName` node references (e.g. `@onready var camera := %Camera3D`) are typed `Node`, so any property access off them (`camera.global_position`, `camera.fov`) yields `Variant` and `var x := camera.global_position` fails with "Cannot infer the type". Cast first (`var cam := camera as Camera3D`) or use an explicit type (`var pos: Vector3 = camera.global_position`).
- **`as Array[T]` does not convert an array — it only type-checks one.** An untyped `Array` stays untyped, so the classic `dict.get(key, []) as Array[Player]` still fails the assignment with `Trying to assign an array of type "Array" to a variable of type "Array[Player]"`. Check `dict.has(key)` and index it, or build a properly typed default. An earlier `docs/05-known-issues.md` entry recommended the cast as the fix for this — it was wrong, and the corrected entry is #3's follow-up.
- **Defer re-hosts across a frame.** Any teardown + re-`create_server()` must not happen synchronously in one frame, or `NetworkEvents` misses the transition and movement (rollback) dies. `return_to_lobby()` uses `call_deferred("boot_to_lobby")`.
- **The offline fallback needs a manual `NetworkTime.start()`.** `NetworkEvents` ignores `OfflineMultiplayerPeer`, so `create_server()` starts `NetworkTime` itself when it falls back.
- **`NetworkManager` owns the client's `NetworkTime.start()`.** netfox's `on_client_start` listener is disconnected in `join_party()`; if you add one back — or start the loop before `_adopt_server_tick_rate()` — a joiner seeds its whole tick origin from a clock reading taken across the join stall, which is a 40-second desync. `03-event-flow.md`, `05-known-issues.md` #18.
- **`NetworkTime.tick` is monotonic; only a full stop/start moves it.** Never apply a tick rate after `start()` — the client's seed is `seconds_to_ticks(...)` evaluated with the live rate, so a wrong multiplier there is unrecoverable. The session tick rate lives in `NetworkManager.apply_tick_rate()`, and it also derives netfox's *tick-count* limits from seconds (`HISTORY_SECONDS` / `CATCHUP_SECONDS`), so do not also set `history_limit` / `max_ticks_per_frame` in `project.godot`.
- **`physics_factor` must wrap everything `move_and_slide()` integrates, and nothing else.** The rollback tick runs from `_process`, so `move_and_slide()` advances by the frame delta; any velocity term added outside the `*= physics_factor` / `/=` sandwich is silently scaled by the client's frame rate. `_noclip_move` is the opposite case — it integrates by the tick delta itself and must apply no factor. `02-netcode.md` §8.
- **Never reference a map scene from a resource the lobby loads eagerly.** `MapData` stores `map_scene_path: String`, not a `PackedScene`. It used to hold a `PackedScene`, and because `ConnectionUtils.scan_map_data()` loads every `MapData` (from the host menu, which `HostServer` builds on every peer), each one parsed its whole map — ~50 MB, `maps/bind.tscn` alone at 47.7 MB, on every lobby instantiation including a joining client's. That was an 8–9.5 s main-thread stall and it also desynced netfox (it re-anchors the tick on any frame past `stall_threshold`). `05-known-issues.md` #25.
- **Use `queue_free`, not `free()`, when swapping maps** — the `MultiplayerSpawner` must receive the node-removal event to despawn it on peers.
- **HUD must tolerate `MAIN_MENU` and map swaps.** `hud_controller.gd` has a `_menu_mode` flag (hides the whole HUD in the lobby), an idempotent `_create_panel_registry()` (it re-runs when the match map replaces the lobby), and an `is_instance_valid(gmc)` guard in `_on_hud_tick` (the `GameModeComponent` is freed during a map swap).
- `.claude/Strafing.txt` contains the original design note for the Quake/Source air-strafe movement math.
