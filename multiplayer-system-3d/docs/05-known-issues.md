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
| 39 | 🟡 Medium | Correctness | ✅ FIXED — Hitscan stopped on bodies it could not hurt (yourself, teammates) instead of passing through |
| 40 | 🔴 Critical | Correctness | ✅ FIXED — Invisible weapon `BoundingBox` areas stopped every shot → impacts in mid-air |
| 41 | 🟡 Medium | Netcode | A charged weapon's movement penalty reaches observers one RTT late (the draw is broadcast state, not rollback state) |
| 42 | 🟡 Medium | Netcode | A duplicated `fire_intent` on a charged weapon spends a full shot at **zero** charge |
| 43 | 🟡 Medium | Netcode | `min_charge` is measured against the server's clock, which starts ~½ RTT after the player's |
| 44 | 🟡 Medium | Fragility | A bot stuck mid-draw holds the charge and its movement penalty through the whole force-wander |
| 45 | 🟡 Medium | UX | A draw cancelled below `min_charge` is completely silent |
| 46 | 🟡 Medium | Netcode | Ability charges are per-peer with no reconciliation; a boundary cast is refused and not refunded |
| 47 | 🟡 Medium | Netcode | A metered ability's pool is per-peer; a refused turn-on leaves the bar draining an ability that is not running |
| 47b | 🟡 Medium | Correctness | Noclip can expire inside geometry, where it re-enables collision |
| 52 | 🟡 Medium | Visuals | `painted_toon.gdshader`'s `light()` replaces the built-in path — brightness is pinned to an unchecked engine convention |
| 53 | 🟡 Medium | Visuals | The juggernaut renders darker under the toon swap than Burley-vs-Lambert explains; cause not isolated |
| 54 | 🟡 Medium | Fragility | Character material overrides sit on nodes inside an instanced GLB, with glTF-derived indices — a GLB re-import breaks them silently |
| 55 | 🟡 Medium | Fragility | The segmented health bar is driven by a per-frame push, because `max_health` is derived and emits no signal |
| 56 | 🟡 Medium | Assets | Ability icons depend on per-icon `.import` settings nothing asserts, and the icon library is ~8400 tracked files |
| 57 | 🟡 Medium | Fragility | A cross-script static call into a `class_name` widget drew a phantom "non-static function" error the editor would not clear |
| 58 | 🟡 Medium | Assets | Portrait lighting is reproduced from gitignored, machine-local editor state (`.godot/editor/*-editstate-*.cfg`) |
| 59 | 🟢 Low | Fragility | The asset generators strip `uid=` from every `.tres` they re-save |
| 60 | 🟡 Medium | Authoring | An entity `.tres` missing from `entity_definitions` is invisible to TrenchBroom, and builds as a bare `Marker3D` |
| 61 | 🟡 Medium | Authoring | `FuncGodotFGDModelPointClass.target_map_editor` defaults to `GENERIC`, so the display model exports as `studio` and TrenchBroom draws a box |
| 62 | 🟡 Medium | Tooling | The headless boot smoke test reports `Parse Error` on resources that are not broken — a different set every run |
| 63 | 🟡 Medium | Authoring | TrenchBroom silently refuses to rotate a point entity whose `size` box is not centred on XY — `R` just moves it |
| 64 | 🟡 Medium | Authoring | `generate_size_property` offsets the box by the average root-child position, which can leave the origin outside it — TrenchBroom then draws no model at all |
| 65 | 🟢 Low | Authoring | ✅ FIXED — A property-driven model scale only draws from the conditional form in the **model map**; five other placements left the prop undrawn |
| 66 | 🟡 Medium | Authoring | A **rigged** display model does not preview in TrenchBroom at all — bake a static one via `tools/bake_static_model.gd` |
| 67 | 🟡 Medium | Authoring | Entities generated by `tools/generate_prop_entities.gd` build with **no collision** — a raw model imports with no physics, so the prop is walk-through |
| 84 | 🟢 Low | Fragility | The character preview's ambient is a sky that only *works* because the SubViewport is transparent — removing `transparent_bg` draws it as an opaque backdrop |
| 104 | 🟡 Medium | Crash | ✅ FIXED — Removing a bot left dangling name lookups / node references; a projectile, DoT tick, stuck projectile or pusher list could deref the freed bot |
| 105 | 🟡 Medium | Correctness | Bot projectile lead ignores the shooter's `forward_boost` (and the actual fired recoil), so a fast-moving bot can slightly over-lead |
| 106 | 🟡 Medium | Correctness | ✅ FIXED — Bots aimed healing gravity projectiles at the impact point instead of along the lofted launch direction, so syringes fell short/low |
| 107 | 🟡 Medium | Fragility | FLEE/COVER/COMBAT can cycle when a critical bot has no reachable shelter — bounded by cooldowns, not eliminated |
| 108 | 🟡 Medium | Performance | Hunt-seed and flee-search ray bursts can coincide when many bots lose a target / drop critical together |
| 109 | 🟢 Low | Fragility | Damage taken while frozen or stunned is booked as one delta on the first free tick, so a bot can resume already at high threat pressure |
| 110 | 🟢 Low | Design | FLEE deliberately outranks medic self-heal below the flee threshold; a low-health medic runs before channelling |
| 111 | 🟢 Low | Fragility | Hunt sweep points are ray-validated, not graph-validated; an unreachable point costs the per-point timeout |
| 112 | 🟢 Low | Fragility | `_accept_self_damage` estimates the cost from the full authored splash value; real splash falls off with distance and can be scaled further, so a borderline self-damage shot can be accepted or refused slightly wrong |
| 113 | 🟢 Low | Limitation | A spectator's HUD shows a remote target's ability cooldowns/charges/meters as ready — those pools are per-peer and never networked |
| 114 | 🟢 Low | Fragility | First-person spectating hides the target's head meshes every frame on the spectator's copy; a character model with no `head_meshes` configured will clip |
| 115 | 🟢 Low | Memory | Spectator HUDs are built on demand and persist per watched target for the session |
| 116 | 🟢 Low | Correctness | A bot's character/weapon loadout is applied server-side with no broadcast, so a client's copy (and its spectator HUD) shows a bare mannequin |
| 138 | 🟠 High | Netcode | ✅ FIXED — Remote Player authority was the stable player id, not the ENet peer: body/aim sync rejected on every client; input ownership could stay empty |
| 139 | 🟡 Medium | Fragility | `HoldBlend` was authored at `0.0` and never written; it is now driven to `1.0` in combat, so the weapon-hold pose and one-shot arm chain are live for the first time |
| 140 | 🟠 High | Flow | Phase transition was server-local only: `MatchSession.set_phase()` broadcast ACTIVE but left the host's own `phase` at STAGING, so a later `welcome` carried a stale phase and host-side OR-checks saw the wrong room state. ✅ FIXED 2026-11-17 |
| 141 | 🟡 Medium | Flow | Party service is not implemented. The Globe Party tab is an explicit disabled placeholder; there is no PartyManager, party lobby allocation, follow, promote or kick. |
| 142 | 🟡 Medium | Flow | Staging team assignment is self-service `SWITCH TEAM` plus host `ADD BOT`; there is no host drag-and-drop assignment or team-balance validation yet. Ready is advisory and local/server-mirrored only. |
| 143 | 🟡 Medium | Flow | `GameManager.local_loadout` is process-local; it is not saved to disk. A process restart rolls a new build. |
| 144 | 🟡 Medium | Flow | The merged Find Match list shows only fields the sources actually provide. lobbyd still reports issued grants/`staging` (no live phase), and LAN has no ping/host name; do not add those columns without server status reporting. |
| 145 | 🟡 Medium | UX | ✅ FIXED 2026-11-18 — the `JoinParty` Area3D, its LAN/Direct popup and `world/match_browser.gd` are removed. The Match Menu's FIND MATCH tab is the only join UI. |
| 146 | 🟢 Low | Flow | Host migration is still the existing reserved-slot expiry path (90 s), not immediate promotion. A listen-server host quitting still ends the server. |
| 147 | 🟢 Low | Tooling | New test hooks: `--test-title-start`, `--test-staging-start`, `--test-staging-map=`, `--test-end-match`. They are debug-only paths in `world_1.gd`. |
| 148 | 🟡 Medium | Visuals | Weapon models are re-shaded at spawn by `WeaponToonMaterials`; transparency, `cull_mode` and `uv1_offset` are not carried |
| 149 | 🟠 High | Netcode | Join grants are temporarily advisory — any direct-IP join is accepted even when `MATCH_SECRET` is set (deliberate unblock for the public VPS) |
| 151 | 🟡 Medium | Correctness | Practice targets are `Player`s under `SpawnParent`; any "all Players are participants" scan that forgets `is_practice_target` silently mis-scopes it |
| 153 | 🟡 Medium | Netcode/UI | ✅ FIXED 2026-11-19 — Leaderboard showed the room host's ping as 0 ms on dedicated/VPS matches; the host row was forced to 0 before peer sampling |
| 154 | 🟠 High | Netcode | ✅ FIXED 2026-11-19 — Results auto-return left the netfox tick loop dead: look/shoot worked in the returned lobby, movement did not |
| 155 | 🟡 Medium | Flow | ✅ FIXED 2026-11-19 — A staging countdown coroutine could fire into the next session and swap the returned lobby to the match map |
| 156 | 🟢 Low | Assets/Perf | Toon FX are selected by bare preset strings; a typo silently falls back, the grenade presets and the Carpet Bomb explosion preset exist only in the project copies of the vendored tables, and stacked 18 s nuke presets allocate a 700-instance batch each |
| 158 | 🟡 Medium | Correctness | Water containment is an axis-aligned box approximation; rotated brushes leak water outside the brush |
| 159 | 🟢 Low | UX | WET can retrigger while bobbing on the waterline (no exit cooldown / hysteresis) |
| 160 | 🟡 Medium | AI | Bots have no swim intent and water adds no navmesh polygons |
| 161 | 🟢 Low | Perf/Visuals | Transparent double-sided water doubles rasterised area and sits in the per-object sorted transparent queue |


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
- **Resolution:** `_update_targeted_previews` now throttles `find_candidates` (the group query + LOS raycast + sort) to a 10 Hz interval (`PREVIEW_REFRESH_INTERVAL`), caching the ordered candidate list per ability in `_preview_candidates`; between refreshes the per-frame loop only re-projects discs from the cached list. `find_candidates` itself is unchanged — it remains the live one-shot cast path in `ability_manager.gd:206`.
- **Update (2026-09-27):** the projected thing is no longer a name `Label` but a `TargetedAbilityIcon` disc (icon + coloured rim), moved from above the enemy to beside them so it does not stack on the health bar. Same pool-and-reposition shape, so the cost above is unchanged: `set_preview()` early-returns unless the icon or colour moved, and the disc draws one `draw_circle` pair + one `draw_arc` + at most one `draw_texture_rect`, only on that redraw.
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
- **Files:** `player/weapon_controller.gd:2575-2614` (`_on_hitscan_hit`), `weapon/tracer.gd`, `effects/bullet_impact.gd`, `effects/bullet_decal.gd`
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
- **Files:** `player/weapon_controller.gd` (`_sync_mag`; reliable siblings `_sync_all_mags`, `_confirm_reload_done`)
- **Status:** fixed in P5. `_sync_mag` is now `@rpc("authority", "call_local", "reliable")`; clients cannot call it and a dropped packet no longer diverges the displayed magazine. Verified with the `--test-fire` client: authoritative mag counts arrive and decrement.

### 7. `fire_intent` has no sender validation
- **Files:** `player/weapon_controller.gd` (`fire_intent`)
- **Status:** fixed in P5. `fire_intent` calls `_rpc_sender_allowed()` (via `Player.is_rpc_sender_allowed`) before any ammo/fire work; only the owning peer or the server can fire a player's weapon. Verified by the cross-process fire test (`input_auth=true`, authoritative mag sync).

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

### 13. Explosion per-particle material dup + GLSL substring scan — `[RETIRED 2026-11-19]`
- **Files:** `effects/generic_explosion.gd:42-129`
- **Symptom:** `mat.duplicate(false)` / `material.duplicate()` per particle per explosion; `_shader_has_param` (`123`) does `param_name in mat.shader.code` (substring over full GLSL) per particle.
- **Why:** allocation + expensive string scan per particle.
- **Status:** nothing spawns `effects/explosion.tscn` any more; `ExplosionComponent._explode_visual` uses `effects/rocket_impact/`, which allocates its two `ShaderMaterial`s once and never per particle. The file remains only for the retired scene — if that scene is ever revived, fix this first.

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
- **Symptom:** none observed after #31. But the death path has no re-entry guard: any second `no_health` on the same life re-runs `clear_all_effects()`, `_spawn_ragdoll.rpc(...)` and `rpc_reset.rpc(...)` — a second respawn reset, and a second ragdoll spawn. *(The ragdoll half is now bounded: `_spawn_ragdoll` keeps one corpse per player by replacing the previous `Ragdoll_<player>`, so repeat deaths no longer accumulate corpses.)*
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

### 39. Hitscan stopped on bodies it could not hurt (self, teammates) — `[FIXED 2026-09-25]`
- **Files:** `player/weapon_controller.gd:2195-2236` (`_fire_single_shot`), `:2462` (`_hitscan_passes_through`), `player/player.tscn:479-482` (`HurtComponent2.hurtbox_components`)
- **Reported as:** "I can shoot my own hitbox with my own bullets when I shoot hitscan weapons", and then, more precisely: "impact effects land on my own model".
- **Root cause — it was never damage, it was *stopping*.** `_fire_single_shot` built `query.exclude` **by hand, every shot**, from `_hurt_component2.hurtbox_components` (`weapon_controller.gd:2195-2199`) plus the player body RID and the shield area. Anything not in that list *stopped the bullet*: the ray ended there, `_on_hitscan_hit.rpc` drew the impact/tracer/decal at that point, and — because `Player.FRIENDLY_FIRE_MULTIPLIER` is **0.0** (`player.gd:52`) — the hit dealt nothing. A teammate is tinted the same colour as you, so an impact on a teammate's body reads as an impact on your own.
- **Why it was invisible in the damage numbers:** the zero multiplier means `apply_health_delta(0)` early-returns. No damage number, no HP change, no hit sound — **only the impact visual**, which is exactly what got reported. Two consequences worth keeping in mind when triaging something similar: "no damage" never meant "no hit", and the impact visual is evidence that something *was* hit.
- **Fix applied:** hitscan now travels **through** bodies it cannot hurt, and stops only on ones it can. `_hitscan_passes_through()` (`weapon_controller.gd:2462`) allows exactly two cases — the shooter's own hurtboxes, and a teammate's while `FRIENDLY_FIRE_MULTIPLIER` is 0.0 outside FFA — and `_fire_single_shot` re-casts with each ignored collider's RID added to the exclude list, bounded by `MAX_HITSCAN_PASSES = 16` (`weapon_controller.gd:194`). Deployed shields are deliberately *not* passed through: they are physical barriers. The predicate is derived from the damage rule (`weapon_controller.gd:2266`, `2325`) rather than restating a team check, so the two cannot disagree.
- **This also closed the registry fragility** the entry was originally opened for: a hurtbox missing from `HurtComponent2.hurtbox_components` is still recognised as *mine* by its owner, so a shot can no longer stop on its own owner even with an incomplete list. The hand-built exclude list remains as the cheap first-line filter (it is what lets a shot pass the shooter without a re-cast), but it is no longer load-bearing for correctness.
- **Verified (Godot 4.7.2, real rigs, real ENet server peer).** Since a friendly hit already dealt nothing, "the teammate took no damage" could not tell *stopped on them* from *went through them* — so each case aimed at a second body aligned bone-exactly behind the first and asserted which one the server registered:
  - teammate in line, enemy behind (both controls confirm the geometry): `_hit_player='3'`, teammate ±0.0, **enemy −33** — travelled through and hit what's behind.
  - the same shot in **FFA**: `_hit_player='2'`, teammate −33, enemy untouched — correctly still stops, since same-team isn't friendly in FFA.
  - shot at one's **own** hurtbox with the registry emptied so only the predicate can catch it: travelled through **3** of the shooter's own hurtboxes, `_hit_player=''`, shooter ±0.0.
- **Residual — teammate ragdoll corpses still stop a bullet.** They are on the RAGDOLLS layer (in the hitscan mask) and `player.gd:676` strips their `HurtboxComponent`, so they are neither damageable nor identifiable as a teammate by owner. Passing through them needs a `find_ragdoll_corpse` check.
- **Also worth knowing — the shooter's own head cannot be hit from inside.** The FP camera sits inside the head capsule, and a ray that starts inside a shape never reports it (`hit_from_inside = false`), so the head was never reachable even before this fix. The reachable ones are the arm/weapon-hand bones in front of the camera, and those are what the new loop passes through.
- **Related bug found while measuring (NOT fixed — different direction, dormant):** `weapon_controller.gd:2119` calls `_apply_on_hit_effects(weapon_fire, player_name)` with the **victim's** name, while the function's parameter is `shooter_name` and both other call sites pass `_parent_player.name`. For a **SHOTGUN-mode** weapon that sets `self_health_delta_on_hit`, the self-effect would land on the *victim* instead of the shooter. Dormant today: the only two weapons setting that field (`weapon/assistance_weapons/bat.tres` "Katana" +35, `weapon/tf2/syringe.tres` "Poison Syringe" +100) are `multishot_mode = 2`, not SHOTGUN. One-line fix: pass `_parent_player.name`.
- **Two look-alikes still worth knowing** — both make *the shooter's own health change when their shot lands*, which reads as "I hit myself" if you are watching your HP: `WeaponFire.self_health_delta_on_hit` (`weapon_fire.gd:94`, applied to the shooter at `weapon_controller.gd:2489-2494`; Katana +35, Poison Syringe +100) and `Character.lifesteal_percent` (`character.gd:55`; Stalker 0.3, applied per landed hit at `weapon_controller.gd:2519-2522`).

### 40. Every weapon's invisible `BoundingBox` area stopped shots — impacts in mid-air — `[FIXED 2026-09-25]`
- **Files:** all 18 weapon-model scenes under `weapon/` (e.g. `weapon/assault_weapons/minigun.tscn:16`, `ak.tscn:213`), `player/weapon_controller.gd:2195-2199` (`_fire_single_shot`)
- **Reported as:** "when I use the minigun or any other weapon and move around I tend to hit something invisible (seems like my own hitbox) and I see decals in the air."
- **Symptom match, point for point:** invisible (`BoundingBox` has no mesh), moves with you (the weapon model is parented under the player's skeleton at `GunAttach`), affects every weapon (every weapon model scene has one), and the decal lands in mid-air (on the box's surface, off the model). The "seems like my own hitbox" reading was the giveaway — it *was* part of the player, just not a hurtbox.
- **Why:** each weapon model carries `BoundingBox` → `CollisionShape3D`, an authoring volume that `weapon/killfeed_icon_generator.gd:332` reads to frame the killfeed icon. Its own comment says "It does not need to participate in collision detection" — **but none of the 18 scenes ever set `collision_layer`, so every one sat on the default layer 1 (WORLD)**, which the hitscan mask `(1 << 0) | (1 << 2) | (1 << 7)` includes. So every shot stopped on the weapon's own box: `_on_hitscan_hit` drew the impact/tracer there and no damage was dealt (an `Area3D` is not a `HurtboxComponent`, so it went down the "hit world geometry" path).
- **Why the earlier pass-through fix (see #39) did not catch it:** that predicate only recognises `HurtboxComponent`s. This is an `Area3D` belonging to the shooter by *parentage*, not by owner-player — so the ray had no idea it was "mine".
- **Fix, both halves:**
  1. **`collision_layer = 0` / `collision_mask = 0` on all 18 authoring boxes** (mechanical edit to the `.tscn` files). This is the root cause and it also fixes the same symptom for *other* players' weapons — your shot used to stop on an enemy's invisible gun box too, which no shooter-side exclusion could ever have fixed.
  2. **`_fire_single_shot` now excludes every collision object the shooter owns**, by walking the player's subtree — `_parent_player.find_children("*", "CollisionObject3D", true, false)` — instead of appending only the 20 registered hurtboxes from `HurtComponent2.hurtbox_components` plus the shield. `owned = false` so colliders inside instanced sub-scenes (the weapon models, the shield scene) are included; the registry loop it replaces could only ever be as complete as whoever last added a collider to the rig. `_hurt_component2` is no longer referenced by the fire path. Cost is one subtree walk per shot (~300 nodes), not per frame.
- **Verified (Godot 4.7.2 headless):** fresh instances of `ak.tscn` / `minigun.tscn` / `shielded_minigun.tscn` report `layer=0 mask=0` on their `BoundingBox`; firing excludes the weapon model's area RID alongside the body and all 20 hurtboxes (22 RIDs).
- **Trap found while fixing it — never write `#` comments into a `.tscn`.** The first patch inserted explanatory `#` lines above the property; Godot's text resource format comments with **`;`**, so the `#` lines were parsed as garbage and **silently swallowed the `collision_layer = 0` line right after them** while the `collision_mask = 0` line survived — the file looked correct in an editor and in `git diff`, and the property simply did not apply. If a `.tscn` edit appears not to take effect, check for non-`;` comment lines above the property.

---

### 41. A charged weapon's movement penalty reaches observers one RTT late
- **Files:** `player/weapon_controller.gd:1969` (`_begin_charge_synced`), `:1986` (`_cancel_charge_synced`), `:714` (`get_active_fire_speed_mult`); `player/player.gd:1127`, `:1736` (the two `calc_speed` sites)
- **Symptom:** while another player draws a bow, the draw's speed penalty starts and ends a network-latency late on your copy of them (and on the *server's* copy of a remote client). The movement is briefly mis-predicted and corrected by rollback.
- **Why it's inherent:** the draw is not rollback state — `_charge_active`/`_charge_time` cannot go in the `RollbackSynchronizer` for the same reason the fire flags cannot (`02-netcode.md` §1: netfox stomps them on re-simulation ticks). `get_active_fire_speed_mult()` runs inside `_apply_movement_from_input`, which *is* re-simulated, so the two are structurally mismatched. The nearest existing thing, `_is_firing`, feeds the very same function and is never synced at all — so this is strictly better than the status quo, not a new class of problem.
- **Suggested fix:** none attempted. Moving the draw into `Player`-level rollback state would need a determinism review of `get_active_fire_speed_mult()` first, and it would still be re-simulated against a *broadcast* flag.

### 42. A duplicated `fire_intent` on a charged weapon spends a full shot at zero charge
- **Files:** `player/weapon_controller.gd:2264-2265` (the `_charge_time = 0.0` reset in `fire_intent`)
- **Symptom:** if `fire_intent` is delivered twice for one release, the first scores the draw and zeroes the clock; the second is scored at ratio 0, i.e. a 0.2×-speed / 0.5×-damage arrow for a full magazine round.
- **Why:** this is #7 (`fire_intent` has no sender validation, `@rpc("any_peer")`) with a sharper symptom than a mere double-tap — on an ordinary weapon a duplicate costs a second bullet at full power; here it also wastes the draw. Nothing in the current code can produce the duplicate (the client sends one intent per release), so this is a consequence of #7's exposure rather than an independent bug.
- **Suggested fix:** sender validation on `fire_intent` (#7), or a per-release nonce. Do not "fix" it by removing the reset — `_charge_time` must be zeroed after scoring or the next shot inherits it.

### 43. `min_charge` is measured against the server's clock, which starts late
- **Files:** `player/weapon_controller.gd:2243-2262` (`fire_intent`), `:1940` (`_release_charge`)
- **Symptom:** with `min_charge > 0` and a high-latency client, a release the player made exactly at the threshold can be refused server-side: no ammo spent, no cooldown, no shot, no feedback. The client's own gate passed, so it looks like the weapon misfired.
- **Why:** the server's `_charge_time` starts accumulating when `_begin_charge_synced` *arrives*, ~½ RTT after the player pressed. Every ratio the server computes is therefore slightly lower than the one the player watched fill the bar.
- **Bounded by** ½ RTT, and it vanishes entirely at full charge (the ratio clamps at 1.0, so only a partial-charge release is affected). The bow is unaffected — `min_charge = 0.0`, and `ratio < 0.0` is never true.
- **Suggested fix if it ever bites:** add half of `ENetPacketPeer.PEER_ROUND_TRIP_TIME` to the score at `fire_intent`, or carry the client's ratio and take `min(client, server)` — the latter is a small trust regression for a small fairness gain, which is why it isn't done.

### 44. A bot stuck mid-draw holds the charge through the whole force-wander
- **Files:** `player/bot_controller.gd:217-221` (the `_force_wander_timer` early return), `:997-1004` (the charged branch in `_try_fire_current_weapon`)
- **Symptom:** a bot that gets stuck while drawing keeps `primary_fire_held` true until the force-wander expires, because that branch returns before reaching `_try_fire_current_weapon`. It wanders at the draw's movement penalty for the duration, holding a full charge it never looses.
- **Why:** every other non-firing path in the controller calls `_clear_fire_inputs()` first (`:200`, `:953`, `:962`, `:1088`); this one returns early.
- **Suggested fix:** call `_clear_fire_inputs()` in that branch (it is one line, and it also matches the other paths). Note that clearing the flag on a charged weapon is a *release* — it looses the arrow rather than cancelling it, which is what the bot's disengage paths already do and is intended.

### 45. A draw cancelled below `min_charge` is completely silent
- **Files:** `player/weapon_controller.gd:1940` (`_release_charge`); `player/player_ui.gd` (`_update_charge_ui`)
- **Symptom:** releasing early costs no ammo and starts no cooldown, and the charge bar hides instantly — so the player cannot tell "I released too early" from "my shot did nothing". The bow is unaffected (`min_charge = 0.0`), but any weapon that sets it will feel broken without feedback.
- **Mitigated** by the HUD's min-charge threshold tick (`player_ui.gd`, shown when `min_charge > 0`), which states the rule *before* the failure. That was the cheap half of the fix.
- **Suggested fix:** a short cue on a dropped draw — reuse `WeaponFire.empty_sound`, or hold the bar visible ~0.25 s tinted red. Needs a new timer + state, so it was left out.

### 46. Ability charges are per-peer with no reconciliation — a boundary cast is refused and not refunded

- **Files:** `player/abilities/ability_manager.gd` (`_begin_ability_gate`, `_is_on_cooldown` /
  `is_ability_ready`, `_cast_ability`), `player/abilities/ability.gd` (`max_charges`,
  `charge_interval`)
- **Introduced by:** the charged-ability feature, 2026-09-25. **Recorded, not fixed** — see the
  scope note below, because the behaviour is inherited rather than invented.
- **Symptom:** with `charge_interval` tuned tight (or any charged ability cast right at the
  interval boundary), a client's cast can be accepted locally and **silently refused by the
  server**. The client has already spent the charge and started its own interval, so the ability
  briefly reads as unavailable even though nothing happened — no effect, no feedback.
- **Why:** the charge pool and the inter-cast interval are tracked **locally on each peer and never
  networked**, exactly like the `_cooldowns` beside them: the owning client's copy is optimistic
  (`_request_cast` spends before the RPC leaves) and the server's is authoritative (`_cast_ability`
  re-checks its own state). The server's interval starts when the RPC *arrives*, ~½ RTT after the
  client's, so the two disagree by half a round trip at the boundary. Nothing reconciles them, and a
  server-side rejection does not refund the client's optimistic charge.
- **Scope — this is the pre-existing cooldown model, not a new class of bug.** Every ability has
  always worked this way: cooldowns are per-peer, and a rejected cast (target died, range lost,
  action-locked) has never rolled back the client's timer. Charges inherit the identical shape, so
  the feature adds no new authority hole — a modified client still cannot cast more than the server
  allows. The only thing that is new is that a **charged** ability makes the window easier to hit,
  because `charge_interval` can be authored short enough that a ½ RTT difference matters.
- **Bounded by** ½ RTT, and it vanishes for a 1-charge ability (`charge_interval` is not consulted
  there — see `02-netcode.md`), so nothing that shipped is affected.
- **Suggested fix if it ever bites:** carry the client's request time with the RPC and have the
  server accept a cast made within ½ RTT of its own deadline (mirroring the note in #43 for
  `min_charge`), or mirror the remaining interval to the owning client alongside the status-effect
  sync so the two start from the same instant. Both are more invasive than the current design and
  should only be done for an ability whose `charge_interval` is authored tight enough to feel it.

### 47. A metered ability's pool is per-peer, and a refused turn-on leaves the bar draining nothing

- **Files:** `player/abilities/ability_manager.gd` (`_meter_at`, `_set_meter`, `_request_cast`,
  `_cast_ability`, `_physics_process`), `player/abilities/metered_ability.gd`, `player/hud/ability_circle.gd`
- **Introduced by:** the metered-ability feature, 2026-09-25. **Recorded, not fixed** — the residual
  is the same per-peer trade #46 already makes, and the worse variant is already closed.
- **Symptom:** a client turns noclip on, the server refuses (its own toggle delay had not elapsed
  yet — a ~½ RTT window), and the client's meter bar starts draining and reads "in use" for up to
  five seconds for an ability that is not actually running. Nothing about the player's *state* is
  wrong, and it self-corrects: the local pool hits empty, the exhaustion tick clears the flag, the
  bar refills, and the two peers converge on the next successful toggle.
- **Why:** the meter pool is tracked locally on each peer and never networked, exactly like the
  charge pool beside it (`_meter_stamp_ms` is local, the client's copy is optimistic and the
  server's is authoritative). The server additionally only begins its own drain when the RPC
  *arrives*, so the two clocks are half a round trip apart for the whole activation — the bar leads
  the true state by that much even on the happy path.
- **The sharp version of this was already designed out, and that is the part to not regress.** A
  toggle is its own inverse, so a naive implementation that flipped a local bit would not merely
  desync: two peers whose flags disagreed would flip in *opposite* directions and stay inverted, and
  the player's press-to-turn-**off** would switch noclip back **on**. That is why the direction is
  resolved once in `_request_cast` and carried with the cast (`want_on`), and why `_set_meter` is
  idempotent — asking for the state the slot is already in does nothing, so the redundant press is a
  no-op rather than an inversion. **If someone ever "simplifies" `want_on` away in favour of each
  peer re-deriving the direction from its own flag, this entry becomes a real bug.**
- **Scope — no authority hole.** `want_on = true` still has to pass the server's own
  `is_ability_ready` (toggle delay + pool) before anything happens, and `activate()` / `deactivate()`
  are silent no-ops unless the caller is the server. A modified client can mis-draw its own HUD bar
  and nothing else.
- **Bounded by** ½ RTT, and it only bites when a press lands exactly on the 1 s toggle boundary. A
  second metered ability would inherit the same model.
- **Suggested fix if it ever bites:** mirror the pool and the on/off flag to the owning client
  alongside the status-effect sync so both copies start from the same instant — the same fix #46
  suggests for the charge interval, and the same reason it was not done up front.

### 47b. Noclip can expire inside geometry

- **Files:** `player/player.gd` (`_noclip_move`, `_apply_movement_from_input`),
  `player/abilities/ability_manager.gd` (`_physics_process`)
- **Introduced by:** the metered-ability feature, 2026-09-25. **Recorded, not fixed.**
- **Symptom:** the meter runs out while the player is inside a wall, noclip ends, `move_and_slide()`
  resumes with the capsule embedded in geometry — the player is depenetrated or briefly stuck.
- **Why:** `_noclip_move` integrates `global_position` directly with no `move_and_slide()` at all
  ("nothing blocks the body"), so being inside geometry is the normal state during flight.
- **This is not new — it is what already happens on a manual exit.** Today the player solves it
  socially, by choosing a clear spot before switching off; the meter removes that choice by making
  the exit involuntary. Deliberately *not* "fixed" by refusing to auto-off while embedded: that would
  re-enter the infinite-retry loop that `_physics_process` bypasses the cast guards to avoid.
- **Suggested fix if it bites:** push the player to the last known clear position, or refuse the
  auto-off for a bounded grace period (not indefinitely) and drain a little more for it.

---

### 48. A loadout change could leave the previous slot's viewmodel in hand — `[FIXED 2026-09-26]`
- **Files:** `player/weapon_controller.gd:184-194` (the `_weapons` setter), `:197` (`current_weapon_index` setter), `:723` (`apply_loadout`), `:1416-1448` (`_begin_switch`), `:617` (`reset`); `world/loadout_menu.gd:901` / `:934`; `world/spawn_manager.gd:237`; `player/player.gd:574-592`
- **Reported as:** "the viewmodel for the weapon is sometimes incorrect … the second time you change your loadout. For example, you could shoot AK bullets from a visually pistol viewmodel."
- **Symptom:** after confirming a new loadout you keep holding the *old* slot's gun while everything else (index, ammo, damage, recoil, the HUD) is already on the new one. It persists until you switch slots away and back.
- **Why:** assigning `_weapons` spawns the model for the **current (old) index** (`_on_weapon_index_changed()` defaults `previous_index = -1` → `_begin_switch(-1)` → immediate `_do_swap_model()`). The `current_weapon_index = 0` that used to follow it then starts an animated put-away — every Weapon ships `put_away_time = 0.1` (`weapon/weapon.gd:38`) and none override it, so `_begin_switch` always takes its `PUT_AWAY` branch and *defers* the swap to `_advance_switch_phase()`. `_request_loadout` ends with `player.rpc_reset.rpc(...)`, whose `weapon_controller.reset()` zeroes `_switch_phase` — so the swap never ran and the deferred model was left standing. Not a race: both RPCs are issued in one synchronous call and the reset lands long before the 0.1 s timer could elapse.
- **Why it looked like "the second time":** the first confirm is the initial loadout on a fresh player whose index is already 0 (`world/world_1.gd:61-64` gates the menu on `world.class_selected`, so the first confirm is structurally the spawn loadout) — both index writes are no-ops and the chain is harmless. Every later confirm happens mid-round with a possibly non-zero slot.
- **Why nothing caught it:** `_is_ready()` (`:280-284`) only checks `current_weapon_model != null`, never that it corresponds to `current_weapon_index`.
- **Fix:** new `WeaponController.apply_loadout(new_weapons, index)` (`:723`) — sets the array, lands on the index, then voids any put-away the two assignments started and spawns outright (`_switch_phase = IDLE` → `_do_swap_model()` → `_restart_hold_anims()` → `_finish_switch()`). All five loadout-apply sites now route through it and no longer write `current_weapon_index` themselves. `set_weapons()` keeps its plain semantics (it is still the only correct *assignment* primitive, and `_ready()` wants it unadorned). The `_weapons` setter also re-clamps `current_weapon_index`, closing a latent out-of-range deref in `_emit_weapon_changed()` (`:675`) / `spawn_weapon_model()` (`:866`) reachable from the 2-element array that `rpc_sync_full_state` builds when the melee path is missing.

### 49. Randomize-on-death desynced every client from the server — `[FIXED 2026-09-26]`
- **Files:** `player/player.gd:862-895` (`_randomize_weapons_from_class`), `:897-908` (`_rpc_sync_randomized_loadout`); `world/loadout_menu.gd:888-889` / `:922-926`
- **Reported as:** "on the client, the weapons they have and the weapons on the server are mismatched … they shoot their server weapon, but with certain attributes of the weapon they think they are holding" (holding a flamethrower locally, firing an AK).
- **Symptom:** client-only (the host never sees it, having no remote peer to disagree with). Recoil, spread and the viewmodel behave like weapon A; damage, ammo, muzzle flash and the killfeed are weapon B.
- **Why:** `_randomize_weapons_from_class` picked weapons and immediately `duplicate(true)`d them, then read `_loadout_primary_path = primary.resource_path` **off the duplicate**. `resource_path` is registered `PROPERTY_USAGE_EDITOR` only, so `duplicate()` never carries it — all three paths were `""`. `_rpc_sync_randomized_loadout` then did `load("") → null → return`, a silent no-op, while the server had already installed the randomized set via `weapon_controller.set_weapons(nw)`. Fired from `rpc_reset` on every respawn while "Randomize on every death" is ticked.
- **Why the attributes split from the shot:** the client computes recoil from *its own* `_weapons[current_weapon_index]` (`weapon_controller.gd:2074`) and broadcasts it via `_apply_recoil_rpc` (`:2088`), while `fire_intent` resolves the shot against the server's `_weapons[weapon_index]` (`:2269`). `player.tscn`'s replication config carries only `.:current_weapon_index`, so the two peers agree on the index while their arrays diverge silently — nothing downstream can detect it.
- **Collateral:** the blanked `_loadout_*_path` fields are what `rpc_sync_full_state` sends a late joiner (`spawn_manager.gd:44`), whose guard at `player.gd:576` then skipped the weapon sync entirely — new joiners saw that player on `player.tscn`'s default weapons.
- **Fix:** read the paths off the **originals** before duplicating (the pattern `spawn_manager.gd:197-200` already used), bail with a `push_error` if any is blank, and apply through `apply_loadout()` (#48) so the randomized set lands on the same slot with the same model everywhere. The two `load()`-null guards in `_rpc_sync_randomized_loadout` and `loadout_menu.gd`'s `_request_loadout`/`_apply_loadout` now `push_error` too — this whole class of bug is invisible precisely because a dropped loadout sync looks identical to a successful one.
- **Deliberately not done:** no `weapon_index` cross-check in `fire_intent`. It would not have caught this (both peers were on index 0; only the arrays differed) and `current_weapon_index` is replicated, so it must tolerate in-flight lag — a hard reject would eat legitimate shots right after a switch. Detecting divergence by weapon *identity* would be new netcode.

---

### 50. `trenchbroom/` is 844 MB and `.gitignore` excludes none of it
- **Files:** `.gitignore:1-8`; `trenchbroom/textures/Material-LIB.zip` (412 MB), `trenchbroom/textures/Free Painterly Textures 1k.zip` (42 MB), `trenchbroom/textures/Material-LIB/Material-LIB/Material-LIB.blend` + `.blend1` (8.2 MB each), `trenchbroom/textures/Material-LIB/Material-LIB/**/*.txt` + `.txt~`
- **Symptom:** the whole 844 MB tree is eligible to be committed. `.gitignore` only carries `.godot/`, `/android/`, `.DS_Store` and `*.tmp`. Only 13 files under `trenchbroom/textures/` are tracked today (all from `8540936 add trenchbroom`), so the risk is latent until someone runs `git add -A` — at which point 455 MB of source archives land in history permanently and cannot be pruned without a rewrite.
- **Also in the tree:** `Material-LIB/Material-LIB/RoofTiles/RoofTiles-N.png~` is a stray editor backup sitting inside the texture root, so Godot's importer walks it; `blender_assets.cats.txt~` is the same for the asset catalog. Both are inert today (Godot ignores the `png~` extension) but they are clutter in a directory FuncGodot scans wholesale.
- **Suggested fix:** add `trenchbroom/textures/*.zip`, `trenchbroom/textures/**/*.blend*`, `trenchbroom/textures/**/*~` to `.gitignore`, and delete the two `*.blend` files from disk — the `Material-LIB/` folder is already fully extracted beside its zip (409 MB extracted vs 412 MB archived), so that archive is redundant. The 42 MB `Free Painterly Textures 1k.zip` has **no** matching extracted folder, so check before removing it.
- **Related:** `tools/resize_textures.gd` rewrites any image under `trenchbroom/textures/` whose longest edge exceeds 2048 (today: 8 files, the `-B/-M/-N/-R` sets for `Cobblestone` and `StoneTiles`), backing the originals up under `backup/trenchbroom/textures/`. It never upscales, so the 64×64 TrenchBroom sentinels (`clip`/`origin`/`skip`/`default_texture`) are skipped by construction.

---

### 51. The rim light never reached a spawned character model — `[FIXED 2026-09-26]`
- **Files:** `player/player.gd:2271-2284` (`_spawn_character_model`); `player/player_model.gd:6`, `:41-49` (`RIM_LAYER`, `disable_rim_layer` / `enable_rim_layer`); `player/weapon_controller.gd:7`, `:897-902`; `player/player.tscn:995,998` (mannequin meshes, `layers = 513`) and `:2615-2629` (the RimPivot spotlights, `light_cull_mask = 512`)
- **Reported as:** "the rim light does not work."
- **Symptom:** the warm `RimPivot` backlight appears only on the built-in mannequin. Every real character — i.e. every player in a normal game — renders completely unlit by it. Confusingly, the same player's **gun** *does* catch it, so the body reads as the odd one out rather than the feature reading as dead.
- **Why:** the rim light is a render-layer handshake and only one half of it was ever authored. Both spotlights have `light_cull_mask = 512`, so they illuminate only meshes carrying bit 9 (`PlayerModel.RIM_LAYER := 1 << 9`). The project's *only* meshes with that bit are the mannequin's two (`layers = 513` in `player.tscn` — a repo-wide grep for `layers =` across all `.tscn` returns those two lines and nothing else). The nine character model scenes under `assets/character_models/characters/` leave `layers` at its default of 1. `_spawn_character_model()` hides the mannequin's meshes whenever the character has a `character_scene` (`:2250`), and every shipped `Character` `.tres` has one — so the only rim-lit body in the project is removed from view and replaced by an unlit one, on the normal path, every time.
- **Why it looked like a half-working feature:** `PlayerModel.enable_rim_layer()` (`player_model.gd:47`) existed with **zero call sites** — only the disable half was wired up (`player.gd:2274`). `weapon_controller.gd:897-902` did perform the mirror-image opt-in for weapon models, which is what made the gun light up while the body did not. The opt-in was simply never written for bodies.
- **Fix:** `_spawn_character_model()` now calls `enable_rim_layer()` on everyone else's model and keeps `disable_rim_layer()` for the local player's own, under the same `own` predicate `weapon_controller.gd:899` uses, so body and weapon stay consistent by construction. It must stay **after** `$Body.add_child(world_instance)` — `PlayerModel._ready()` is what populates `_meshes` and `add_child` is what triggers it. `enable_rim_layer()` uses `|=`, so the repeated calls `_spawn_character_model()` gets (`set_character` on spawn, mid-round character swaps, `rpc_sync_full_state` for late joiners) are idempotent. The `model_script == null` guard is correct rather than a gap: the built-in mannequin carries no script and already has the bit from the scene file.
- **Why the scene-file fix is not viable:** authoring `layers = 513` on each character model's meshes would be dropped on save — the meshes live inside instanced GLB sub-scenes (`assets/character_models/characters/stalker.tscn` instances `stalker.glb`; the meshes are `stalker/Skeleton3D/...`), and Godot serializes overrides only on an instance's *root*. See the `maps/koth_castle.tscn` note under "Not bugs, but worth knowing" below; it would also have to be redone for every new model.
- **Not fixed, deliberately:** the local player's own model is never rim-lit, including in third person — `RimPivot._own_model` is baked in `_ready()` (`player/rim_pivot.gd:8-19`) and hides both lights for the owner in every view mode. That is a behaviour question, not a bug.
- **Related fragility:** `player/rim_pivot.gd:38` guards a zero-length look direction but not "direction parallel to `Vector3.UP`", which makes `look_at()` fail with an engine error when a camera sits nearly straight above or below the pivot. Unconfirmed in practice — the third-person spring arm's pitch limits may rule it out.

### 52. `painted_toon.gdshader` replaces the built-in light path, so its brightness is pinned to an engine convention nothing checks
- **Files:** `assets/materials/painted_toon.gdshader` (`280` `light()`), `assets/materials/painted_toon.tres`; harness `verification/toon_shader_harness.gd`
- **Symptom:** none today — the material's `light()` mirrors the engine's own accumulation. The risk is that it stops matching, silently.
- **Why:** writing a `light()` function sets `LIGHT_CODE_USED`, and `scene_forward_lights_inc.glsl` makes that branch **exclusive** — Godot's entire built-in direct-lighting branch is skipped, not merely the diffuse/specular lobes. So the shader's exposure is correct only because it mirrors the engine's accumulation `light_color * brdf * attenuation`, with `1/M_PI` living **in the BRDF** and `light_color` arriving **premultiplied by PI**. If that convention moves in an engine upgrade, every material using this shader shifts relative to every `StandardMaterial3D` beside it and compiles **clean** — no error, just a differently-lit object.
- **Measured, do not re-derive:** `LIGHT_COLOR` **is** `color × energy × PI`, and `1/PI` in a custom `light()` is therefore **required**. Confirmed empirically, not from documentation or source reading — a flat-shaded probe that emits `LIGHT_COLOR * scale` measures `0.314` at `energy = 0.1`, i.e. exactly `0.1 × PI`, and `scale = 1/PI` lands within 7 % of a `StandardMaterial3D` in `DIFFUSE_LAMBERT` on the same sphere. The shading reference's "× PI" wording is right and a reading of `light_compute` alone suggests otherwise; the probe settles it. If a brightness question comes up again, re-run a probe of this shape rather than reading the source.
- **Also measured:** replacing Godot's default `diffuse_burley` with a Lambert-shaped toon ramp costs **~0.72×** the reference material's brightness on an identical sphere (`verification/toon_shader_harness.gd` prints this ratio). That is a shading-model difference, not a bug — but it is why a dark albedo looks muddier under this shader than under `StandardMaterial3D`. See #53.
- **Second consequence:** the `diffuse_*` / `specular_*` `render_mode`s and the `RIM` / `BACKLIGHT` fragment built-ins are all **no-ops** on any material using this shader. `render_mode diffuse_toon;` here does nothing; the toon look comes entirely from the shader's own ramp.
- **Suggested fix:** if a scene ever looks wrong after an engine bump, A/B against a `StandardMaterial3D` before touching the shader. Do not correct a brightness mismatch with a magic multiplier — find which convention moved. `verification/toon_shader_harness.tscn` renders exactly that comparison (reference sphere vs. this shader with the ramp flattened back to plain Lambert); they must sit at the same brightness.

### 53. The juggernaut renders darker under the toon shader than under its original materials, by more than Burley-vs-Lambert explains
- **Files:** `assets/character_models/characters/juggernaut.tscn` (the `ToonMaterialSwap` node), `components/toon_material_swap.gd`; harness `verification/juggernaut_inspect.gd`
- **Symptom:** the juggernaut is legible but notably darker and less saturated than before the swap; the dark-green uniform in particular reads close to black. Measured mean over the torso band: original `(0.169 0.202 0.174)` vs toon `(0.102 0.111 0.108)` sRGB. The original is clearly green (`g > r > b`); the toon is nearly neutral.
- **Why the obvious explanations are ruled out:** the controlled sphere test in `toon_shader_harness.gd` puts a Lambert-shaped ramp at **0.72×** the `StandardMaterial3D` reference, which would account for only part of this. And the shader's own look knobs barely move the character's number — `tint_strength = 0` and `toon_steps = 2` change it by less than `0.001`, which means the **direct-light term is a small fraction of the total in that test scene**, so those parameters cannot be what is causing the gap.
- **Not established:** *why* the direct-light term is small there. The test scene's character stands over no ground geometry, so self-shadowing was the first suspect, but disabling `shadow_enabled` reproduced the measurements to three decimals — i.e. that change had no effect, which is itself unexplained and suggests the measurement setup is untrustworthy for this question. Every probe built to isolate a single term also misbehaved (a `vec3(ATTENUATION)` addition came out non-neutral, which is impossible for a scalar).
- **Partial mitigation, in place:** `albedo_gain` (default `2.0`) lifts the albedo, and it is the only lever that works here — a multiplier on the *direct* term does nothing in a scene lit mostly by ambient (swept 1.0 → 4.0 on the old `diffuse_gain` and the result moved 8 %). `albedo_gain` moved the same character 0.048 → 0.082 over the same range. It does **not** reach parity: even at 4.0 the toon is short of the original's `0.148`, and much past 2.0 it starts clipping bright albedo (the face, the belt buckle). Treat it as an improvement, not a fix.
- **Related, and the reason "matte" makes things worse:** the retune that zeroed `specular` — which is what actually removes the shine, since it drives both the highlight's F0 and the ambient/IBL reflection via the `SPECULAR` built-in — cost more light than `albedo_gain` returns. Raising `specular` back toward 0.2 is the other half of the brightness trade if the matte look proves too dark.
- **Suggested fix:** do not tune this blind. Re-measure in a scene where direct light demonstrably dominates — a ground plane, a light at a known angle, ambient killed, and the character confirmed lit — and compare original vs toon on the same pixels. Only then decide whether the gap is the Burley→Lambert difference (#52), the cool `shadow_tint` desaturating a dark albedo, or something in `toon_material_swap.gd`'s conversion. The swap itself is verified correct — 14/14 surfaces converted, albedo textures and the two-material eye/teeth pairs preserved.

### 54. Character material overrides are authored onto nodes that live inside an instanced GLB, with indices derived from glTF order
- **Files:** `assets/character_models/characters/*.tscn` (`surface_material_override/N` entries), `assets/materials/character_toon/*.tres` (69 generated materials); generator lived in a throwaway script, **not committed** — regenerate from the GLBs if it is ever needed again
- **Symptom:** none today — all 125 overrides land, verified by loading every scene and counting surfaces on the painted-toon shader.
- **Why it is fragile anyway:** the mesh nodes are *not in the .tscn*. Godot writes a `[node ...]` entry only for a node carrying an override, so `blackhat.tscn` declares 9 nodes while its GLB has 11 mesh nodes. The override entries here were authored as text onto paths that only exist inside the instanced GLB, with a child `index` taken from the mesh node's position in glTF order. That rule was verified against every mesh-node entry the project already had (juggernaut's `Juggernaut_Body`=1, blackhat's `Blackhathead`=3, scientist's `Scientist_clothes_001`=2), and `index` turns out **not** to be load-bearing — Godot resolves an instance-descendant override by path, which is why juggernaut's `BoneAttachment3D` sits at `index="9"` alongside 10 mesh nodes and still works.
- **What will break it:** re-importing a character GLB can rename nodes and reorder meshes, silently invalidating both the paths and the indices. A renamed node means the override lands nowhere and that surface silently renders with its original `StandardMaterial3D` — no error. **If a character's textures ever stop matching its toon look, re-check that scene's override entries against the GLB before touching the shader.**
- **Two deliberate exceptions, do not "fix" them:** `blackhat.tscn`'s `Glasses[1]` keeps its `glass.001` (`alphaMode: BLEND`, alpha 0.35) because the toon shader is opaque and converting it would render the glass solid; and `ghost.tscn`'s two `MeshInstance3D` nodes under `BoneAttachment3D2`/`3` are author-added attachment meshes, not GLB skin surfaces, so they were never in scope.
- **Materials are per (character, material), not deduped.** Gums/Teeth/`Material.001` recur across characters with identical parameters, so ~69 files could be fewer — but sharing would mean one edit silently re-skins several characters, and the point of the assets is that they are tunable per character.
- **Related:** the generator lived only in a temp directory and was not committed, so regenerating means re-deriving the GLB parse (Godot stores `albedo_color` as sRGB while glTF's `baseColorFactor` is linear, and embedded images extract as `<glb>_<image name>.<ext>` where the extension comes from the mime type — blackhat's shoes are JPEG, which is what a naive `.png` assumption gets wrong).

### 55. The segmented health bar is driven by a per-frame push, because `max_health` emits nothing
- **Files:** `player/segmented_health_bar.gd`, `player/player.gd` (`set_public_health_visible`, `_update_visibility`); the contract it depends on is `components/attribute_component.gd` `recompute_max_health`
- **Symptom:** none today. The risk is a future "optimization": the bar's values are pushed from `set_public_health_visible()`, which `_update_visibility` already calls once per frame per other player — it is **not** driven by `AttributeComponent.health_changed`.
- **Why it can't be signal-driven:** `health` has a setter that emits `health_changed`, but `max_health` is **derived** — `recompute_max_health()` writes the field directly (`components/attribute_component.gd:100-107`) and emits nothing. It moves under size effects via `_rpc_size_change` → `apply_synced_max_health_mult` → `recompute_max_health`, and on spawn via `Player.set_character` writing `starting_health`. A `health_changed`-driven bar would keep a stale **width** through every one of those, which silently misreports max health — the exact thing the sections exist to convey. The per-frame push is what makes the width correct; the quantization gate inside the widget is what makes it cheap (`04-optimization.md`). If a future change moves this onto a signal, it must cover all three writers, not just `health`.
- **Second, intended, limitation — reading is approximate off the 100 boundary.** The bar is exact for whole and half sections and readable-but-approximate otherwise: a 307 max draws 3.07 sections, which reads as "just past 3". Snapping up to a whole section was rejected because it would over-report max health far more often (any non-multiple of 100). The width also scales linearly with no cap, deliberately: capping it would trade an unreachable cosmetic inaccuracy for a bar that stops reporting. Revisit only if a stacked size-effect target ever draws an absurdly wide bar.

### 56. Ability icons: per-icon import settings and a ~4k-file asset library, both silent when wrong
- **Files:** `assets/icons/game-icons.net.svg/**/*.svg.import` (4180 of them — the 20 an ability actually draws are hand-authored, the rest are Godot's defaults), `player/abilities/ability.gd` (`icon`), `player/hud/ability_circle.gd`
- **Symptom:** none today. The failure modes all produce a **silent** wrong result rather than an error:
  1. **An icon drawn without tuned import params aliases badly.** The sources are `viewBox="0 0 512 512"` thin white strokes, drawn at ~40–48 px in the circle — a ~12× minification. The `.import` for each icon an ability references is hand-authored to pin `svg/scale=0.25` (128×128) and `mipmaps/generate=true` precisely for this. The other ~4160 library icons keep Godot's default scale, which is fine because nothing ever draws them. **A new icon assigned to an ability WITHOUT those params still works — it just shimmers**, most visibly as the circle animates between 64 and 76 px. Nothing in code or in a test asserts the params, so an import-settings reset silently reverts it.
  2. **The library is 4180 SVGs + 4180 generated `.import` files.** It is committed as real project content (there is deliberately no `.gdignore` — the abilities reference these files in place by path), so `assets/icons/` is ~8400 tracked files. This is the same species of problem as #50 (`trenchbroom/`), just smaller. First import after a fresh clone is a multi-minute scan.
- **Why hand-authored `.import` files, and why they survive:** Godot reads `[params]` out of an existing `.import` when it (re)imports, so the tuned scale is not lost on a cache wipe. The `uid=` line is deliberately absent from `[remap]` — Godot assigns one on first import. The `[deps]`/`path` hashes are `md5("<res:// path>")` and are regenerated if they drift, so they are informational rather than load-bearing.
- **Adding an icon is a two-step job.** Copy the tuned `.import` from an existing referenced icon (or re-import in the editor with `svg/scale = 0.25`) and point the ability's `icon` at the library path. Skipping the first step is the silent failure above.
- **Attribution — handled, keep it there:** the game-icons.net set is **CC BY 3.0** (individual sets, e.g. Zeromancer's, are CC0), so the credit has to be visible in the build rather than only in a licence file. `world/loadout_menu.gd` `_build_icon_credit()` puts "Icons: game-icons.net (CC BY 3.0)" in the loadout screen's bottom-right corner, which is the one screen every player sees before spawning. The full author list is `assets/icons/game-icons.net.svg/icons/license.txt`; the icons in use are Lorc's, Delapouite's, Carl Olsen's, Skoll's, Sbed's and Zeromancer's. If the loadout screen is ever replaced, this credit needs a new home — nothing else asserts it.
- **Suggested fix if it grows:** script the two-step job — one command that (a) sets `svg/scale` / `mipmaps` on a chosen library icon and (b) writes the `icon = ExtResource(...)` line into the ability. Doing both by hand is what gets half-skipped.

### 57. A cross-script static call into a `class_name` widget drew a phantom "non-static function" error
- **Files:** `player/hud/ability_circle.gd` (`icon_rect`), `player/hud/targeted_ability_icon.gd` (`_fit_rect`)
- **Symptom:** `Error at (65, 17): Cannot call non-static function "fit_icon_rect()" on the class "AbilityCircle" directly. Make an instance instead.` — reported repeatedly against a file whose target function **was** declared `static` on disk. Column 17 with a tab rendered as 4 columns is `AbilityCircle` in the call at `targeted_ability_icon.gd:65`, so the location was right.
- **What was checked, and did not reproduce it:** one `static func fit_icon_rect(...)` at `ability_circle.gd:219`, exactly one `class_name AbilityCircle` in the project, file mtime unchanged across the failed runs. `godot --headless --check-only --script res://player/hud/targeted_ability_icon.gd` exited **0** with no diagnostics, and a full `--quit-after 180` boot logged no such error. A cold Godot process parsed the exact file and line cleanly while the editor kept reporting it.
- **Most likely cause:** the editor's in-memory `GDScriptCache` holding a pre-edit analysis of `ability_circle.gd` and resolving the cross-script reference against it. **An F5 re-run does not clear this** — a game launched from the editor runs in the editor process and inherits the cache. Only `Project → Reload Current Project` or an editor restart does.
- **Workaround adopted anyway:** the fit is now a plain instance method on each widget (`AbilityCircle.icon_rect`, `TargetedAbilityIcon._fit_rect`) and **no script calls into another `class_name` widget's static function**. Six duplicated lines of arithmetic is a cheaper failure mode than a tooling state we could not reproduce or clear from outside the editor.
- **Consequence — the thing to remember:** those two functions are now two copies of the same contain-fit. **Change one and you must change the other.**
- **If it recurs:** suspect the editor's script cache before the declaration, and reach for `Project → Reload Current Project` rather than re-running the game. Note this also means a fix committed from outside the editor may not be visible in a running editor session until the project is reloaded — which is exactly how the first attempt at this fix appeared to do nothing.

### 58. Portrait lighting is reproduced from a machine-local, gitignored editor file
- **Files:** `player/character_portrait_generator.gd` (`_load_preview_settings`, `_editstate_candidates`), source data in `res://.godot/editor/<scene file name>-editstate-<md5 of the scene's res:// path>.cfg`
- **What it is:** the character `.tscn` files carry no lights and no `WorldEnvironment`, so the lighting you see when you open one in the editor is Godot's per-scene **preview sun + preview environment**. That is editor metadata, not scene data: it lives in the `3D → preview_sun_env` dictionary of the scene's editstate `.cfg`, and `Node3DEditor::_load_default_preview_settings()` is where its defaults come from. The generator reads it back and rebuilds it as real nodes in the portrait's own `World3D` (sun rotation is `Vector3(x, y, 0)` in radians, matching the engine's `Basis::from_euler(Vector3(x, y, 0))`; ambient is the sky, with `BG_CLEAR_COLOR` so the PNG keeps its alpha).
- **Symptom:** none today — every portrait is correct *on this machine*. The failure is geographic, not temporal. `.godot/` is excluded by `.gitignore:2` (0 files tracked), so on a fresh clone, another machine, or after `Project → Reload Current Project` rebuilds the cache, the exact-hash file is absent for all nine scenes and the lookup degrades to `<name>.tscn-editstate-*.cfg`, then to the engine defaults (a plain white sun). The portraits still regenerate and still look *plausible* — a person, lit — so nothing flags the regression except the generator's own `lighting:` log line, which names the `.cfg` it used.
- **The designed-for case, exercised on every run today:** `governess` and `stalker` have **no** file at their current-path hash (`a993e67f…` / `f74f1024…`); their scenes were renamed at some point and only stale-hash files survive. Those happen to carry the engine default white sun, so they degrade gracefully. This is why the fallback sorts stale candidates by mtime rather than refusing to guess.
- **Deliberately not used:** the editor's own `AMBIENT_SOURCE_BG` (its ambient comes from the background, which here must stay clear) and the editor's `Add Preview Sun/Environment to Scene` buttons — baking those in would put a real `DirectionalLight3D` and `WorldEnvironment` **inside the character scenes**, where they would light the world around every spawned player.
- **Suggested fix if it ever bites:** commit the nine `preview_sun_env` dictionaries as a sidecar (`.tres`/JSON) in `character_portraits/` and treat the editstate file as an *override* rather than the source. Worth doing only once someone actually regenerates portraits off this machine — until then it is extra state to keep in sync.

### 59. The asset generators strip `uid=` from every `.tres` they re-save
- **Files:** `player/character_portrait_generator.gd` (`_capture_deferred`, `ResourceSaver.save(character, file_path)`), `weapon/killfeed_icon_generator.gd` (same shape); affected `player/characters/*.tres`
- **Symptom:** each generator run rewrites the `Character` `.tres` with **every `uid="uid://…"` attribute removed** — both the resource's own header uid and those on all its `ext_resource` lines. Nothing else in the file changes: paths, sub-resources and properties round-trip intact, so the diff reads as a wall of deleted uids and the game still loads. Godot resolves the references by path and the resource simply loses its stable identity.
- **Correlation, not theory:** `mannequin.tres` is the one character resource the generator **skips** (no `character_scene`), and it is the one that still has a `uid=` in its header. Seven of the eight committed files were already stripped before this was noticed, so the behaviour is long-standing and not introduced by any recent change.
- **Mechanism — not isolated.** The save happens in a *game* process (`F6` / a scene passed on the CLI), not the editor; the likely cause is that such a process never populates the `ResourceUID` path→uid cache, so the saver has nothing to write. Unconfirmed, and worth confirming before acting on it.
- **Why it matters little, and why it is still recorded:** uid references keep resolving via their path fallback, so this has not broken anything observable. It is recorded because a uid is the only thing protecting a reference across a file move, and because the diff churn makes every regeneration look like it touched more than it did.
- **Suggested fix:** if the stripped diffs become annoying, register the mapping before saving (`ResourceUID.set_id(ResourceUID.text_to_id(uid), path)`) or run the generators from the editor rather than the CLI — but only after confirming the mechanism above.

### 60. An entity that is not in `entity_definitions` is invisible to TrenchBroom, and builds as a bare `Marker3D`
- **Files:** `trenchbroom/entities/multiplayer_system_3d_fgd.tres` (`entity_definitions`); `addons/func_godot/src/core/parser.gd:83-87`; `addons/func_godot/src/fgd/func_godot_fgd_file.gd:88-100, 104-114`
- **Symptom:** two faces of one mistake. In TrenchBroom the entity is **absent from the entity browser** and cannot be placed at all. In Godot the other direction: rebuilding a map whose `.map` already contains that classname **replaces every placed instance with an empty `Marker3D`**, silently deleting the prop with no error on either side.
- **Why:** the `.tres` files under `trenchbroom/entities/` are not auto-discovered. `build_class_text()` walks only `base_fgd_files` + `entity_definitions`, so an unlisted definition produces no `@PointClass` and TrenchBroom never learns the classname. On the build side `parser.gd:83` resolves classnames through `map_settings.entity_fgd.get_entity_definitions()` and falls back to `default_point_class.node_class = "Marker3D"` (`:86-87`) for anything it cannot find — the degradation is a *default*, not an error, so nothing is reported.
- **Confirmed in this repo:** `entity_definitions` was empty in every committed revision (including before the folder was moved into `entities/` in `30f62c5d`), while `trenchbroom/maps/test.map` and `maps/hyb_castle.tscn` both contain `Forklift` and `Truck` entities. The three entities were therefore orphaned and the generated `.fgd` contained zero `@PointClass` entries. Fixed 2026-09-28 by registering all three.
- **Suggested fix:** keep every `.tres` in `trenchbroom/entities/` listed in `entity_definitions`, and re-export the FGD. `tools/export_trenchbroom_fgd.tscn` now asserts registration and exits non-zero if a classname is missing, so this is checkable rather than a thing to remember. See `06-trenchbroom-entities.md`.
- **Now automated:** `tools/generate_prop_entities.gd` writes the entity `.tres` for every model dropped into `assets/props/` and rebuilds `entity_definitions` from the folder (sorted, deduped, uids preserved) on every run, so a deleted entity leaves the array too. The export harness likewise discovers entities by scanning the folder instead of a hardcoded list. The registration step is no longer manual for props — only for entities sourced outside `assets/props/`, like `Truck`.

### 61. `FuncGodotFGDModelPointClass.target_map_editor` defaults to `GENERIC`, which TrenchBroom cannot read
- **Files:** `addons/func_godot/src/fgd/func_godot_fgd_model_point_class.gd:20` (the default), `:69-82` (the writer); `addons/func_godot/src/fgd/func_godot_fgd_point_class.gd:110-120`
- **Symptom:** a model entity looks correct in the inspector and exports without any warning, but appears in TrenchBroom as a **bare bounding box** with no model drawn.
- **Why:** `target_map_editor` defaults to `GENERIC`, and `_generate_model()` then writes the `studio` keyword. `studio` is the Hammer/J.A.C.K. spelling; TrenchBroom's display-model keyword is `model`. The name mismatch is entirely invisible from the Godot side — `build_def_text` only filters the `model` key for non-TrenchBroom targets (`func_godot_fgd_entity_class.gd:86-87`), so a stray `studio` is written straight through. `truck.tres` had exactly this: `target_map_editor` unset plus a hand-written `meta_properties["studio"]`, which read as correct but produced an entry TrenchBroom ignored.
- **Suggested fix:** always set `target_map_editor = 1` (`TRENCHBROOM`) on a `FuncGodotFGDModelPointClass`, and let `_generate_model()` own `meta_properties["model"]` rather than hand-writing either keyword. The export harness asserts the written `.fgd` contains `model(`, not `studio(`.

### 62. The headless boot smoke test reports `Parse Error` on resources that are not broken
- **Files:** the smoke-test recipe in `CLAUDE.md`; any `.tres` whose header carries a `script_class=` attribute — observed on `player/player_classes/*.tres`, `weapon/*/*.tres`
- **Symptom:** a `--headless --quit-after N` run prints `ERROR: res://…tres:NN - Parse Error: .` followed by `Failed loading resource:` for a handful of resources. It reads exactly like a malformed weapon or class resource, but **the failing set is different on every run**, so no single file is actually broken.
- **Evidence (4 consecutive runs, no code change between them):** 9 / 3 / 3 / 5 distinct failing files per run, 13 distinct across the union, and exactly one file (`player/player_classes/assistance.tres`) failed in all four. That one is a *downstream* victim, not the cause: it references 13 weapons, so it has the most chances to depend on one that lost the race. Nothing fails consistently on its own account.
- **Why:** a startup load-order race. A `.tres` declaring `script_class="Weapon"` (etc.) cannot be parsed until the matching `class_name` script is registered, and on a cold headless start the resource loader can reach the `.tres` first. Resources with many cross-references are simply more likely to be hit. This does not reproduce in a normal game launch, where scripts register well before class resources load.
- **Suggested fix:** none needed for the game. For diagnosis, **do not treat one run's `Parse Error` lines as a finding** — re-run and check whether the same file fails again before chasing it. When validating a specific change, prefer a *named* scene run (`godot_console.exe --path . --headless res://tools/<name>.tscn`, as the `tools/` harnesses do), which loads a small dependency set and does not exhibit this, over the full boot.

### 63. TrenchBroom silently refuses to rotate a point entity whose `size` box is not centred on XY
- **Files:** `trenchbroom/entities/*.tres` (`meta_properties["size"]`, `generate_size_property`); `addons/func_godot/src/fgd/func_godot_fgd_model_point_class.gd:157-197`; `docs/06-trenchbroom-entities.md`
- **Symptom:** in TrenchBroom, pressing `R` on a prop and dragging does **not** change its `mangle`/`angle` — the entity is shoved around instead, as if the rotate tool were a translate tool. Typing the keyvalue by hand does work, so the entity looks incorrectly authored rather than the bounds being at fault. Downstream, the map builds with the entity unrotated.
- **Why:** TrenchBroom blocks rotation for point entities whose bounding box is not centred on the XY plane — its manual documents the guard ("attempts to rotate the entity in TrenchBroom will be blocked", to avoid moving the model out of its collision box), and `TrenchBroom/TrenchBroom` #2498 reports the same finding from the bug side. `generate_size_property = true` is what triggers it: it derives `size` from the mesh's real AABB, which is off-centre whenever the prop's origin isn't at its middle. Every prop here is — the Truck came out `x -92…71` (centre −10.5), the Forklift `x -32…99` (centre 33.5).
- **Related trap:** `apply_rotation_on_map_build` is the *other* half. It is what makes the assembler read `mangle`/`angle`/`angles` at all (`entity_assembler.gd:172-200`), so setting it `false` builds every entity unrotated no matter what the map says — an easy thing to flip while debugging and then forget.
- **Suggested fix:** leave `generate_size_property` **off** and author `size` by hand, symmetric on X and Y about the origin while still containing the real extents (Z is left alone — only XY is checked). The export harness asserts centring for every registered entity, so re-enabling generation fails loudly instead of silently breaking `R` again.

### 64. `generate_size_property` offsets the box by the average root-child position, which can put the origin outside it
- **Files:** `addons/func_godot/src/fgd/func_godot_fgd_model_point_class.gd:157-197` (`_generate_size_from_aabb`); `trenchbroom/entities/mannequin_ref.tres`; `docs/06-trenchbroom-entities.md`
- **Symptom:** the entity has **no preview model at all in TrenchBroom** — not a box, not a misplaced model, nothing — while other entities using the same model pipeline draw fine. Nothing is logged on either side.
- **Why:** TrenchBroom will not preview a point entity whose `size` box does not contain the origin (`TrenchBroom/TrenchBroom` #4573, "3D model is missing/invisible in entity browser with specific `size()`", fixed in milestone 2024.2). The box here was `z 7…65`, so the origin at `(0,0,0)` sat *below* it. The offset came from `_generate_size_from_aabb`, which adds the **average position of the scene root's direct children** to the mesh AABB:
  ```gdscript
  for node in nodes:
	  if node.parent == 0:
		  pos_ofs += node.position
		  ct += 1
  pos_ofs /= maxi(ct, 1)
  aabb.position += pos_ofs
  ```
  That is exact when the root has one child carrying the whole model — the Truck and Forklift both do, and both were correct. The mannequin is **rigged**, and its root has four armature children, so the average was meaningless and shifted the box `+7` on Z. The true bounds, read from the glTF `POSITION` accessor `min`/`max`, are `z 0…58`.
- **Not the cause:** the model being skinned. `mannequin.glb` carries a 164-joint skin and `JOINTS_0`/`WEIGHTS_0`, and its mesh nodes hang directly off the root at identity transform — but the `POSITION` accessors are still valid bind-pose geometry (`0.88 × 1.8 × 0.33` m, feet at `y = 0`), so a renderer that ignores skinning still has a human to draw. The box was the whole problem.
- **Suggested fix:** as #63 — author `size` by hand with `generate_size_property` off, measured from the model's `POSITION` accessors rather than from the generator, and make sure it spans the origin. The export harness now asserts origin containment for **every** registered entity (and XY centring additionally for rotatable ones), so this cannot silently return.

### 65. A TrenchBroom model-scale expression cannot reference the entity's `scale` key
- **Files:** `trenchbroom/entities/*.tres` (`scale_expression`); `addons/func_godot/src/fgd/func_godot_fgd_model_point_class.gd:69-82`; `docs/06-trenchbroom-entities.md`
- **Symptom:** the prop's `scale` key scales correctly **on map build** but the TrenchBroom preview never reflects it. Trying to make it reflect it is worse than not trying: `[scale * 32, 32]` drew every prop ~32× too small, and `scale * 32` drew nothing at all.
- **Why:** TrenchBroom's model scale is units-per-model-unit (default 32), not a multiplier, so tracking a multiplier requires the expression to multiply — and on this setup referencing the property at all breaks the model. Neither failure matches the documentation: `TrenchBroom/TrenchBroom` #4149 (fixed 2023.1, PR #4165) is supposed to make `'1' * 32` evaluate to `32`, and the manual describes model-scale arrays as a "try each until one is not Undefined or Null" fallback chain, under which **both** forms should have landed on 32. They did not. **The structural cause is the class type, not the expression:** a per-model `"scale"` overrides the game config's scale expression entirely, and `FuncGodotFGDModelPointClass` always writes one (`func_godot_fgd_model_point_class.gd:69-82`, `if scale_expression.is_empty()` → literal `32.0`). Every entity here is therefore hard-wired to a literal 32 and the property-driven expression is never consulted.
- **Not the cause, despite fitting:** a `scale` name collision with the model map's own key. That was the first theory and it is wrong — the key name is fixed by `entity_assembler.gd:202-218` (`properties["scale"]`) but nothing in the FGD output suggests the parser is confused by it.
- **Attempted, four forms, none correct.** `scale * 32` in the model map → prop not drawn. `[scale * 32, 32]` in the model map → ~32× too small. `[scale * 32, 32]` as the game config's `entity_scale` → **scales correctly once a value is set**, unset prop invisible. `{{ scale == undefined -> 32, scale * 32 }}` as `entity_scale` → always natural size. The last is the informative one: **its `32` branch is taken even when `scale` is set**, so the identifier never resolves to the property at all — which also explains the first two rows, since the "fallback" 32 they appeared to land on is really the property failing to evaluate.
- **Two structural blockers, neither fixable from the FGD.** (1) TrenchBroom does not write an FGD default onto a newly placed entity, so `scale` is absent until the mapper types a value — making the property a `float` instead of a `String` does not change that, and an absent property makes the expression evaluate to nothing so the prop does not draw. (2) The **entity-browser preview has no entity**, so there is no property to read: a property-driven scale leaves the browser preview permanently blank however the unset case is handled.
- **Resolution — one shape works:** the conditional must sit in the **model map** *and* carry a property-free branch:
  `model({ "path": "...", "scale": {{ scale == undefined -> 32, scale * 32 }} })`. Set it via `scale_expression` on a `FuncGodotFGDModelPointClass`, or `display_descriptors[0].scale` on a `FuncGodotFGDPointClass` — both emit the identical line. The identical conditional in the game config's `entity_scale` always takes its `32` branch instead; **why the two contexts differ is not established**, only that they do.
- **Why that shape and no other:** TrenchBroom evaluates a model expression with **no entity behind it** in the entity browser (`TrenchBroom/TrenchBroom` #4253), and an FGD default is not written onto a freshly placed entity. Both make `scale` absent — so anything that *requires* the property leaves the prop undrawn, which is exactly the failure the first five forms produced. Assigning `32` to the missing case fixes the browser, the unscaled prop, and the scaled prop at once.
- **`entity_scale` stays a literal `32`** as the outer fallback for when the model map's expression cannot be evaluated. The `scale` key must be a numeric (`float`) type and must keep that name — `entity_assembler.gd:202-218` looks up `properties["scale"]` literally.
- **Confirmed in TrenchBroom 2026-09-28** on all three props: browser thumbnail draws, an unscaled prop draws at natural size, and setting `scale` scales the preview.

### 66. A rigged display model does not preview in TrenchBroom
- **Files:** `trenchbroom/entities/mannequin_ref.tres`; `trenchbroom/models/mannequin.glb` (rigged) vs `mannequin_static.glb` (baked); `tools/bake_static_model.gd`
- **Symptom:** one entity of three shows **no model at all** in TrenchBroom — not in the entity browser, not in the viewport — while the other two, using the same entity definition shape and the same scale expression, draw fine.
- **The distinguishing property:** the model is **rigged**. `mannequin.glb` is the only one of the three carrying `skins: 1`, 168 nodes, and `JOINTS_0`/`WEIGHTS_0`; `Truck.glb` and `Forklift.glb` have `skins: 0` and neither attribute. Everything else was ruled out: the GLB parses, its chunk lengths agree with the declared buffer size, it needs no textures, it uses no unsupported extensions (`GODOT_single_root` only, which the working models also carry), its `size` box contains the origin and is XY-symmetric, and its scale expression matches the others byte for byte.
- **Incomplete explanation on record:** TrenchBroom's Assimp path does have skeletal-animation handling, added for HL1 and [never validated against other formats](https://github.com/TrenchBroom/TrenchBroom/issues/1140), but its own description says it falls back to the unanimated path when a model has no animations — and this one has none. So the mechanism is not pinned down; "rigged models do not preview" is the **leading hypothesis**, not a proven rule. It is also the *third* explanation for this model, after the `studio`-vs-`model` keyword (#61) and the off-centre bounds (#64) — both of which were real defects that did not fix it.
- **Workaround:** `tools/bake_static_model.gd` strips the rig and writes a static `.glb`; the entity points its `display_descriptors` at that while keeping the rigged scene as its `scene_file`, so maps still build the real model. Requires `FuncGodotFGDPointClass` — a `FuncGodotFGDModelPointClass` would regenerate the display from `scene_file` and undo the bake.
- **Confirmed 2026-09-28:** with the `skins=0` bake the mannequin previews, so the rigged model was the cause. The mechanism inside Assimp is still not pinned down, but the rule is now empirical rather than hypothesised: **check `skins` before believing a display model is correct.**

### 67. Entities generated by the prop script build with no collision
- **Files:** `tools/generate_prop_entities.gd` (`_entity_text`, the `scene_file` line); affected entities under `trenchbroom/entities/` that came from `assets/props/`
- **Symptom:** a prop placed in TrenchBroom appears correctly in the editor, builds into the map, and is **walk-through in game** — no `StaticBody3D`, no `CollisionShape3D`, nothing to collide with. Nothing warns; the model is simply decoration.
- **Why:** the generator points `scene_file` at the **raw model**, and Godot's glTF importer synthesises collision only for meshes whose *names* carry a `-col` / `-convcol` / `-colonly` suffix (`nodes/use_name_suffixes=true`; the forklift's mesh is `Cube.001`). Verified against the imported scene: neither `StaticBody3D` nor `CollisionShape3D` is present.
- **Deliberate, for now:** collision is hand-authored where it matters. `Truck` is solid because its `scene_file` is a CSG scene with `use_collision = true` rather than a model — which is why it remains the one entity authored by hand. To make a generated prop solid, wrap it in a `.tscn` (`StaticBody3D` + the model instanced + a `CollisionShape3D`) and point `scene_file` at the wrapper, or name its source meshes with a `-col` suffix. See `docs/06-trenchbroom-entities.md`.

### 68. A text scene can serialize a texture as an inline `CompressedTexture2D` pointing into `.godot/imported/`
- **Files:** `maps/main_menu_world.tscn` — fixed on the wall material (was `:115-122`, `CompressedTexture2D_b3rx5`); **still live on the sky** at `:18-19` (`CompressedTexture2D_gpsch` → `kloppenheim_06_puresky_4k.exr-27b1161dfebcb065a385f1c82c00ce9b.bptc.ctex`). Check any hand-edited scene the same way: `grep -rn 'load_path = "res://.godot/imported' maps/`.
- **Symptom:** `ERROR: Unable to open file: res://.godot/imported/<name>-<hash>.<fmt>.ctex` at **`world_1.gd:32`** — the backtrace's `[0]` frame is the *caller* (`load_game_scene`'s `load(map_path)`), so it reads like a failed map load. It is not one: the map loads and the surface silently samples nothing. No magenta, no other warning.
- **Why:** Godot can write a `Texture2D` as an inline `CompressedTexture2D` sub-resource whose entire body is `load_path = "res://.godot/imported/…"`. That is a **build artifact, not a project resource**: `.godot/` is gitignored, and the hash in the filename comes from the source file plus its import settings. It dangles whenever the source is deleted or renamed, when the import settings change (a reimport writes a new hash directory), or on any clean checkout. Here the source was `assets/images/greybox/greybox_light_solid.png`, deleted while the greybox textures moved to `trenchbroom/textures/greybox/`; only the `.md5` for that hash survived, so the `.ctex` itself was gone.
- **Not fatal — verified 2026-09-28.** A `PackedScene` containing a `CompressedTexture2D` whose `load_path` names a nonexistent `.ctex` (no matching `.md5` either), and a scene with a missing `ExtResource`, **both still load**; only `Unable to open file` is logged. `load()` returns null for an unreadable or unparsable scene *file*, not for a dead dependency — so this cannot produce `Attempt to call function 'instantiate' in base 'null instance'` at `world_1.gd:32`.
- **Fix:** replace the inline sub-resource with an `ExtResource` on a real texture file. The wall's `ShaderMaterial_b3rx5.texture_b` now points at `greybox_grey_grid.png` (`4_ykm5p`), matching the light-floors/grey-walls pairing the two sibling materials in that same scene already use. **The sky is still on the baked form** and will go black on a clean checkout; converting it means pointing `PanoramaSkyMaterial_bgj78.panorama` at an `ExtResource` for `res://assets/environment/kloppenheim_06_puresky_4k.exr`, which `maps/hyb_castle.tscn` already references that way.

### 69. A health pack's availability is not part of any snapshot, so a late joiner can see a pack that is not there
- **Files:** `world/special_entities/health_pack_spawner.gd`; `world/special_entities/health_pack.gd`; `docs/02-netcode.md` §6
- **Symptom:** a client that joins while a pack is on its cooldown renders the pack at its scene default (available) until something changes. Walking into it does nothing — the heal is server-authoritative and the server knows the pack is gone — so it reads as "the pickup is broken" rather than "my state is stale". It self-corrects on the next availability change.
- **Why:** the availability boolean is **deliberately not a synced property** — it changes at most twice per pickup, so a `MultiplayerSynchronizer` would be a per-frame cost for something with nothing to interpolate. Nothing therefore replays it to a newcomer, and `phase_changed` is not replayed either (`components/game_mode_component.gd:128-144` writes the phase *without* emitting). The spawner closes that window by **pulling**: a client's `_ready()` sends `_request_availability.rpc_id(1)` and the host answers with `_set_available.rpc_id(get_remote_sender_id(), …)`. That is a plain reliable RPC, so the window only reopens if the connection itself is failing.
- **The failure direction is chosen, not accidental.** The scene default is available-and-visible. A stale *hidden* pack would be worse than a phantom one: the host would still allow the heal, so players would be picking up something they cannot see. A stale *visible* pack is a cosmetic that self-corrects.
- **Per-frame cost, recorded so a future map has a number:** server-side only, one `_physics_process` early-out per pack per physics tick (`health_pack.gd`), doing nothing unless a body is actually inside. Negligible for a handful of packs; if a map ever wants hundreds, drive it from the area's `body_entered`/`body_exited` instead of polling.
- **Suggested fix (if it ever matters):** make availability a `MultiplayerSynchronizer` property with `spawn = true` on the spawner, which delivers the current value with the node instead of requiring the pull. It costs a per-pack sync, which is exactly why it was not the first choice.

### 70. A brush entity's `auto_apply_to_matching_node_properties` defaults to `false`, so every class property is dropped silently

- **Files:** `trenchbroom/entities/{trigger,mover,rotate,button,physics}.tres`; `addons/func_godot/src/fgd/func_godot_fgd_entity_class.gd:38` (the default), `func_godot_fgd_solid_class.gd`; `addons/func_godot/src/core/entity_assembler.gd:250-265`
- **Symptom:** the entity builds, gets its script, gets its collision, and looks entirely correct in the scene — but every property the mapper set is at its script default. A trigger has `target == ""` and fires nothing; a mover has `move_translation == Vector3.ZERO` and does not move; `physics.mass` stays `1.0`. Nothing errors, and the FGD is correct, so the mapper sees their values in TrenchBroom and the game ignores them.
- **Why:** `auto_apply_to_matching_node_properties` is the only mechanism that writes a `.map` key onto the built node, and it **defaults to `false`** (`func_godot_fgd_entity_class.gd:38`). Without it, `apply_entity_properties` skips the whole per-property loop and only calls `_func_godot_apply_properties()`. That makes the failure shape distinctive and worth recognising: a property that needs build-time conversion still runs its conversion, on the **default** rather than the authored value — `button.depth` came out `0.125` (`4.0 / 32`) from an authored `16`, which is what pointed at the real cause.
- **Confirmed:** all five brush definitions were authored without the flag. `tools/verify_brush_entities.tscn` failed 7 assertions against it, and adding `auto_apply_to_matching_node_properties = true` to each cleared all of them.
- **Related:** `player_spawn.tres` and `health_pack_spawner.tres` both already set it, which is why `team` and `respawn_time` work. There is no equivalent trap for point entities that only use `scene_file`.
- **Suggested fix:** none needed now the flag is set. Worth remembering when adding any entity whose script owns `@export`s: `docs/06-trenchbroom-entities.md` lists it as the one setting that produces no error at all, but neither harness asserts it. A cheap future check would be to assert a registered entity with `class_properties` also has the flag.

### 71. A `moving_brush`'s link to its trigger only exists after the map is rebuilt **and saved**

- **Files:** `world/brush_entities/brush_entity_util.gd` (`link_targets`); `world/brush_entities/{trigger,button}_brush.gd` (`_func_godot_build_complete`); `addons/func_godot/src/core/entity_assembler.gd:267-268, 347`; `addons/func_godot/src/map/func_godot_map.gd:60-63`
- **Symptom:** a mapper wires a trigger to a door, tests nothing in the editor, and returns later to find the link gone — the trigger builds, the door builds, and walking into the trigger does nothing. Rebuilding the map without saving the scene produces exactly this.
- **Why:** the link is a `CONNECT_PERSIST` signal connection, so it is a *scene fact* rather than something resolved at runtime. It is created by `BrushEntityUtil.link_targets()` from each source entity's `_func_godot_build_complete()`, which func_godot calls **deferred** so that every entity exists by then (`entity_assembler.gd:267-268`). Connections only serialize into a `.tscn` when both endpoints carry an `owner`, which the assembler sets to `edited_scene_root` (`:347`) — so the wiring is real in the editor session and persists only if the scene is saved.
- **Consequence for verification:** `tools/verify_brush_entities.tscn` can prove the connection is made and carries `CONNECT_PERSIST`, but **cannot prove serialization**, because `edited_scene_root` is null outside the editor and `owner` is therefore never set on the generated nodes. That half needs a real build-and-save in the editor followed by a grep for `[connection]` in the `.tscn`.
- **Suggested fix:** none available — it is inherent to choosing build-time wiring over a runtime registry (the alternative, which would trade the editor-time lookup for a per-fire name search). Document it at the point of authoring, and treat "rebuild then save" as one action.

### 72. Qodot's `trigger` has no `wait`, no re-arm and no `spawnflags`, so it re-fires on every entry

- **Files:** `world/brush_entities/trigger_brush.gd`; `world/brush_entities/button_brush.gd`; `world/brush_entities/moving_brush.gd` (where the workaround landed)
- **Symptom:** a player who steps out of a trigger and back in re-fires it. It is not a Quake `trigger_multiple`, and there is no way to author a one-shot trigger — a trigger that fires exactly once per round regardless of what it drives.
- **Why:** this is a faithful port. Qodot's `trigger.gd` is eight lines that emit a signal from `body_entered` and never read the entity's properties at all; the entire "when and how often" semantics live in the Quake entity set Qodot chose not to ship. The port was deliberately kept to Qodot's set rather than inventing a Quake-idiomatic one alongside it.
- **Partly mitigated — the timing moved to the receiving end.** `mover` gained `wait` / `toggle` / `automatic` (`docs/06-trenchbroom-entities.md`), which covers most of what the missing flags were for: `wait` is a return delay in one-shot mode and a re-trigger guard in toggle mode, so a re-firing trigger no longer rattles a door, and `automatic` runs a platform with no trigger at all. What is still absent is the *trigger's* own `once` / `spawnflags`.
- **Also missing, same origin:** `trigger_hurt`, `trigger_teleport`, `trigger_push`, `func_button`, `func_plat`, and any `spawnflags`. `func_door` is now effectively `mover` + `toggle` + `wait`. `target` resolves to `use()` only, so `mover` is the only entity a trigger can drive.
- **Suggested fix:** for a one-shot trigger, add `once` / `spawnflags` to `TriggerVolume` — the emission point is one function and the build-time wiring does not care how often the signal fires. Adding a `targetfunc` key would let a trigger name a method other than `use()`, which is the general form of the same limitation.

### 73. `PhysicsBrush` sync is approximate by nature and cannot be made exact cheaply

- **Files:** `world/brush_entities/physics_brush.gd`; `docs/02-netcode.md` §9
- **Symptom:** a physics brush looks correct while it is at rest and slightly rubbery while it is actually moving — it lags the host, and its client-side pose is a replay rather than a simulation.
- **Why:** every other brush entity here is kinematic, so the host computes a pose and everyone adopts it exactly. A `RigidBody3D` is simulated by the physics engine on each machine independently, and two Godot/Jolt worlds given identical inputs do not stay identical — determinism holds only for identical builds, identical timesteps and identical contact ordering, none of which survives a network. There is no cheap way to make the client's simulation *match*, so it is not asked to: the host owns the body and streams its transform at 20 Hz, and clients freeze with `FREEZE_MODE_KINEMATIC` and follow.
- **Note:** the freeze mode is load-bearing. `FREEZE_MODE_STATIC` would pin the follower so the assigned transform never took effect — a client-side brush that simply stands still.
- **Suggested fix:** none for the current use. If a map ever needs a *reliable* physics prop, the workable shapes are to make it kinematic and drive it from the host (losing real physics), or to accept a lower-latency host by having the host also be the only peer allowed to interact with it. Recorded rather than fixed because Qodot's `physics` is a demo stub with a single `use()` that sets `linear_velocity.y = 10`.

### 74. A custom `class_properties` vector gets no axis swap, so a brush entity moves sideways

- **Files:** `world/brush_entities/brush_entity_util.gd` (`to_godot_axes`); the `_func_godot_apply_properties` hook on each of `moving_brush.gd`, `rotating_brush.gd`, `button_brush.gd`, `physics_brush.gd`; `addons/func_godot/src/core/entity_assembler.gd:209, 224`
- **Symptom:** the entity builds, the value reads correctly in TrenchBroom's inspector, and the brush moves the wrong way — a door a mapper aimed `"0 0 128"` at rises not at all and instead slides horizontally. Worse, because map-unit conversion *is* applied, the movement is also 32× smaller than typed, so the common first reaction is "it barely moves" rather than "it moved wrong".
- **Why:** TrenchBroom is Z-up and Godot is Y-up. func_godot swaps its own vector keys — `origin` at `entity_assembler.gd:224`, a per-axis `scale` at `:209`, both `(x, y, z) -> (y, z, x)` — but a custom `class_properties` vector is parsed straight out of the `.map` text and handed over in the order it was written. There is no generic hook; each property has to opt in.
- **Found by:** authoring the first real map by hand (`trenchbroom/maps/test.map`), where `move_translation "0.0 1.0 0.0"` was meant to lift a platform and would have moved it 3 cm sideways.
- **Covers:** `move_translation` and `move_scale` (mover), `axis` (rotate, button), `velocity` (physics). `move_rotation` is deliberately *not* swapped — a rotation triple encodes component order (pitch, yaw, roll), which is portable across the two conventions, unlike an axis identity. `depth` is a scalar and unaffected.
- **Suggested fix:** done — every directional property goes through `BrushEntityUtil.to_godot_axes()`. `tools/verify_brush_entities.tscn` now asserts **literal Godot vectors** (`move_translation == (0, 2, 0)` from an authored `"0 0 64"`) rather than deriving the expectation through the same helper, so a regression here fails the harness. Worth remembering for any future brush-entity property that is a direction.

### 75. A mover returning to its origin teleported home — `[FIXED 2026-09-29]`

- **Files:** `world/brush_entities/moving_brush.gd` (`_apply_progress`)
- **Symptom:** opening a mover was animated and closing it was instant. It worked until the return leg was exercised at all, which is why the one-way version shipped clean.
- **Why:** the pose was computed by interpolating **from the authored pose towards whichever pose the mover was heading for** — `base.interpolate_with(target, _progress)`, with `target` itself switching on `_target_open`. On the way out that is `base -> base * offset` and behaves. On the way back the target *is* the authored pose, so both ends of the interpolation are the same `Transform3D` and every progress value yields fully closed. The mover snapped the instant `_target_open` flipped, on the host and on every client at once, since all of them derive the pose from the same two values.
- **The trap, stated generally:** an interpolation whose *far end* is chosen by the same flag that drives the motion is degenerate whenever that flag points at the near end. Anchor the interpolation at a fixed end and let the scalar carry position; direction must not enter the arithmetic.
- **Why the harness missed it:** `tools/verify_brush_entities.tscn` covered the wait/toggle/automatic *decisions* thoroughly and never checked the *pose*. Those tests all passed against the broken build. The gap was testing the state machine and assuming the geometry under it.
- **Suggested fix:** done. `_apply_progress` interpolates `base -> base * offset` on `_progress` alone, so it is direction-agnostic. The harness gained four assertions covering the pose — authored pose at 0, offset pose at 1, the midpoint at 0.5, and, the one that matters, that a given progress is the same position whichever way the mover is heading. Verified to fail against the old code with exactly the signature above before being kept.

### 76. No control-point map has a capture volume until it is rebuilt in TrenchBroom

- **Files:** `world/special_entities/control_point.tscn`, `maps/koth_castle.tscn`, `maps/dom_castle.tscn`, `maps/hyb_castle.tscn`
- **Symptom:** a control point renders, registers with its `GameModeComponent`, and shows `LOCKED` — and then never captures. Walking into it, with any number of players of either team, moves the label no further and changes no owner. Nothing errors, and the HUD indicator for the point sits at its neutral state.
- **Why:** the control point's capture volume used to be an `Area3D` + `BoxShape3D` authored inside `control_point.tscn`. It is now a **`trigger` brush the mapper draws**, wired to the point by `targetname` — see `docs/06-trenchbroom-entities.md`. That is a deliberate change, and it costs the three existing maps their volumes: `koth_castle` and `dom_castle` are hand-authored Godot scenes with **no `FuncGodotMap`**, so they cannot carry a brush at all, and `hyb_castle`'s ControlPoint is still a hand-placed sibling with nothing wired to it.
- **Accepted, not overlooked:** breaking `koth_castle` and `dom_castle` was chosen over keeping the `Area3D` in the scene. Restoring them means rebuilding both as `FuncGodotMap` scenes.
- **Suggested fix:** leave the existing `ControlPoint` instances alone — they are placed correctly and will work the moment a volume exists. To wire one by hand in the editor: place a `ControlPoint` entity (or keep the existing node), give it a `targetname`, draw a `trigger` brush around it whose `target` is that name, then **rebuild the map and save the scene** — the link is `CONNECT_PERSIST` and a rebuild that is not saved loses it (#71). Hoisting the check into a harness is not practical: the harness cannot serialize, so this half is always manual.
- **Found by:** converting the control point into a placeable entity on 2026-09-30.

### 77. A brush tag's `material` does nothing, silently, if TrenchBroom cannot resolve the name

- **Files:** `trenchbroom/trenchbroom_config.tres` (the `trigger` brush tag), `trenchbroom/textures/trigger.png`
- **Symptom:** a brush converted to the `trigger` class keeps `__TB_empty` faces — on conversion and on newly drawn brushes alike. It *does* turn semi-transparent. Saving writes `__TB_empty` into the `.map`. Texturing it by hand works and persists.
- **The rule:** TrenchBroom resolves a tag's `material` against its material collection by the texture's **full relative path** inside the materials root. If that name does not resolve, the tag does nothing and says nothing. The `attribs` half is a separate code path and keeps working, so the symptom is a brush that goes see-through but stays untextured — which reads as "half-broken tag" rather than "wrong material name".
- **This is the whole content of TrenchBroom [#4595](https://github.com/TrenchBroom/TrenchBroom/issues/4595)**, and it is worth knowing before re-diagnosing it: the issue was closed by [PR #4651](https://github.com/TrenchBroom/TrenchBroom/pull/4651) with a **config change, not a code change** — the stock Quake 2 tag said `material: "trigger"` when the texture actually lives at `e1u1/trigger`. Nothing in TrenchBroom was ever broken.
- **Ruled out (2026-09-30):** the name resolves and the tag *is* matched. `trigger` is visible in TrenchBroom's material browser beside `clip`/`skip`/`origin` (so the collection is current and the name is right), and a converted brush **does** go semi-transparent — which can only happen if the classname pattern matched and the tag was found. So this is neither a stale collection nor a bad name: the tag is applied, and only its `material` field is dropped.
- **Where that leaves it:** the remaining suspect is TrenchBroom's own condition for applying a brush tag's material — most likely that it fires when a brush is *created for* the entity (entity browser → select `trigger` → draw a new brush) and not when an existing brush is converted to it. **Unverified.** The one-line Quake 2 fix in PR #4651 argues the feature does work on the assign path, so this entry should not be trusted until that test is run.
- **The discriminating test:** with `trigger` selected in the entity browser, *draw* a new brush rather than converting an existing one. Textured ⇒ the condition is "created for", and the fix is a workflow change (`06` should say so). Untextured ⇒ TrenchBroom's apply path is at fault and this needs a bug report with our config attached.
- **Also true independently of any of this:** a tag only ever supplies a *default*, so it never repaints faces that already carry a texture. A pre-existing brush will not change for that reason alone.
- **Found by:** converting the trigger entity to a TrenchBroom brush tag on 2026-09-30.

### 78. Guessing a mesh's UV convention instead of authoring it — `[FIXED 2026-09-30]`

- **Files:** `player/calligraphy_sphere.gd` (`_tangent_to_uv`, `_patch_uv`, `_build_patch_mesh`)
- **Symptom:** ink appeared on the canvas but **not under the crosshair that drew it** — first reported as a left-right mirror, then as still-wrong after a sign flip. Everything looked functional; the strokes were simply somewhere the player was not aiming.
- **Cause:** painting is keyed by direction → UV, and the sheet was a stock `SphereMesh` whose texcoord convention was *guessed* at in closed form (`u = theta / TAU`, `v = phi / PI`). Painting and rendering only agree when the painting function is the exact inverse of the vertex generation, and nothing enforced that — the guess was a statement about engine internals that no headless test can falsify. It was wrong, in a way that was mistaken for a sign error, and the "fix" (negating `u`) was a second guess, made without looking.
- **Fix (final):** the ink no longer touches the sphere mesh at all. The bubble is a stock `SphereMesh` again and **untextured**, so nothing reads its texcoords; the drawable area is a separate `_patch` mesh — a spherical section generated in `_build_patch_mesh()` — whose texcoords come from `_tangent_to_uv()` while painting goes through `_patch_uv()`, the same map inverted. They are inverses by construction, in plain tangent space, with no equirectangular projection and no engine convention anywhere in the path. (An intermediate fix authored the whole sphere with `SurfaceTool` and made _that_ self-consistent; it worked, but scoping the map to a small patch — see below — made the sphere mesh irrelevant to the ink and deleted the problem outright.)
- **The invariant to preserve:** `_tangent_to_uv` and `_patch_uv` must stay inverses, and `_build_patch_mesh`'s vertex UVs must keep coming from the former. Change one alone and the symptom returns: ink landing away from the crosshair.
- **Two things this cost, worth not repeating:**
  - The first version asserted in a code comment and in this file that the `u` sign had been *measured*. It had not — it was inferred from one line of user feedback. Do not write "measured" for "guessed"; it is actively misleading to the next reader.
  - `BaseMaterial3D.texture_repeat` is a **`bool`** and already defaults to `true` on Godot 4.7 — there is no `TEXTURE_REPEAT_ENABLED` enum member on `BaseMaterial3D`; that name is Godot 3's `flags_repeat_enable`. The equirect map that needed it is gone, so this is only a note about the name.
- **Found by:** adding the calligraphy ability on 2026-09-30; resolved the same day after three failed play-test iterations.

### 79. The calligraphy canvas is an equirectangular map, so it distorts at the poles and has a seam — `[FIXED 2026-09-30]`

- **Files:** `player/calligraphy_sphere.gd`
- **Was:** the ink map covered the whole sphere as a 512×256 equirectangular unwrap. Texels crowded toward the poles, so the brush was effectively much finer — and much more aliased — near `y = ±1` (where `u` is singular, since every column names the same point), and the ±180° meridian was a seam a stroke could cross, splitting it across two non-adjacent image columns.
- **Fixed by the same change as #78, for a different reason.** The drawable area is now a **square section** of the sphere (`PATCH_DEGREES`, 15° by default) centred on wherever the player was looking when they raised the canvas, and the ink map is scoped to *that* rather than to the whole sphere. A tangent-space square has no poles and no seam, so both artefacts are gone by construction rather than mitigated.
- **The resolution consequence, which is what forced the redesign:** a 15°×15° region of a 512×256 equirectangular map is **21×21 px**. Not "a bit coarse" — unusable for drawing a character. Scoping the map to the patch gives it the full `CANVAS_SIZE` (256×256) instead, at a *quarter* of the upload cost the old map had. That is the real argument for the patch-local map; the pole/seam fixes are a bonus.
- **Found by:** adding the calligraphy ability on 2026-09-30.

### 80. The first cast that draws a given character stalls a frame building its scoring mask

- **Files:** `player/calligraphy_sphere.gd` (`_glyph_data`, `_compute_score`)
- **Symptom:** the first time a canvas is raised on a glyph the player has not drawn before, that frame hitches. Casts after that are free.
- **Cause:** `_glyph_data()` is cached in a `static Dictionary`, but on a miss it does all of the work in one frame on the main thread: `Texture2D.get_image()` (a PNG decode), `Image.convert()`, a **dilation** of every stroke pixel over a `SCORE_TOLERANCE_PX` (8) radius — ~3.5k stroke pixels × ~200 samples each — and a second full pass building the white-recoloured overlay copy. Five glyphs × two loops over 22 500 pixels.
- **Why it is only a hitch and not a stall:** it is bounded, it happens at most once per glyph per process, and it lands on a canvas raise rather than during a fight. The cache is `static`, so it is shared by every player in the process and never rebuilt — the five glyphs cost a few frames in total, spread across the first five casts.
- **Suggested fix:** if it ever shows in a profile, precompute the masks offline into a `PackedByteArray`-backed resource per glyph rather than dilating at runtime. The dilation is the expensive half and it is a pure function of a committed asset — nothing about it needs to be runtime work. Cheaper intermediate: drop the radius and test 4 offsets instead of a disc, or dilate separably (horizontal pass then vertical), which is the same result for ~2·r taps instead of r².
- **Found by:** adding glyph tracing on 2026-09-30.

### 81. The drawing score is a client claim the server cannot check

- **Files:** `player/weapon_controller.gd` (`calligraphy_release`), `player/calligraphy_sphere.gd` (`_throw`, `_compute_score`)
- **Symptom:** a modified client can send any score it likes and get a full-strength throw for a drawing it never made.
- **Why it is unavoidable, not a bug:** "how well did this match the character" is only knowable on the peer that drew it — the guide image, the ink and the trace comparison all live on the owner and are deliberately never networked (see `02-netcode.md` §7). Any check the server could run for itself would have to ship the drawing to it, which is a much larger change than it is worth for a cosmetic damage bonus.
- **What actually holds:** the score is **clamped** to `[0, 1]`, so a claim cannot exceed the design maximum, and it is the *only* thing the client gets to assert. The glyph index is resolved against the server's own `CalligraphyAbility.glyphs`, so a client cannot fire an arbitrary `WeaponFire`; and the whole request is refused unless the `calligraphy_hold` effect is present, which only the server can have granted. A cheating client gets a stronger hit from an element it was already entitled to throw — it cannot fire a projectile without spending the ability and the hold.
- **If it ever needs to be authoritative:** the server would have to receive the stroke geometry (or the ink bitmap) and re-run `_compute_score` itself. That is a real design change — a new RPC, a size budget, and rate limiting — and should not be done piecemeal.
- **Found by:** adding score-scaled damage on 2026-09-30.

### 82. The calligraphy throw only works because the holster is signal-driven — polling it would silently drop the shot

- **Files:** `player/weapon_controller.gd` (`set_holstered`, `_refresh_holstered`, `_is_ready`, `calligraphy_release`), `components/status_effect/status_effect_manager.gd` (`is_weapon_holstered`)
- **Symptom if the ordering is ever broken:** the throw does nothing at all — no projectile, no error, and the hold effect is already gone, so the player is left with an empty hand and no way to retry except by casting again.
- **The load-bearing chain:** `calligraphy_release` does `sem.remove_effect(HOLD_ID)` and then `fire_weapon_fire(...)` in the same call. The holster is refreshed from `client_effects_changed`, which `remove_effect` → `_sync_to_clients()` emits **synchronously**, so by the time `fire_weapon_fire` runs the gun is back in hand. `set_holstered(true)` makes `_is_ready()` false, and `fire_weapon_fire` bails on `not _is_ready()` — so if the holster were recomputed in `_physics_process` instead, that check would still read `true`, the shot would be dropped, and nothing would report it.
- **The rule:** the holster must stay derived from the effect mirror *and* stay signal-driven. If a future change needs it polled (e.g. a second holster source that emits no signal), `calligraphy_release` has to clear it explicitly before firing rather than relying on the refresh having happened.
- **Related:** the same shape as the `NetworkEvents` client-start takeover in `03-event-flow.md` — an ordering that is correct but invisible, where the failure mode is silence rather than an error. Anything that reads `_is_ready()` is a potential victim of a future reorder here.
- **Found by:** adding the no-weapon state on 2026-09-30.

### 83. Scoring a trace by precision alone is degenerate — it was replaced by F1

- **Files:** `player/calligraphy_sphere.gd` (`_compute_score`, `SCORE_TOLERANCE_PX`)
- **Symptom:** every score came out high, regardless of what was drawn.
- **Two causes, and only fixing one would not have been enough:**
  - **The metric.** The original rule was precision only — *fraction of the player's ink that landed on the character*. The amount of ink drawn never entered into it, so a single small dab placed on any stroke scored **100%**, and a short squiggle anywhere inside the character scored near it. That is inherent to precision, not a tuning problem.
  - **The tolerance.** `SCORE_TOLERANCE_PX` was 8 on a 150 px glyph. Measured across the five shipped glyphs, an 8 px band covers **34–51% of the sheet** — so "scribble roughly over the character" was scoring well even before the metric is considered.
- **Fix:** score is now the **F1** of precision (ink on the character) and recall (character covered by ink), with the tolerance tightened to **3 px** (band covers 21–34%). A single dab now scores ~4%, scribbling the character's box ~52%, and a confident trace ~80%. Both halves use the same tolerance — they are the same question asked from opposite sides.
- **Why it needs both halves, not just a tighter band:** tightening alone still leaves precision degenerate at the top end (a perfect dab is still 100% *of nothing*), and recall alone would reward flooding the sheet. Only the harmonic mean requires the ink to both stay on the character and cover it.
- **Cost of the fix:** the recall half needs the *ink* dilated, not just the glyph, so `_compute_score` gained a second dilation over the 256×256 map — see `04-optimization.md`. It runs once per cast.
- **Calibration note:** the tolerance was chosen from a measurement of the shipped art (`grep` the tables in this entry, or rerun the dilation sweep over `assets/images/chinese_characters/*.png`) rather than by eye. Re-measure if the glyph art is ever replaced — the numbers above are a property of *these* five images, and the first estimate for this constant was off by more than 2× because it was guessed instead of measured.
- **Found by:** the first play test of glyph tracing, 2026-09-30.

### 84. The character preview's ambient depends on the SubViewport staying `transparent_bg`

- **Files:** `world/character_subviewport_preview.tscn` (the `WorldEnvironment`), `world/loadout_menu.tscn:128-133` (`CharacterViewport`)
- **Symptom:** if `transparent_bg` is ever turned off on the loadout menu's `CharacterViewport`, the preview gains an opaque procedural-sky background behind the character instead of just ambient light.
- **Why:** the SubViewport is `own_world_3d = true`, so it renders into its own `World3D` and inherits no environment from the lobby — no ambient, no sky, no tonemapping. Because the character materials are `painted_toon.gdshader`, whose `light()` override replaces the built-in direct-light path, the *only* thing lighting the shadow side is the shader's wrap term plus the rim floor. The scene therefore ships a `WorldEnvironment` with `background_mode = BG_CLEAR_COLOR` and a `ProceduralSkyMaterial` attached: Godot skips the sky **draw** on a transparent viewport while still using the sky as the ambient/reflection source, which is what makes it a pure light source. That is a renderer detail the scene does not express anywhere — remove `transparent_bg` and the sky starts drawing.
- **Suggested fix:** leave `transparent_bg = true`; if an opaque background is ever wanted, that is the moment to revisit `background_mode` deliberately.
- **Measured 2026-09-30** (mean luminance of the character's pixels over the menu panel colour): ghost/juggernaut render at `0.307`/`0.090` under the old lights with no environment, and `0.331`/`0.144` at the shipped settings. The ambient is real rather than inert: with all three lights forced to 0, the ghost still renders at `0.213`.
- **Tune the ambient with the sky material's `energy_multiplier`, not `ambient_light_energy`.** With `ambient_light_source = AMBIENT_SOURCE_SKY`, sweeping `ambient_light_energy` from 0.0 to 3.0 produced a pixel-**identical** render on this scene, while `ProceduralSkyMaterial.energy_multiplier` moves it directly. The first pass at this change set `ambient_light_energy = 1.3` and shipped too bright, because the part of the image that actually changed was the light energies.
- **Also worth knowing:** the same environment is hand-duplicated by `character_portrait_generator.gd:_build_preview_environment()` (`:353-385`) for the offline portraits, which derive their sky from the editor's gitignored editstate (`#58`) rather than from this scene. Keeping the preview and the portraits looking alike is manual.

---

### 85. The payload route's head is guessed, so a branching chain silently drops points

- **Files:** `world/payload/payload_path_builder.gd` (`build_chain`)
- **Symptom:** a route that forks, or a map with two unrelated chains, builds **one** route from whichever chain the heuristic picked. The other points exist as nodes and do nothing. Points not on the chosen chain are counted and warned about (`"%d of %d path points are not on the chain"`), but a mapper who is not reading the console will just see a route that is subtly the wrong shape.
- **Why:** a Quake-style `target`/`targetname` chain has no declared entry point, so the head is inferred — it is the point no other point's `target` names. Two chains produce two heads, and a closed loop produces none; both cases `push_warning` and continue rather than failing, because a broken route should still leave the map playable.
- **Accepted, not overlooked:** the alternative is an explicit `start` flag on the head entity, which is one more thing for a mapper to get wrong, and a map with two payloads is not a shape this project has. Warn-and-pick was chosen deliberately.
- **Suggested fix:** if two routes are ever wanted, add an optional `route` name to both the path point and the payload, and scope `find_path_points`/`build_chain` to it. The `Path3D` is already in a group (`payload_path`) rather than being assumed unique, so `_path()` and the checkpoint lookup need no change — `find_path` would just need the same key.

### 86. A generated payload route is baked into the scene — but its line is still runtime-only

- **Files:** `world/payload/payload_path_builder.gd`, `world/payload/payload_path.gd`, `maps/map.gd`
- **Symptom:** the residual half of an old one. A mapper authors path points in TrenchBroom, rebuilds, opens the map scene — and the `Path3D` and its curve **are** there (they are baked on save), but the glowing route line is nowhere in the editor. It looks like the line was dropped.
- **Why:** only the route's *shell* is baked — the `Path3D` and its `Curve3D`. Everything derived from that curve is deliberately kept out of the file: the zone table and the `PathLine` tube are stripped by `PayloadPath.strip_derived()` before the save and rebuilt on every peer by `PayloadPathBuilder.ensure_path()` calling `configure()`. The reason is that the tube is a generated `ArrayMesh` plus a `ShaderMaterial`, and as node properties they would serialize into every map scene that carries a route.
- **Why the routing changed:** the route used to be compiled entirely at runtime, which meant *nothing* was in the scene. Baking the shell was the trade the user asked for — the curve is now inspectable and editable — accepting that it inherits a rebuild-**and-save** requirement (#71) that the pure-runtime route did not have. `bake_path()` refuses to run on a map that already hand-authors its route (the legacy `Path3D`), so the two shapes never coexist.
- **What to do instead:** inspect the curve in Godot (it is a real `Path3D` now), and the route line in play. The waypoints are still visible and draggable in TrenchBroom, where `PayloadPathPoint` is not rotatable and takes no `scale`, so the marker's position is the whole of what it contributes.
- **Note for debugging:** `PayloadPathBuilder.ensure_path()` is idempotent and safe to call from a console or a probe on any peer; it will return the route (baked or transpiled), or `null` with a `push_warning` explaining which part of the chain was rejected.

### 87. A payload zone has no in-world visual other than the route line

- **Files:** `world/payload/payload_path.gd`, `world/payload/payload_path_point.gd`
- **Symptom:** a `rollforward_zone`, or a `rollback_zone` and its no-wait rollback, can only be confirmed by watching the cart. Nothing on screen says which stretch the cart is in, and a mapper testing a route has no way to see whether their flags took effect short of playing it.
- **Why:** the user asked for the route line to be red, full stop, so no per-zone tinting was added — and `PayloadPathPoint` hides its marker at runtime (the sphere is authoring decoration, like `PlayerSpawn`'s mannequin).
- **Workaround, and it is a real one:** the flags are plain `@export`s on nodes that *are* in the built map scene, so the Godot editor shows them in the inspector per waypoint. `PayloadNode.payload_state` also distinguishes `ROLLING` from `IDLE`/`RETURNING`/`AT_CHECKPOINT` on the cart's own `Label3D` and in the escort HUD panel, which is enough to tell the regimes apart in play.
- **Suggested fix:** tint the line per stretch. The mechanism is already there — `PayloadPathLine` writes `UV.x` as arc-length, and `PayloadPath.zones` carries each stretch's `start` — so a second uniform (a stretch boundary) and one `mix()` in `payload_path_line.gdshader` would do it. Not done because it changes the appearance the user explicitly specified.

### 88. The payload's immediate-sync-on-state-change has never fired — `[FIXED 2026-09-30]`

- **Files:** `world/payload/payload.gd` (`_physics_process`)
- **Symptom:** none visible, which is why it survived. A payload state change reached clients on the next 15 Hz tick rather than at once — up to a `PAYLOAD_SYNC_RATE` (0.066 s) of latency on every transition, on top of the unreliable packet's own loss window.
- **Why:** the flag was read *after* the assignment it was comparing against.

  ```gdscript
  if new_state != payload_state:
	  _set_state(new_state)          # writes payload_state = new_state
  ...
  var _state_changed: bool = new_state != payload_state   # now always false
  ```
  So `_rpc_sync` only ever sent on the timer, and the `or` branch that was meant to short-circuit it was dead. The `_` prefix on the variable hid it from the project's unused-variable warning, which is the only reason a compiler check did not catch it.
- **Fix:** the comparison is captured before `_set_state`. Safe by construction — it can only ever send *earlier* than before, never later or more often than once per state change.
- **Worth knowing generally:** "read the old value after writing the new one" is invisible by inspection and silent at runtime whenever the flag feeds an `or` that is also satisfied by a timer. Grep for the shape, not just this instance.
- **Found by:** adding `ROLLFORWARD`, whose only distinguishing signal *is* the state enum — a state-only change with no progress delta behind it.

### 89. A rebuilt map leaves a hand-placed payload with a null `checkpoints` array — `[FIXED 2026-09-30]`

- **Files:** `maps/hyb_castle.tscn`, `world/payload/payload.gd` (`_bake_checkpoint_progresses`, `_resolve_generated_route`)
- **Symptom:** `Invalid access to property or key 'global_position' on a base object of type 'null instance'` from `payload.gd`, on map load, immediately and every time.
- **Why:** two causes stacked, and the second is the one worth remembering.
  1. **The map carried two carts.** `maps/hyb_castle.tscn` is a hand-authored scene wrapping a `FuncGodotMap`, and it still had the original hand-placed `Payload` node at the map root alongside the new `entity_44_Payload` the build produced. A func_godot rebuild only owns the subtree under its `FuncGodotMap`, so a hand-placed sibling survives it — and both carts register with the `GameModeComponent` and ride the same route.
  2. **`NodePath` arrays go `null`, not empty, when their targets disappear.** That hand-placed cart's `checkpoints = [NodePath("…"), ×5]` had pointed at the five `PathFollow3D` anchors of the map's old hand-authored route. The rebuild removed those nodes, so Godot left the array as `[null, null, null, null, null]` — still **non-empty**. `_bake_checkpoint_progresses` dereferenced a null on the first iteration, and the non-emptiness also meant `_resolve_generated_route` skipped discovering the checkpoints the map now actually had.
- **Fix:** `_bake_checkpoint_progresses` compacts the array to `is_instance_valid` entries before deriving anything from it, warns with the count, and `_resolve_generated_route` now compacts **before** testing for emptiness so an array of garbage is treated as unauthored. `_warn_if_duplicate` names the two-carts case, which was previously silent.
- **The general rule:** an `@export` array of `NodePath`-assigned nodes is not a stable authoring surface across a map rebuild. Never test it for emptiness without compacting first, and never dereference an entry without `is_instance_valid`.
- **Found by:** converting `hyb_castle` from a hand-authored payload route to the TrenchBroom entities, 2026-09-30.

### 90. Inserting a path point mid-route appends it to the end of the route — `[MITIGATED 2026-09-30]`

- **Files:** `world/payload/payload_path_builder.gd` (`build_chain`), `world/payload/payload_path_linker.gd`, `docs/06-trenchbroom-entities.md`
- **Symptom:** a route runs `A → B → C → D`, the mapper adds a fifth waypoint between B and C, and the route becomes `A → B → C → D → E` — with the new point placed where it belongs visually but wired to the end, so the leg from D dives back to the new point instead of continuing.
- **Why:** placement order is creation order. TrenchBroom appends a new entity to its own list, and func_godot builds entities in `.map` order, so a point created after the route already existed is last in the chain regardless of where it sits in the level. This is the deliberate cost of chaining by placement order rather than by hand-typed links — see `06-trenchbroom-entities.md`.
- **Mitigation:** the `Auto Setup Payload Path` button on `maps/map.gd` freezes a route that is already right into explicit `target`/`targetname` links written into the `.map`. After that, insertion reorders nothing, and the cost is one button press per route rather than a name typed into every point. A route that is never frozen keeps the behaviour above.
- **Still true, and visible immediately:** until a route is frozen, the generated route line draws the wrong leg the first time the map is run, so the feedback loop is one play-test rather than a mystery. Re-placing the point so it is created last in the right place also still works, and needs no tooling.
- **Not fixed by design:** ordering by anything else — nearest-neighbour along the route, distance to the cart, an index property — trades this for a worse failure. A heuristic that silently draws the wrong route is harder to notice and harder to correct than one that appends, and an explicit index property is a field to fill in on every point, which is the tedium the placement-order default exists to remove.
- **Found by:** replacing the `target`/`targetname` chain with placement order on 2026-09-30; mitigated the same day.

### 91. TrenchBroom cannot link or number entities, so the authoring tools live on the Godot side

- **Files:** `maps/map.gd` (`_auto_setup_payload_path`), `world/payload/payload_path_linker.gd`
- **The limitation:** upstream TrenchBroom has **no scripting and no plugin API**. Its
  [manual](https://trenchbroom.github.io/manual/latest/) documents extensibility as data only — game
  configs, FGD/DEF/ENT entity definitions, mods, material collections, preferences and keyboard
  shortcuts — plus running external programs. There is no way to make it fill in a property for you,
  and an FGD property value is a static string with no expression support (the `model()` expression is
  a special case for the display model path).
- **What that costs:** every "the editor should do this for me" idea about entity *links* has to be
  built outside the editor. The one feature that would have solved this case —
  [TrenchBroom #4554](https://github.com/TrenchBroom/TrenchBroom/issues/4554), auto-incrementing
  numbered `targetname`/`target` when duplicating, proposed specifically for `path_track` chains — has
  been open since June 2024 with no implementation.
- **What to do instead:** keep the tooling in this project, where file-writing tools already exist
  (`tools/generate_prop_entities.gd`, `tools/export_trenchbroom_fgd.gd`), and put the entry point
  where the mapper already is — an `@export_tool_button` on the map node. That is what
  `Auto Setup Payload Path` is.
- **The one thing TrenchBroom *can* help with**, should it ever be wanted: declaring a property as a
  `NodePath` in the `.tres` emits it as an FGD `target_destination`, which TrenchBroom renders as a
  picker over the map's existing names. `target` is deliberately **not** declared that way — the picker
  would help hand-editing, but forward references (a `target` naming a point that does not exist yet)
  are the normal case in a chain and it is unverified whether TrenchBroom preserves an unresolvable
  value.
- **Do not plan around `trenchbroom-api` on PyPI.** It advertises type stubs for "TrenchBroom's
  embedded Python module (`tb`)", which contradicts the manual. It is alpha, publisher-unaffiliated,
  and its page does not say whether it targets upstream or a patched build. The MCP server in the same
  search space likewise needs "a patched build", which is the pattern: people patch TrenchBroom rather
  than extend it.
- **Found by:** asking whether the linking could be made automatic on 2026-09-30.

### 92. Godot's own platform carry carried riders at 3x the platform's speed — `[FIXED 2026-09-30]`

- **Files:** `project.godot` (`netfox/time/sync_to_physics`, `physics/common/physics_ticks_per_second`), `player/player.gd` (`_force_update_is_on_floor`), `docs/02-netcode.md` §8
- **Symptom:** standing on the payload cart or a `mover` platform shoved the rider in the direction of travel hard enough to push them off the front. Worst on a fast cart, and worse the lower the frame rate. A first attempt to fix it by hand-rolling the carry then produced the *opposite* bug — sometimes no carry at all — which is what prompted abandoning the custom code.
- **Why:** `CharacterBody3D.move_and_slide()` applies the platform's motion as a position offset (`get_velocity_at_local_position(...) * delta`), once per **call**, gated only on the platform's velocity — never on the body's own. This project broke both of its assumptions at once:
  1. It called `move_and_slide()` **twice per tick** — once in `_force_update_is_on_floor()` (`player.gd:1133`, the zero-velocity probe that re-derives `is_on_floor()`) and once for real (`:1884`) — so the carry fired twice.
  2. It picked the delta from `is_in_physics_frame()`, and the netfox tick loop ran from `_process` (`sync_to_physics=false`) against 60 Hz physics, so that delta was the **frame** delta while a tick is `1/90 s`. Every other velocity term is rescaled by `NetworkTime.physics_factor` to fix exactly that; the engine's carry is not part of the sandwich and cannot be scaled.
  Net: `2 / physics_factor` = **3x** at 90 ticks / 60 fps, growing as frame rate falls.
- **Fix — use the engine's carry, and make the two invariants it needs true:**
  - `_force_update_is_on_floor()` now saves and restores `global_position` around its slide, not just `velocity`. It still re-derives the floor state for the tick netfox is about to simulate (which is why it exists — `global_transform` is restored from history but `is_on_floor()` is not), but it no longer moves the player, so its carry and floor snap are discarded.
  - `netfox/time/sync_to_physics = true` and `physics/common/physics_ticks_per_second = 90` (matching `time/tickrate`). The loop now runs from `_physics_process`, so `move_and_slide()` integrates with `1/90`, `physics_factor` is `1.0`, and one tick is one physics step. The carry is then exactly one tick of the platform's motion.
  - No custom carry code. A previous hand-rolled version (`_apply_platform_carry`, diffing the platform's transform with a cached baseline, `move_and_collide`, `CARRY_MAX_STEP`) was written and then deleted: it was far more machinery than the feature deserves, and it intermittently carried nothing, which two probes failed to reproduce.
- **Verified** with a throwaway `--script` harness running the real slide sequence: platform and rider both end at `x = 6.6444` after 300 ticks at 2 m/s (gap `0.00000`), and `physics delta == ticktime == 1/90` inside the tick. The same harness with the position restore removed lands the rider at `10.9334` — the doubled carry, reproduced.
- **Also fixed here:** the payload carried a `MultiplayerSynchronizer` replicating `.:position` at `replication_mode = 1` in parallel with `_rpc_sync` — a second writer that the mover brushes deliberately do not have. It stuttered the cart on clients and gave the physics server a velocity spike four times the real one, which the engine's carry then reads. It is gone, and `PayloadNode._request_state` (mirroring `MovingBrush` / `RotatingBrush` / `ButtonBrush` / `PhysicsBrush`, behind the same `BrushEntityUtil.should_pull_state` guard) replaces the `spawn = true` sync it was doing for late joiners. The payload and the movers also now **ease** toward their replicated progress on clients rather than snapping to it, which is what keeps the platform's reported velocity smooth enough for the carry to read.
- **Found by:** riding the payload cart on 2026-09-30.

### 93. The session tick rate is no longer settable at runtime

- **Files:** `network/network_manager.gd` (`apply_tick_rate`), `project.godot`, `docs/02-netcode.md` §8
- **Symptom:** a `push_warning` on the first `apply_tick_rate()` of every session: *"netfox/time/sync_to_physics is on, so the session tick rate is Engine.physics_ticks_per_second (90 Hz) and cannot be set per session."* No functional loss — the derived tick-count limits are still applied.
- **Why:** #92 turned `sync_to_physics` on so the engine's platform carry integrates with the tick delta. With it on, `NetworkTime.tickrate` answers `Engine.physics_ticks_per_second` (`network-time.gd:13-16`) and its setter is a `push_error` no-op, so the rate is a build setting rather than a per-session one. `apply_tick_rate()` detects this and returns early rather than writing a rate netfox would ignore.
- **Not fixed on purpose:** the alternatives are worse. Turning `sync_to_physics` back off re-breaks platform carry (#92). Making the tick rate settable again means decoupling it from physics, which is the thing that was wrong.
- **If a different rate is ever wanted:** change `physics/common/physics_ticks_per_second` and `netfox/time/tickrate` together in `project.godot` — they must stay equal for the carry to stay exact — and update the `[NTSYNC]` expectation in `03-event-flow.md`/`01-boot-sequence.md`, which assume a runtime handshake.
- **Found by:** implementing #92 on 2026-09-30.

### 94. Physics now steps at 90 Hz, up from 60

- **Files:** `project.godot` (`physics/common/physics_ticks_per_second`)
- **Symptom:** none observed. Recorded because it is the real cost of #92 and it is easy to forget where it came from.
- **Why:** the tick rate and the physics rate have to coincide for the engine's platform carry to integrate one tick's worth of motion at the right delta, and the project's tick rate is 90.
- **What to watch:** ~50 % more physics steps per second in Jolt, on every peer, for the whole session — not just while someone is standing on a cart. If a physics-bound profile ever shows up, this is the first knob to question, and the answer is to take the tick rate down to 60 with it rather than to decouple them again.
- **Found by:** implementing #92 on 2026-09-30.

### 95. A payload route with two coincident waypoints spams `The axis ... must be normalized`

- **Files:** `world/payload/payload_path_builder.gd:236` (`_build`, the `curve.add_point` loop)
- **Symptom:** loading `maps/hyb_castle.tscn` prints `ERROR: The axis Vector3 (0.0, 0.0, 0.913395) must be normalized.` five times — once per coincident pair — from `_build` via `ensure_path` and `PayloadNode._resolve_generated_route`. The route still builds and the cart still runs.
- **Why:** `Curve3D.add_point` derives a frame (forward/up/right) from the tangent to the neighbouring points. Two waypoints at (or very near) the same position give a zero-length tangent, and the up-vector it derives from that is the un-normalized `(0, 0, 0.913…)`. It is a duplicate or near-duplicate `PayloadPathPoint` in the map, not a code fault — the same build runs clean on the payload maps without one.
- **Not fixed on purpose:** the cheap guard would be to skip a point within some epsilon of the previous one, but the right epsilon is a guess and silently dropping a mapper's waypoint is a worse failure than a printed error that names the axis. Prefer fixing the map: find the two coincident points and remove one.
- **Found by:** loading `maps/hyb_castle.tscn` headless on 2026-09-30 while verifying #92.

### 97. The payload bake runs during the save, so the first save after a route change leaves the scene dirty

- **Files:** `maps/map.gd` (`_notification`, `_auto_bake_payload`), `world/payload/payload_track_builder.gd` (`bake`)
- **Symptom:** the map saves with the new route and track baked in, but the editor tab keeps its unsaved-changes asterisk — so the very save you expected to be a clean no-op still reads as "you have unsaved work".
- **[b]Qualified by #103:[/b] that holds only when the nodes already exist.** `add_child` cannot run inside a propagated notification, so a save can *refresh* a route and track but never *create* them — on a fresh map, press the button.
- **Why:** the bake must add its nodes **before** the file is written, so it runs in `NOTIFICATION_EDITOR_PRE_SAVE`. Adding nodes marks the edited scene dirty again, which is unavoidable for anything that changes the scene *as part of* saving it. `POST_SAVE` would avoid the asterisk but would be useless — it fires after `pack()`, so the nodes would appear only on the *next* save.
- **Accepted, and bounded to one extra save:** a second save is a clean no-op. `PayloadTrackBuilder.bake` short-circuits when the container's `bake_signature` metadata still matches the route, and matching touches nothing at all, so it cannot re-dirty. The cost is exactly one extra save per route change.
- **What to do instead:** press **Bake Payload Route & Track** before saving when the extra save matters. It runs the identical bake, so the save that follows finds the signature already current.
- **Suggested fix:** none wanted. The alternative — keeping the generated nodes out of the scene and rebuilding them at runtime, the way the route's *derived* half already is — is the design this replaced, on the user's explicit call for the track to be baked and editable.

### 98. A baked payload route and track are stale until the map is saved

- **Files:** `maps/map.gd`, `world/payload/payload_path_builder.gd` (`bake_path`), `world/payload/payload_track_builder.gd`
- **Symptom:** move a path point in TrenchBroom, rebuild the map in Godot, and the railroad still runs through where the route *used* to be. It catches up the moment the map is saved, which makes it look intermittent.
- **Why:** both bakes run from `NOTIFICATION_EDITOR_PRE_SAVE` (see #97). A func_godot rebuild replaces the `FuncGodotMap` subtree, and the baked `PayloadPath` and `PayloadTrack` live under the **Map root**, deliberately, so the rebuild neither updates nor removes them — only the save does.
- **Accepted:** this is the direct price of the route and track being real scene nodes instead of runtime-generated ones. The alternative was #86's runtime route, which could never be visible in the editor at all.
- **What to do instead:** after a rebuild, press **Bake Payload Route & Track** (or just save). `PayloadTrackBuilder.signature` includes every curve point position, so the bake does notice the move and rebuilds rather than short-circuiting.

### 99. A map with both path points and a hand-authored route gets no baked route — by design

- **Files:** `world/payload/payload_path_builder.gd` (`bake_path`, `_legacy_route`)
- **Symptom:** `bake_path` pushes a warning naming the hand-authored `Path3D` and returns `null`; the track is still swept, but no `PayloadPath` is written.
- **Why:** the three maps that predate the path points (`castle`, `esc_castle`, `hyb_castle`'s siblings) carry a plain `Path3D` their cart is wired to by NodePath. If a mapper adds `PayloadPathPoint` entities to one of those maps, baking would create a **second** route beside the authored one: the cart would keep riding the old path while every `find_path` lookup returned the new one — silently, with no error. Refusing to bake is the honest behaviour.
- **Accepted, not overlooked:** the check is a hard refuse rather than a merge, because there is no correct merge — two routes in one map is a map-authoring mistake, and the warning names the node to delete.
- **Suggested fix:** delete the hand-authored `Path3D` (and re-point `PayloadNode.path_follower`) if the path points should own the route. Not automated, because it means re-wiring a `NodePath` the mapper authored.

### 100. Hand-placed `PayloadTrackStraight` entities double up with the generated track

- **Files:** `trenchbroom/entities/payload_track_straight.tres`, `assets/props/payload_track/payload_track_straight.tscn`, `world/payload/payload_track_builder.gd`
- **Symptom:** a map that still holds hand-placed track segments gets a second railroad swept through the same place once it is baked.
- **Why:** the entity predates the generator and is still live — `maps/hyb_castle.tscn` carries **21** instances, and `trenchbroom/maps/test.map` more. `bake` cannot tell a hand-placed segment from scenery, so both render.
- **What to do instead:** delete the hand-placed `PayloadTrackStraight` entities from the map (in TrenchBroom) when adopting the generated track. The entity definition and prop are **kept**, not removed — removing the definition would turn every already-placed instance into a `Marker3D` on the next rebuild (#60), which is a far worse failure than a duplicate.
- **Suggested fix:** have `bake` warn when the map still contains hand-placed segments, which is cheap — the built entities are instanced from the prop scene, so they are recognisable by `scene_file_path`. Not done yet; the count above is from a manual census.

### 101. `PayloadPathBuilder.ensure_path()` now writes to a serialized node at runtime

- **Files:** `world/payload/payload_path_builder.gd` (`ensure_path`), `world/payload/payload_path.gd` (`configure`)
- **What changed:** before the bake, `ensure_path` only ever built a transient node. It now also finds a **baked** route and calls `configure()` on it, which fills in `path_points`, `zones` and the `PathLine` mesh — state it previously only ever wrote to a node it had just created itself.
- **Why it is safe:** every field `configure` writes is non-`@export`, so it cannot serialize; the baked node is a **shell**, and the derived half is rebuilt per peer exactly as it always was. `strip_derived()` runs before the save and clears those fields back out, so the file on disk is unaffected by what a previous session's load put in memory.
- **Worth knowing when debugging:** a `PayloadPath` you inspect in a running game has a populated `zones`; the same node in the saved `.tscn` has none. That is the contract, not a bug — see #86.

### 102. `PayloadPath` had to become a `@tool` script, or the editor could not call into it — `[FIXED 2026-10-01]`

- **Files:** `world/payload/payload_path.gd`
- **Symptom:** with a payload map open in the editor (`esc_castle`), saving or closing it printed
  `Invalid call function 'strip_derived' in base 'Path3D (PayloadPath)': Attempt to call a method on a placeholder instance. Check if the script is in tool mode.`
  twice — once from `payload_path_builder.gd:331` (`bake_path`) and once from `map.gd:287` (`_strip_derived_route`).
- **Why:** Godot instantiates a script that is **not** `@tool` as a `PlaceHolderScriptInstance` in the editor. The object still reports its own class — `get_script()` is the real `GDScript`, so `node as PayloadPath` succeeds and the error names `Path3D (PayloadPath)` — but it carries **no methods and no script properties**. The node is nonetheless *written* by editor-side code: `map.gd` (`@tool`) calls `PayloadPath.strip_derived()` from `_strip_derived_route()`, which runs from both `_exit_tree()` and `NOTIFICATION_EDITOR_PRE_SAVE`, and `PayloadPathBuilder.bake_path()` calls it at its end. Both are editor-only paths, so both hit a placeholder and, in Godot 4, a failed call aborts the calling function — which is why `bake_path` also returned `null`.
- **Fix:** `@tool` on `payload_path.gd`. It executes nothing that was not already executing: the script has no `_ready` and no `_process`, and `configure()` is only ever reached at runtime. The annotation exists purely to make the instance real on the editor side.
- **Verified 2026-10-01:** reproduced in a headless editor (`godot_console.exe --path . --editor --headless --quit-after 600 res://maps/esc_castle.tscn`, firing from `_exit_tree`), then zero occurrences after the change.
- **Worth knowing:** a **game** run is unaffected either way — a non-tool script is a real instance there, so no runtime path and no headless harness can ever catch this class of bug. It is the same rule the brush entities follow: anything whose node an editor-side tool has to call a *method* on must be `@tool`. `PayloadPathLine` and `PayloadPathPoint` are deliberately **not** `@tool` — nothing calls into them from the editor, and `strip_derived()` only touches `PayloadPathLine.mesh`, a native property that answers fine on a placeholder.
- **The same rule caught `PayloadNode` (`world/payload/payload.gd`) at the same time**, and there the cost was real rather than cosmetic: func_godot's `entity_assembler.gd:265` calls `_func_godot_apply_properties` on a built entity, so the error
  `Invalid call function '_func_godot_apply_properties (via call)' in base 'AnimatableBody3D (PayloadNode)': Attempt to call a method on a placeholder instance.`
  meant a `Payload` placed in TrenchBroom **never had `vertical_offset` axis-swapped or unit-converted** — the cart would sit sideways and 32× too far. It is `@tool` now, with `Engine.is_editor_hint()` guards on `_ready` and `_physics_process` (the same arrangement `world/brush_entities/moving_brush.gd` uses) and no guard on `_func_godot_apply_properties`, which must run at build time.

### 103. `add_child()` fails inside a *propagated* notification, so the save-hook bake can only update a route, never create one

- **Files:** `maps/map.gd` (`_notification` → `_auto_bake_payload`), `world/payload/payload_path_builder.gd` (`bake_path`), `world/payload/payload_track_builder.gd` (`bake`)
- **Symptom:** saving a map whose `PayloadPath` / `PayloadTrack` do not exist yet prints
  `ERROR: Parent node is busy setting up children, add_child() failed. Consider using add_child.call_deferred(child) instead.`
  followed by **two** `ERROR: Invalid owner. Owner must be an ancestor in the tree.` — one per node the detached container would have owned (itself and its `MeshInstance3D`).
- **Why:** `Node::add_child` refuses while the parent's internal `blocked` counter is non-zero (`scene/main/node.cpp:1721`), and `propagate_notification` is what raises it. `NOTIFICATION_EDITOR_PRE_SAVE` reaches **every descendant** of the edited scene, i.e. it is propagated — so during the save hook the `Map` is blocked and `root.add_child(container)` cannot succeed. **Verified 2026-10-01** with a throwaway `SceneTree` probe: `add_child` from a `_notification` reached via `propagate_notification()` fails with exactly that error, while the identical call from `_ready` succeeds.
- **Consequence — the save hook's bake is update-only.** It works on a map that already carries the nodes, which is why #97 and #98 read as if saving bakes them; on a map where they do not exist yet the save cannot create them. Press **Bake Payload Route & Track** — the tool button calls the identical code *not* through propagation. `remove_child` is not blocked, so a stale container is still deleted either way.
- **Suggested fix:** none taken yet, because it is a change of documented behaviour rather than a bug fix. The options are to do the creating half on the button only (leaving PRE_SAVE to refresh), to keep the generated nodes out of the scene and rebuild them at runtime — the design #97 replaced on an explicit call for the track to be baked and editable — or to create them from `_process` on the frame after a save.

### 104. Removing a bot leaves dangling references behind — `[FIXED 2026-10-23]`

- **Files:** `world/spawn_manager.gd:69-77` (removal), `components/attribute_component.gd:176-208`, `weapon/projectiles/simple_projectile.gd:111-122`, `world/payload/payload.gd:477-484,642-646`, `player/player_ui.gd:886-903`, `player/bot_controller.gd:503-525`, `world/host_server_area.gd:62-67`, `world/practice_range.gd` (zone list)
- **Symptom:** removing a bot with the spawn menu's ✕ could error one or more frames later — `Invalid access to property or key 'is_bot' on a base object of type 'null instance'` at `attribute_component.gd:184` (or `:202` for a heal), or a per-frame `Previously freed instance` from a projectile still stuck in the removed bot, the payload cart, or the ability-preview cache. Because `queue_free()` is deferred and the work that pays out (a projectile in flight, an explosion tick, a burn/bleed/poison tick) is world- or victim-owned, the error looks unrelated to the removal.
- **Why:** removal is a bare `queue_free()`; `Player` has no `_exit_tree`. A damage source is carried as a **name**, and a name may stop resolving (`GameManager.find_player` → `null`) the moment the bot is freed; several other systems cached a **node reference** instead. Godot 4.7 makes a freed reference compare `== null` and test falsy, so `if x != null:` / `if x:` **skip** it — yet `x as Player` and `x.prop` still raise `Trying to cast a freed object` / `Previously freed instance`. Neither null comparison nor truthiness is a liveness test: the damage-number popup's `if _target_node != null:` guard therefore never nulled its dead target, and the later cast crashed (the original `FIX TODO` at `damage_number_popup.gd:149`).
- **Resolution:** `apply_health_delta` now treats a missing changer as an anonymous source — damage/heal and score credit still apply, only the hit-sound / damage-number feedback (which needs a live player) is skipped. The stuck projectile frees itself when its hurtbox is gone; the payload pusher loops (`_tick_healing`, `_count_team`), the targeted-ability preview cache, the medic bot's heal-target revalidation and the two lobby zone lists all validate with `is_instance_valid()`. **The check must come before the cast** — `cached as Player` on a freed object raises `Trying to cast a freed object` on its own, so filtering the preview cache needs `if not is_instance_valid(cached): continue` *then* the cast. The two references held **across frames** (the damage-number popup's target and a lodged projectile's stuck target) now use `WeakRef`: `get_ref()` returns `null` once the object is dead, which is the only structurally safe way to hold a node whose lifetime you do not own. A lodged projectile also carries an explicit `_is_stuck` flag, because a dead target and "never attached" are otherwise indistinguishable once the freed reference compares equal to `null`.
- **Worth knowing:** `host_menu._assignment` is still not pruned when a bot is removed; it only over-counts teams for auto-fill (every `find_player` there is null-checked), so it is not part of this crash.

### 105. Bot projectile lead ignores the shooter's forward momentum and fired recoil

- **Files:** `player/bot_controller.gd` (`_solve_linear_lead`, `_solve_ballistic_lead`, `_shot_arc_blocked`), `player/weapon_controller.gd:2918-2919` (`_spawn_projectile`'s `forward_boost`)
- **Symptom:** none observed in a stationary test, but a bot firing while running toward the lead direction can over-lead by roughly `velocity_projectile / forward_boost`. The arc validation also models the shot from the desired camera direction, which is close to but not exactly the fired ray while recoil is nonzero.
- **Why:** the solver uses the projectile's authored speed and the estimated target velocity, while the real launch is `world_dir * speed + world_dir * max(shooter.velocity.dot(world_dir), 0)`. The solver has no shooter-velocity term, and it does not read `Body/Recoil` when sampling the path. Both are second-order for a walking bot (3 m/s vs 20-50 m/s) and deliberately ignored in Stage 6 rather than adding a coupled solver.
- **Suggested fix:** after the first solve, set `effective_speed = speed + max(player.velocity.dot(dir), 0)` and re-run one iteration; for validation, transform the direction by the current recoil rotation. Do not add `forward_boost` to `_get_proj_info` itself — it is per-shot and per-shooter, not a property of the scene.

### 106. Bots aimed healing gravity projectiles at the impact point, not along the launch arc — `[FIXED 2026-10-25]`

- **Files:** `player/bot_controller.gd` (`_predict_aim_point`, `_act_heal`, `_solve_ballistic_lead`)
- **Symptom:** a bot using the Syringe Gun visibly aimed low and the syringe dropped below the ally. Heal Grenade Launcher and Medpack Launcher had the same failure mode.
- **Why:** the ballistic solver returns both `target_point` (the predicted impact) and `point` (a far point along the lofted launch direction). Combat used `point`, but the heal wrapper `_predict_target_pos` returned `target_point` and `_act_heal` fed that to the Mouse. The bot therefore looked straight at the ally and fired flat, discarding the gravity compensation the solver had just computed.
- **Fix:** the heal helper is now `_predict_aim_point` and returns `solution["point"]`. For non-arc projectiles the two points are identical. Keep this distinction: `target_point` is for validation/lead maths, `point` is the look target.
- **Verified:** at 15 m a syringe solution had `dir.y = 0.075`, `target_y = 3.00`, `aim_y = 5.34`; the wrapper returned exactly the launch `point`. A live bot healed an ally from 63 to 125 HP.

### 107. FLEE/COVER/COMBAT can cycle when a critical bot has no reachable shelter

- **Files:** `player/bot_controller.gd` (`_assess_retreat`, `_act_flee`, `_end_flee`, `_act_retreat_cover`, `Decision._desired_state`)
- **Symptom:** a bot at the flee threshold in open ground or a corner alternates a few seconds of running with a couple of seconds of fighting. It may visibly pace between directions.
- **Why:** the thresholds are health/pressure based, not destination based. FLEE sets `_flee_cooldown` (1-2.5 s) and cover sets `_cover_cooldown` (2-6 s), which bound the cycle, and the "no destination → fight" fallback intentionally stops a bot from grinding into geometry — but neither removes the oscillation.
- **Suggested fix:** validate a flee destination before entering FLEE (make `_assess_retreat` destination-aware), or raise the cooldowns / add hysteresis on the health threshold if it reads poorly in play. Do not remove the cornered fallback: running into a wall forever is worse.

### 108. Hunt-seed and flee-search ray bursts can coincide

- **Files:** `player/bot_controller.gd` (`_seed_hunt_points`, `_find_flee_position`, `_find_cover_position`)
- **Symptom:** a frame-time spike when several bots lose line of sight in the same tick (search seeding) or drop below the flee threshold together (flee + cover searches). Individual cost is bounded: ~48 rays per hunt seed and ~72 per flee search.
- **Why:** each is state-entry-only and candidate-capped, but the work is additive across bots. Bots already stagger their think phase (`_timer = randf_range(0, PROCESS_INTERVAL)`), which spreads but does not eliminate collisions.
- **Suggested fix:** if it regresses with 12+ bots, lower `HUNT_ANGLES` / `HUNT_SWEEP_RADII`, drop a flee ring, or add a shared per-frame ray budget for AI searches. Measure with the debug overlay and the frame-time log before tuning.

### 109. Damage while frozen or stunned is booked on the first free tick

- **Files:** `player/bot_controller.gd` (`_physics_process` early returns, `_record_damage`)
- **Symptom:** a bot shot while frozen/stunned can resume already at high `_recent_damage` and immediately FLEE, because the whole health delta is recorded on the first tick after the early return.
- **Why:** health sampling and the damage bucket sit after the frozen/stunned/not-spawned early returns, by design — the reaction layer should not run while the bot is locked. The bucket is a leaky fraction, so the spike decays over ~2.5 s rather than compounding.
- **Suggested fix:** if it matters, sample health before the early returns and record damage there (but keep `_react_to_damage` behind the lock), or decay the bucket by the elapsed lock time.

### 110. FLEE deliberately outranks medic self-heal below the flee threshold

- **Files:** `player/bot_controller.gd` (`Decision._desired_state`, `_act_self_heal`)
- **Symptom/trade-off:** below the flee threshold a medic runs for 2-5 s instead of standing still to heal. Once `_flee_cooldown` is set, HEAL takes over.
- **Why:** a stationary heal at 10 % under fire is usually death; creating space first is the human choice. This reverses the older "self-heal outranks cover" ordering only for the critical band — HEAL still outranks COVER at 34-50 %.
- **Alternative:** gate FLEE on "no self-heal weapon" or require low recent pressure before a standstill heal, if medics read as too passive. Whichever is chosen, keep the ordering in one place (`_desired_state`).

### 111. Hunt sweep points are ray-validated, not route-validated (mitigated)

- **Files:** `player/bot_controller.gd` (`_ground_point`, `_seed_hunt_points`, `_act_search`, `NavRoutes.query`)
- **Symptom:** a sweep point can be standable in isolation but unreachable from the bot (across a gap, behind a wall, on another floor). A navmesh partial path is followed only to the closest reachable point (`PathSource.NAV_PARTIAL`), and since 2026-10-27 a partial approach is abandoned after `HUNT_PARTIAL_ABANDON` (0.5 s) and each point's timeout is distance-scaled (`2–8 s`) instead of a fixed 3.5 s. On an unbaked map the `TravelGraph` fallback still applies.
- **Why:** `_ground_point` checks only a floor ray and a headroom ray; it deliberately does not require LOS back to the hunt origin (that would exclude the far side of the pillar). The directional fan (3 radii × 5 angles) is seeded before any route query, so an unreachable candidate still consumes one timeout (now bounded).
- **Suggested fix:** when the navmesh or graph is ready, query the route to each candidate before appending it and drop points with no full route; keep the no-LOS rule — it is what makes the sweep clear cover.

### 112. `_accept_self_damage` estimates splash from the full authored value

- **Files:** `player/bot_controller.gd` (`_accept_self_damage`, `_too_close_for_explosive`, `_weapon_damage_viable_at`, `_weapon_situation_score`, `_try_explosion_jump`)
- **Symptom:** a borderline rocket jump or point-blank explosive is occasionally accepted when the real blast would drop the bot a little lower than predicted, or refused when the falloff would have made it safe.
- **Why:** `ExplosionComponent` damage falls off with distance from the blast and can be multiplied further (team/character/self multipliers); the bot reads `splash_health_delta * self_health_delta_multiplier` as a single full-power value. That is conservative in the common case and cheap, but not a simulation of the real hit.
- **Suggested fix:** if it matters, apply the same falloff curve the explosion uses to the expected distance from the blast centre, or add a small safety margin to the comparison. Keep the policy: self-damage is acceptable while healthy; only refuse a blast that would leave the bot about to die.

### 113. Spectator HUD shows a remote target's ability pools as ready
- **Files:** `player/player_ui.gd` (`_update_ability_cooldowns`), `player/abilities/ability_manager.gd:44-50`
- **Symptom:** watching another player from a client shows their ability circles fully ready, and their meter/charge bars at rest, regardless of what the target is actually doing. The health/ammo/stamina/weapon readouts are correct.
- **Why:** cooldown, charge-bank and meter pools are deliberately per-peer and never networked (the same limitation as #46/#47). The spectator HUD reads the *spectator's local copy* of the target's `AbilityManager`, which never receives casts. On the host it reads the authoritative server copy and is accurate.
- **Suggested fix:** if exact cooldowns matter, broadcast a coarse per-player ability snapshot from the server at a low rate and have `PlayerBodyUI` prefer it when `_spectator_bound`. Do not move the pools into the rollback/state sync just for the HUD.

### 114. First-person spectating depends on the target model's `head_meshes`
- **Files:** `world/spectator_controller.gd` (`_apply_camera`), `player/player_model.gd:26-36`
- **Symptom:** spectating a character whose `PlayerModel.head_meshes` is unset shows the inside of their head in first person.
- **Why:** the camera copies the target's first-person camera transform and the controller calls `target._set_own_head_visible(false)`; that only hides the meshes listed on the model scene. The controller re-applies it every frame because `_apply_model_visibility()` (ghost tiers) can re-show them.
- **Suggested fix:** every character model scene should list its head/face meshes, exactly as the first-person owner path already requires.

### 115. Spectator HUDs are built on demand and stay built
- **Files:** `player/player_ui.gd` (`set_spectator_active`, `_ensure_built`), `world/spectator_controller.gd`
- **Symptom:** a peer that spectates many different players accumulates one built `PlayerBodyUI` (and its UI timer) per watched target for the rest of the world's life. Only the current target's HUD is visible; the rest sit hidden and idle.
- **Why:** `_ensure_built()` is one-shot per Player copy and `set_spectator_active(false)` only hides, rather than freeing, the widget — re-binding is the common case when cycling.
- **Suggested fix:** if this ever matters (very long sessions, many targets), free the built HUD on unbind when it is not the owner's own, or cap the number of remembered builds.

### 116. A bot's loadout is server-only, so clients (and spectator HUDs) see a bare mannequin
- **Files:** `world/spawn_manager.gd` (`_apply_bot_loadout_with`, `_apply_saved_bot_loadout`, `_apply_bot_weapons`), `player/player.gd` (`rpc_sync_full_state`)
- **Symptom:** on the host a bot has its character and weapons; on a connected client the same bot renders as the default mannequin with no weapon models, and spectating it shows an empty weapon list. The camera, health, team and movement are correct.
- **Why:** bot loadouts are applied only on peer 1 (`controller.apply_loadout` + `set_character`), and the `_loadout_*_path` fields that `rpc_sync_full_state` sends are only ever set for human loadouts (`world/loadout_menu.gd:1089`) and randomized human respawns (`player/player.gd:944`). A late-joining peer's `_sync_existing_players_to_peer` therefore sends empty paths for bots, and a bot spawned while a peer is connected is never synced at all.
- **Suggested fix:** store the applied paths on the bot in `_apply_bot_weapons`/`_apply_bot_loadout_with` and broadcast a loadout sync (or reuse `rpc_sync_full_state` after the apply) on every peer. Do not solve it by putting `PackedScene`/weapon objects in a synchronizer.

### 117. A baked navmesh is a build artifact, and some geometry cannot be represented

- **Files:** `maps/navmesh_generator.gd` (`AGENT_MAX_CLIMB`), `maps/death_castle.tscn` (`NavigationMesh`), `player/bot_controller.gd` (`NavRoutes`)
- **Symptom:** after changing an agent/cell setting in `navmesh_generator.gd`, pressing **Setup Navigation** and saving does **not** change the shipped mesh until the region is re-baked; bots keep using the old vertices. Separately, on a map with a payload cart or `mover` door, the `AnimatableBody3D` collider is baked at its **authored** position (static-collider mode accepts `StaticBody3D` subclasses), unlike the old `TravelGraph`, which excluded dynamic bodies by RID. Crouch-only passages and jump-gap shortcuts are absent because the mesh uses standing height and has no links. A ledge taller than `AGENT_MAX_CLIMB` (1.0 m) is not connected either, even though it may still be jumpable below `JUMP_STEP_MAX`; Recast can only link what the bake is told to connect.
- **Why:** `NavmeshGenerator.setup()` only writes `NavigationMesh` bake inputs; the resource is baked by `NavigationRegion3D.bake_navigation_mesh()`. Dynamic props are not marked differently from static map collision for the parser, and a single agent-height mesh cannot express crouch or jump routes.
- **Suggested fix:** always re-bake and save after changing a setting; the shipped maps must be re-baked after the 1.0 m change. If a moving collider matters, exclude it from the nav source group or add a `NavigationObstacle3D`. `_ledge_jump_state` handles vertical faces up to `JUMP_STEP_MAX` (1.1 m) once the mesh routes to them; a **drop** is represented only by the `TravelGraph`, whose `DROP_MAX` is 12 m (fall damage starts at 15 m) — ESC castle's SCI spawn is ~9 m above the cart and relies on that fallback. A jumpable **gap** should also be left to the graph (nav partial → graph bake), because the follower has no generic "execute a `NavigationLink3D` jump" path. Author a ramp/stairs for anything wider than the character's jump.

### 118. Remaining bot path/state handoff gaps

- **Files:** `player/bot_controller.gd` (`_follow_path`, `_act_search`, `_act_flee`, `_act_retreat_cover`, `_act_combat`, `_trigger_stuck`, `_react_to_damage`)
- **Symptom:** a `PathSource.NAV_PARTIAL` route stops at the closest reachable point. COMBAT now gives up after `COMBAT_CHASE_STALL_TIME` (1.5 s), but FLEE, RETREAT_COVER and HEAL keep calling the same partial route until their state timer expires, so the bot can stand at that point for 2-10 s. Several early returns (combat switch/reload, reload-safe, cover, heal-state) still leave the previous movement keys held, so the bot can keep walking unguided; travel/wander and the unready `_act()` now zero them. Nav path queries still ignore `_recent_stuck` (only stage 4 demotes nav for 5 s), and hunt sweep points use a fixed 3.5 s timeout that can skip distant ones (the approach to a heard sound is now distance-scaled).
- **Why:** `Traversal` has no "partial approach ended" signal for callers, `Keyboard` latches keys until changed, and `NavigationServer3D.map_get_path` has no per-query avoidance penalty.
- **Suggested fix:** expose a partial-approach/failure flag and repick flee/cover/heal destinations on it; perturb the nav goal or briefly demote nav on a stuck event.
- **Fixed 2026-10-27:** the hunt deadline is wall-clock (`_search_deadline_ms`, ticked at the top of `_think`, so it expires through HEAL/COVER/FLEE); hunt points are distance-timed and partial approaches abandoned after 0.5 s; the main combat/heal/reload/cover early returns release movement keys via `_release_movement()`; the lost target is remembered/predicted rather than erased.
- **Still open:** FLEE/RETREAT_COVER/HEAL can still sit on a partial route until their state timers expire (COMBAT has its own stall check), unattributed fall damage that carries a direction can still start a SEARCH, and `ManeuverRunner`, `_act_pursue_last_seen` and `_reload_while_travelling` remain dead code. The combat peek/cover behavior reuses the existing `_act_retreat_cover` state rather than the dormant runner.

### 119. A freed bot target crashed `BotController._think`

- **Files:** `player/bot_controller.gd` (`_think`, `_physics_process`)
- **Symptom:** removing a bot could throw `Invalid type in function '_update_target_velocity_estimate' ... The Object-derived class of argument 1 (previously freed) is not a subclass of the expected argument class` from every bot that still had the removed bot as `_current_target`.
- **Why:** `_think` called `_update_target_velocity_estimate(_current_target, now)` unconditionally. A freed object compares `== null`, but it still fails the typed `Player` parameter check before the function's own `is_instance_valid` guard can run. The scan's stickiness comparison could also keep a freed `prev_target`.
- **Fix (2026-10-26):** clear invalid `_current_target`/`_heal_target` at the top of `_physics_process` and `_think`, guard the velocity call and the `_estimated_velocity_for` access, and sanitize `prev_target` before the scan's stickiness comparison. Verified headlessly: free one bot while another targets it, call `_think()` directly — no error, target becomes null.

### 120. Target memory is deliberately single-target and predictive

- **Files:** `player/bot_controller.gd` (`_think`, `_mark_target_unseen`, `_predicted_last_known`, `_begin_memory_search`, `_target_position_for_ai`)
- **Symptom / limits:** only the current target has identity/recognition memory. Acquiring another visible enemy overwrites it, so a bot cannot resume a chase after switching. A predicted pursuit point is a 2 s frozen-velocity lead (capped at 20 m); if the runner turns sharply, the directional fan (±55°) is the fallback, not true tracking. Reacquisition outside the 140° recall cone falls back to the normal 120° horizontal FOV and recognition, and an invisible/dev-hidden target is forgotten immediately. The detection cone is horizontal; `Camera3D.fov = 90` is vertical (KEEP_HEIGHT), so the rendered horizontal FOV is ~121° at 16:9. A 90° detection cone left a blind band at the screen edges; 120° matches it.
- **Why:** this is the intended scope of the 2026-10-27 pass — enough memory to stop the one-tick target drop and make a runner pursuit plausible, without wallhack tracking or per-enemy memory. While unseen, all reads use the frozen `_memory_last_position`; `_target_position_for_ai()`/`_target_look_point_for_ai()` are the audited entry points. The hidden live body is never read.
- **Suggested future work:** a small per-enemy last-seen table if multi-target re-engagement matters; a route-validated fan (#111); and consider the dormant `ManeuverRunner` if combat peeks need scripted timelines beyond the existing cover state.

### 121. The bot objective hold radius is a bot-side approximation

- **Files:** `player/bot_controller.gd` (`OBJECTIVE_HOLD_RADIUS`, `_control_point_info`, `_payload_info`, `_act_hold_objective`, `_act_combat`)
- **Symptom:** a control point's capture volume is a TrenchBroom `trigger` brush with no exposed radius, so `OBJECTIVE_HOLD_RADIUS` (3 m) is the bot's guess at "touching the point". If a mapper draws a much smaller capture brush, a bot can hold/capture from just outside it; if the brush is much larger, bots cluster at the centre. A payload is computed from its actual `PushZone` box (`PayloadNode.get_push_zone_horizontal_radius()`, 0.95× the short horizontal half-extent); `push_radius` is an authored gameplay radius, not the trigger shape, and using it parked bots just outside the box so the cart never moved. The route arrival radius also used to have a hard 1.5 m floor, which is larger than the payload box; `_objective_arrival_radius()` now uses 0.7× the hold radius (minimum 0.5 m). Actual overlap with the push Area3D (`PayloadNode.has_pusher`) also counts as "at objective", so a bot blocked by the cart body holds and pushes instead of trying to reach an impossible centre.
- **Why:** the point scene deliberately has no `Area3D` or radius export; the trigger brush is authored in the map and linked at build time. The bot cannot cheaply read the brush's shape through `BrushEntityUtil`.
- **Suggested fix:** add a `capture_radius` export to `ControlPoint` (mirroring `PayloadNode.push_radius`) and use it as the hold radius; or compute the linked trigger's AABB once. Until then, tune `OBJECTIVE_HOLD_RADIUS` for the project's maps. The 12 m `OBJECTIVE_LEASH_RADIUS` is also a deliberate bot-side choice: a visible enemy farther than that does not pull a bot off the point.

### 122. Persistent heard memory is intentionally un-timed

- **Files:** `player/bot_controller.gd` (`_on_sound_made`, `_persistent_heard_*`, `_search_persistent`, `_tick_target_memory`, `_objective_is_near`)
- **Symptom / limit:** after hearing an enemy, a bot with no objective nearby keeps `_persistent_heard_position` forever and an un-deadlined `HUNT` search loops the fan until it finds a target, a new sound replaces the lead, or an active objective comes within `OBJECTIVE_NEARBY_RADIUS` (20 m) of the bot. **An active objective outranks the persistent search:** `_act_search` pulls the bot back whenever it is outside the objective hold radius, and reaching the point with no visible target ends the search; a sound heard while already on the point does not start one. The heard memory remains for later. The memory is not cleared by time, only by respawn or a newer accepted sound.
- **Why:** this is the requested "remember where they last heard the enemy forever as long as there is no objective nearby". The alternative — timing it out — is what made bots forget sounds in the lobby. The objective hold pull is what stops a heard lead from parking attackers away from a cart or leaving them facing the wall the sound came through.
- **Suggested tuning:** raise/lower `OBJECTIVE_NEARBY_RADIUS` if bots leave objectives too readily (raise) or ignore audible fights near points (lower). The memory is per-life; do not persist it across respawn unless that becomes desirable.

### 123. The map manifest hashes source bytes, so the export must not convert text scenes to binary

- **Files:** `network/match_manifest.gd`, `tools/map_manifest.gd`, future `export_presets.cfg`
- **Symptom:** `MatchManifest` hashes the bytes of each map file with `FileAccess.get_sha256()`. Godot's export option `convert_text_resources_to_binary` rewrites `.tscn` resources into binary at export time, so a manifest generated from the source tree will not match the exported client or dedicated server. Every join then fails the handshake with `MAP_MISMATCH`, and the error looks like a corrupted map rather than an export setting.
- **Why:** the map manifest exists so maps never cross ENet. That only works if the client and server hash identical files, and the export is the first point where those bytes can change.
- **Suggested fix:** keep `convert_text_resources_to_binary` disabled in both the client and the Linux Dedicated Server preset; generate the manifest in the same build step as the export; run `godot_console.exe --path . --headless res://tools/map_manifest.tscn -- --check` in CI before shipping. If binary conversion is ever required, hash the exported file from the PCK instead of the source `.tscn`.

### 124. Server-side join sync can send RPCs before the client's world exists

- **Files:** `world/spawn_manager.gd:29-38` (`_sync_existing_players_to_peer`), `network/network_manager.gd:351-364` (`enter_existing_game_scene`), `network/network_manager.gd:844` (`_on_connected_to_server`)
- **Symptom:** a joining client logs `Node not found: "Main/World1/SpawnParent/<id>/StatusEffectManager"`, `Failed to get path from RPC`, and `Invalid packet received. Requested node was not found`. The server's `peer_connected` handler adds the Player and then syncs existing players after one process frame, but the client may still be building `world1.tscn` (character previews, loadout menu, navigation region). The RPC arrives before the node the server addresses exists on the client.
- **Why:** the one-frame defer assumes both peers build the world in the same frame. A dedicated server that accepts a connection while idle makes the client's build time more variable, so the race is wider than in the old simultaneous P2P join.
- **Suggested fix:** make the client signal `world_ready` after `enter_existing_game_scene` has completed, and have the server add the roster Player and send late-join sync only after that signal. This is the P2 handshake in `docs/07-dedicated-server.md`. Until then the error is noisy but non-fatal: the next sync re-sends the state.
- **P2 status:** fixed for the joining player's own node. The client sends `client_node_ready` after its Player exists, the server hides existing players' `MultiplayerSynchronizer`s from that peer until then, and `StatusEffectManager` only broadcasts to ready peers. Existing-player state still travels through the old `rpc_sync_full_state` path after readiness; the chunked join state is the planned replacement. Late joins now also hide each newly spawned Player's synchronizers for two frames so established peers receive the spawn before state sync.

### 125. The client's first loadout/model spawn can stall after its tick loop starts

- **Files:** `network/network_manager.gd:844-880` (`_on_connected_to_server`), `world/loadout_menu.gd:97-157` / `_ready`, `player/player.gd` (`spawn`, `_spawn_character_model`)
- **Symptom:** on a dedicated server the client starts `NetworkTime`, then builds the loadout preview and the first character model. A measured headless join spent ~0.8 s in that frame and netfox logged one `Trying to run rollback for ticks … past the history limit of 63` warning before recovering.
- **Why:** the join settle check covers only the world scene build. The loadout preview and the first spawned character model are built afterwards, on the tick loop's time. In the old P2P flow the host and joiner stalled together; a dedicated server keeps ticking, so the client falls behind.
- **Suggested fix:** preload/preview character models before `NetworkTime.start()`, or start the client tick loop only after the first loadout is applied and the first player has spawned. The P2 `world_ready`/`player_ready` handshake is the right place for this; do not simply widen the history window.

### 126. A match-session map swap has no client-ready barrier

- **Files:** `network/network_manager.gd` (`load_match_map`), `world/world_1.gd` (`_on_session_phase_changed`, `_install_session_map`), `network/match_session.gd` (`set_phase`)
- **Symptom:** on a match-session map swap the server replaces the map locally, broadcasts `phase_changed(ACTIVE, path, hash)`, and immediately calls `rpc_reset` for every player. Each client loads the same map from disk asynchronously. A client can be respawned before its map node exists, so its first ticks run against the staging map's collision and it can fall through or be corrected when the new map arrives.
- **Why:** the P2 map model is "local load + hash"; the server announces the path but does not wait for clients, and `rpc_reset` is an unreliable `call_local` RPC that is not ordered against the reliable `phase_changed`.
- **Suggested fix:** add the map-start handshake: broadcast `phase_changed(LOADING, path, hash)`, have every client reply `map_ready` after loading and verifying, and only then swap/respawn and broadcast `ACTIVE`, with the 15 s deadline in `MatchProtocol.MAP_MATCH_DEADLINE_SECONDS`. Do not solve it by adding sleeps to the server.
- **P3 status:** the host-start path is verified (client → `MatchSession.request_start_match` → server `load_match_map` → local map load on every peer), and a name-collision bug was fixed: the client must `remove_child()` the old `Map` before `queue_free()`, or the new map is auto-renamed (`Map2`) and every `Map/...` path breaks. The barrier is still recommended for a large map or a slow client, because the server respawns immediately after broadcasting.

### 127. A Player whose synchronizer is invisible is never spawned on that peer

- **Files:** `world/spawn_manager.gd` (`_reveal_player_after_spawn`, `hide_players_from_peer`), `network/match_session.gd` (`client_node_ready`)
- **Symptom:** setting `public_visibility = false` on a newly spawned Player's `MultiplayerSynchronizer`s, to stop state sync arriving before the spawn, also stops the node from being spawned on the joining client. The client sits with `SpawnParent = ["Map"]` forever and the loadout confirm times out waiting for its Player.
- **Why:** Godot's scene replication gates a spawn for a peer on the node's synchronizer visibility. Visibility cannot be used as a "spawn first, state second" barrier. Setting public visibility back to true after three frames does not retroactively deliver the missed spawn.
- **Current mitigation:** the new Player's synchronizers stay public. The client sends `client_node_ready` once its own node exists; live state for *existing* players is still public and can arrive before their nodes, producing `Ignoring sync data from non-authority or for missing node`. That warning is non-fatal, but it is the remaining late-join race.
- **Suggested fix:** make the server wait for a spawn acknowledgement before treating the peer as in-game (the chunked join-state step), or use a custom spawn function with a client-acknowledged token. Do **not** re-enable `public_visibility = false` on player synchronizers without re-testing a join; it silently prevents spawning.

### 128. lobbyd passes the HMAC secret on the child's argv

- **Files:** `server/lobbyd/lobbyd.c` (`spawn_match`), `network/join_grant.gd`
- **Symptom:** the match server is spawned with `--match-secret=<secret>`, which is visible to anything that can list processes on the host. WSL interop did not pass `MATCH_SECRET` through the Windows child's environment, so argv is the dev workaround. A server started without any secret accepts every join grant, which is intentional for direct `--connect` dev but unsafe for a lobby-spawned server.
- **Why:** the secret is what stops a client from minting its own grant; a leaked secret defeats it.
- **Suggested fix:** pass the secret through a root-only `0600` file or the loopback control handshake, never argv; make `--server --match-id=` refuse to start when no secret is configured; add a `--allow-insecure` dev flag for the direct-connect path. P5.

### 129. lobbyd has no control channel or child re-adoption

- **Files:** `server/lobbyd/lobbyd.c` (poll loop, `spawn_match`, `reap_children`)
- **Symptom:** browser rows come from process liveness only: the phase is always `staging`, the player count is a count of issued join grants (not actual connections), and there is no heartbeat or idle teardown. Restarting lobbyd loses its match table; the live child servers keep running but are no longer supervised, and their ports are not reclaimed until those processes exit. An empty match server stays alive indefinitely.
- **Why:** P3 implements the HTTP allocation half of the plan; the loopback control protocol (`hello`/`heartbeat`/`state`/`event`, child journal) is not written yet.
- **Suggested fix:** add the control socket from `docs/07-dedicated-server.md`: child reports phase and connected players, supervisor journals `{pid, match_id, ports, secret}` for re-adoption after restart, and empty/staging matches are terminated after a grace period. P4/P6.

### 130. Resume tokens are single-use, but the nonce is not bound to a session epoch

- **Files:** `network/join_grant.gd` (`issue_resume`, `resume_data`), `network/match_session.gd` (`hello`, `_send_welcome`)
- **Status:** fixed in P5. Each welcome issues a token with a nonce; the roster entry remembers the latest nonce; `hello` rejects any older token (`SESSION_EXPIRED, Resume token was already used`), and the accepted resume rotates the nonce. A captured current token can still be used once before the real client reconnects, but it cannot be replayed afterwards.
- **Remaining:** the nonce is per-player, not per-connection-epoch; a full session-token/epoch scheme (with a server-side revocation list) would close the single-use window entirely.

### 131. Host migration promotes the next player, but there is no explicit host UI

- **Files:** `network/match_session.gd` (`_expire_reserved`, `broadcast_host`), `world/host_server_area.gd` (`_is_leader`)
- **Status:** fixed in P5. Pre-auth connections are reaped after `Protocol.PREAUTH_TIMEOUT_SECONDS` (20 s, because the client builds its world before the handshake). When the host's reserved slot expires, `_expire_reserved` promotes the lowest surviving **connected** player and broadcasts `host_player_id`; the new host's HostServer zone and Start Match now pass the server's `is_player_host` check.
- **Remaining:** no dedicated "host changed" notification in the HUD, and a host who stays reserved keeps the role until the grace expires (by design).

### 132. Detaching the world before queue_free breaks netfox's deferred settings

- **Files:** `network/network_manager.gd` (`_remove_game_scene`, `host_local_match`)
- **Symptom:** the shell → listen-server transition logged `SCRIPT ERROR: Cannot call method 'get_unique_id' on a null value` from `RollbackSynchronizer.process_authority` and `TickInterpolator.process_settings`. Twice per transition.
- **Why:** `_remove_game_scene()` used `remove_child(game_scene)` then `queue_free()`. Removing the node makes `Node.multiplayer` resolve to null immediately, but netfox's `process_settings` had been deferred from a property change and ran after the removal. `get_unique_id()` was called on the null MultiplayerAPI.
- **Fix:** `queue_free()` only; keep the world in the tree until the end of the frame so deferred netfox work sees a valid tree. Do **not** reintroduce `remove_child()` for the world scene.
- **Related:** `host_local_match()` also keeps the offline peer alive until `create_server()` replaces it, for the same reason (nulling the peer early exposed the same null path).

### 133. LAN discovery announces are unauthenticated and unbounded

- **Files:** `network/lan_discovery.gd` (`_announce_json`, `discover`), `world/globe_menu.gd` (FIND MATCH LAN list)
- **Symptom:** any process on the LAN can answer a probe with arbitrary map/player/state metadata, and replies are not rate-limited. A spoofed entry appears in the browser exactly like a real host. Joining it still goes through `hello` → `welcome`, so a fake entry only produces a failed or timed-out join; it cannot bypass the handshake or a configured grant secret.
- **Why:** P3/P4 need zero-service discovery first; the announce carries no secret.
- **Suggested fix:** sign announces with the same HMAC secret (hosts already have one), rate-limit replies per source, and have the client reject an announce whose game port does not accept a handshake. P5.

### 134. Auto-picking a listen port logs a handled ENet bind error

- **Files:** `network/network_manager.gd` (`boot_listen_server`)
- **Symptom:** when 8080 is busy, the log contains `Couldn't create an ENet host` / `Could not bind UDP port 8080 (error 20)` before the server starts on 8081. The process continues normally and the fallback works.
- **Why:** Godot's ENet wrapper prints the engine-level failure before returning the error code; there is no silent-mode bind.
- **Suggested fix:** pre-check the port with a temporary `PacketPeerUDP` bind before calling `create_server`, or accept the line as expected output. Cosmetic.

### 135. Payload-path harness fails on an already-linked real map

- **Files:** `tools/verify_payload_path.gd:246-258`, fixture `trenchbroom/maps/test.map`
- **Symptom:** `verify_payload_path.tscn` exits 2: `FAIL: the linker rewrote res://trenchbroom/maps/test.map, which is already linked` and `FAIL: the linker found 1 gaps in an already-linked map`. The test opens the real map read-only and expects `PayloadPathLinker.link_map_text()` to return it byte-identical with zero `named`/`linked` results; the current fixture has one unlinked waypoint, so the linker rewrites it.
- **Why:** map-authoring tooling, unrelated to the netcode rework. Not bisected; it may be a fixture that drifted from the linker's expected linked state.
- **Suggested fix:** run `Auto Setup Payload Path` on `test.map` and commit the linked file, or update the harness to assert the exact expected gap count. Do not change the linker to force zero gaps without a failing real map.

### 137. Post-resume firing is not covered by the smoke test

- **Files:** `tests/net/run_net_smoke.ps1`, `player/weapon_controller.gd` (`_sync_mag` test print), `network/network_manager.gd` (`_begin_reconnect`)
- **Symptom:** in a manual P5 run with `--test-fire`, authoritative mag syncs stopped after `resumed as player 2` even though movement and input authority were restored. It may be benign (the weapon was empty/reloading, or the held-fire test hook was cleared by the respawn) rather than a netcode bug.
- **Why:** the smoke test asserts resume + movement, not a post-resume shot.
- **Suggested fix:** add a harness step that waits for `spawned=true` after resume, then asserts a new `fire_intent` is accepted (mag decrements) with the held-fire hook, or drive a one-shot fire explicitly.

### 138. Remote Player authority was the stable player id, not the ENet peer — `[FIXED 2026-11-16]`

- **Files:** `player/player.gd` (`owner_peer_id` setter, `_apply_input_authority`, `bind_owner_peer`), `world/spawn_manager.gd:166-186`, `network/match_session.gd:161-175`, `player/player.tscn:56-65` / `:531-536`.
- **Symptom:** every client flooded `ERROR: Ignoring sync data from non-authority or for missing node.` at ~60/s per remote player (dedicated server + 2 clients: 1773 and 2430 in ~30 s), and the other player's body never turned/aimed. In the worse case the client also transmitted no input: the server never simulated it, so its copy stayed at spawn and server-spawned projectiles/tracers (`%Head.global_transform`, `weapon_controller.gd:2952`) came out of the spawn point while the owner saw normal local prediction. Listen-server runs and the smoke harness showed zero errors, because player 1's node name equals peer 1 and no third-party observer existed.
- **Why:** a match session names the node with the stable `player_id` (`2`, `3`, …) while the owner is a random ENet peer. On a client, `_enter_tree` derived the owner from the node name before the replicated `owner_peer_id` spawn property arrived, and nothing re-applied it afterwards — so `Body` (the only client-owned synchronizer: `Body:rotation`, `Recoil/Head:rotation`, `WeaponTilt:rotation`) had an authority no packet is sent from, and Godot dropped the whole stream. Separately, `bind_owner_peer()` changed `PlayerInput` authority without netfox's `process_settings()`, so the per-peer owned-input cache could stay empty for the session.
- **Fix:** `owner_peer_id` is a property whose setter re-runs `_apply_input_authority()` (catching the replicated spawn value and the resume rebind); `bind_owner_peer()` still re-applies unconditionally because the value can match while authority is stale; `_apply_input_authority()` calls `rollback_sync.process_settings()` when the node is ready and this peer owns the input, rebuilding netfox's ownership cache deterministically.
- **Verification:** dedicated server + two concurrent `--connect --auto-loadout --test-move` clients: zero `Ignoring sync data` in both client logs and on the server; both `[NTSYNC]` lines keep `inp` tracking `tick` and `state` fresh with `pred=false`. Listen host + one client unchanged.
- **Residual (TODO):** `process_settings()` clears that Player's state history on the owning client, so a bind that lands mid-session can log a few `netfox::DiffHistoryEncoder Reference tick … missing` warnings until the next full state (`full_state_interval = 45`). Harmless today; if it becomes visible, refresh ownership without tearing down the state history. The smoke harness still has no third-observer assertion — see `tests/net/run_net_smoke.ps1` and #137.

### 139. `HoldBlend` was dead audio-visual state and is now live in combat

- **Files:** `player/player.tscn:712` (`parameters/HoldBlend/blend_amount`), `player/animation_tree.gd` (`HOLD_RATE` and the target blend), `player/player.gd` (`in_combat`), `player/weapon_controller.gd` (`_refresh_holstered` / `refresh_holstered`).
- **Symptom / risk:** the `HoldBlend` parameter shipped at `0.0` and no script ever wrote it, so the `OneShot` chain (pullout / putaway / reload / inspect / shoot arm animations) and the `HoldAnim` weapon-hold pose were fully muted. Combat mode now ramps it to `1.0`, which enables that entire branch for the first time — any long-masked animation defect (wrong clip, missing hand IK, one-shot leaking past its window) will now be visible in normal gameplay.
- **Suggested fix / check:** verify draw, reload (empty and non-empty), inspect, shoot and holster-out transitions in first and third person before shipping. If one clip misbehaves, fix it on the tree rather than reverting the blend; the non-combat pose depends on the same parameter reaching `0.0`.
- **Replication note:** `in_combat` is replicated (root `MultiplayerSynchronizer`, spawn + on-change). A client-side dev toggle goes through the owner-gated request, identical to noclip/spectating. Do not add a per-frame poll of the effect mirror to derive the holster — it breaks the calligraphy throw path (see `02-netcode.md` §5).

### 140. Third-person aim ray hit the player's own hurtboxes — `[FIXED 2026-11-17]`

- **Files:** `player/player.tscn:531-533` (`ThirdPersonCamera3D/RayCast3D`, `collision_mask = 5`), `player/player.gd` (`_ready` exception sweep, `_third_person_aim_target`).
- **Symptom:** in third person the body/aim occasionally snapped sideways or downward, most visibly with the player's back against a wall — when the `SpringArm3D` collapses and the camera comes close to the character model.
- **Why:** the aim ray goes from the camera along its forward with a `WORLD | HURTBOX` mask. The player's own hurtboxes are `PhysicalBone3D` bodies on the HURTBOX layer (`player.tscn` `Physical Bone DEF-*` nodes), and the ray starts at the camera — so when the arm shortens, the ray passes through the player's own arms/shoulders/legs and `_third_person_aim_target()` returns a point on the player. `_aim_body_head_at_point` then yaws/pitches the body at itself, which reads as being "caught" on geometry. RayCast3D `hit_from_inside` is false by default, so this only bites once the origin leaves the shape and the ray re-enters another bone.
- **Fix:** `Player._ready` adds every `CollisionObject3D` in the player's subtree as an exception on `third_person_raycast` — the same superset `weapon_controller` excludes per shot. **Residual TODO:** the sweep runs once at `_ready`, so a collidable spawned later into the player subtree (a new model/prop body on WORLD or HURTBOX) is not excluded; add it to the sweep point or keep such collidables off those two layers.

### 148. Weapon toon materials are derived at spawn, and a few source properties have no shader equivalent

- **Files:** `weapon/weapon_toon_materials.gd` (`WeaponToonMaterials`), `assets/materials/weapon_toon.tres`, `assets/materials/painted_toon.gdshader` (the Surface group's separate metallic/roughness maps), `player/weapon_controller.gd` (`spawn_weapon_model`, `WEAPON_TOON_PRESET`); harness `tools/verify_weapon_toon.tscn`.
- **Symptom:** none today — the harness instantiates every `.tscn` under `res://weapon/` and asserts no opaque `StandardMaterial3D` survives. The risk is the same shape as #54: weapon meshes mostly live inside imported GLBs, so a GLB reimport that changes the material layout converts a different set of surfaces, silently.
- **What is deliberately dropped, not bugs.** Materials whose `transparency != DISABLED` are left on PBR, because the toon shader is opaque — the same exception #54 records for `blackhat`'s glasses (a scope lens must stay see-through). `cull_mode` cannot be carried: `render_mode` is compile-time, and `assets/weapon_models/ak_test/ak.tres` is `CULL_DISABLED`, so a weapon that relies on double-sided rendering would need a `cull_disabled` variant of the shader rather than a uniform. `uv1_offset` has no uniform (only `uv1_scale`, carried as `uv_scale`).
- **What the source keeps, and what it does not.** The source keeps its textures — albedo, normal/AO/emission, and the *separate* metallic/roughness maps with their channel selectors (`BaseMaterial3D.metallic_texture_channel` etc.) — but **not** its `metallic`, `roughness` or `metallic_specular` scalars. Those three define the family look: the character materials are non-metal, sit around roughness 0.85 and carry no stylised highlight. A gunmetal source is `metallic = 1.0`, and under this shader that multiplies the whole diffuse ramp by `(1 - METALLIC)` — it is why the first pass read as a different shading family. The maps still multiply the preset's level, so metal/roughness detail survives without lifting the surface out of the character look.
- **The shader change is additive.** `use_metallic_texture` / `use_roughness_texture` and their channel uniforms default off, so every character and map material on `painted_toon.gdshader` is unaffected; the harness checks the mapping on a synthetic material.
- **Tuning is one file.** `weapon_toon.tres` carries the whole weapon look; `albedo_gain` (2.0 to start, parity with the character materials) and `toon_specular_size` are the knobs that matter, and the shader only compiles when something is drawn, so the visual half is an in-game check.

### 149. Join grants are temporarily advisory — any direct-IP join is accepted

- **Files:** `network/match_session.gd` (`hello`, the `Grant.validate` branch).
- **Symptom (before the change):** a player joining the dedicated VPS by Direct IP
  was left on the staging "WAITING FOR HOST" screen forever. The VPS runs with
  `MATCH_SECRET` set, the direct-IP path sends an empty grant, `hello` answered
  `BAD_TOKEN`, and the client therefore never received a `welcome` — no player id,
  no phase, no spawn. The same gate rejected *every* direct join, not only late
  joins.
- **Temporary rule:** `hello` still runs `Grant.validate` (HMAC, expiry, match id)
  but an invalid result now only pushes a warning; the player is allocated and
  welcomed as before.
- **Security note:** anyone who can reach the UDP port can join and take a player
  slot. Do not treat the public VPS as authenticated while this is in place.
- **Suggested fix:** restore `_send_error(..., BAD_TOKEN, ...)` + `return`, and
  make grant issuance the only join path (lobbyd `join_match`, or a signed direct
  grant generated by the host). The match-id binding also rejects valid tokens
  when `--match-id` is not numeric (`local-1`), so fix `Grant.validate`'s
  `is_valid_int` branch at the same time.

### 150. Air Control adds a rollback state property whose peer reconciliation is unverified

- **Files:** `player/player.gd` (`air_control_meter`, `_update_air_control_meter`, `_air_accelerate`), `player/player.tscn` (`RollbackSynchronizer.state_properties`), `player/abilities/air_control_ability.gd`; harness `verification/air_control_harness.tscn`.
- **Symptom:** none seen today. The harness drives a real `Player` with no ENet peer, so it proves the drain/refill math and the full-vs-empty multiplier switch but **not** that the server and an owning client agree on the new `:air_control_meter` state across a real join/re-simulation. A disagreement would show as FlyGirl's air control rubber-banding near the empty boundary — subtle, and easy to misread as packet loss.
- **Why it matters:** this is the one metered pool that is read inside the rollback tick. Unlike noclip's per-peer meter (#46), a mismatch here changes predicted movement, not just a HUD bar.
- **Suggested fix:** extend `tests/net/run_net_smoke.ps1` (or add a two-peer harness) to have both peers log `air_control_meter` for several seconds of air-strafing and assert they converge; also confirm a late joiner receives a non-zero value rather than the 0.0 default before the first drain tick.
- **Deliberate non-issues:** `AbilityManager.is_meter_active` for this ability reads `_air_strafe_draining`, a display-only flag written by the last simulated tick (cosmetic colour only); the manager's local `_meter` pool for the slot is allocated but unused (the HUD delegates).

### 151. Practice targets are `Player`s under `SpawnParent` — every participant scan must filter them

- **Files:** `player/player.gd` (`is_practice_target`, `spawn_transform_provider`, `_get_spawn_transform`, `no_health`), `components/attribute_component.gd` (`practice_target_died`, `apply_health_delta`, `_process`), `player/practice_target.gd`, `world/special_entities/practice_target_spawn.gd/.tscn`, `world/practice_range.gd`, `maps/main_menu_world.tscn`; harness `verification/practice_target_harness.tscn`.
- **Symptom:** practice targets are real Players in group `"players"` under `SpawnParent` with `is_bot = true` on the server. Any scan that assumes every Player is a participant includes them. The dangerous one is `world/staging_room.gd:_normalize_teams_if_needed`: it would retag a target's FFA team to SPI/SCI for the selected map mode, and friendly fire is zeroed for same-team non-FFA hits — **the dummy becomes unkillable**, silently, with no error. Roster columns, team-count/autofill (`world_1.gd:_count_team_players`), bot targeting (`bot_controller.gd`), spectator cycling, dev "Remove all bots", and the spawn-bot list all share the assumption and have been filtered.
- **Why it matters:** the failure is data-dependent (staging only, or after a map mode with teams) and looks like a damage bug, not a roster bug. Also note a **client** copy has `is_bot == false` because `is_bot` is not replicated, so a client-side filter must read `is_practice_target`, which is a replicated root property on `player/player.tscn`.
- **Suggested fix:** when adding any "iterate Players under SpawnParent / in group `players`" logic, ask whether a practice target belongs. Filter with `is_practice_target`; do **not** filter `SpawnManager._all_player_syncs` / `sync_existing_players_to_peer` — the target needs spawner visibility and full-state sync.
- **Practice-target respawn timing is load-bearing.** `rpc_reset` ignores `respawn_time` for practice targets and uses `Player.PRACTICE_RESPAWN_DELAY` (0.1 s, identical on every peer) — a client copy otherwise keeps the scene default 1 s and shows a dead dummy for a second. It must **never be 0**: the pending spawn needs a few rollback ticks before netfox's history records the new position, or the rollback tick re-applies the pre-death state, the dummy stands where it died, and only the kill counter moves. `PracticeRange._verify_respawn` forces a fresh `rpc_reset` four ticks later as a backstop.
- **Deliberate non-issues:** targets never reach `Leaderboard` (no damage/kill/death/streak, no kill feed, no Deathmatch count) and never regen; `practice_target_died` fires before the health assignment so a listener can finish a run before `no_health` calls `rpc_reset`, and listeners must not call `rpc_reset`/`free` from it (only deferred `queue_free` on the final kill). Ragdolls are skipped on purpose to avoid 30 corpses per run. `spawn_transform_provider` is server-only and guarded with `Callable.is_valid()`; a freed provider falls back to the map's random spawn.

### 152. The loadout preview borrows the player rig by extracting `Body` at runtime

- **Files:** `world/loadout/loadout_preview_rig.gd`, `player/player.tscn`, `player/animation_tree.gd`, `player/weapon_controller.gd` (`spawn_weapon_model`, `_set_hold_anim`), `world/loadout_menu.gd`.
- **Symptom:** the character-select preview reuses the real rig instead of re-creating it: it instantiates a detached `player.tscn` (root never enters the tree), keeps only `Body`, and frees or script-clears everything gameplay-facing (`PlayerUI`, synchronizers, camera, physical-bone simulator, damage/health labels, and the `Body`/`AnimationTree`/`Recoil`/`WeaponTilt` scripts that dereference the Player parent). The extracted `Body` keeps the mannequin, the full `AnimationTree` blend tree with its aim `CCDIK3D` and both `CopyTransformModifier3D`s, `RotationDir`, `WeaponTilt` and the real `GunAttach`. Node paths inside the tree resolve only because that relative hierarchy is preserved.
- **Why it matters:** the extraction is name-based. **Renaming or moving any of `Body`, `Mannequin`, `AnimationTree`, `Recoil`, `RotationDir`, `WeaponTilt`, `GunAttach`, or inserting a node between the skeleton and those targets silently breaks the preview** (weapon at the origin, no IK, no animation) while the game itself is fine. Adding a script with a `Player` dependency to a kept node also breaks it — the preview clears scripts by name, not by behaviour.
- **The tree is driven manually.** With no local Player, `animation_tree.gd` is cleared and the rig writes its parameter subset: blend spaces `(0, -1)` forward or `(0, 0)` standing, `CrouchWalkSprintBlend3` 1 in run, `JumpBlend = 0`. `HoldBlend` is **1 for weapons that ship a `human_anims` library** (arms on the weapon, matching in-combat `HoldBlend`), and **0 otherwise** (locomotion). The weapon-hold and `other_movement/a_pose` poses point toward +X and read as "looking right" when nothing drives the tree; the walk clips face `-Z`. If `animation_tree.gd`'s blend layout changes, update the rig with it.
- **The hover ghost is a material override.** Hovering a different agent rebuilds only the character model and assigns one shared unlit translucent blue `StandardMaterial3D` as `material_override` on every `GeometryInstance3D` of the model and the weapon (the material replaces the toon/weapon shaders). Unhover rebuilds the selected model and re-instantiates the weapon, which drops the overrides. A CSG-based weapon model would not be covered by the override (none ship today; `WeaponToonMaterials` accounts for CSG, the ghost does not).
- **The armed walk is a two-source composite.** The armed hold chain has no locomotion, so walking/running with such a weapon copies the leg bones (name contains `thigh`, `shin`, `foot`, `toe`) from a hidden second mannequin playing `walk/walk_w` / `sprint/sprint_w`, while everything above the hips comes from the real tree. The pose copy therefore runs on every 30 Hz render tick rather than only on `skeleton_updated`. A bone-mask change or a rename of the leg bones silently freezes the legs while the arms hold; the mask lives in `_is_leg_bone`.
- **Suggested fix:** keep the extracted-node names in one list, and re-check the preview whenever `player.tscn`'s `Body` subtree or the blend tree changes.
- **Deliberate non-issues:** the rig renders at 30 Hz through a timer while the menu is visible (`UPDATE_ONCE`), not per frame; it creates no hitboxes, physics bones, camera scripts or rollback state; the character model's own AnimationPlayer stays disabled and only receives copied bone poses (same by-name copy as `Player._copy_mannequin_pose`).

### 153. Dedicated-server room host always showed 0 ms ping — `[FIXED 2026-11-19]`

- **Files:** `network/match_session.gd` (`_broadcast_pings`).
- **Symptom:** on a dedicated or lobbyd-spawned match, the player who started the room showed `0` in the leaderboard ping column — the same value a listen-server host gets — even though the server and that player are on different machines. It made a VPS match look like it was running on the player's own device.
- **Why:** `_broadcast_pings()` wrote `snapshot[str(host_player_id)] = 0` **before** sampling peers. On a dedicated server `host_player_id` is the first client to send `hello` (`match_session.gd:577-578`), not the local process; the comment claiming a dedicated server "sets neither" was wrong. Only a listen-server host is a player inside the server process with no ENet peer.
- **Resolution:** the 0 ms row is now written only when the host's roster entry carries the server's own peer id (`Protocol.SERVER_PEER_ID`) and no peer sample exists. A dedicated room host is sampled like every other peer. Verified with `--server --port=8092` plus `--connect=127.0.0.1:8092`: the room host row reported real loopback RTT (500 ms during handshake settling, then 15 ms) instead of 0; a solo listen host (`--test-host-local`) still reports 0.

### 154. Results auto-return left the rollback tick loop dead — `[FIXED 2026-11-19]`

- **Files:** `network/network_manager.gd` (`return_to_lobby`, `create_offline_peer`, `_rehost_after_stop_observed`), `world/post_match.gd:177-190`, `addons/netfox/network-events.gd:93-107`.
- **Symptom:** after a match ended and the results overlay auto-returned to the lobby (10 s countdown), WASD did nothing. Mouse look and firing still worked, which is the netfox signature: the rollback tick loop was dead.
- **Why:** `NetworkEvents._process` samples `is_server()` once per frame and keeps `_is_server`. The auto-leave runs from `post_match._process`, i.e. **after** that frame's sample. `return_to_lobby()` nulls the peer, and the deferred boot then installs an `OfflineMultiplayerPeer` and calls `NetworkTime.start()` manually. On the next frame the poll still had `_is_server == true`, saw a non-server peer, emitted `on_server_stop` → `NetworkTime.stop()` and killed the freshly started loop. Nothing restarted it: `PlayerInput._gather` is bound to `NetworkTime.before_tick_loop` and `Player._rollback_tick` runs from it, so movement never simulates; look (`Body._input`) and fire (`WeaponController._physics_process`) do not use the loop. The RETURN TO LOBBY button path was not affected (input is dispatched before the autoload's `_process`).
- **Resolution:** `return_to_lobby()` now re-hosts through `_rehost_after_stop_observed()`, which awaits **two** `process_frame` emissions. `SceneTree` emits `process_frame` before node `_process`, so one await still resumes before the poll; two guarantee one complete poll with no server peer present (the stop is a no-op) before the new peer installs its loop. Both the OFFLINE and LEGACY_P2P branches use it, and a monotonic `_lifecycle_epoch` cancels a superseded rehost so a double `return_to_lobby()` cannot build two lobbies.
- **Verification:** `--test-title-start --test-host-local --test-host-map=res://maps/castle.tscn --test-end-match --test-move`. After `Returning to lobby...`, `[NTSYNC] tick=` keeps advancing (to 5000+ over the run). Reverting the helper to a single await reproduced the bug: `tick=0`, `inp=-1`, `pos` frozen for the rest of the run.

### 155. A staging countdown could fire into the next session — `[FIXED 2026-11-19]`

- **Files:** `network/network_manager.gd` (`start_staging_match`).
- **Symptom:** leaving during the 5 s staging countdown and returning to the lobby left the new lobby eventually swapping itself to the match map, setting `LOADING` and waiting out the map-ready barrier.
- **Why:** the only post-timer guard was `is_instance_valid(GameManager.spawn_parent)`, and the rebuilt lobby's `world_1._ready()` repoints `GameManager.spawn_parent` to the new world — so a coroutine from the dead session passed it.
- **Resolution:** `start_staging_match()` captures `_lifecycle_epoch` after its entry guards and re-checks it (plus `MatchSession.role == SERVER`) after the countdown and after `await_map_ready()`. `return_to_lobby()`, `join_party()` and `host_local_match()` bump the epoch.

### 156. Toon FX are preset-string driven, and the grenade smoke preset is project-local

- **Files:** `weapon/projectiles/explosion_component.gd` (`effect_preset`, `_explode_visual`), `weapon/projectiles/simple_projectile.gd` (`trail_preset`, `_start_trail`), `effects/toon_trail/trail_profiles.gd`, `effects/toon_explosions/profiles.json`.
- **Symptom / why:** preset ids are unvalidated strings. An unknown explosion id makes `toon_explosion.play()` return `false` and the burst is invisible (the projectile still detonates); an unknown trail id leaves no trail. `grenade_smoke` and `grenade_ribbon` were appended to the **project copy** of `trail_profiles.gd` only — re-copying `toon_rocket_trails_godot/` over `effects/toon_trail/` silently drops them and grenade/nuke trails disappear. The same applies to `carpet_trail` in `trail_profiles.gd` and `bigboom/ExplosionCore_CarpetBomb_Flare` in the project copy of `effects/toon_explosions/profiles.json`: re-copying either vendor package removes them and `rocket_carpet.tscn` silently loses its trail or burst. Each toon explosion also allocates two 700-instance `MultiMesh` batches for its lifetime (the Goldrush nuke preset runs ~18 s), so overlapping nukes stack memory and per-frame sort/draw work with no global cap.
- **Suggested fix:** validate `effect_preset` / `trail_preset` against the catalog once in `_ready()` and `push_warning` (debug builds) when missing; keep `grenade_smoke` in a project-owned table or re-append it in a sync step; if nuke spam becomes common, cap concurrent `toon_explosion` nodes or shorten the Goldrush preset.

### 157. The asset viewer borrows the loadout rig and keeps a manual effect catalog

- **Files:** `world/loadout/loadout_preview_rig.gd` (raw-animation APIs, `EFFECT` view mode), `world/asset_viewer.gd`, `world/asset_viewer/effect_preview.gd`, `world/asset_viewer_catalog.gd`, `effects/bullet_impact.gd` (`auto_release`).
- **Symptom / why:** Several independent invariants make the viewer work:
  - Raw animation playback **must** keep `AnimationTree.active = false`; if a future path re-enables the tree (or a new `show_character`/`set_weapon` call skips `_stop_raw_human_anim`), the blend tree fights the `AnimationPlayer` and the preview freezes or snaps.
  - Loop mode is applied to a **duplicated** clip in the runtime `__viewer` AnimationLibrary, never to the GLB's shared `Animation`. Removing that library on stop is what keeps `get_animation_list()` clean; forgetting it grows the list every click.
  - `SCENE_EFFECTS` in `world/asset_viewer_catalog.gd` is explicit. A new effect scene will not appear in the viewer until it is added there (the toon lists follow their JSON/profile data automatically).
  - `BulletImpact.auto_release = false` keeps the preview instance out of the static gameplay impact pool. If a preview impact is released into that pool it is still a valid scene, but the viewer would be feeding gameplay's pool.
  - `ToonTrail.top_level = true` means the trail emits in global space: stop and free it on switch/close, and drive the nozzle by `global_position`.
  - The SubViewportContainer uses `stretch = true`, so cursor → world projection must go through normalized container coordinates (the rig's `screen_to_stage`), not raw pixel values.
- **Effect camera state is deliberately conditional.** `enter_effect_view()` resets pan/focus only when `_view_mode != EFFECT`; switching effects must not call `frame_effect()`. If a future path frames on every selection, the user's orbit/pan/zoom is lost. The mannequin reference is parented under `get_effect_root()` (a sibling of the effect preview, never cleared by `EffectPreview._clear()`), so its visibility must be toggled by tab.
- **Weapon→human pairing and locomotion preview are also rig invariants.** `play_weapon_animation` resolves the clip's `WeaponAnimGroup` and plays the paired `human_anim` through `_play_raw_human_clip`; `_weapon_human_sync` makes `stop_weapon_animation` release that human clip too. `set_locomotion_state` stops both raw players, re-enables the tree, writes the continuous blend direction and the ground-state blend, and forces `HoldBlend` to `0.0` — do not apply `_apply_animation_state` after it. The tree has no `speed_scale`; `set_animation_speed` switches it to MANUAL callback mode and `_process` advances it with `delta * speed` (restore IDLE at 1.0). Do not enable manual mode while the render timer is stopped, and do not expect the loadout screen to need it. A weapon whose groups are not authored simply plays without a human pair (the viewer shows no sync).
- **Suggested fix / regression checks:** keep the rig's new methods additive and gated on `_view_mode`; re-run the H loadout preview (walk/sprint, weapon hold, ghost hover) after touching the rig; run a headless script that selects every effect and plays a human + weapon animation, checking `raw=true`, the `__viewer/...` current animation, `_weapon_human_sync`, the locomotion blend values, and that stopping restores the pose.

### 158. Water containment is an axis-aligned box approximation

- **Files:** `world/brush_entities/water_volume.gd` (`_ensure_bounds`, `contains_point`), `maps/map.gd:is_point_in_water`.
- **Symptom / why:** `WaterVolume` caches one world-space `AABB` per generated `ConvexPolygonShape3D`. For the intended authoring shape — an axis-aligned box brush — the bounds are exact. A **rotated** brush's corners still fit the AABB, but the box also covers empty space diagonally, so the player swims in air outside the brush; a **concave** brush (several wedges in one entity) gets one box per convex shape, which is correct, but an L-shaped *single* brush is not representable and comes out as its bounding box.
- **Suggested fix:** author water as axis-aligned boxes (documented in `docs/06-trenchbroom-entities.md`). If rotated pools become necessary, replace the AABB with exact point-in-convex-hull half-space tests: the convex `points` are already cached, and hull planes can be derived once per shape.

### 159. WET can retrigger while bobbing at the waterline

- **Files:** `player/player.gd` (`_update_server_water_state`).
- **Symptom / why:** the effect is applied on the transition from "inside" to "outside", sampled once per real frame at the collider centre. A player floating exactly on the boundary can cross it repeatedly as reduced gravity and drag settle, re-applying an 8 s effect each time. Harmless (the effect does nothing but drive the HUD label and drips), but it can keep WET lit indefinitely while the player hovers at the surface.
- **Suggested fix:** add a short cooldown (e.g. 0.25 s) or hysteresis — sample the body centre for "inside" and a point above it for "outside" — before applying on the exit edge.

### 160. Bots have no swim intent, and water contributes no navmesh

- **Files:** `player/bot_controller.gd` (unaided), `player/player.gd:_swim_move`.
- **Symptom / why:** bots are `Player`s, so if one ends up inside a water volume it runs the same swim branch. `BotController` keeps steering along the navmesh and issuing ground jumps, which the swim branch cancels every tick, so the bot sinks and flails rather than crossing. The water brush is an `Area3D` with no static collider, so the navmesh baker produces no polygons over it — bots route around a pool, which is the safe failure mode.
- **Suggested fix:** give `BotController` a water state (`player.is_body_in_water()` is already a cheap deterministic query) with a simple swim-toward-target input, or explicitly forbid water path segments in the navigation graph.

### 161. Transparent double-sided water is a draw-order and overdraw cost

- **Files:** `assets/materials/water_surface.gdshader`, `trenchbroom/textures/Material-LIB/Nature/Water/Water[swim].tres`.
- **Symptom / why:** `cull_disabled` plus `blend_mix` is what makes the top surface visible from underneath, but it doubles the rasterised area (both faces of the volume draw) and puts the water in the transparent queue, sorted per object rather than per triangle. Large volumes, or several overlapping pools, show sorting seams where a water surface and another transparent object (scope glass, particles, another pool) intersect. The water group is also a full-screen-ish transparent surface over whatever is behind it.
- **Suggested fix:** paint only the top face with the water texture and the rest with `skip` (documented authoring recipe) — that removes the side overdraw while keeping the surface visible from both sides. Keep pools modest in size; if overlapping transparent effects become common, move the water to an opaque deferred pass with a `depth_prepass_alpha` style trick.

## Not bugs, but worth knowing

- **The exported PCK is asset-driven, and nothing in code caps it.** The
  dedicated-server binary went 1.47 GB → 656 MB on 2026-11-18 purely from
  `.import` `process/size_limit` caps and `export_presets.cfg` exclusions — see
  `docs/07-dedicated-server.md`, "Build size & texture import policy". Two things
  will silently undo it: a new 4K source imported without a `size_limit` (the
  default is `0`, unlimited), and a new map/prop/loadout that points into an
  excluded tree (`backup/`, …) — the PCK just loses the file, with no
  export-time error. `trenchbroom/models/` looks editor-only but is **not**:
  `player_spawn.tscn`, `practice_target_spawn.tscn` and `wood.tscn` instance its
  GLBs, and excluding it broke the deployed server while it still reported
  `active (running)`. Full failure trace: `docs/07-dedicated-server.md`, "Build
  size & texture import policy". Still shipping and not yet addressed:
  `assets/icons` (~34 MB — 4 154 of 4 181 game-icons.net SVGs are unreferenced;
  removing them needs either a curated copy folder or a generated exclude list,
  and `CLAUDE.md` documents the whole-library import as deliberate), and the
  un-referenced remainder of `assets/props_unprocessed` (~27 MB).
- **`painted_toon.gdshader`'s back rim is deliberately light-independent — it glows in pitch darkness and ignores shadow.** It is `1 - dot(NORMAL, VIEW)` written to `EMISSION` from `fragment()` (`:251-277`), never from `light()`. That *is* the feature: it fakes a light behind the subject regardless of what the scene's lights are doing, so it reads as a back light from any angle and under any lighting. It follows that the rim is not occluded by anything, does not dim in shadow, and stays on when the surface is otherwise unlit — verified by rendering it with every light and the ambient switched off, where it is the only thing on screen. If it ever reads as a bug ("why is this glowing in a dark room"), it is working as designed; turn `rim_enabled` off. The reason it lives in `EMISSION` rather than `light()` is that `light()` runs once **per light**, so a rim written there would be added N times.
- **The stylised highlight was multiplied by zero on every material that shipped, until 2026-10-01.** `light()` computed `f0 = mix(vec3(0.16 * specular * specular), ALBEDO, METALLIC)`, tying the highlight's reflectance to the `specular` uniform — which is *also* the ambient/IBL reflection strength, and which every preset sets to `0.0` deliberately ("a PBR sheen on top of flat bands reads as plastic"). So `SPECULAR_LIGHT += f0 * spec * toon_specular_strength * …` is zero regardless of `toon_specular_strength`, and the character shader has **never** shown a stylised highlight — its back rim is unrelated and does that job instead. `painted_toon.gdshader` still has the coupled version, deliberately, since the rim covers the job there — but the whole lobe is now skipped when `toon_specular_strength == 0.0` (every shipped preset), so it costs nothing. Turning the strength up still does not produce a highlight; that is the first thing to change if a character highlight is ever wanted.
- **Property overrides written into an instanced sub-scene are never saved.** Godot serializes overrides only on an instance's *root*. In `maps/koth_castle.tscn` every piece of geometry is `instance=ExtResource(<glb>)`, and each GLB's root is a `Node3D` with the `MeshInstance3D` one level **inside** it — `Block_16x16x2__col2` → `Block 16x16x2` → `StaticBody3D` → `CollisionShape3D`. So a `material_override` set on one of those 106 meshes is dropped on save: the edit looks like it worked right up until you reopen the map. Only properties on the map's *own* nodes survive, which is why `MaterialReplacer`'s `material` (the `ExtResource("7_hufvf")` on `Geometry`) round-trips fine while everything derived from it does not. Any future editor tool that mutates descendants of an instance hits the same wall.
- **The workaround, and why `MaterialReplacer` has an `apply_on_ready`.** Treat the derived state as derived and re-derive it on load: `components/material_replacer.gd` applies in `_ready()`, which runs in the editor as well as in game, so the preview and the saved state agree and no override ever needs to be serialized. The alternative — marking all 106 instances `editable_instance` and baking the overrides in — puts ~106 node entries into the scene file for a purely cosmetic result. Note `run` (the tick-to-apply export) is *not* enough on its own for this reason; it exists only to re-apply after changing `material`, since editing the inspector does not re-run `_ready`.
- **`ERROR: Couldn't create an ENet host. / Parameter "host" is null.` is the expected second-instance path.** `enet_host_create()` returns NULL when UDP `NetworkManager.SERVER_PORT` (8080) is already bound, and Godot logs the C++ failure *before* returning the code that `create_server()` catches on the next line — so it prints on the way into a handled branch and reads like a crash. Whichever instance prints `Server created!` is the host; the one printing this is the joiner and should use "Join Local". Confirmed across every two-instance run: the error appears in every second-instance log and no first-instance log, always paired with `Port 8080 in use — falling back to offline peer.`  To check for a real conflict (another instance or a leftover process), use `netstat -ano -p UDP | findstr :8080` — a **TCP** check will not show it, ENet is UDP.
- **Auto-PBR needs the map face name to be the bare texture stem, and the base color to be a file of that exact name.** `func_godot_util.gd:104` (`load_texture`) resolves a face's texture name as `<base_texture_dir>/<name>.<ext>` and uses its size for UV scaling; `:148` (`build_base_material`) then appends the `%s_albedo` / `%s_normal` / `%s_metallic` / `%s_roughness` patterns (`func_godot_map_settings.gd:127-133`) to **that same name**. So a face named `Material-LIB/BrickWall[Grey]_albedo` finds its albedo but hunts for `..._albedo_normal.png` / `_metallic` / `_roughness`, none of which exist — while a face named `Material-LIB/BrickWall[Grey]` resolves all three. The catch is the other lookup: the bare stem only satisfies `load_texture` if a file literally called `BrickWall[Grey].png` exists, and the pack used to store it as `BrickWall[Grey]-B.png`, which fell back to the 64x64 `default_texture` for UV sizing — wrong tiling on the **first** build, self-correcting on the second once the generated `.tres` exists and `:228-232` reads the size off its albedo instead. **Both lookups are satisfied at once when the base color is stored as the bare stem** (`<stem>.png` + `<stem>_normal.png` + …), which is the current layout; the trade-off below no longer applies. Note the albedo *pattern* is a no-op regardless: `_pbr_features[0]` is `-1` and `build_texture_map` assigns `material.albedo_texture = load_texture(...)` *before* calling `build_base_material`, so only normal/metallic/roughness/emission/ao actually depend on the patterns. `build_base_material` skips a missing pattern **silently** (`:187-191`; the `printerr` at `:181` only fires for a malformed pattern, never a missing file), so a naming mismatch shows up as a silently albedo-only material, never an error. Sets whose maps aren't named `_normal`/`_metallic`/`_roughness` stay albedo-only by construction — `Material-LIB/Nature/Moss/` ships `Moss_N`/`Moss_M`, which no pattern matches.
- **The `trenchbroom/textures/` pack stores base colors as the bare stem, and that is load-bearing in two places at once.** Base colors went `-B/-M/-N/-R` → `%s_*` (`_albedo/_metallic/_normal/_roughness`) → bare stem, all on 2026-09-26. The middle step was reverted the same day because `TrenchBroomGameConfig.texture_exclusion_patterns` defaults to `["*_albedo", "*_ao", "*_emission", "*_height", "*_metallic", "*_normal", "*_orm", "*_roughness", "*_sss"]` (`addons/func_godot/src/trenchbroom/trenchbroom_game_config.gd:47`) and `trenchbroom/trenchbroom_config.tres` never overrides it, so the generated `GameConfig.cfg` hid every `*_albedo` file — and the whole `BrickWall/` set is `_albedo`/`_metallic`/`_normal`/`_roughness`, i.e. 100% invisible in TrenchBroom's material browser while the Tudor pack (`..._basecolor_2k`) and `Moss_N`/`Moss_M` showed up fine. Bare-stem base colors fix TrenchBroom *and* satisfy both auto-PBR lookups, so no `texture_exclusion_patterns` override is needed. If the `_albedo` names are ever wanted back, override that array on `trenchbroom_config.tres` (drop `"*_albedo"`) and re-export the GameConfig — do not rename 51 files again. Renaming textures means a three-way fixup — image, `.import` sidecar (`source_file` **and** `dest_files`), and every `.map`/generated `.tscn` name — and the `uid` in each `.import` must be preserved so `maps/hyb_castle.tscn`'s uid references still resolve. `trenchbroom/maps/test.map` currently has no brush faces, so nothing references the BrickWall names yet.

- **The Stage 7 retreat/hunt states are deliberately conspicuous; do not read them as locomotion bugs.** FLEE is movement-only (trigger released) and SEARCH is an aggression-scaled hunt that extends along the last-seen velocity, then sweeps a ring of standable points around the last-known spot with a dwell at each. A bot that breaks off or loses contact will visibly run away or circle. **One ordering invariant in `_act_retreat_cover` phase 1:** it may `_act_combat()` and return only while `_cover_timer > 0` *and* `_has_line_of_sight_to_player()` says the threat is actually visible. Returning on "`_current_target != null`" alone made that return unconditional, so the timer check below it was unreachable and RETREAT_COVER never waited, peeked or ducked. `_cover_timer` is decremented **before** the phase match — keep it there, or the peek phase becomes unreachable again. `_pick_backoff_position` also clamps its step to `_score_direction()` and floor-tests the endpoint: a fixed 8 m point could land inside the wall the bot had just probed, making a cornered bot push it for the whole FLEE window.
- **Bot weapon scoring is intentionally a damage proxy, not a hit simulator.** `_fire_range_info()` sets projectile DPS from `max(impact_damage, splash_damage)` on the spawned scene (a grenade is no longer scored as the default 10 `hitscan_damage`), and the explosive self-splash guard uses the real `splash_radius + EXPLOSIVE_SAFE_MARGIN`. That guard is now gated by `_accept_self_damage`: a healthy bot accepts its own blast (keeping and firing the explosive), while a blast that would leave it at/below the survival flee threshold triggers the sidearm switch. It does **not** value hitting several enemies with one blast or weight splash area; a future scoring pass should separate those. Slot 0 carries a +95 **primary preference** while `_primary_viable_at()` is true; a viably primary also bypasses the 22-point switch hysteresis, while a weapon whose falloff has made it useless at that range does not. Do not remove the primary bias without re-testing grenade-vs-pistol and sniper-vs-knife behaviour.
- **Dev-menu bot skill edits are server-local and event-driven.** New bots are forced to `SpawnManager.DEFAULT_BOT_SKILL = 1.0`; `random_seed = 0` draws one stable style seed per bot lifetime (not per respawn), so dragging the Skill slider redraws `Style` without re-rolling the personality. Advanced traits are per-bot `_trait_overrides` keyed by `BotController.BOT_TRAIT_KEYS` (eight as of Stage 7, including `survival` / **Self-preservation**); they survive master-skill redraws and respawns until RESET. `Randomize bot skills` is the only thing that rolls general skill (and clears overrides). Manual-bot team/skill/overrides persist in `GameManager.lobby_bots`; autofill bots are session-only. Edits call `Style.draw` / `Style.apply_trait` only on change — there is no per-frame cost. **The Stage 7 threat assessment, `Decision.State.FLEE` and hunt sweep state are server-local `BotController` state; nothing new is replicated and there is no RPC.**
- **The dev hacks menu (`0` key, debug builds) has deliberately narrow semantics.** Health buttons only act while the player is spawned; "No Health" kills through the ordinary death/respawn path, and "Half Health" is a snapshot that passive regen heals back after the character's `regen_delay`. God mode is an `AttributeComponent.dev_god_mode` flag checked at the top of `apply_health_delta()` — so it blocks damage from every path, including the direct `HurtComponent`/explosion calls that bypass `Player.change_health`'s invincibility check — but it does **not** stop knockback or the application of non-damaging status effects (it clears negative effects once, when enabled). Cooldowns and ammo are per-peer flags set on the owner and server copies only; stamina is broadcast because it is rollback state. No flag is in `RollbackSynchronizer.state_properties` or the late-join sync, so a late joiner can briefly mispredict a hacked player's movement until the next toggle.
- **The dev infinite-ammo toggle must emit `mag_changed` when it is switched *off*.** `player/weapon_controller.gd:733` (`set_dev_infinite_ammo`) originally returned early on the off-path, and `player/player_ui.gd:1112` (`_update_ammo`) is signal-driven only (no timer), so the HUD readout stuck on "∞" until the next unrelated ammo event repainted it. The setter now emits on both transitions — the on-path repaints through the refill / `_sync_all_mags`. Any future flag that changes only how a signal-driven HUD field *reads* (rather than the data behind it) needs the same explicit emit; the sibling dev toggles are safe because cooldowns and stamina are polled per frame (god mode is mirrored through `_sync_dev_god_mode`, and its indicator is a cached per-frame string).
- **Dev noclip must reuse `Player.has_noclip()`, never a second movement path.** `player/player.gd` gates the free-fly branch, the hurtbox toggle, `change_health` immunity and both ghost-tier reads on `has_noclip()` (`dev_noclip or has_effect("noclip")`). The dev override deliberately does **not** apply `NoclipEffect`: that avoids the ability's meter/cooldown and, above all, its 999-damage exit pulse. `_start_noclip_exit_pulse()` returns early while `dev_noclip` is on, and `rpc_reset()` clears `_noclip_exit_time` — without that, "Respawn now" (which zeroes the respawn timer) could spawn the player inside the 1 s pulse window and hit enemies at the new spawn.
- **The dev "hide my model" override is not the ghost tier, and `set_ghost_tier` cannot be used to restore it.** That function early-returns when the tier is unchanged, so turning the toggle off called it as a no-op and left the model hidden forever. Model visibility now runs through `_apply_model_visibility()` (called by `set_ghost_tier`, `_spawn_character_model` and the dev setter): `GhostTier.HIDDEN` or the dev flag hides, the mannequin is hidden at the mesh level so the weapon under `GunAttach` stays visible, and custom models are hidden at the node level so a previously hidden head cannot reappear on restore. If a new function shows model meshes, it must call `_apply_model_visibility()` afterwards or it will silently undo the dev override.
- **A frozen bot used to follow the host's mouse look.** Bots are server-authoritative, so `is_multiplayer_authority()` is **true** for a bot's `Body` on the host. `player/body.gd:_input` only checked authority, so host mouse motion rotated every bot's yaw; `BotController._apply_smooth_aim` overwrote that every frame while the bot was thinking, which masked the bug — "Freeze all bots" stops those writes, so the bots then visibly tracked the host's view. `_input` now also bails when `_player.is_bot`; keep that guard, because any future change that stops a per-frame bot writer would expose it again.
- **The dev HUD/model flags are local-only and persist across world swaps.** They live on `GameManager`/`Player`, not on the world, so returning to the lobby and loading a new match keeps them. `world_1._ready()` re-applies the world-HUD one to the rebuilt HUD nodes, and the dev menu's "Reset all dev flags" button is the recovery path; do not "fix" a blank-looking screen by clearing these flags on world load unless that becomes the intended UX.
- **A dev-menu bot loadout edit respawns the bot.** Confirm goes through the normal `_request_loadout` flow (`apply_loadout` + `set_character` + `rpc_reset`), so the bot teleports to a team spawn with full health and fresh ammo. The edit also updates the matching `GameManager.lobby_bots` entry through `SpawnManager.update_lobby_bot_entry`, so it survives return-to-lobby; autofill bots have no entry and revert. `_request_loadout`'s sender check deliberately allows `bot_` targets from any peer, so the Bots-tab disable is UI-only — the server still requires `is_server()` for the apply.
- **The loadout menu's bot-edit mode is cancelled by hiding it, and confirm hides before the RPC runs.** `_on_visibility_changed` restores the local player's pending selection and `player_id`; `_bot_applying` suppresses that restore while confirm is in flight, and confirm captures the target id and paths into locals first. Reordering those operations applies the bot's loadout to the local player — keep the guard.
- **The three damage-feedback sounds are wired in two different places, and "kill sound" is not a one-shot.** The hit and headshot cues are `_hit_sound` / `_crit_sound` in `weapon_controller.gd:62-64`, preloaded `AudioStream`s played through `AudioPool` by `play_hit_sound` / `play_crit_sound` (fired from `AttributeComponent.apply_health_delta`, `components/attribute_component.gd:209-211`). `_play_sound` forwards an optional `volume_db`, and the headshot cue's level is the tunable `CRIT_SOUND_VOLUME_DB` (`+12 dB` so it reads over the hit cue). The hit cue is `assets/sounds/hitmarker_tick.wav` (bright tick + low thump); the kill cue is `GameMenu.base_sound` on `world/world1.tscn` — `world/game_menu.gd:_on_killstreak_changed` builds a 30-kill melody by spawning an `AudioStreamPlayer` per note and setting `pitch_scale` from a semitone table, so **the assigned clip is a melodic sample, not a single hit**. It is now `assets/sounds/kill_note_sax_e4.wav`, a **short (0.26 s) punchy E4 sax stab** — near-instant attack, quick decay, hard release and a jazz fall-off, so consecutive kills read as distinct notes instead of one sustained smear. Reed harmonics are shaped by broad 900 / 1500 / 2800 Hz formants with breath noise and a pitch scoop. **Its root pitch is load-bearing** — `PITCH_E` is 1.0, so replacing it with a note at another pitch shifts the whole theme. Both assets are generated by `tools/generate_hit_and_kill_sounds.py` (stdlib only, re-run to tweak). Swapping `base_sound` for an impact/whoosh clip means every note of the killstreak theme is that clip re-pitched (and long clips overlap heavily). If a single one-shot per kill is wanted instead, change `_on_killstreak_changed` rather than the asset.
- **`ui_open` is now guarded when the lobby interaction areas open their popups.** `HostServer` used to open on E regardless of another menu, and its close handler then cleared `ui_open` underneath it. The dev menu assumes `ui_open` is owned by exactly one menu, so `globe_menu.open_menu` returns early when it is already true.

## New local-flow gaps (2026-11-17)

- **`MatchSession.set_phase()` must write the server's own `phase`.** The
  broadcast is `@rpc("authority", "call_remote")`, so a server that only called
  `broadcast_phase.rpc()` kept its local phase at STAGING. Host-side checks
  (`world_1._sync_flow_ui`, `request_join_in_progress`, `await_map_ready`) and
  the `welcome` phase then disagreed with the clients. The assignment now
  happens before the broadcast; do not move it back into `broadcast_phase`.
- **The staging overlay is local, not replicated.** `world/staging_room.gd` is
  created by `world_1` for every non-dedicated peer and reads `Player` nodes,
  `MatchSession.phase`, and READY flags. Do not parent it under `SpawnParent`.
- **READY is advisory and per-peer.** The server keeps `_ready_flags` and
  broadcasts changes; START GAME does not block on them. Team balance and host
  drag-assignment are still open.
- **The map-ready barrier only covers clients that are connected when LOADING
  starts.** A client that joins after LOADING enters through the normal
  `welcome` path and loads the announced map; it is not retroactively counted
  in the in-flight barrier. This is safe because the server only activates
  after its current peer set ACKs, but a late join during LOADING can reach
  the staging/join-in-progress path after ACTIVE.
- **`GameManager.local_loadout` is process-only.** Add a ConfigFile/player
  profile before treating it as persistent. The title flow rolls a random
  build if the dictionary is empty.
- **`world/host_menu.tscn` is now unused by the HostServer globe.** Keep it
  only if another entry point is intended; otherwise remove it with the old
  pads in the deferred 3D-cleanup phase.
- **`JoinParty` is gone.** The zone node, `world/join_party_area.gd` and
  `world/match_browser.gd` were deleted; the Match Menu's FIND MATCH tab is the
  only join UI (#145).

## Lower priority (recorded, not blocking)

These are real but not current bottlenecks — revisit only if profiling flags them.

- `player/animation_tree.gd:23-85` — per-frame `$` lookups + string-keyed param writes + `basis.inverse()`.
- `player/skin.gd:119-143` — no own-model gate; runs per-frame for every replicated player.
- `player/rim_pivot.gd:24-38` — per-frame `get_camera_3d()` + `look_at` per non-own model.
- `world/payload/payload.gd:121-392` — per-frame label string formatting + `_tick_healing` per pusher.
- `weapon/projectiles/simple_projectile.gd:90-138` — per-physics-frame curve sample + distance math per projectile.
- `player/weapon_controller.gd:737,756` / `player/player.gd:2364,600-635` — `find_children` recursive scans on spawn/tier-change (not per-frame).
- `player/bot_controller.gd:628`, `maps/map_game_mode_assigner.gd:89` — raw `free()` (safe today: unparented / editor-only, but fragile).
- `singletons/game_manager.gd:24-28` — ✅ guarded 2026-10-23: `find_player` / `get_despawn_position` and `Player._get_spawn_transform` now check `is_instance_valid(spawn_parent)` first and return `null` / a zero transform. Previously they hard-errored when SpawnParent was null or freed (an isolated harness, or a lookup racing scene teardown).
- `ui/main_menu.gd:236,241,248-250` — calls `NetworkManager.create_client()` / `enter_existing_game_scene()` directly. Dead today (the 2D menu is bypassed), but those entry points no longer start a tick loop or hide the loading screen on their own; a revived menu would produce a client that can look and shoot but not move. Route it through `NetworkManager.join_party()`.
- `network/network_manager.gd` `_await_settled()` — on a machine that never gets two consecutive frames under `SETTLE_FRAME_SECONDS` (10 fps), a join waits the full `SETTLE_TIMEOUT_SECONDS` (5 s) behind the loading screen before starting the tick loop. It logs a debug warning when it gives up; tune the threshold if this ever bites.
- ✅ **FIXED 2026-11-17 — the thumbnail tool was listed as a map.**
  `maps/map_data/map_thumbnail_generator.tres` (no `game_mode`, scene → the
  tool itself) was returned by `ConnectionUtils.scan_map_data()` and offered
  in the Match Menu and staging picker; selecting it would `load_match_map` a
  plain `Node`. The stale `.tres`, its thumbnail and `.import` are deleted,
  `scan_map_data()` now returns only entries with a real scene path and a
  gameplay `game_mode` (`network/connection_utils.gd:_is_playable_map_data`),
  and the generator runs an orphan-cleanup pass before it renders. If a
  future tool scene is added under `res://maps`, add it to `scan_maps()`'s
  excluded list as well.
- **`UITheme` is a global `Window.theme`.** It restyles every Control in the
  process, including the Console addon and any future third-party UI. If one
  of those breaks visually, override locally in that addon rather than
  narrowing the global theme. Theme lookup still falls back to the engine
  default theme for items the custom theme does not define (icons, sliders),
  so new controls inherit sensible defaults.
- **Portraits in the staging roster depend on the synchronizer, not on
  `_character`.** `UITheme.roster_card` reads
  `Player._loadout_character_path`, which is spawn + on-change replicated.
  A player whose loadout has never been applied has an empty path and shows
  a blank portrait slot; that is expected, not a missing asset. Do not fall
  back to `player._character` on a client — it is only populated after the
  loadout RPC lands and would make the row flicker between empty and filled.
- **Staging roster rebuilds are signature-gated on purpose.**
  `world/staging_room.gd:_refresh_roster` rebuilds cards only when the
  player/team/ready/character signature changes. The screen also runs a
  250 ms `_refresh` timer; rebuilding nodes on every tick would churn the
  scene and leak the queued-free children. Preserve the signature check when
  adding roster fields.
- **The active-ability ring for noclip reads the per-peer meter.** The pose
  itself is derived from the replicated `noclip` effect and is correct on every
  peer, but the ring's remaining fraction comes from
  `AbilityManager.get_meter_fraction()`, which is local per peer (#46). The
  owner sees the true countdown; a spectator's bound HUD sees an empty ring.
  Shoulder charge, bashdown and heal-over-time are derived from rollback state /
  the effect mirror and are accurate everywhere.
- **`WeaponCard.CONTENT_MARGIN` must equal the card stylebox's content
  margins.** `weapon_card.gd:_fit_icon()` sets the icon's *minimum* width from
  the card's current `size.x - 2 * CONTENT_MARGIN`. If the stylebox margins in
  `weapon_card.tscn` are larger than the constant, each layout pass asks for a
  slightly wider card and the minimum width runs away: the loadout columns
  reached 200 000 px each and pushed the INFO panel off-screen (found while
  restyling the card margins 6 → 7). Keep the two numbers in lock-step, or
  rewrite `_fit_icon` to derive the margin from the stylebox.
