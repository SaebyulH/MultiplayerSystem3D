# MultiplayerSystem3D — Project Documentation

Class-based team FPS (TF2-style hero shooter) on **Godot 4.7** (Forward Plus, Jolt physics, d3d12) using **netfox 1.35.3** rollback netcode. There is no test suite or linter — the only validation is running the game. This documentation is the source of truth for *how the system works*, *where it is fragile*, and *what needs fixing*.

> **Reading rule (enforced at session start):** every Claude Code session begins by loading this index via a `SessionStart` hook. Read the parts relevant to your task before touching code.

## Reading order

| # | File | What it covers | Read when… |
|---|---|---|---|
| 1 | [`01-boot-sequence.md`](01-boot-sequence.md) | Press Play → loading → lobby → loadout → spawn → playing; join/leave/map-swap | anything about startup, menus, spawning, scene transitions |
| 2 | [`02-netcode.md`](02-netcode.md) | Rollback vs server-authoritative split, authority model, `fire_intent` round-trip, determinism | anything about movement, firing, damage, sync, RPCs |
| 3 | [`03-event-flow.md`](03-event-flow.md) | `NetworkEvents`/`NetworkTime` lifecycle, connection ordering invariants, teardown/re-host | anything about connect/disconnect, re-host, the "movement died" bug |
| 4 | [`04-optimization.md`](04-optimization.md) | Performance model, hot paths, patterns to avoid | anything touching `_process`/`_physics_process`/`_rollback_tick` or spawning effects |
| 5 | [`05-known-issues.md`](05-known-issues.md) | High-signal TODO backlog (perf bugs, correctness fragilities), severity-ranked | triage before starting any perf/bug work; add entries here when you introduce risk |

## Contribution rule (binding)

**Every code change must update the matching `docs/*.md` part.** In particular:

- If you change startup / scene flow → update `01-boot-sequence.md`.
- If you change sync, authority, RPCs, or determinism → update `02-netcode.md`.
- If you change connection/teardown/re-host → update `03-event-flow.md`.
- If you add or touch a per-frame / per-shot hot path → update `04-optimization.md`.
- If you introduce (or find) a bug, fragility, or perf risk → **add a TODO to `05-known-issues.md`** with file:line, symptom, and a suggested fix. Even if you don't fix it, record it.

Treat a missing doc update as an incomplete change.

## Architecture at a glance

- **Autoload order is load-bearing** (`project.godot:22-32`): `NetworkManager → Console → Leaderboard → NetworkTime → NetworkTimeSynchronizer → NetworkRollback → NetworkEvents → NetworkPerformance → GameManager`. `NetworkEvents` (7th) wires `on_server_start/stop → NetworkTime.start/stop` in its `_ready`, which is safe only because `NetworkTime` loads before it.
- **Peer 1 is always the server and the party leader.** The host is also a player. Bots are fully server-authoritative. The entire "party leader" model is *implied* by `get_unique_id() == 1` — there is no explicit leader state.
- **The lobby is just another map** (`maps/main_menu_world.tscn`, `game_mode = MAIN_MENU`). `world/world1.tscn`'s `MultiplayerSpawner` (`spawn_path = "../SpawnParent"`) replicates whatever node named `"Map"` is in `SpawnParent`, plus every `Player`. No map-selection special case — a joiner gets whatever map the host currently has.
- **Movement is rollback-simulated; everything else is server-authoritative RPC.** Inputs (`input_dir`, `jump_input`, `crouch`, `dash_input`, ability trigger dirs) are rollback-synced; firing/reload/damage/effects/score are RPC. See `02-netcode.md`.
- **Fire-held flags must never be rollback-synced** — netfox stomps them on re-simulation ticks. See `02-netcode.md`.
- **`ConnectionUtils`** (`network/connection_utils.gd`, `class_name ConnectionUtils`) is a stateless `static` helper, **not** an autoload.

## Top gotchas (the invariants most likely to bite you)

1. **Never do a synchronous teardown + re-host in one frame.** `return_to_lobby()` must `call_deferred("boot_to_lobby")`, or `NetworkEvents` misses the stop transition and the rollback tick loop dies (movement stops; look/shoot keep working). `network_manager.gd:104-114`.
2. **The offline fallback needs a manual `NetworkTime.start()`.** `NetworkEvents` treats `OfflineMultiplayerPeer` as "not a server", so the second local instance's lobby can't move without it. `network_manager.gd:27-43`.
3. **`_sync_mag` is unreliable** (`@rpc("any_peer","call_local")`), unlike `_sync_all_mags`/`_confirm_reload_done`. Authoritative ammo can drop and client mag diverges. `weapon_controller.gd:2015`.
4. **Movement is camera-relative but the camera basis is not synced** — remote simulation of movement/dash/charge uses a stale basis and relies on netfox state correction. `player.gd:1493`, `1864`; `body.gd:26-57`.
5. **Health regen used to run on every peer, un-gated** — fixed 2026-09-20, `_process` is now behind `multiplayer.is_server()`. See `05-known-issues.md` #16.
6. **Use `queue_free`, never `free()`, when swapping maps** — the spawner needs the removal event to despawn on peers. `network_manager.gd:133`.
7. **`spawnable_scenes` requirement:** any map the scanner returns must have its scene uid in `world1.tscn`'s `MultiplayerSpawner._spawnable_scenes`, or it won't replicate.
8. **Godot shares `Resource`/sub-resource instances across scene instances.** Per-player mutable state must be `duplicate(true)`'d (weapons, `Shape3D`s, `AnimationTree.tree_root`, team-tint materials).
9. **Never use `:=` on an untyped `Variant` source** (e.g. `%UniqueName` node refs are typed `Node`). Cast first or use an explicit type.
10. **`NetworkManager` owns the client's `NetworkTime.start()`, not `NetworkEvents`.** netfox's own client-start listener is disconnected in `join_party()`; if you add one back, a joiner seeds its entire tick origin from a clock reading taken across the join stall. `03-event-flow.md`.
11. **A peer's `NetworkTime.tick` is monotonic and can only be moved by a full stop/start.** netfox's clock-stretch servo closes an offset at 25 %/s, so nothing self-heals quickly. Never let a tick rate be applied after `start()`. `02-netcode.md`.
12. **The session tick rate lives in `NetworkManager.apply_tick_rate()`, not `project.godot`.** It is server-chosen and client-adopted; it also derives netfox's tick-count limits (`history_limit`, `max_ticks_per_frame`) from *seconds*, so do not also set those in `project.godot`.
13. **Never store a spawned scene as an inline `SubResource` `PackedScene`.** `MultiplayerSpawner` resolves scenes by matching `scene_file_path` against `_spawnable_scenes` entry *paths*, so anything without a `.tscn` on disk can never replicate correctly — the peer instantiates whatever its base scene is. Use an `ExtResource` on a real scene file. `05-known-issues.md` #28.
14. **Projectiles are parented to the world, not the Player.** `GameManager.projectile_parent` (set by `world_1.gd`, consumed by `WeaponController._projectile_parent()`) points at `world1.tscn`'s `ProjectilesParent`, which is also where the replicating `ProjectileSpawner` sits. `Player.despawn()` hides the Player and a disconnect frees it — either would take in-flight projectiles with it.
15. **Deregister a status effect before running its `_on_remove`.** That teardown can re-enter `StatusEffectManager` — `SizeChangeEffect` writes the player's health back, and `AttributeComponent.health`'s setter emits `no_health` at `<= 0`, which runs `clear_all_effects()`. A still-registered id made that recurse until the stack overflowed (known-issues #31). Same in `_tick_server`, which also walks a `keys()` snapshot. Any effect that writes health must itself be dead-player-safe — see #32.

See `03-event-flow.md` for the full ordering invariants and `05-known-issues.md` for the actionable backlog.
