# 04 — Optimization: Performance Model & Hot Paths

This explains *why* the game can drop frames and where the pressure is, so you can reason about new code. The actionable "fix this" backlog lives in [`05-known-issues.md`](05-known-issues.md) — this doc gives the mental model and the catalog behind it.

## Frame budget model

There is no profiler-friendly budget configured; the game runs `_process` (render frame), `_physics_process` (fixed Jolt physics step), **and** netfox's rollback re-simulation (multiple `_rollback_tick` calls per frame) on the **same single core**. Three pressures stack:

> **Tickrate 90 Hz (2026-09-24):** the rollback tick loop now runs at 90 Hz (`netfox/time/tickrate=90`, up from the addon default 30), so `_rollback_tick` fires **3×** as often per player. Movement-sim cost is tripled relative to 30 Hz; the rollback hot paths below (`player/player.gd:968`, `_apply_movement_from_input` at `1503`) are the ones most sensitive to this.

1. **Rollback re-simulation** — netfox re-runs `_rollback_tick` for several past ticks each frame to reconcile state. Anything expensive inside `_rollback_tick` is multiplied by the number of re-simulated ticks, **and** must be deterministic (no physics queries, no RNG, no `get_nodes_in_group`, no raycasts — all of these break determinism *and* cost CPU).
2. **Per-frame work** — every `_process`/`_physics_process` runs 60+ times/second *per node*. A node that exists once per player multiplies by player count; a node that exists once per projectile multiplies by projectile count.
3. **Allocation / GC churn** — GDScript `Dictionary`/`Array` literals, `instantiate()`, `Node.new()`, `Material.new()`, `Tween` creation all hit the allocator and later the GC. Churn in per-frame/per-shot paths is the classic cause of hitches.

### The three costs to always ask about

| Cost | Where it hides | Symptom |
|---|---|---|
| **Scene-tree/group query** (`get_nodes_in_group`, `find_player`, `find_child`, `get_node`) | per-frame loops | O(N) scans every frame |
| **Physics query** (`intersect_ray`, `PhysicsRayQueryParameters3D`) | per-frame/per-shot | sync raycast stalls, Jolt cost |
| **Node/resource churn** (`instantiate`, `new`, `duplicate`, `create_tween`) | per-shot/per-particle | GC hitches |

---

## The big three hot spots (fix first — see `05-known-issues.md`)

### 1. Per-frame raycast + group-query cascade in visibility/wallhack — `[FIXED 2026-09-20]`

`player/player.gd` `_update_visibility(delta)` (`2384`) runs every rendered frame from `_process` (`1488`). It loops the cached `_visibility_players` list and, per other player, reads the cached occlusion result (`_occlusion_cache`); the raycasts and `get_nodes_in_group("players")` are throttled to 10 Hz (`OCCLUSION_REFRESH_INTERVAL`).

**Cost (before fix):** N−1 unthrottled raycasts/frame + one group query/frame, per client — likely the single biggest render-frame cost with many players. Now reduced to N−1 raycasts + one group query at 10 Hz, with results cached in between.

### 2. Per-frame raycast + sort + dictionary alloc in targeted-ability previews — `[FIXED 2026-09-20]`

`player/player_ui.gd` `_update_targeted_previews` now throttles `ability.find_candidates` (the group query + `has_line_of_sight_to` raycast per enemy + `sort_custom`) to 10 Hz (`PREVIEW_REFRESH_INTERVAL`), caching the result per ability in `_preview_candidates`. Between refreshes only the cheap label re-projection runs.

**Cost (before fix):** for every equipped targeted ability (cooldown 0), a group query + raycast per enemy + screen projection + dictionary allocation + sort **every frame**. Now reduced to 10 Hz.

### 3. Un-gated per-frame regen → RPC + linear scans + signal emit — `[FIXED 2026-09-20]`

> Fixed: regen is now gated behind `is_server()` and the self-heal stat is throttled (see `05-known-issues.md` #1). Kept here for context on the pattern.

`components/attribute_component.gd` `_process(delta)` (`160`) has **no `is_server()` gate**. Every physics frame for every below-full-health player it calls `apply_health_delta(...)` (`180`), which:
- calls `GameManager.find_player(changer)` (`game_manager.gd:15`, a **linear scan** over `spawn_parent` children) — twice per call (`attribute_component.gd:64,131`),
- on heal sends `Leaderboard.request_add_self_heal` → `rpc_id(1, ...)` → `scores_changed.emit()`.

**Cost:** O(N) scans × O(N) healing players per frame + 60 RPC/s per healing peer, and it cascades into `player_ui._on_health_changed` → `_update_health` (which itself calls `find_player` again and reformats label text). This is the single highest-impact perf bug.

---

## Per-shot churn (hitscan fire path) — effects + allocations `[FIXED 2026-09-20]`

The automatic-weapon fire path no longer allocates per shot:

- **Pooled hitscan effects** — `weapon_controller.gd` `_on_hitscan_hit` now acquires tracers, impacts, and decals from node pools (`Tracer.acquire`, `BulletImpact.acquire`, `BulletDecal.acquire`). `Tracer` reuses a single `CylinderMesh` + `StandardMaterial3D` and drives its shrink in `_process` (no `create_tween()`); `BulletImpact`/`BulletDecal` track their one-shot lifetime in `_process` (no `Timer.new()`/`create_timer`).
- **No per-shot dict/array + node-path lookups** — `weapon_controller.gd` `_try_fire` reuses a member `_recoil_data` Dictionary; `_fire_single_shot` reuses a member `_ray_query` + `_exclude_rids` array; `$MuzzleFlash` and `$"../HurtComponent2"` are cached `@onready`.
- **Per-shot RPC burst** — `_apply_recoil_rpc`, `_play_shoot_sound`, `_sync_mag`, `_flash_muzzle_flash`, `_on_hitscan_hit`, `fire_intent`, `_change_health_on_server`. At automatic fire rates this is a large RPC burst across all peers. *(Not addressed — RPC count is unchanged.)*

---

## Per-frame group queries in combat loops

- `player/player.gd` `_rollback_tick` (`968`): `get_tree().get_nodes_in_group("players")` (`1025`) while `charge_time > 0` — **inside the rollback tick**, so re-simulated every tick (and it's a group query in the deterministic path). Also `GameManager.find_player(pinned_charger_name)` (`1005`) every tick while pinned.
- `player/player.gd` `_grab_nearby_enemies` (`1271`): group query (`1273`) every frame while charging.
- `player/player.gd` `aimbot_find_target` (`1970`): group query (`1980`) every frame while firing; `_aimbot_rotate_to` (`2047`) does `target.get_node(".../Physical Bone DEF-spine_006")` (`2048`) every frame.
- `weapon/projectiles/explosion_component.gd` `_apply_explosion_tick` (`74`): group query (`78`), per-player raycast (`98`,`104`), `find_player` scans via `apply_health_delta` (`129`), and `get_nodes_in_group("ragdolls")` (`152`) — per explosion tick (explosions can pulse).

## Per-frame HUD / leaderboard rebuilds

- `components/domination_mode.gd` `tick` (`72`): `points_updated.emit(points)` (`80`) every frame while active.
- `components/koth_mode.gd` `tick` (`70`): `time_held_updated.emit(time_held)` (`77`) every frame while a team holds.
- `world/hud/hud_controller.gd` `_push_data_to_panel` (`248`) → `_domination_data`/`_koth_data` (`281`/`272`): `points.duplicate()` (`286`), `time_held.duplicate()` (`276`), `get_cp_states()` (arrays of dictionaries) **every frame** during active KOTH/domination, plus string formatting (`_fmt_seconds`, `"%d  /  %d"` at 430-431).
- `components/deathmatch_mode.gd` `tick` (`69`): loops `Leaderboard.get_players()` (`74`) + `_max_kills` → `get_players()` again (`97`); `ui/leaderboard_singleton.gd` `get_players` (`264`) builds a fresh dictionary and returns `.keys()` (`286`). 2-3 full dictionary traversals + allocations every frame, for data that only changes on kills.

## Per-particle / per-frame material & shader work

- `effects/generic_explosion.gd` `start_effect` (`42`): `mat.duplicate(false)` (`62`), `material.duplicate()` (`102`,`113`) per particle per explosion; `_shader_has_param` (`123`) does `param_name in mat.shader.code` (`129`) — a substring scan over the full GLSL source per particle.
- `player/shield.gd` `_process` (`130`): while regen active, `_update_visual` (`153`) → `_apply_material` (`180`) recursively walks `node.get_children()` (`193`) and `StandardMaterial3D.new()` (`184`) every frame.
- `player/animation_tree.gd` `_process` (`23`): `$".."` (`24`) and `$"../.."` (`25`) node lookups + string-keyed `set("parameters/...")` + `basis.inverse()` every frame.
- `player/skin.gd` `_process` (`119`): no own-model gate; recomputes local velocity + blend smoothing every frame for every replicated player.
- `player/rim_pivot.gd` `_process` (`24`): `get_viewport().get_camera_3d()` + `look_at` every frame per non-own model.
- `world/payload/payload.gd` `_physics_process` (`121`): `_update_label()` string formats every frame; `_tick_healing` (`217`) calls `p.change_health(...)` every frame per pusher (feeding hotspot #3).

---

## What's done well (do not regress)

- **`effects/audio_pool.gd`** — proper pooling for one-shot audio; the code comment documents the original per-shot allocation problem. Follow this pattern for tracers/impacts/decals.
- **`components/status_effect/status_effect_manager.gd`** — effects tick on a 10 Hz `Timer` (not every frame), stops the timer when idle, and skips re-broadcasting permanent passives.
- **`player/bot_controller.gd`** — steering raycasts throttled to a process interval and reuse `_steer_query`; stuck-detection is interval-based.
- **`network/network_manager.gd:133`** — correct `queue_free()` (not `free()`) on map swap.

---

## Patterns to follow when adding code

1. **Cache node references in `_ready`** — never `$`-lookup or `get_node` in `_process`/`_physics_process`/`_rollback_tick`; store `@onready` refs.
2. **Never run `get_nodes_in_group`/`find_player` per frame** — cache a member list and update it only on membership change (e.g. on `add_to_group`/spawn/despawn), or use a `Dictionary` keyed by name instead of a linear scan.
3. **Gate server-only work behind `multiplayer.is_server()`** — the regen bug is the canonical failure: a below-full-HP player regenerates on *every* peer.
4. **Throttle raycasts** to an interval (like `BotController`) or reuse a cached query, and prefer `intersect_ray` only when strictly needed.
5. **Pool transient effects** (tracers, impacts, decals, projectiles) like `AudioPool` rather than `instantiate()` per event.
6. **Keep `_rollback_tick` deterministic and cheap** — no physics queries, no RNG, no group scans, no `global_position` reads from non-synced nodes. Re-simulation multiplies its cost.
7. **Avoid per-frame `duplicate()` / string formatting** in HUD paths — only rebuild on change (dirty flag / signal), not every frame.
8. **`queue_free`, never `free()`, on replicated nodes** — the spawner must observe the removal event.

## Frame rate & vsync

The rendered FPS is capped only by **VSync** — there is no `max_fps`/`Engine.max_fps` anywhere in the project. Godot 4 enables vsync by default (`display/window/vsync/vsync_mode = 1`), which locks FPS to the display refresh rate. The project now sets `window/vsync/vsync_mode=0` in `project.godot` (vsync disabled) so there is no artificial cap; `Engine.max_fps` stays at its default `0` (uncapped). To re-cap later, re-enable vsync or set `Engine.max_fps`.
