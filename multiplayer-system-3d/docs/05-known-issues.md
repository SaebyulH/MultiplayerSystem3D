# 05 — Known Issues & TODO Backlog

The high-signal triage list: bugs, fragilities, and perf risks likely to cause frame drops, hitches, crashes, or desync. **Ranked by impact.** Each entry has file:line, the symptom, why it's a problem, and a suggested fix.

> When you introduce a new bug/fragility/perf risk, add an entry here — even if you don't fix it. When you fix one, mark it `[FIXED]` with the commit/date.

## Severity summary

| # | Severity | Area | Symptom |
|---|---|---|---|
| 1 | 🔴 Critical | Perf | ✅ FIXED — Per-frame regen RPC + linear scans (O(N) × healing players, 60 RPC/s/peer) |
| 2 | 🔴 Critical | Perf | ✅ FIXED — Per-frame raycast cascade in wallhack/visibility |
| 3 | 🔴 Critical | Perf | ✅ FIXED — Per-frame raycast+sort in targeted-ability previews |
| 4 | 🔴 Critical | Perf | ✅ FIXED — Unpooled per-shot hitscan effects (decal/tracer/impact/tween/mesh) |
| 5 | 🔴 Critical | Perf | ✅ FIXED — Per-shot dict/array alloc + `$` node-path lookups in fire path |
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
| 16 | 🟡 Medium | Correctness | ✅ FIXED — Health regen runs on every peer (no `is_server()` gate) |
| 17 | 🟡 Medium | UI | ✅ FIXED — FPS counter `CanvasLayer` leaked on tree root across return-to-lobby |
| 18 | 🟠 High | Netcode | Client/server tick desync → host movement delayed by seconds (client tick falls behind) |

---

## 🔴 Critical

### 1. Per-frame regen: RPC + linear scans + signal emit every frame — `[FIXED 2026-09-20]`
- **Files:** `components/attribute_component.gd:160-180`, `singletons/game_manager.gd:15-19`, `ui/leaderboard_singleton.gd:257`
- **Resolution:** `attribute_component.gd:_process` now early-returns unless `multiplayer.is_server()` (clients mirror health via the `MultiplayerSynchronizer`), and the self-heal stat is accumulated and flushed on a 0.5 s throttle timer (`_flush_regen_stat`) instead of calling `apply_health_delta` → `Leaderboard.request_add_self_heal` every frame. The regen path no longer calls `find_player` at all.
- **Symptom:** while any player is below full HP and past the heal delay, *every physics frame* they call `apply_health_delta`, which does two `find_player` linear scans, sends `rpc_id(1, ...)` for self-heal, and emits `scores_changed`/`health_changed`.
- **Why:** O(N) scans × O(N) healing players per frame + 60 RPC/s per healing peer; cascades into `player_ui._on_health_changed` → `_update_health` → another `find_player` + label reformat each frame.
- **Suggested fix:** gate `_process` regen behind `multiplayer.is_server()` (clients mirror health via the synchronizer anyway); replace `find_player` with a name-keyed `Dictionary`; accumulate regen and only report at a throttle interval instead of every frame.

### 2. Per-frame raycast cascade in wallhack/visibility — `[FIXED 2026-09-20]`
- **Files:** `player/player.gd:2384-2467` (`_update_visibility`), `2322-2330` (`_is_occluded_by_wall`)
- **Resolution:** `_update_visibility` now throttles both the occlusion raycasts and the players-group query to a 10 Hz interval (`OCCLUSION_REFRESH_INTERVAL`), caching the player list (`_visibility_players`) and each player's last occlusion result (`_occlusion_cache`) between refreshes. The per-frame loop still drives outlines/health bars/ghost tiers, but `intersect_ray` and `get_nodes_in_group("players")` no longer run every frame (they're guarded by `is_instance_valid` so a player that disconnects mid-interval can't be dereferenced).
- **Symptom:** every rendered frame, per other player, a `space.intersect_ray` occlusion test + a `get_nodes_in_group("players")` query.
- **Why:** N−1 unthrottled raycasts/frame/client. No caching, throttling, or occlusion reuse — grows linearly with player count.
- **Suggested fix:** throttle to ~10 Hz (only when the target moved), cache the last occlusion result, or use a cheaper overlap test; cache the players list.

### 3. Per-frame raycast + sort + dictionary alloc in targeted-ability previews — `[FIXED 2026-09-20]`
- **Files:** `player/player_ui.gd:747-815` (`_update_targeted_previews`), `player/abilities/targeted_ability.gd:29-66`
- **Resolution:** `_update_targeted_previews` now throttles `find_candidates` (the group query + LOS raycast + sort) to a 10 Hz interval (`PREVIEW_REFRESH_INTERVAL`), caching the ordered candidate list per ability in `_preview_candidates`; between refreshes the per-frame loop only re-projects labels from the cached list. `find_candidates` itself is unchanged — it remains the live one-shot cast path in `ability_manager.gd:206`.
- **Follow-up (2026-09-24):** the throttling exposed a runtime type error — when an ability's key was missing from `_preview_candidates` (first frame, or an ability that came off cooldown between refreshes), `_preview_candidates.get(ability, [])` fell back to an **untyped** `[]`, which fails the `Array[Player]` assignment and spammed `Trying to assign an array of type "Array" to a variable of type "Array[Player]"`. Fixed by casting the default: `_preview_candidates.get(ability, []) as Array[Player]` (`player_ui.gd:802`).
- **Symptom:** for every equipped targeted ability (cooldown 0), each frame: group query + per-enemy `has_line_of_sight_to` raycast + `unproject_position` + `scored.append({...})` dict + `sort_custom`.
- **Why:** multiple raycasts + allocations + sort per enemy per frame; stacks with #2.
- **Suggested fix:** only recompute when the ability is selected/held (dirty flag), throttle to ~10 Hz, and reuse arrays instead of allocating.

### 4. Unpooled per-shot hitscan effects — `[FIXED 2026-09-20]`
- **Files:** `player/weapon_controller.gd:2448-2481` (`_on_hitscan_hit`), `weapon/tracer.gd`, `effects/bullet_impact.gd`, `effects/bullet_decal.gd`
- **Resolution:** tracers, bullet impacts, and decals are now node-pooled (static `acquire`/`_release`, capped pools) following the `AudioPool` pattern. `Tracer` builds its `CylinderMesh` + `StandardMaterial3D` once in `_ready` and reuses them; the per-shot `create_tween()` is replaced by a `_process`-driven shrink. `BulletImpact` and the new `BulletDecal` track their one-shot lifetime in `_process` instead of an awaited `create_timer`. The decal scenes (`bullet_hole.tscn`, `scratch.tscn`) now carry the `BulletDecal` script; the texture is (re)applied on `place()` so the shared pool can serve either kind.
- **Symptom:** per bullet impact: `decal_scene.instantiate()` + `Timer.new()`, `_tracer_scene.instantiate()`, `_bullet_impact_scene.instantiate()`; `tracer.fire` also `CylinderMesh.new()` + `StandardMaterial3D.new()` + `create_tween()` + lambda.
- **Why:** hundreds of allocations/sec per shooter at automatic fire rates; the project already pooled audio (`AudioPool`) for exactly this reason but left tracers/impacts/decals unpooled.
- **Suggested fix:** pool tracers/impacts/decals like `AudioPool`; reuse mesh/material/tween instead of allocating per shot.

### 5. Per-shot dict/array allocation + `$` node-path lookups in fire path — `[FIXED 2026-09-20]`
- **Files:** `player/weapon_controller.gd:1783-1795` (`_try_fire`), `2160-2180` (`_fire_single_shot`), `2442` (`_flash_muzzle_flash`)
- **Resolution:** `$MuzzleFlash` and `$"../HurtComponent2"` are cached `@onready` (`_muzzle_flash`, `_hurt_component2`); the recoil RPC reuses a member `_recoil_data` Dictionary, and the hitscan ray reuses a member `_ray_query` + `_exclude_rids` array instead of `PhysicsRayQueryParameters3D.create()` and a fresh `exclude_rids` per shot.
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

### 18. Client/server tick desync → host movement delayed by seconds
- **Files:** `addons/netfox/network-time.gd:557` (tick catch-up loop), `addons/netfox/encoder/redundant-history-encoder.gd:90-96` (rejects old input), `addons/netfox/rollback/network-rollback.gd:327-332` (clamp + warning), `project.godot` `[netfox]` (`time/max_ticks_per_frame`), `network/network_manager.gd:46-55,62-66,96-100` (join path)
- **Symptom:** the client sees the host player's movement delayed by seconds (look stays smooth). Console shows `RedundantHistoryEncoder: Received data for 1768, rejecting because older than 64 frames` and/or `NetworkRollback: Trying to run rollback for ticks 1680 to 3284, past the history limit of 64`. On a bad connect the client can be kicked back to its own lobby.
- **Why:** the client's `NetworkTime.tick` drifts **behind** the server's. netfox's tick loop runs in `_process` (render FPS, since `sync_to_physics=false`) and catches up at most `max_ticks_per_frame` ticks per frame (`network-time.gd:557`). The default **8** can only stay in step above ~3.75 fps; the client's FPS dips below that during connect (shader compilation + map/player replication) and in heavy scenes (two instances on one machine), so its tick falls behind. Once behind, its inputs are stamped old and rejected by the server (`redundant-history-encoder.gd:90-96`), and the host player's rollback-synced movement renders late. Look is unaffected because it isn't rollback-synced (local camera; `body.gd:59-68` `sync_rotation` commented out).
- **Fix applied (2026-09-21):**
  - `netfox/time/max_ticks_per_frame` 8 → **60** — the tick loop can now catch up to real time after a severe FPS drop (keeps up down to ~0.5 fps; below that the netfox stall detection resets). Applies to both peers.
  - `application/run/disable_low_processor_usage_mode=true` — keep the host ticking when unfocused (a separate earlier contributor).
  - `display/window/vsync/vsync_mode=1` — cap both instances to reduce CPU/GPU contention.
  - Join guarded behind the existing `LoadingScreen`.
- **Tried & reverted:** raising `netfox/rollback/history_limit` (64 → 256) made the per-frame rollback re-sim worse and caused a connect timeout — do **not** re-raise it.
- **Follow-up if insufficient:** `netfox/time/sync_to_physics=true` fully decouples the tick from render (fixed 60 Hz). Note: as of 2026-09-24 tickrate is **90** (`time/tickrate=90`), so switching `sync_to_physics=true` would now *lower* the tick to the 60 Hz physics rate — not applicable while 90 Hz is intended.

### 19. Tickrate raised 30→90 — watch rollback CPU
- **Files:** `project.godot` `[netfox]` (`time/tickrate=90`), `player/character.gd:62` (`knockback_multiplier` 2.0→0.667)
- **Symptom/risk:** `_rollback_tick` now runs 3× as often (90 vs 30 Hz), tripling movement-sim cost per player on the shared single core. Knockback was re-scaled to keep 60-Hz-equivalent feel, but any future tickrate change must re-visit this multiplier (`60 / tickrate`).
- **Watch for:** frame-time creep with many players/bots; if it regresses, consider `sync_to_physics=true` (60 Hz) or reverting to 30 Hz.

---

## 🟡 Medium

### 15. Damage-number popup derefs player on disconnect
- **Files:** `components/damage_number_popup.gd:149` — `var p := _target_node as Player # FIX TODO when disconnect causes isue`
- **Symptom:** a pre-existing TODO flagging a crash/issue when the target player disconnects in the per-frame popup path.
- **Why:** dereferencing a freed `Player` is a crash risk.
- **Suggested fix:** guard with `is_instance_valid(_target_node)` before use.

### 16. Health regen runs on every peer (no `is_server()` gate) — `[FIXED 2026-09-20]`
- **Files:** `components/attribute_component.gd:160-180`
- **Resolution:** Same fix as #1 — `_process` is gated behind `multiplayer.is_server()`, so negative-regen damage-over-time no longer applies (and can no longer kill) on clients; they get the result via the health synchronizer.
- **Symptom:** regen `_process` has no `is_server()` guard; negative-regen (damage-over-time) applies on every peer and calls `apply_health_delta` (which triggers kill/score bookkeeping). The server value wins via the synchronizer, but clients duplicate-simulate death/score side effects.
- **Why:** correctness edge case (duplicate death/score on negative regen) and wasted CPU.
- **Suggested fix:** gate regen to the server; clients mirror health from the synchronizer only.

### 17. FPS counter `CanvasLayer` leaks across return-to-lobby — `[FIXED 2026-09-20]`
- **Files:** `player/player_ui.gd:292-316` (`_build_fps`)
- **Symptom:** the FPS `CanvasLayer` ("FPSCanvas") is added to `get_tree().root` and never freed. Each `return_to_lobby()` → `boot_to_lobby()` rebuild frees the `PlayerUI` but not the root-level canvas, so another FPS counter is stacked each time (stale frozen numbers layered over the live one).
- **Resolution:** `_fps_canvas` is stored as a member and `queue_free()`d in `_exit_tree()`.

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
