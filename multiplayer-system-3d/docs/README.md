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
5. **Health regen runs on every peer, un-gated** (`attribute_component.gd:160-180`), sending an RPC + doing linear `find_player` scans every frame per healing player. This is the #1 perf hotspot. `05-known-issues.md`.
6. **Per-frame raycast cascades** in `_update_visibility` and targeted-ability previews (N−1 raycasts/frame/player). `player.gd:2374`; `targeted_ability.gd:29`.
7. **Use `queue_free`, never `free()`, when swapping maps** — the spawner needs the removal event to despawn on peers. `network_manager.gd:133`.
8. **`spawnable_scenes` requirement:** any map the scanner returns must have its scene uid in `world1.tscn`'s `MultiplayerSpawner._spawnable_scenes`, or it won't replicate.
9. **Godot shares `Resource`/sub-resource instances across scene instances.** Per-player mutable state must be `duplicate(true)`'d (weapons, `Shape3D`s, `AnimationTree.tree_root`, team-tint materials).
10. **Never use `:=` on an untyped `Variant` source** (e.g. `%UniqueName` node refs are typed `Node`). Cast first or use an explicit type.

See `03-event-flow.md` for the full ordering invariants and `05-known-issues.md` for the actionable backlog.
