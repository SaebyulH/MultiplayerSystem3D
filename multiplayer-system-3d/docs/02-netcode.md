# 02 — Netcode: Rollback vs Server-Authoritative Split

The project deliberately splits simulation responsibility. Getting this wrong (e.g. putting a fire flag in the `RollbackSynchronizer`, or reading `global_position` inside `_rollback_tick`) produces subtle desyncs and "look/shoot works but movement doesn't" bugs.

## Topology

- Peer 1 is always the server (and the host player). Humans connect with ENet ids > 1. `network/network_manager.gd:27-55`.
- Autoloads: `NetworkManager`, `Leaderboard`, `NetworkTime`, `NetworkTimeSynchronizer`, `NetworkRollback`, `NetworkEvents`, `NetworkPerformance`, `GameManager` (`project.godot:22-32`).
- `[netfox] time/tickrate = 90`, `time/sync_to_physics = false` (`project.godot:217-220`); Jolt physics; collision layers WORLD=1, PLAYER_COLLISION=2, HURTBOX=3, HITBOX=4, RAGDOLLS=8 (`project.godot:208-214`). The rollback tick runs at **90 Hz** (the addon default was 30); `knockback_multiplier` is scaled for it (see `player/character.gd:59-62`).

---

## 1. The split

| Concern | Mechanism | Where |
|---|---|---|
| Movement, jump, crouch, dash, shoulder-charge | **Rollback-simulated** (inputs rollback-synced; `_rollback_tick` re-simulates) | `player/player.tscn:446-452` |
| Firing, reload, weapon switch, damage, status effects, score | **Server-authoritative RPC** | `weapon_controller.gd`, `status_effect_manager.gd`, `leaderboard_singleton.gd` |

### RollbackSynchronizer config — `player/player.tscn:446-452`

```
state_properties = [
  ":global_transform", ":velocity", ":stamina",
  ":dash_held_prev", ":jump_held_prev", ":crouch_held_prev",
  ":air_jumps_used", ":air_dashes_used", ":dash_time", ":active_dash_dir",
  ":dash_grounded", ":dash_jump_locked", ":crouch_tap_timer",
  ":is_crouching", ":charge_time", ":charge_dir", ":pinned_at_wall",
  ":bashdown_time", ":bashdown_dir", ":bashdown_slamming"
]
input_properties = [
  "PlayerInput:input_dir", "PlayerInput:jump_input", "PlayerInput:crouch",
  "PlayerInput:dash_input", "PlayerInput:charge_trigger_dir",
  "PlayerInput:bashdown_trigger_dir", "PlayerInput:teleport_trigger_dir"
]
enable_prediction = true
```

A separate `TickInterpolator` (`player/player.tscn:440-444`) interpolates `:global_transform` + `:velocity` for smooth render.

### Fire flags that MUST NOT be rollback-synced

`primary_fire_held`, `secondary_fire_held`, `tertiary_fire_held` are declared at `player/player_input.gd:48-51` and **deliberately absent** from `input_properties`. The reason is documented in two places:

- `player/player_input.gd:3-13`: "primary/secondary/tertiary_fire_held must NOT be in RollbackSynchronizer's input_properties. Netfox stomps them on re-simulation ticks before WeaponController can consume them."
- `player/weapon_controller.gd:61-78`: fire state is polled raw in `_physics_process`, outside the rollback tick.

Also excluded: the local ability-staging vars `queued_charge_trigger_dir` / `queued_bashdown_trigger_dir` / `queued_teleport_trigger_dir` (`player_input.gd:26-46`); `_gather()` copies them into the rollback input property each tick (`player_input.gd:102-107`).

---

## 2. Rollback input flow

1. `PlayerInput._ready()` connects `NetworkTime.before_tick_loop → _gather` (`player/player_input.gd:63-64`).
2. `_gather()` (`player_input.gd:66-107`) runs once per network tick, **only on the input authority** (`is_multiplayer_authority()`), skips bots, zeroes inputs when `ui_open` or stunned/pinned, otherwise reads `Input.get_vector(...)`/`Input.is_action_pressed(...)` (98-101) and copies queued ability trigger dirs into the rollback input properties, clearing the local staging (102-107).
3. `_input()` (`player_input.gd:109-152`) fills the **non-rollback** fire flags from `Input.is_action_pressed("primary_fire"...)` (134-136) and emits `previous_weapon`/`next_weapon`/`reload`/`inspect`/`toggle_camera` on `is_action_just_pressed` (138-147).
4. `RollbackSynchronizer` records input after each tick and restores recorded state before each `_rollback_tick`. `enable_input_broadcast = true` (default).
5. `Player._rollback_tick(delta, tick, is_fresh)` (`player/player.gd:968-1052`) re-simulates movement, consuming the rollback input properties. Netfox calls `_rollback_tick` on every rollback-aware node under `root`.

> **Tick desync** (`05-known-issues.md` #18): when a peer's render FPS drops below the
> tickrate, its `NetworkTime.tick` falls behind the other peer's (the tick loop is capped
> by `max_ticks_per_frame`), so rollback inputs are stamped too old and rejected, and
> movement renders seconds late. Fixed by raising `max_ticks_per_frame` (8 → 60).

### Determinism requirements (explicit in code)

- **Rising-edge detection** so presses replay deterministically: `_apply_movement_from_input` (`player.gd:1493`) computes `jump_pressed`/`dash_pressed`/`crouch_pressed` against `*_held_prev` and updates those held-prev flags — which are themselves in `state_properties`.
- **State that persists across re-simulation**: `_spawn_pending_position` is consumed only in `_physics_process`, never inside `_rollback_tick`, so re-simulated ticks see the same flag (`player.gd:317-322, 975-982`). Same pattern for `pinned_charger_name` (`328-332, 1004-1016`) and `_enlarge_scale` (`334-339`).
- **`scale` re-derived every tick**: because netfox re-applies `global_transform` from rollback history each tick, `_rollback_tick` sets `scale = Vector3.ONE * _enlarge_scale` at the top (`player.gd:969-972`).
- **Real-frame-only work** (sound, footsteps, fall damage) is kept **out** of `_rollback_tick` and placed in `_physics_process` (`player.gd:896-898, 901-905`).

### Determinism hazard (the single most fragile assumption)

Movement direction is **camera-relative** but the camera's basis is **not** rollback-synced. `_apply_movement_from_input` derives `forward`/`right` from `_movement_basis()` (`player.gd:1493`, and `_movement_basis` at `1864-1867` reads the local `camera` or `third_person_camera`). Dash, charge, and bashdown directions use the same basis. Body yaw/pitch are set **only** on the authority via mouse-look (`player/body.gd:26-57`), and there is a commented-out `sync_rotation` RPC (`body.gd:59-68`) — so body/camera orientation is neither rollback state nor replicated.

On remote peers the camera basis for that player's copy is stale, so camera-relative movement (and especially dash/charge direction) can diverge from the authority's simulation. The server is the rollback state authority, so corrections snap any drift — but this is the deepest determinism assumption in the project. **TODO in `05-known-issues.md`.**

---

## 3. `fire_intent` RPC round-trip (server-authoritative firing)

### Polling (owning peer only)

`WeaponController._physics_process` (`weapon_controller.gd:403-412`) calls `_process_fire()` only when: this is a bot (server drives it) **or** `my_id == _parent_player.name.to_int()` (the owning human). Everyone else's weapon controller is idle.

`_process_fire` (`1613-1642`) → `_handle_fire_input` per fire button (`1636-1638`). `_handle_fire_input` (`1645-1710`) dispatches by `ActionType`:
- `ADS` → `toggle_ads_synced.rpc()` (1671)
- `SHIELD` → `deploy_shield_synced.rpc(fire_index)` (1676)
- `SIGNAL` → `_send_signal.rpc()` (1681)
- `SHOOT` → ammo pre-check (1697-1705) then `_try_fire(fire_index)` (1707)

`_try_fire` (`1755-1814`): gates on cooldown/reload/pending/switching. If `pre_shoot_delay > 0`, sets `_pending_fire` + `_pre_fire_timer` (1802-1805), resolved in `_tick_timers` (480-497). Otherwise:
- Server (host): `fire_intent(...)` directly (1808).
- Client: sets optimistic `_fire_cooldown` for responsiveness, then `fire_intent.rpc_id(1, current_weapon_index, weapon_fire_index)` (1813-1814).

### Server validation and ammo

`fire_intent` (`@rpc("any_peer")`, `1948-2011`):
1. Backstop reject: `not spawned`, `not _is_ready()`, `is_switching()` (1951-1956).
2. Re-validate ammo via `_get_fire_ammo_cost` (1960-1966) — the only authoritative deduction point.
3. Set `_fire_cooldown` + `_start_firing` (1968-1969); capture scoped amp; force-unscope if configured (1973-1978).
4. Self damage/heal on shoot (1981-1982).
5. Deduct ammo (burst vs non-burst), `_sync_mag.rpc(...)` (1991-2003), then `_execute_fire` + `_play_shoot_sound.rpc` (1995-2000), auto-reload/auto-switch (2006-2011).

### Actual shot + visuals

`_execute_fire` (`2022-2043`) applies recoil/knockback, then by `MultishotMode` → `_fire_burst` / `_fire_all_shots` / shape. `_fire_single_shot` (`2097-2243`):
- HITSCAN: raycast from the shooter's camera, `_flash_muzzle_flash.rpc` (2147), then on hit `_on_hitscan_hit.rpc(...)` (2175) which spawns decal/tracer/impact **on every peer** (2439-2473). Damage: server path `_apply_damage_direct` (2213-2220) → `change_health`; client path `_change_health_on_server.rpc_id(1, ...)` (2222).
- PROJECTILE: `_spawn_projectile_on_server.rpc_id(1, ...)` (2238-2241) → `_spawn_projectile` (2325-2348) instantiates under `ProjectilesParent` (server-authoritative).

Ammo correction to clients: `_sync_mag` (2015) clamps and re-emits `mag_changed`. Reload completion uses `_confirm_reload_done` (1595-1610).

### Fire-path fragilities

- **`_sync_mag` is unreliable** (`@rpc("any_peer","call_local")` at `2015` — no `"reliable"`), while `_sync_all_mags` and `_confirm_reload_done` are reliable. An authoritative mag value can be dropped; the optimistic client mag then diverges until the next reliable correction. **TODO.**
- **`fire_intent` has no sender validation** — it's `@rpc("any_peer")` and does not check `get_remote_sender_id()`, unlike `request_reload` (`1459-1469`) which rejects non-owner senders. Any peer can invoke `fire_intent` on any player's weapon controller (the server still validates ammo, but the asymmetry is notable). **TODO.**
- Spread uses `randf()` and reads `_parent_player.velocity` — fine because the whole fire path is server-side (never inside `_rollback_tick`), but non-deterministic by design.

---

## 4. GameModeComponent sync (10 Hz) + phase machine

`components/game_mode_component.gd`:
- `SYNC_INTERVAL = 0.1` (10 Hz), line 89.
- `_process` (213-243) runs only on server+authority; every 1 s broadcasts remaining time (unreliable `_rpc_broadcast_time`, 517-520, 220-223); every 0.1 s calls `_rpc_sync_state.rpc(_build_snapshot())` (237-240).
- `_rpc_sync_state` (`@rpc("authority","call_local","reliable")`, 128-144) writes `current_phase`, `phase_timer`, `round_wins`, then `apply_sync_state` on each mode node. `_build_snapshot` (146-156) collects `get_sync_state()` from koth/domination/hybrid/deathmatch.
- Phase machine: `_transition_phase` (411-432) sets `phase_timer` per phase and emits `_rpc_sync_phase`. Ticks: `_tick_setup`, `_tick_objective_locked`, `_tick_active`, `_tick_overtime`, `_tick_round_end`.
- Overtime: `_start_overtime` only when `overtime_enabled` + contested; `_tick_overtime` ends it when uncontested or timer expires.
- Round win `_end_round` → `_rpc_round_won`; match win `_rpc_match_won`.

### DeathmatchMode polls the Leaderboard

`components/deathmatch_mode.gd:4-8, 69-80`: `tick()` loops `Leaderboard.get_players()` and checks `Leaderboard.get_kills(p) >= kills_to_win`. It keeps **no** kill counters of its own — kills are owned by `Leaderboard` (autoload, server-authoritative). `determine_timer_winner` picks the max-kills player on time expiry. `get_sync_state`/`apply_sync_state` mirror `winner_name`, `end_reason`, `standings`.

Other modes follow the same shape: `koth_mode.gd:23-39` and `domination_mode.gd:34-49` embed per-control-point snapshots via `ControlPoint.get_cp_state()`/`apply_cp_state()` (so late joiners see capture progress); `hybrid_mode.gd:31-39` mirrors `captured`/`time_held`; `escort_mode.gd` has no sync state (PayloadNode drives itself).

### ControlPoint — independent unreliable 10 Hz backup

`world/control_point.gd`:
- `_ready` calls `game_mode_component.register_control_point(self)` (53-54) and connects `phase_changed` (55).
- `_process` (69-122) is server-only; ticks capture logic and at `CP_SYNC_RATE = 0.1` (line 20) sends `_rpc_sync_state.rpc(...)` — **unreliable** (242) — while `_rpc_on_captured` (253-261) is reliable. The reliable GameModeComponent 10 Hz snapshot is the authoritative fallback.
- Body tracking: `Area3D.body_entered/body_exited` append/erase `Player` nodes to `_players_on_point` (139-144); `_count_team` (146-151) tallies by team.

---

## 5. Authority model

- `SpawnManager._add_player_to_game` (`world/spawn_manager.gd:54-62`) sets the whole `Player` node's authority to `network_id` **before** `add_child`; then `Player._enter_tree` re-wires per-child authority (`player/player.gd:404-414`):
  - **Bots** (`is_bot`, set at `spawn_manager.gd:129-131`): `player_input`, `body`, `DamageNumberManager` → authority **1**.
  - **Humans**: root `Player` → authority **1** (server), but `player_input` → `id`, `body` → `id`, `DamageNumberManager` → `id`.
- Everything else (`WeaponController`, `AttributeComponent`, `StatusEffectManager`, `AbilityManager`, `HurtComponent2`) inherits root authority = **server (1)**. This is why ammo/health/effects are server-authoritative while the human keeps authority only over `player_input` (rollback input source) and `body` (camera look).
- Root `MultiplayerSynchronizer` (`player/player.tscn:454-455`, config 26-32) replicates `AttributeComponent:health` (spawn + always) and `.:team` (spawn + always). The `WeaponController`'s `MultiplayerSynchronizer` (474-475, config 34-37) replicates `current_weapon_index` on change.
- **Bots are fully server-authoritative**: `BotController._physics_process` guards `is_bot`, `multiplayer.is_server()`, `spawned` (`bot_controller.gd:188-194`) and writes directly into `player.player_input.input_dir`/`jump_input`/fire flags. Bot `player_input` authority is 1 and `_gather()` skips bots (`player_input.gd:71-72`), so bot input is written by `BotController` on the server and recorded/broadcast by the RollbackSynchronizer from peer 1.
- Bots' aim (`_apply_smooth_aim`, `bot_controller.gd:343-353`) writes `player.body.rotation.y`/head pitch directly — meaningful only because the server owns the bot's body node.

---

## 6. MultiplayerSpawner: Map, Players, Projectiles

- The world's `MultiplayerSpawner` is `world/world1.tscn:95-97`: `spawn_path = "../SpawnParent"`, `_spawnable_scenes` = 13 uids (player + all maps + lobby). It replicates whatever node named `"Map"` is in `SpawnParent`, plus every `Player` node `SpawnManager` adds there.
- Map swap is server-authoritative with no RPC — see `01-boot-sequence.md` Stage 11.
- **`spawnable_scenes` requirement:** any scene spawned under a spawner's `spawn_path` must have its uid in `_spawnable_scenes`, or it won't replicate. Any map the scanner returns must be in the list.
- Projectiles use a **separate** `MultiplayerSpawner` per map (`maps/*.tscn` `ProjectilesParent/ProjectileSpawner`, `spawn_path = ".."`) and one inside `player/player.tscn:503-505`. `player/auto_projectile_spawner.gd` extends `MultiplayerSpawner` to auto-scan the projectiles folder.

---

## 7. StatusEffectManager (server ticks, client mirror via RPC)

`components/status_effect/status_effect_manager.gd`:
- Header (4-15): effects applied and ticked **entirely on the server**; clients do no local ticking; remaining times pushed on apply/remove and at ~10 Hz.
- `TICK_INTERVAL = 0.1` (40). `_on_tick_timeout` (55-62) returns unless `multiplayer.is_server()`. `_tick_server` (65-114) decrements `remaining`, fires `_on_tick` at `tick_interval`, removes expired, and calls `_sync_to_clients()` only if a timed effect exists or one just expired (avoids re-broadcasting permanent wallhack/health markers).
- `apply_effect` (120-149): server-only; negative effects extend duration; permanent effects use `INF`; calls `_on_apply` then `_sync_to_clients`.
- `_sync_to_clients` (239-255) rebuilds the client mirror and pushes via `_rpc_sync_effects` (`@rpc("authority","call_remote","reliable")`, 271-278) — three parallel arrays: `effect_ids`, `effect_names`, `remaining_times`. Poison hidden until `drain_started` (260-268).
- `has_effect`/`is_stunned`/`is_pinned` read the client mirror `_client_effects` (170-171, 199-210).
- Late joiners get an explicit `_sync_to_clients(peer_id)` from `SpawnManager._sync_existing_players_to_peer` (`spawn_manager.gd:44-45`).

---

## Consolidated fragility list (cross-referenced to `05-known-issues.md`)

1. **Camera-relative movement with unsynced camera** (`player.gd:1493, 1864`; `body.gd:26-57` + commented `sync_rotation`).
2. **`_sync_mag` unreliable** (`weapon_controller.gd:2015`).
3. **`fire_intent` lacks sender validation** (`weapon_controller.gd:1948`) vs `request_reload` (`1459`).
4. **Health regen simulates on every peer** (`attribute_component.gd:160-180`, no `is_server()` gate) and calls `apply_health_delta`, triggering kill/score bookkeeping. The server's value wins via `MultiplayerSynchronizer` (always), but the client duplicate-simulates death/score side effects on negative regen. **`[FIXED 2026-09-20]` — regen is now `is_server()`-gated and self-heal stat reporting is throttled.**
5. **Two overlapping 10 Hz control-point syncs** — `ControlPoint._rpc_sync_state` unreliable (`control_point.gd:242`) vs `GameModeComponent._rpc_sync_state` reliable (`game_mode_component.gd:128`). Intentional redundancy, easy to mistake for a duplicate.
6. **Manual state kept in sync against netfox rollback** — `scale` re-derived each tick (`player.gd:969-972`); `_spawn_pending_position`/`pinned_charger_name` persist across re-sim.
7. **Server-side randomness is fine, rollback randomness is not** — `_get_spawn_position` uses `randi()` but runs server-side via RPC; fire spread `randf()` runs only in server-side `_fire_single_shot`. Neither is inside `_rollback_tick`.
8. **Map swap ordering** — `remove_child` + `queue_free` (not `free`) so the spawner emits the removal event; teardown+rehost deferred a frame (`network_manager.gd:104-114`).
