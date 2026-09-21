# 05 — Known Issues & TODO Backlog

The high-signal triage list: bugs, fragilities, and perf risks likely to cause frame drops, hitches, crashes, or desync. **Ranked by impact.** Each entry has file:line, the symptom, why it's a problem, and a suggested fix.

> When you introduce a new bug/fragility/perf risk, add an entry here — even if you don't fix it. When you fix one, mark it `[FIXED]` with the commit/date.

## Severity summary

| # | Severity | Area | Symptom |
|---|---|---|---|
| 1 | 🔴 Critical | Perf | Per-frame regen RPC + linear scans (O(N) × healing players, 60 RPC/s/peer) |
| 2 | 🔴 Critical | Perf | Per-frame raycast cascade in wallhack/visibility |
| 3 | 🔴 Critical | Perf | Per-frame raycast+sort in targeted-ability previews |
| 4 | 🔴 Critical | Perf | Unpooled per-shot hitscan effects (decal/tracer/impact/tween/mesh) |
| 5 | 🔴 Critical | Perf | Per-shot dict/array alloc + `$` node-path lookups in fire path |
| 6 | 🟠 High | Correctness | `_sync_mag` is unreliable → ammo divergence |
| 7 | 🟠 High | Correctness | `fire_intent` has no sender validation |
| 8 | 🟠 High | Determinism | Camera-relative movement with unsynced camera basis |
| 9 | 🟠 High | Perf | Group queries inside `_rollback_tick` (shoulder charge / pinned) |
| 10 | 🟠 High | Perf | `find_player` linear scan used in hot paths |
| 11 | 🟠 High | Perf | HUD rebuild + array/dict duplication every frame (KOTH/domination) |
| 12 | 🟠 High | Perf | Deathmatch rebuilds leaderboard dictionaries every frame |
| 13 | 🟠 High | Perf | Explosion per-particle material dup + GLSL substring scan |
| 14 | 🟠 High | Perf | Shield recursive material traversal every frame during regen |
| 15 | 🟡 Medium | Crash | Damage-number popup derefs player on disconnect (existing `FIX TODO`) |
| 16 | 🟡 Medium | Correctness | Health regen runs on every peer (no `is_server()` gate) |

---

## 🔴 Critical

### 1. Per-frame regen: RPC + linear scans + signal emit every frame
- **Files:** `components/attribute_component.gd:160-180`, `singletons/game_manager.gd:15-19`, `ui/leaderboard_singleton.gd:257`
- **Symptom:** while any player is below full HP and past the heal delay, *every physics frame* they call `apply_health_delta`, which does two `find_player` linear scans, sends `rpc_id(1, ...)` for self-heal, and emits `scores_changed`/`health_changed`.
- **Why:** O(N) scans × O(N) healing players per frame + 60 RPC/s per healing peer; cascades into `player_ui._on_health_changed` → `_update_health` → another `find_player` + label reformat each frame.
- **Suggested fix:** gate `_process` regen behind `multiplayer.is_server()` (clients mirror health via the synchronizer anyway); replace `find_player` with a name-keyed `Dictionary`; accumulate regen and only report at a throttle interval instead of every frame.

### 2. Per-frame raycast cascade in wallhack/visibility
- **Files:** `player/player.gd:2374-2430` (`_update_visibility`), `2322-2330` (`_is_occluded_by_wall`)
- **Symptom:** every rendered frame, per other player, a `space.intersect_ray` occlusion test + a `get_nodes_in_group("players")` query.
- **Why:** N−1 unthrottled raycasts/frame/client. No caching, throttling, or occlusion reuse — grows linearly with player count.
- **Suggested fix:** throttle to ~10 Hz (only when the target moved), cache the last occlusion result, or use a cheaper overlap test; cache the players list.

### 3. Per-frame raycast + sort + dictionary alloc in targeted-ability previews
- **Files:** `player/player_ui.gd:698-767`, `player/abilities/targeted_ability.gd:29-62`
- **Symptom:** for every equipped targeted ability (cooldown 0), each frame: group query + per-enemy `has_line_of_sight_to` raycast + `unproject_position` + `scored.append({...})` dict + `sort_custom`.
- **Why:** multiple raycasts + allocations + sort per enemy per frame; stacks with #2.
- **Suggested fix:** only recompute when the ability is selected/held (dirty flag), throttle to ~10 Hz, and reuse arrays instead of allocating.

### 4. Unpooled per-shot hitscan effects
- **Files:** `player/weapon_controller.gd:2439-2468` (`_on_hitscan_hit`), `weapon/tracer.gd:20-69`
- **Symptom:** per bullet impact: `decal_scene.instantiate()` + `Timer.new()`, `_tracer_scene.instantiate()`, `_bullet_impact_scene.instantiate()`; `tracer.fire` also `CylinderMesh.new()` + `StandardMaterial3D.new()` + `create_tween()` + lambda.
- **Why:** hundreds of allocations/sec per shooter at automatic fire rates; the project already pooled audio (`AudioPool`) for exactly this reason but left tracers/impacts/decals unpooled.
- **Suggested fix:** pool tracers/impacts/decals like `AudioPool`; reuse mesh/material/tween instead of allocating per shot.

### 5. Per-shot dict/array allocation + `$` node-path lookups in fire path
- **Files:** `player/weapon_controller.gd:1772,1786` (`_try_fire`), `2159-2172,2147` (`_fire_single_shot`), `2430` (`_flash_muzzle_flash`)
- **Symptom:** a fresh `data_dict` + `exclude_rids` array + `PhysicsRayQueryParameters3D` per shot, and `$"../HurtComponent2"` / `$MuzzleFlash` node-path lookups per shot.
- **Why:** per-shot allocation + node-path resolution churn.
- **Suggested fix:** cache `$MuzzleFlash`, `HurtComponent2`, and `ShieldArea` in `@onready`; reuse a member array/dict for the ray params.

---

## 🟠 High

### 6. `_sync_mag` is unreliable → ammo divergence
- **Files:** `player/weapon_controller.gd:2015` (vs reliable `_sync_all_mags` `534`, `_confirm_reload_done` `1595`)
- **Symptom:** `_sync_mag` is `@rpc("any_peer","call_local")` — no `"reliable"`. An authoritative mag value can be dropped, and the optimistic client mag diverges until the next reliable correction.
- **Why:** ammo counts can desync between client and server.
- **Suggested fix:** make `_sync_mag` `"reliable"`, or fold mag into a reliable snapshot.

### 7. `fire_intent` has no sender validation
- **Files:** `player/weapon_controller.gd:1948` (`fire_intent` `@rpc("any_peer")`) vs `request_reload` `1459-1469`
- **Symptom:** `fire_intent` does not check `get_remote_sender_id()`, unlike `request_reload`. Any peer can invoke `fire_intent` on any player's weapon controller.
- **Why:** asymmetric trust; the server still validates ammo but a malicious/buggy peer can trigger fire logic out of turn.
- **Suggested fix:** validate `get_remote_sender_id()` == owning player (mirror `request_reload`).

### 8. Camera-relative movement with unsynced camera basis
- **Files:** `player/player.gd:1493` (`_apply_movement_from_input`), `1864-1867` (`_movement_basis`), `player/body.gd:26-57` (commented-out `sync_rotation` at `59-68`)
- **Symptom:** movement/dash/charge direction is camera-relative, but body/camera orientation is neither rollback state nor replicated; on remote peers the basis is stale.
- **Why:** remote simulation can diverge from the authority; relies entirely on netfox state correction to snap drift. The deepest determinism assumption in the project.
- **Suggested fix:** sync the yaw basis (re-enable/repair `sync_rotation`), or derive movement from a rollback-synced orientation, or move direction inputs into rollback state.

### 9. Group queries inside `_rollback_tick`
- **Files:** `player/player.gd:968-1052` (`_rollback_tick`), `1005` (`find_player`), `1025` (`get_nodes_in_group`)
- **Symptom:** during a shoulder charge, `get_nodes_in_group("players")` runs every rollback tick; while pinned, `find_player(pinned_charger_name)` runs every tick.
- **Why:** rollback re-simulates multiple ticks per frame, multiplying the cost; a group query in the deterministic path is also a correctness smell.
- **Suggested fix:** cache the charge target/ragdoll ref at charge start (in `_physics_process`), don't re-query in `_rollback_tick`.

### 10. `GameManager.find_player` is a linear scan in hot paths
- **Files:** `singletons/game_manager.gd:15-19`
- **Symptom:** `for child in spawn_parent.get_children()` by name, called from regen (`attribute_component.gd:64,131`), fire/damage, HUD health updates.
- **Why:** O(N) per call, and called many times/frame.
- **Suggested fix:** maintain a name-keyed `Dictionary[int, Player]` updated on spawn/despawn.

### 11. HUD rebuild + array/dict duplication every frame (KOTH/domination)
- **Files:** `components/domination_mode.gd:72-80`, `components/koth_mode.gd:70-77`, `world/hud/hud_controller.gd:248-286,430-431`
- **Symptom:** `points_updated`/`time_held_updated` emit every frame while active → `_domination_data`/`_koth_data` `points.duplicate()`, `time_held.duplicate()`, `get_cp_states()` (arrays of dicts) + string formatting every frame.
- **Why:** full HUD rebuild + allocation every frame during the most common modes.
- **Suggested fix:** emit only on change (compare last value), and only push changed control points.

### 12. Deathmatch rebuilds leaderboard dictionaries every frame
- **Files:** `components/deathmatch_mode.gd:69-97`, `ui/leaderboard_singleton.gd:264-286`
- **Symptom:** `tick()` loops `Leaderboard.get_players()` + `_max_kills` calls `get_players()` again; `get_players()` builds a fresh dictionary and returns `.keys()`.
- **Why:** 2-3 full dictionary traversals + allocations every frame, for data that only changes on kills.
- **Suggested fix:** poll the leaderboard at an interval or react to `scores_changed`, and have `get_players()` return a cached list.

### 13. Explosion per-particle material dup + GLSL substring scan
- **Files:** `effects/generic_explosion.gd:42-129`
- **Symptom:** `mat.duplicate(false)` / `material.duplicate()` per particle per explosion; `_shader_has_param` (`123`) does `param_name in mat.shader.code` (substring over full GLSL) per particle.
- **Why:** allocation + expensive string scan per particle.
- **Suggested fix:** cache the has-param result per shader once; reuse materials where safe.

### 14. Shield recursive material traversal every frame during regen
- **Files:** `player/shield.gd:130-193`
- **Symptom:** while `hp < fire.shield_hp`, `_update_visual` → `_apply_material` recursively walks `node.get_children()` and `StandardMaterial3D.new()` every frame.
- **Why:** recursive subtree walk + material allocation every frame during an active state.
- **Suggested fix:** cache the mesh/material list once, update material params in place instead of rebuilding.

---

## 🟡 Medium

### 15. Damage-number popup derefs player on disconnect
- **Files:** `components/damage_number_popup.gd:149` — `var p := _target_node as Player # FIX TODO when disconnect causes isue`
- **Symptom:** a pre-existing TODO flagging a crash/issue when the target player disconnects in the per-frame popup path.
- **Why:** dereferencing a freed `Player` is a crash risk.
- **Suggested fix:** guard with `is_instance_valid(_target_node)` before use.

### 16. Health regen runs on every peer (no `is_server()` gate)
- **Files:** `components/attribute_component.gd:160-180`
- **Symptom:** regen `_process` has no `is_server()` guard; negative-regen (damage-over-time) applies on every peer and calls `apply_health_delta` (which triggers kill/score bookkeeping). The server value wins via the synchronizer, but clients duplicate-simulate death/score side effects.
- **Why:** correctness edge case (duplicate death/score on negative regen) and wasted CPU.
- **Suggested fix:** gate regen to the server; clients mirror health from the synchronizer only.

---

## Lower priority (recorded, not blocking)

These are real but not current bottlenecks — revisit only if profiling flags them.

- `player/animation_tree.gd:23-85` — per-frame `$` lookups + string-keyed param writes + `basis.inverse()`.
- `player/skin.gd:119-143` — no own-model gate; runs per-frame for every replicated player.
- `player/rim_pivot.gd:24-38` — per-frame `get_camera_3d()` + `look_at` per non-own model.
- `world/payload/payload.gd:121-392` — per-frame label string formatting + `_tick_healing` per pusher.
- `weapon/projectiles/simple_projectile.gd:90-138` — per-physics-frame curve sample + distance math per projectile.
- `player/weapon_controller.gd:737,756` / `player/player.gd:2364,600-635` — `find_children` recursive scans on spawn/tier-change (not per-frame).
- `player/bot_controller.gd:628`, `maps/map_game_mode_assigner.gd:89` — raw `free()` (safe today: unparented / editor-only, but fragile).
