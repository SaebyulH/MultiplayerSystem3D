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
| 18 | 🔴 Critical | Netcode | ✅ FIXED — Tick-domain divergence → movement delayed by seconds (joiner's tick origin seeded across the join stall) |
| 19 | 🟠 High | Perf | Tick rate is per-session and scales rollback CPU linearly |
| 20 | 🟠 High | Determinism | ✅ FIXED — Knockback was scaled by the render frame rate (not the tick rate) |
| 21 | 🟡 Medium | Determinism | ✅ FIXED — Noclip integrated with `physics_factor` on a manual tick-delta path |
| 22 | 🟡 Medium | Netcode | `netfox/rollback/input_redundancy` is dead config in 1.35.3 |
| 23 | 🟡 Medium | Netcode | `diff_ack_interval = 0` → a full state send every tick |
| 24 | 🟡 Medium | Netcode | `RollbackSynchronizer.get_last_known_input()` throws (bad call in the addon) |
| 25 | 🔴 Critical | Perf | ✅ FIXED — Lobby instantiation parsed ~50 MB of map scenes (8–9.5 s main-thread stall) |
| 26 | 🟠 High | Perf | Residual ~1.6 s lobby-load stall (CSG + VoxelGI + environment) |
| 27 | 🟡 Medium | Anim | ✅ FIXED — `AnimationNodeBlendTree.get_node()` hard error every shot (dead guard) |
| 28 | 🔴 Critical | Netcode | ✅ FIXED — Rocket/syringe projectiles replicated as the mesh-less base scene (inline `SubResource` bundles) |
| 29 | 🟡 Medium | Hygiene | Dead `ProjectilesParent`/`ProjectileSpawner` in all 10 maps |
| 30 | 🟡 Medium | Netcode | `SimpleProjectile.hide_model` is `@rpc("any_peer")` |
| 31 | 🔴 Critical | Crash | ✅ FIXED — Stack overflow: dying while enlarged (existing TODO) |
| 32 | 🟡 Medium | Fragility | `Player.no_health()` is not idempotent |
| 33 | 🟡 Medium | Netcode | `blocks_actions` is a client-side courtesy — not enforced on movement |
| 34 | 🟡 Medium | Netcode | ✅ FIXED — Late joiner renders size-changed players at 1.0× |
| 35 | 🟠 High | Security | ✅ FIXED — Size RPC was `@rpc("any_peer")` while writing `starting_health` |
| 36 | 🔴 Critical | Correctness | ✅ FIXED — Size effects corrupted max health permanently ("1/0" or unbounded HP) |
| 37 | 🟡 Medium | Visuals | ✅ FIXED — Ragdoll spawned at normal size for a shrunk/enlarged player |
| 38 | 🟡 Medium | Netcode | Projectile damage amp lives only on the server's projectile copy → shield absorption diverges per peer |

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
- **Follow-up (2026-09-24):** the throttling exposed a runtime type error — when an ability's key was missing from `_preview_candidates` (`_preview_timer` starts at `0.0`, so on the first frame the throttle has not refreshed yet and the cache is still empty), `_preview_candidates.get(ability, [])` fell back to an **untyped** `[]`, which fails the `Array[Player]` assignment and spammed `Trying to assign an array of type "Array" to a variable of type "Array[Player]"`.
- **Fix (`player_ui.gd:809-811`):** skip uncached abilities rather than defaulting to a literal —
  ```gdscript
  if not _preview_candidates.has(ability):
	  continue
  var candidates: Array[Player] = _preview_candidates[ability]
  ```
  They would produce no entries anyway, so this is behaviour-preserving.
- ⚠️ **Do not "fix" this by casting the default** — i.e. `_preview_candidates.get(ability, []) as Array[Player]` does **not** work. `as` performs a type check, not a conversion, so an untyped `Array` stays untyped and the assignment still throws. An earlier revision of this entry recommended exactly that; it was wrong. Checking `has()` first (or building a correctly-typed default with `Array([], TYPE_OBJECT, "RefCounted", Player)`) is the way.
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

### 18. Tick-domain divergence → movement delayed by seconds — `[FIXED 2026-09-24]`
- **Files:** `addons/netfox/network-time.gd:427,440` (the only absolute tick writes), `addons/netfox/network-time-synchronizer.gd:267-276` (the uncompensated initial timestamp), `addons/netfox/encoder/redundant-history-encoder.gd:90-96` (rejects old input), `addons/netfox/rollback/network-rollback.gd:327-332` (clamp + warning), `network/network_manager.gd` (`_take_over_client_time`, `_on_connected_to_server`)
- **Symptom:** the host player's movement renders seconds late (look stays smooth). Console logs, for thousands of consecutive frames: `NetworkRollback: Trying to run rollback for ticks 1968 to 2925, past the history limit of 64` and `RedundantHistoryEncoder: Received data for 1999, rejecting because older than 64 frames`. Note `B@2920|2857>2921` on the first line — the *previous* frame's span, which is clamped to exactly 64, i.e. the loop has been re-clamping every frame. On a bad connect the client can be kicked back to its own lobby.
- **Why (this is a tick *origin* bug, not a tick *rate* bug):** `NetworkTime.tick` is a purely local counter, set absolutely only at `start()` — to `0` on a host, and on a client to `seconds_to_ticks(NetworkTimeSynchronizer.get_time())` exactly once (`network-time.gd:440`). That clock sample carries **no RTT or elapsed-time compensation** (`network-time-synchronizer.gd:267-276`); the properly-compensated NTP ping/pong only starts afterwards. And the sample was taken *across the join stall*: `_on_connected_to_server` calls `enter_existing_game_scene()` without `await`, so it runs the synchronous `preload(world1.tscn)` and then suspends at `await process_frame` — and it was *during that suspension* that netfox's `on_client_start` listener fired the clock-sync request. The reply landed after two frames of D3D12 shader compilation, so the joiner seeded its whole tick origin from a reading seconds out of date. `NetworkTime.tick` is monotonic and netfox's clock-stretch servo closes the gap at only 25 %/s (`network-time.gd:523-537`), so a 10 s stall took ~40 s to heal — the "thousands of frames". Until it healed, `history_start = tick - history_limit` had moved past the host's live inputs, so they were discarded; the host then treated those ticks as predicted, stopped sending state for that player (`rollback-history-transmitter.gd:119-122`), freezing the client's `_latest_state_tick` at its spawn value — that frozen number is the constant `1968` in the log — which pinned `_resim_from` and clamped every rollback to 64. Look was unaffected because it is not rollback-synced (`body.gd:59-68`, `sync_rotation` commented out).
- **Not the cause** (both were checked and ruled out): `history_limit` — 64 is only where the divergence becomes *visible*; and `max_ticks_per_frame` — the tick loop's accumulator is bounded, and it fully catches up every frame it can, so it does not accrue a permanent deficit.
- **Fix applied (2026-09-24):**
  - `NetworkManager._take_over_client_time()` disconnects netfox's `on_client_start → NetworkTime.start()` listener; `_on_connected_to_server()` starts the loop itself, after `enter_existing_game_scene()` and a settle wait, so the clock round trip is short and the seed is correct. See `03-event-flow.md`.
  - A tick-domain watchdog (`NetworkManager._evaluate_resync` / `request_resync`) detects and repairs divergence as a safety net: the host broadcasts its tick at 1 Hz, the client compares and does a full `NetworkTime.stop()`/`start()` re-seed when the offset exceeds a quarter of the rollback window. It never resyncs the host.
  - The `max_ticks_per_frame` 8 → 60 bump from 2026-09-21 was aimed at the wrong mechanism and is now derived from `NetworkManager.CATCHUP_SECONDS` instead.
- **Tried & reverted:** raising `netfox/rollback/history_limit` (64 → 256) made the per-frame rollback re-sim worse and caused a connect timeout. That is explained by the pinning above — while `_resim_from` was pinned, the clamp replayed `history_limit` ticks every frame, so a bigger limit was 4× the work. With the origin fixed, a wider window is only memory; re-evaluate if more latency tolerance is needed.
- **`display/window/vsync/vsync_mode=1` was listed here as an applied fix. It was never set** — see the note in `04-optimization.md`. The effective value is Godot's default (vsync on).

### 19. Tickrate is per-session and scales rollback CPU
- **Files:** `network/network_manager.gd` (`server_tick_rate`, `apply_tick_rate`, `HISTORY_SECONDS`/`CATCHUP_SECONDS`), `project.godot` `[netfox]` (`time/tickrate` — the *default* only)
- **Symptom/risk:** `_rollback_tick` runs once per tick, so movement-sim cost per player is **proportional to the tick rate** (3× at 90 Hz vs 30 Hz) on the shared single core. A server choosing a high rate pays for it on every peer. `NetworkManager.MAX_TICK_RATE` (240) is the cap.
- **Watch for:** frame-time creep with many players/bots. If it regresses, lower the session rate (`tickrate <n>` in the console) rather than editing `project.godot`.
- **Superseded:** the old rule here was "any future tickrate change must re-visit `knockback_multiplier` (`60 / tickrate`)". That is no longer true — the knockback impulse is converted inside the physics-factor sandwich where it is integrated, so it is tick-rate independent and `knockback_multiplier` is a pure feel knob. See `02-netcode.md` §8.

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

### 20. Knockback was scaled by the render frame rate — `[FIXED 2026-09-24]`
- **Files:** `player/player.gd:1764-1772` (`_apply_movement_from_input`), `player/character.gd:65`
- **Symptom:** the same explosion or recoil impulse moved a player further the lower their frame rate — ~1.5× too strong at 60 fps, ~3.6× at 25 fps — so two players on one server disagreed.
- **Why:** `move_and_slide()` advances by whatever delta is current where it is called, and the rollback tick runs from `_process`, so it integrates with the *frame* delta. `velocity` was correctly wrapped in the `NetworkTime.physics_factor` sandwich to convert, but `knockback_velocity` was added *outside* it and so was left frame-delta scaled. `Character.knockback_multiplier`'s `0.667` default happened to cancel that at a nominal 60 fps, which is why it survived — it was never really `60 / tickrate`.
- **Resolution:** `velocity += knockback_velocity * NetworkTime.physics_factor`, and `knockback_multiplier` is now a pure per-character feel knob with default `1.0`. Knockback is unchanged at 90 Hz / 60 fps and correct at every other rate. `knockback_decay` was checked and left alone: it is applied as `decay * delta` with `delta == ticktime`, so `tickrate × ticktime == 1` already.

### 21. Noclip integrated with the wrong delta — `[FIXED 2026-09-24]`
- **Files:** `player/player.gd:1107-1113` (`_noclip_move`)
- **Symptom:** noclip flew at ~2/3 speed at 90 Hz / 60 fps, and its speed varied with both the tick rate and the frame rate.
- **Why:** the path integrates manually with the tick delta (`global_position += velocity * delta`) yet also applied the `physics_factor` multiply/divide, which exists only to convert between the tick delta and `move_and_slide()`'s delta — a delta this path never uses.
- **Resolution:** dropped both the multiply and the divide. `knockback_velocity` stays un-scaled here, matching what the normal path now stores. **This makes noclip ~1.5× faster at 60 fps than it was** — the old speed was the bug.

### 22. `netfox/rollback/input_redundancy` is dead config
- **Files:** `addons/netfox/rollback/network-rollback.gd:104-108`, `addons/netfox/encoder/redundant-history-encoder.gd:4`
- **Symptom:** setting `netfox/rollback/input_redundancy` changes nothing. The encoder's `redundancy` is hardcoded to `4` and nothing calls `set_redundancy()`; the setting is read but never wired. Effective loss tolerance is 4 ticks (44 ms at 90 Hz).
- **Why:** an unwired 1.35.3 gap. Worth knowing before anyone tunes it to fix packet loss.
- **Suggested fix:** none available without editing the addon. If loss tolerance becomes a problem, prefer `NetworkRollback.input_delay` (also a tick count — scale it by the rate) or lower the session tick rate.

### 23. `diff_ack_interval` is 0 → a full state send every tick
- **Files:** `player/player.tscn:446-452` (unset → `rollback-synchronizer.gd:53` default 0), `addons/netfox/rollback/composite/rollback-history-transmitter.gd:152-157`
- **Symptom:** because no peer ever acknowledges a diff, `_ackd_state` stays empty and the transmitter falls back to `_send_full_state` on every transmit — diff states are configured on but never actually used.
- **Why:** wasted bandwidth that scales with player count; not tick-domain related, but it interacts with join-time jitter.
- **Suggested fix:** set `diff_ack_interval` to ~16 on the Player's `RollbackSynchronizer` and measure with `NetworkPerformance.get_sent_state_props_ratio()` before/after.

### 24. `RollbackSynchronizer.get_last_known_input()` throws — bad call in netfox 1.35.3
- **Files:** `addons/netfox/rollback/rollback-synchronizer.gd:214`
- **Symptom:** calling it raises `Invalid call. Nonexistent function 'keys' in base 'RefCounted (_PropertyHistoryBuffer)'` and the caller gets a hard error instead of a tick. Hit from `NetworkManager._print_status()` on 2026-09-24.
- **Why:** the method returns `_inputs.keys().max()`, but `_inputs` is a `_PropertyHistoryBuffer`, which `extends _HistoryBuffer` — and `_HistoryBuffer` exposes `ticks()`, not `keys()`. (`_HistoryBuffer.ticks()` is itself `return _buffer.keys()`, so the addon's author reached one level too shallow.) Nothing inside netfox calls it, so the bug is dormant until project code does.
- **Resolution:** worked around in `network_manager.gd` — the same value is derived as `NetworkRollback.tick - get_input_age()`, which uses only the API that works.
- **Suggested fix if the addon is ever updated:** it should read `_inputs.ticks().max()`.

### 25. Lobby instantiation parsed ~50 MB of map scenes — `[FIXED 2026-09-24]`
- **Files:** `world/host_server_area.gd` (`_ready`), `world/host_menu.gd:257` (`_load_maps`), `network/connection_utils.gd:161-175` (`scan_map_data`), `maps/map_data.gd:10`, `maps/map_data/*.tres`
- **Symptom:** every lobby instantiation — boot, **join**, and every `return_to_lobby()` — stalled the main thread for **8–9.5 s**. Measured in the engine logs (`%APPDATA%\Godot\app_userdata\MultiplayerSystem3D\logs\`): `Game stalled for 9.1100s, assuming it was a pause`, alongside `FPS 123.6 | proc 7979.09ms | phys 0.68ms | drawCalls 0 | objs 0`. `phys 0.68 ms` against `proc 7979 ms` with zero draw calls rules out physics and rendering — pure main-thread script/resource work. Joins went from near-instant to many seconds.
- **Why:** `HostServer`'s `_ready()` unconditionally instantiated the host menu and added it to the root — **on every peer, including joining clients that can never host**. `host_menu._ready()` calls `ConnectionUtils.scan_map_data()`, which `load()`s all 11 `maps/map_data/*.tres`. Each of those declared `map_scene` as a **`PackedScene` ext_resource**, so `load()`ing the metadata parsed the referenced map's entire scene. `maps/bind.tscn` alone is **47.7 MB** (1233 `CollisionShape3D`, 2466 inline `ConcavePolygonShape3D`, 2466 `StaticBody3D`). Total ≈50 MB parsed synchronously, of which 47.7 MB was a map that was not even being loaded.
- **Why it also broke netfox sync:** the stall exceeded netfox's `stall_threshold` (1.0 s), so `network-time.gd:542-552` set `_was_paused` and **re-anchored `NetworkTime.tick`** — the only code path that moves the tick origin. The same stall also spanned the client's initial clock-sync round trip, so its seed landed stale. One stall, both symptoms.
- **Fix applied (2026-09-24):**
  - `MapData.map_scene: PackedScene` → **`map_scene_path: String`** (`maps/map_data.gd`), and all 11 `maps/map_data/*.tres` rewritten to store the path. Nothing ever needed the loaded scene: the only runtime consumer was `host_menu.gd` passing `_selected_map.map_scene.resource_path` to `NetworkManager.load_match_map()`.
  - `world/host_server_area.gd` now builds the host menu **on demand** (`_ensure_menu()`, leader-gated) instead of in `_ready()`.
  - `maps/map_game_mode_assigner.gd` and `maps/map_thumbnail_generator.gd` (both editor tools) updated for the path field.
- **Result:** the stall went **8–9.5 s → 1.648 s** measured headless. Steady-state `proc` is now 1.5–6.7 ms. The residual is entry #26.
- **Note:** `map_scene_path` is a plain string, so a typo now fails silently at "Start server" instead of crashing the editor. `ConnectionUtils.scan_map_data()` still does not validate that the path resolves.

### 26. Residual ~1.6 s lobby-load stall
- **Files:** `maps/main_menu_world.tscn` (157 `CSGBox3D` under 3 `CSGCombiner3D`; a `VoxelGI` with 474 KB of data; an `Environment` with SDFGI + SSAO + SSIL + SSR + glow + volumetric fog + panorama sky)
- **Symptom:** after #25, a single ~1.6 s frame remains at lobby instantiation (the frame that prints `MAP ADDED res://maps/main_menu_world.tscn` / `Player 1 added`). It still exceeds netfox's 1 s `stall_threshold`, so netfox still logs `Game stalled for 1.6480s` and re-anchors the tick once, and the first rollback after it clamps (`Trying to run rollback for ticks 0 to 149, past the history limit of 63`) before settling.
- **Why:** CSG combiners rebuild their mesh on dirtiness, and 157 boxes is a known-slow CSG tree; the VoxelGI and the SDFGI/SSAO/SSIL/SSR environment add pipeline and IBL setup. Headless cannot see the D3D12 shader compilation that a real client also pays here, so the on-GPU figure is likely higher.
- **Suggested fix:** re-author the lobby as static meshes instead of CSG; consider dropping SDFGI/SSIL for the lobby. Alternatively raise `netfox/time/stall_threshold` to ~2.5 s so a load hitch is not misread as a pause — but that also delays genuine stall recovery, so prefer fixing the content.
- **Not the cost** (measured/checked, do not chase): `loadout_menu`'s character preview (`[DEBUG PREVIEW] spawned … in 4.01 ms`) and the 3 class `.tres` parse.

### 27. `AnimationNodeBlendTree.get_node()` errors on every shot — `[FIXED 2026-09-24]`
- **Files:** `weapon/weapon_model.gd:196` (`_play_tree_oneshot`), `player/weapon_controller.gd:957` (`_play_weapon_human_reload_anim`)
- **Symptom:** the debugger fills with
  ```
  ERROR: Parameter "node" is null.
	 at: get_node (scene/animation/animation_blend_tree.cpp:1526)
	 [0] _play_tree_oneshot  (weapon/weapon_model.gd:196)
	 [1] play_anim_scaled    (weapon/weapon_model.gd:158)
	 [2] _play_weapon_shoot_anim (weapon_controller.gd:855)
  ```
  once per shot — 26 times in one session — alongside a bare `print(nodes["anim"])` that dumps the slot name.
- **Why:** both sites did `var node := tree.get_node(name)` and then checked the result for null. But `AnimationNodeBlendTree.get_node()` is an `ERR_FAIL_V_MSG` for a name that isn't on the tree — it raises a hard error and aborts the call, so **the null check could never run**. The "node not found in blend tree" branch in `weapon_controller.gd` was written for exactly this case and was dead code.
- **Underlying cause (still open):** at least one weapon's `AnimationTree` blend tree has *some* slots but not others — observed: `PulloutAnim` resolved fine while `ShootAnim` did not, for the same weapon. That weapon now silently uses the legacy playback path for the missing slot instead of erroring. **The weapon's animation tree resource should be fixed**; the new guard only stops it polluting the debugger.
- **Fix applied:** `if not tree.has_node(...)` before `get_node(...)` at both sites, returning false / printing the existing diagnostic.
- **Also seen but left alone:** the bare `print(nodes["anim"])` at `weapon_model.gd:195` and the `[reload-debug]` prints in `weapon_controller.gd` look like deliberate debug instrumentation — remove them when the animation work is finished.

### 28. Rocket + syringe projectiles replicate as the mesh-less base scene — `[FIXED 2026-09-25]`
- **Files:** `weapon/assault_weapons/rocket_launcher.tres:81`, `weapon/assistance_weapons/syringe_gun.tres:83` (the actual cause); `player/weapon_controller.gd`, `world/world1.tscn`, `player/player.tscn` (the parent move, change #2 below)
- **Symptom:** a joining client saw projectile nodes that existed and were `visible = true` but had **no `MeshInstance3D` children at all** — not hidden, never created. Reproduced for the rocket launcher and the syringe gun; every other weapon was fine.
- **Why:** `MultiplayerSpawner` does not send a scene over the wire — it sends an **index into `_spawnable_scenes`**, which it resolves by matching the spawned node's `scene_file_path` against each entry's `Resource.get_path()`. Those two weapons stored their projectile as an **inline `SubResource` `PackedScene`** (`PackedScene_ws514` / `PackedScene_pqaa0`) rather than a scene file. Both bundles are `base_scene: 0` inherited-scene packs whose base is `res://weapon/projectiles/scenes/simple_projectile.tscn` — **the one projectile scene in the folder with zero visual nodes** (its only children are `CollisionShape3D`, `MultiplayerSynchronizer`, `HitboxComponent`, `ExplosionComponent`). A sub-resource has no `res://….tscn` path, so the index that reached the wire resolved the receiving peer to the mesh-less base. The shooter's own peer rendered correctly because it instantiates the bundle locally.
- **Fix applied:** both `.tres` repointed at the real scenes — `rocket.tscn` (`uid://bo0edtxgakruc`) and `syringe.tscn` (`uid://daan6liu8ej2`). Both already existed, carry matching root overrides (same `node_ids`; rocket's `gravity_scale` / `linear_velocity` / hit modes / `align_to_velocity` are identical to the bundle's), and were already in the spawnable list. The bundles and their orphaned shape/mesh sub-resources were deleted.
- **Behaviour delta:** the syringe bundle was a *stale* snapshot of the scene — `linear_velocity` `(0,0,-20)`, no `align_to_velocity`, no `can_hit_shooter`. `syringe.tscn` has `(0,0,-25)`, `align_to_velocity = true` and `can_hit_shooter = true`. The scene file wins, so the syringe now flies 25 % faster, orients along its velocity, and could heal its own shooter (**since removed** — `syringe.tscn`'s `HitboxComponent` no longer sets `can_hit_shooter`, so a syringe passes through the medic who fired it; see `02-netcode.md` §3 "Which targets a projectile can hit"). This makes the shooter's local projectile match what peers actually receive — before, the two could never agree.
- **Side effect (fixed):** `player/bot_controller.gd:585` keys its projectile-prediction cache on `fire.projectile_scene.resource_path`, which was `""` for both of these — so rocket and syringe collided in one cache entry and bot lead prediction was wrong for both.
- **Superseded:** the earlier `[FIXED 2026-09-24]` dedup of `_spawnable_scenes` was correct hygiene but was **not** the cause of this symptom. Its "resolves by position" claim never applied to it; the resolution is by **path**, which is what makes a sub-resource unresolvable at all.
- **Earlier fix, still valid:** `auto_projectile_spawner.gd`'s `@tool` `scan_projectiles` setter used to call `add_spawnable_scene()` for every file on every run, guarded only by a plain `_registered` member that resets each editor session — so each generation appended another full pass, and the list reached 96 entries for 17 distinct scenes. `_scan_and_register()` now collects into a local array, **sorts it**, calls `clear_spawnable_scenes()`, and re-adds, so the result is deduped, deterministic and immune to filesystem enumeration order.
- **Related change:** projectile parenting moved off the Player. `ProjectilesParent` + `ProjectileSpawner` now live on the world (`world/world1.tscn`), reached through `GameManager.projectile_parent`. Two reasons: `Player.despawn()` calls `hide()`, which cascaded to the `top_level` `ProjectilesParent` and made a dead player's in-flight projectiles invisible; and a Player is freed on disconnect, taking its projectiles with it.

### 29. All 10 maps still carry a dead `ProjectilesParent`/`ProjectileSpawner`
- **Files:** `maps/2fort.tscn:78-83`, `main_menu_world.tscn:281-286`, `castle`, `koth_castle`, `hyb_castle`, `esc_castle`, `dom_castle`, `death_pit`, `death_castle`, `bind.tscn:13635-13640`
- **Symptom:** none today — nothing adds a node under a map's `ProjectilesParent`, so the spawner never fires. But each one still holds the stale **12-entry / 7-distinct** list (only 7 of the 17 projectile scenes), the same shape that produced #28.
- **Why it matters:** they are a trap. Anyone who repoints a projectile parent at a map gets a spawner whose list is short, duplicated and unsorted — i.e. exactly the failure mode #28 describes.
- **Suggested fix:** delete the two nodes from each map, or at minimum regenerate their `_spawnable_scenes` with the same sorted 17-entry list. `bind.tscn` is 47 MB, so this is not a cheap diff — hence left out of the #28 change.

### 30. `SimpleProjectile.hide_model` is `@rpc("any_peer")`
- **File:** `weapon/projectiles/simple_projectile.gd:155-159`
- **Symptom:** none observed. `start_explode()` calls `hide_model.rpc()`; because the config is `any_peer`, **any** peer can hide the meshes of **any** projectile in the session.
- **Why it matters:** a remote-triggerable visual kill switch, and it targets meshes specifically — the same visible symptom as #28, which makes it a plausible red herring during future debugging.
- **Suggested fix:** change to `@rpc("authority", "call_local", "reliable")`. It is only ever called from `start_explode()`, which is already authority-gated.

### 31. Status-effect teardown re-entered itself — stack overflow on death while enlarged — `[FIXED 2026-09-25]`
- **Files:** `components/status_effect/status_effect_manager.gd` (`remove_effect`, `_tick_server`), `components/status_effect/effects/size_change_effect.gd` (`_on_remove`)
- **Symptom:** the host crashed with `Stack overflow (stack size: 1024). Check for infinite recursion in your script.` It was reproducible: **be enlarged (Rampage) and die.** The old TODO at `status_effect_manager.gd:159` had already flagged the line as the suspect without diagnosing it.
- **Naming note:** when this was found the effect was `EnlargeEffect` (`enlarge_effect.gd`) with id `enlarge`, applied by `RampageAbility`. It has since been generalized to `SizeChangeEffect` / id `size_change` / the `Size Change` ability (see #34). The trace below keeps the names it had at the time; only the paths are current.
- **Why:** `remove_effect` called `_on_remove` **before** erasing the effect from `_active_effects`, so the effect was still registered for the whole duration of its own teardown. `EnlargeEffect._on_remove` then wrote `attribute_component.health = minf(health, base_max)` — and `AttributeComponent.health` is a **setter** that emits `no_health` whenever the assigned value lands at `<= 0`:

  ```
  lethal damage          -> health = 0 -> no_health.emit()
  Player.no_health()     -> status_effect_manager.clear_all_effects()
  clear_all_effects()    -> remove_effect("enlarge")
  remove_effect()        -> enlarge._on_remove()      [still registered!]
  _on_remove()           -> health = minf(0, 100) = 0 -> no_health.emit()
  ...                    -> unbounded
  ```

  Dying while enlarged is the *common* case — the buff doubles max health, it doesn't stop you dying — so the assignment always ran with `health == 0`. Exactly one effect writes health in its teardown, which is why only enlarge could trigger it.
- **Fix applied (two layers, deliberately):**
  1. **`remove_effect` and `_tick_server` now deregister before tearing down.** The id is erased from `_active_effects` (and the client mirror) *before* `_on_remove` runs, so any re-entry finds nothing and returns. This fixes the class of bug for every effect, present and future, not just the one that crashed.
  2. **`EnlargeEffect._on_remove` no longer writes a non-positive health.** It still always restores `starting_health` (skipping that would leave the next life at double max HP), but only clamps `health` **downward** and only when it exceeds the restored max — so the dead case writes nothing. `SizeChangeEffect._on_remove` carries the same guard forward (every health write is behind `if ac.health > 0.0`) — **if you add a health write to any effect teardown, you must do the same.**
- **Also corrected while in there:** `_tick_server` iterated the live `_active_effects` dictionary. An effect's teardown can remove other effects through this manager, which invalidates that iteration. It now walks a `keys()` snapshot and skips ids removed earlier in the same pass.
- **Verification:** get the enlarge effect (Size Change ability), take lethal damage while it is active. Before: instant stack overflow on the host. After: normal death, ragdoll spawns once, respawn at base max health.
- **Residual risk:** see #32.

### 32. `Player.no_health()` is not idempotent
- **Files:** `player/player.gd:670-692` (`no_health`), `components/attribute_component.gd` (`health` setter)
- **Symptom:** none observed after #31. But the death path has no re-entry guard: any second `no_health` on the same life re-runs `clear_all_effects()`, `_spawn_ragdoll.rpc(...)` and `rpc_reset.rpc(...)` — a second ragdoll and a second respawn reset.
- **Why it matters:** the `health` setter emits `no_health` on *every* assignment that lands at `<= 0`, not on a transition into death. Any code that writes health while the player is already dead (a new status effect doing what EnlargeEffect used to, an environmental damage tick, a clamp) re-enters the whole death path. #31 closed the one path that reached it; the shape of the hazard is unchanged. `SizeChangeEffect` is the current live example of code that has to be careful here — it writes `health` in *both* `_on_apply` and `_on_remove`.
- **Suggested fix:** guard the server branch on a transition — e.g. an `_is_dead` flag set at the top of `no_health()` and cleared in `rpc_reset` — or track the previous health in `AttributeComponent.apply_health_delta` (which already computes `old_health`) and only emit when `old_health > 0.0 and new_health <= 0.0`.

### 33. The `blocks_actions` channel lock is not enforced on movement
- **Files:** `components/status_effect/status_effect_manager.gd` (`_client_blocks_actions`, `is_action_blocked`), `player/player_input.gd:84-97` / `:115-121`, `player/abilities/ability_manager.gd` (`_input`, `_cast_ability`), `player/weapon_controller.gd:1966-1971`, `player/bot_controller.gd:196-201`
- **Introduced by:** the heal-over-time action lock (`HealAbility.block_actions_during_heal`). Recorded rather than fixed — the movement half is a deliberate trade-off, but it should be a known one.
- **Symptom:** a player channeling a locked heal can still be *moving* for the first ~100 ms of the channel, and a modified client can keep moving for the entire channel.
- **Why:** `blocks_actions` is applied server-side on cast, but the gate that reads it runs on the **owning client**, and the flag only reaches that client with the next effect-mirror push — up to `TICK_INTERVAL` (0.1 s) later. That latency is inherited from `stun`/`pinned`, which have it too.
- **What *is* enforced:** casting and firing both have server backstops (`AbilityManager._cast_ability`, `WeaponController.fire_intent` reject while `is_action_blocked()`), so a client cannot cheat an ability or a shot out of the lock — the ~100 ms window only leaks *input*, not effects. **Movement is the exception**, and cannot cheaply be otherwise: movement is rollback-simulated from client-authored input, so the server has no independent notion of "this player's input should be zero" — rejecting movement input mid-rollback would fight the netfox state correction and desync the very thing rollback exists to keep smooth.
- **Why it matters:** for a self-cast, self-inflicted heal the exploit is close to worthless (you are only cheating yourself out of a heal you already cast), which is why this is Medium and not High. It becomes a real problem the moment the lock is used for something an enemy applies — a "revive channel", a "capture hold" — where movement is exactly what the victim wants to keep.
- **Suggested fix (if it is ever needed):** make the *server* the gate for movement too, by having the movement path read a server-authoritative lock rather than the client mirror — either replicate the lock as a `Player` property inside the existing `MultiplayerSynchronizer` (so the server's own value is the one `_gather` reads via `is_multiplayer_authority()`), or drop the client-side `_gather` gate entirely and let the server zero the player's `input_dir` in `_rollback_tick`. Both are more invasive than the current design and should only be done for a lock whose bypass actually matters.

### 34. Late joiners rendered size-changed players at 1.0× — `[FIXED 2026-09-25]`
- **Files:** `player/player.gd` (`rpc_sync_full_state`, `_rpc_size_change`), `world/spawn_manager.gd` (`_sync_existing_players_to_peer`)
- **Found while:** generalizing the Rampage ability into `SizeChangeEffect`. Pre-existing since the effect was written.
- **Symptom:** a player who joined a server **while someone was enlarged** saw that player at normal size, while their own HUD status bar and effect list correctly read "Enlarged". No desync, no error — just a wrong-looking model until the buff expired.
- **Why:** the size and buffed max health are carried by `_rpc_size_change`, which is a **one-shot broadcast** fired the moment the effect is applied. A peer that connects afterwards never receives it, so its freshly instantiated copy of that `Player` keeps the `_size_scale = 1.0` default. The late-join path did push the *effect mirror* (`_sync_to_clients(peer_id)` in `spawn_manager.gd`), which is exactly why the HUD was right and the model was wrong — a good reminder that the mirror is UI state, not simulation state.
- **Fix:** `rpc_sync_full_state` — already the designated "full state for a late joiner" hook, and already called per-player from `_sync_existing_players_to_peer` — now carries `size_mult` and `health_mult` too. Both are read **live** off the player (`_size_scale`, `attribute_component.max_health_mult`) rather than derived from the effect, so they are correct with or without a buff active (both are `1.0` when none is). The block is applied **after** the character block, because `set_character()` derives `starting_health` from the character's `health_mult`. *(The second parameter became a multiplier rather than an absolute max health in #36.)*
- **Verification:** host casts Size Change, then a second instance joins. Before: joiner saw a normal-sized host. After: correct doubled size, and the joiner's HP-bar ratio for that player is right.

### 35. The size/shrink RPC was `@rpc("any_peer")` while writing `starting_health` — `[FIXED 2026-09-25]`
- **Files:** `player/player.gd:1377-1390` (`_rpc_size_change`, formerly `_rpc_enlarge`)
- **Found while:** the same generalization as #34.
- **Symptom:** none exploitable in practice — but any client could call this RPC on any player and set `AttributeComponent.starting_health`, i.e. grant itself (or another player) an arbitrary max HP. Max health is otherwise server-authoritative, so this was a hole in that invariant.
- **Why it matters:** a `@rpc("any_peer")` function that writes authoritative state is the same defect class as #7 (`fire_intent` has no sender validation) and #3 (`_sync_mag`). It is easy to miss because the RPC is *only ever called by the server* in normal operation — the annotation, not the call sites, is what grants the permission.
- **Fix:** `@rpc("any_peer", ...)` → `@rpc("authority", ...)`. Behaviour is unchanged: `SizeChangeEffect` only calls it from `_on_apply`/`_on_remove`, which run server-side, and the server applies the change to itself via `set_size_scale()` *before* the `.rpc()` — which under `call_remote` does not execute on the caller anyway.
- **Also fixed:** the `SizeChangeEffect._on_remove` path used to broadcast unconditionally, including for a dead player; it still does (the scale and max must revert), but it no longer writes `health` when `health == 0`. See #31/#32.
- **Verification:** enlarge and shrink a player from the host, confirm both the host's and a client's view of the scale and max HP track correctly; a client calling the RPC directly is now rejected.

### 36. Size effects corrupted max health permanently — `[FIXED 2026-09-25]`
- **Files:** `components/status_effect/effects/size_change_effect.gd`,
  `components/attribute_component.gd`, `player/player.gd` (`_size_scale` / `_size_multipliers`)
- **Symptom:** two distinct reports that turned out to be one bug. A player's HUD showed
  **`1/0`** health and they were effectively dead/unkillable-degenerate; or their max health grew
  without bound so they read as **invincible**. Both were **permanent** — they survived death,
  respawn, and every subsequent life.
- **Why — `starting_health` was both the character's base health *and* the live max:**

  ```gdscript
  var base_max: float = ac.starting_health   # captures the LIVE max, not the base
  ac.starting_health = new_max               # overwrites the base with a derived value
  ```

  `_on_remove` wrote the captured value back, which is correct only if every effect expires
  cleanly. They don't: `apply_effect` **replaces** the `_active_effects` entry when a non-negative
  effect of the same id arrives, and the outgoing effect's `_on_remove` **never runs** — so the
  captured base is lost and the incoming effect captures an already-scaled max as its new base.
  Every replace compounds.
- **Why the two symptoms differ:** only the direction. Reproduced by porting the effect and
  `apply_effect` verbatim:

  ```
  shrink lands, enlarge replaces it          enlarge lands, shrink replaces it
	start     max=100.0                        start     max=100.0
	cycle 1   max= 25.0                        cycle 1   max= 200.0
	cycle 2   max=  6.25                       cycle 2   max= 400.0
	cycle 3   max=  1.5625                     cycle 3   max= 800.0
	cycle 4   max=  0.3906  HUD="1/0"          cycle 4   max=1600.0  <-- "invincible"
  ```

  `1/0` specifically is the HUD's formatting: `player_ui.gd:955` is `"%d" % ceili(hp)` and `:956` is
  `"/%d" % int(max_hp)`, so `0.39` renders as `1` on top and `0` underneath.
- **What made it loop:** `size_change.tres` (enlarge, ×2) and the shrink shared
  `effect_id = "size_change"`. `StatusEffectManager._active_effects` is keyed by id, so the second
  one **replaced** the first rather than coexisting — the replace path is what dropped the teardown.
  The field medic's inline shrink was additionally `is_negative = false` (Godot omits the field
  because it matches `_init()`'s default), so it took the replace path too and was never cleansed.
- **Fix — the effect no longer touches health at all.**
  1. `AttributeComponent` gained a **registry** of max-health multipliers keyed by effect id
     (`add_max_health_multiplier` / `remove_max_health_multiplier`), with `max_health` **derived** as
	 `starting_health * product`. `starting_health` is now the character's base and is written only
	 by `Player.set_character()`. `Player` got the same shape for size (`_size_multipliers`).
  2. Because the base is immutable and the registry is keyed, **removing a missed teardown can no
	 longer corrupt anything** — the factor is simply absent and the derived value is right. The
	 replace path is now harmless.
  3. `size_change_effect.gd` registers/removes the two multipliers and nothing else. The entire
	 `state["base_max_health"]` capture/restore and every health write are gone.
  4. Enlarge and shrink were split onto **distinct effect ids** (`enlarge` / `shrink`) so they can
	 coexist and **stack multiplicatively** — shrunk to 0.25 and grown by 2.0 is 0.5. That is what
	 the user asked for, and it also removes the replace-collision entirely.
  5. Current health **follows the ratio** across a max change (`new_max / old_max`), which is the
	 agreed behaviour: `100/100 → 50/50 → 25 dmg → 25/50 → expire → 50/100`. It writes only when the
	 value moves and **never while `health <= 0`**, so it also stays clear of #31/#32.
- **Verification:** a standalone `AttributeComponent` harness replays the corrupting sequence —
  200 alternating add/remove cycles — and `max_health` returns to exactly `100.0` every cycle
  (previously: 0.0244 or 1600). Also asserted: stacking to 0.5, exact restoration on removal,
  the ratio table above, no write for `health_mult = 1.0`, no revive/re-emit for a dead player, and
  `reset()` clearing the registry. All pass.
- **Follow-up (same day) — stacking.** The first cut of this fix left same-id applications still
  *extending* duration rather than compounding (verified: two shrinks produced one entry with
  `remaining` 10.0, and the second effect object was discarded entirely). That is the normal rule
  for negative effects, but it is wrong for size. `StatusEffect` gained an opt-in
  **`stacks`** flag; `apply_effect` duplicates the effect and stamps a per-application id
  (`shrink#<instance_id>`) *before* the merge branch, so each application holds its own duration and
  registers its own multiplier key. `SizeChangeEffect` sets `stacks = true` in `_init()`, so both
  directions compound: two 0.25 shrinks → 0.0625, two ×2 enlarges → 400 on a 100 base.
  - Because the id now carries a suffix, lookups by literal id go through
	`StatusEffectManager.base_effect_id()` (`has_effect` falls back to a base-id match; the HUD
	material lookup normalizes). Every existing `has_effect`/`remove_effect` call site uses a
	non-stacking id, so none changed behaviour — `burn`/`slow`/`poison`/`stun` still extend.
  - `apply_effect` duplicates **before** stamping, so the shared `.tres` an ability or weapon holds
	is never mutated — a weapon applying its `status_effects` entry directly would otherwise rewrite
	the resource on disk. Asserted in the harness.

### 37. Ragdoll spawned at normal size for a shrunk/enlarged player — `[FIXED 2026-09-25]`
- **Files:** `player/player.gd` (`no_health`, `_spawn_ragdoll`)
- **Found while:** adding ragdoll scaling for the size effect — it turned out to be an ordering bug rather than a missing feature.
- **Symptom:** die while shrunk or enlarged and the corpse flopped out at **normal size**. Reproduced directly: `player.scale` was `0.5` when alive, `1.0` by the time the ragdoll was built.
- **Why:** `no_health()` cleansed status effects *before* sampling the corpse transform:

  ```gdscript
  status_effect_manager.clear_all_effects()          # -> SizeChangeEffect._on_remove
													 # -> remove_size_multiplier -> set_size_scale(1.0)
  _spawn_ragdoll.rpc(mannequin.global_transform, …)  # sampled too late: scale already 1.0
  ```

  `mannequin` is `$Body/Mannequin` — a child of the scaled Player root, with no `top_level` anywhere in the chain — so its `global_transform` *does* carry the size multiplier. `_spawn_ragdoll` assigns that transform straight to the corpse root, which is exactly the mechanism that should have scaled it. Nothing was missing; the value was just read one step too late.
- **Fix:** capture `mannequin.global_transform` into a local **before** the cleanse and pass that to the RPC. Two lines, no new state. Works on remote peers unchanged — they receive the server's captured transform over the RPC.
- **Verification:** a harness drives the real effect → cleanse → `_spawn_ragdoll` order for four cases — none, `shrink` (0.5), `size_change` (2.0), and a double shrink (0.25) — and asserts the corpse's scale (root *and* mesh, i.e. what the player actually sees) matches. All four pass. The residual ±0.001 is the mannequin's own animated node scale, present pre-fix at normal size too.
- **Note:** the ordering hazard is general — anything that samples the player's transform *after* `clear_all_effects()` in the death path will read a reset size. `despawn()`/`spawn()` also cleanse, but neither samples a transform.
- **Residual — the scale reaches the drawn model, not the bone colliders.** Scaling the corpse root scales the whole subtree, so every `MeshInstance3D` is correct and the proportions look right. But `PhysicalBone3D` does not scale its physics collider (Godot does not support scale on physics bodies), so only the bone *spacing* shrinks — the collider *sizes* stay at full size. Measured world-space AABB of a 0.5× corpse:

  | | normal | shrunk 0.5 | ratio |
  |---|---|---|---|
  | drawn (meshes) | `0.89 × 1.77 × 0.38` | `0.45 × 0.89 × 0.19` | **exactly 0.5** |
  | physics (colliders) | `0.61 × 1.78 × 1.28` | `0.51 × 1.18 × 0.80` | 0.67, not 0.5 |

  So a shrunk corpse carries oversized invisible colliders relative to its model and may settle slightly high; an enlarged one may sink slightly. **The mismatch is pre-existing in kind** — even at normal size the colliders are far fatter than the mesh (1.28 deep vs 0.38 drawn), because they are per-bone shapes that bulge past the skin. Acceptable for a 25 s cosmetic prop that only collides with world geometry; revisit only if shrunk corpses resting on the floor starts looking wrong.

### 38. Projectile damage amp is stamped server-side only, so shield absorption diverges per peer
- **Files:** `player/weapon_controller.gd:2398-2405` (`_spawn_projectile`), `player/shield.gd:202-217` (`_on_hurt_or_heal`, `_on_area_entered`)
- **Introduced by:** the change that made `Character.damage_amp_mult` apply to projectiles (previously it only reached hitscan, via `_apply_damage_direct`).
- **Symptom:** none observed yet. A projectile fired by a character with `damage_amp_mult != 1.0` (Stalker `0.17`, Nerd `0.9`) absorbs a different amount of shield HP on the shooter's/victim's machine than on the host's.
- **Why:** the amp is folded into `HitboxComponent.health_delta` / `ExplosionComponent.splash_health_delta` **at spawn**, and `_spawn_projectile` only ever runs on the server — `_fire_projectile` early-returns unless `multiplayer.is_server()` (`weapon_controller.gd:1926`), and `_spawn_projectile_on_server` is only ever invoked as `rpc_id(1, …)` (`weapon_controller.gd:2257`), though it validates neither sender nor authority itself (the `any_peer` hole in #7). The projectile's `MultiplayerSynchronizer` replicates only `global_transform` and `shooter_name` (`weapon/projectiles/scenes/simple_projectile.tscn`), so every other peer instantiates the scene with the **authored, un-amped** damage. That is harmless for *player* damage — `HurtComponent` is gated on authority, so only the server applies it — but `PlayerShield.absorb_damage` has **no authority gate at all**: it mutates a purely local `hp` mirrored into `fire.shield_current_hp`, so whichever peer sees the overlap absorbs with its own copy of `health_delta`.
- **Scope:** it widens an inconsistency that already exists rather than creating one — `shield.gd` also ignores `enemy_delta_multiplier` (the syringe's `-2.0` never reaches it), and shield HP is per-peer state either way (its regen in `_process` is un-gated too).
- **Suggested fix:** the real one is to make the shield server-authoritative — gate `absorb_damage` on `multiplayer.is_server()` and have clients mirror `shield_current_hp` the way they mirror player health. If that is too invasive, the cheap mitigation is to keep the amp out of the *projectile* and apply it on the hurt side instead (`HurtComponent`), which is where the other per-target multipliers already live — but note that requires teaching `shield.gd` the same multiplier to stay consistent.

---

## Not bugs, but worth knowing

- **Property overrides written into an instanced sub-scene are never saved.** Godot serializes overrides only on an instance's *root*. In `maps/koth_castle.tscn` every piece of geometry is `instance=ExtResource(<glb>)`, and each GLB's root is a `Node3D` with the `MeshInstance3D` one level **inside** it — `Block_16x16x2__col2` → `Block 16x16x2` → `StaticBody3D` → `CollisionShape3D`. So a `material_override` set on one of those 106 meshes is dropped on save: the edit looks like it worked right up until you reopen the map. Only properties on the map's *own* nodes survive, which is why `MaterialReplacer`'s `material` (the `ExtResource("7_hufvf")` on `Geometry`) round-trips fine while everything derived from it does not. Any future editor tool that mutates descendants of an instance hits the same wall.
- **The workaround, and why `MaterialReplacer` has an `apply_on_ready`.** Treat the derived state as derived and re-derive it on load: `components/material_replacer.gd` applies in `_ready()`, which runs in the editor as well as in game, so the preview and the saved state agree and no override ever needs to be serialized. The alternative — marking all 106 instances `editable_instance` and baking the overrides in — puts ~106 node entries into the scene file for a purely cosmetic result. Note `run` (the tick-to-apply export) is *not* enough on its own for this reason; it exists only to re-apply after changing `material`, since editing the inspector does not re-run `_ready`.
- **`ERROR: Couldn't create an ENet host. / Parameter "host" is null.` is the expected second-instance path.** `enet_host_create()` returns NULL when UDP `NetworkManager.SERVER_PORT` (8080) is already bound, and Godot logs the C++ failure *before* returning the code that `create_server()` catches on the next line — so it prints on the way into a handled branch and reads like a crash. Whichever instance prints `Server created!` is the host; the one printing this is the joiner and should use "Join Local". Confirmed across every two-instance run: the error appears in every second-instance log and no first-instance log, always paired with `Port 8080 in use — falling back to offline peer.`  To check for a real conflict (another instance or a leftover process), use `netstat -ano -p UDP | findstr :8080` — a **TCP** check will not show it, ENet is UDP.

## Lower priority (recorded, not blocking)

These are real but not current bottlenecks — revisit only if profiling flags them.

- `player/animation_tree.gd:23-85` — per-frame `$` lookups + string-keyed param writes + `basis.inverse()`.
- `player/skin.gd:119-143` — no own-model gate; runs per-frame for every replicated player.
- `player/rim_pivot.gd:24-38` — per-frame `get_camera_3d()` + `look_at` per non-own model.
- `world/payload/payload.gd:121-392` — per-frame label string formatting + `_tick_healing` per pusher.
- `weapon/projectiles/simple_projectile.gd:90-138` — per-physics-frame curve sample + distance math per projectile.
- `player/weapon_controller.gd:737,756` / `player/player.gd:2364,600-635` — `find_children` recursive scans on spawn/tier-change (not per-frame).
- `player/bot_controller.gd:628`, `maps/map_game_mode_assigner.gd:89` — raw `free()` (safe today: unparented / editor-only, but fragile).
- `ui/main_menu.gd:236,241,248-250` — calls `NetworkManager.create_client()` / `enter_existing_game_scene()` directly. Dead today (the 2D menu is bypassed), but those entry points no longer start a tick loop or hide the loading screen on their own; a revived menu would produce a client that can look and shoot but not move. Route it through `NetworkManager.join_party()`.
- `network/network_manager.gd` `_await_settled()` — on a machine that never gets two consecutive frames under `SETTLE_FRAME_SECONDS` (10 fps), a join waits the full `SETTLE_TIMEOUT_SECONDS` (5 s) behind the loading screen before starting the tick loop. It logs a debug warning when it gives up; tune the threshold if this ever bites.
