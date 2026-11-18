# 04 — Optimization: Performance Model & Hot Paths

This explains *why* the game can drop frames and where the pressure is, so you can reason about new code. The actionable "fix this" backlog lives in [`05-known-issues.md`](05-known-issues.md) — this doc gives the mental model and the catalog behind it.

## Frame budget model

There is no profiler-friendly budget configured; the game runs `_process` (render frame), `_physics_process` (fixed Jolt physics step), **and** netfox's rollback re-simulation (multiple `_rollback_tick` calls per frame) on the **same single core**. Three pressures stack:

> **Tickrate is 90 Hz and is now a build setting, not a per-session one (updated 2026-09-30):** the rollback tick loop runs at `netfox/time/tickrate`, which since #92 **must equal `physics/common/physics_ticks_per_second`** — the engine's platform carry integrates with the slide's delta, so the two have to coincide or riders get carried `1/physics_factor` too fast. `netfox/time/sync_to_physics = true`, so the loop runs from `_physics_process` and `NetworkTime.tickrate` reads straight through to `Engine.physics_ticks_per_second`; `NetworkManager.apply_tick_rate()` can no longer choose a rate and says so. `_rollback_tick` fires **3×** as often per player at 90 than at netfox's 30 default, and movement-sim cost is proportional to the rate; the rollback hot paths below (`player/player.gd:968`, `_apply_movement_from_input` at `1503`) are the ones most sensitive.
>
> **The bill for that is paid in physics, not just in rollback (2026-09-30):** matching the rates meant raising `physics_ticks_per_second` from 60 to 90, so Jolt now steps ~50 % more often on every peer for the whole session — whether or not anyone is standing on a cart. This is the first knob to question if a physics-bound profile ever shows up, and the answer is to move the tick rate down with it, not to decouple them again (`05-known-issues.md` #94).

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

- **Ability pose poll** — `player/player.gd:_process` calls `is_ability_pose_active()` once per rendered frame per player: two float comparisons, `StatusEffectManager.has_effect` dictionary lookups, and a `Time.get_ticks_msec()` read only while a weapon-fire burst window is open. The holster/visual-hide refresh only runs on the edge (ability start/end), not every frame. `player_ui.gd:_update_ability_cooldowns` already ran per frame; `get_active_ability_state()` adds one small loop over the 4 abilities only while a pose ability is running.

`player/player_ui.gd` `_update_targeted_previews` now throttles `ability.find_candidates` (the group query + `has_line_of_sight_to` raycast per enemy + `sort_custom`) to 10 Hz (`PREVIEW_REFRESH_INTERVAL`), caching the result per ability in `_preview_candidates`. Between refreshes only the cheap disc re-projection runs (2026-09-27: these were ability-name `Label`s, now `TargetedAbilityIcon` discs — same pools, same per-frame work, one `queue_redraw` per disc whose icon or colour actually changed).

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
- `weapon/projectiles/explosion_component.gd` `_apply_explosion_tick` (`74`): group query (`78`), per-player raycast (`98`,`104`), `find_player` scans via `apply_health_delta` (`129`), and `get_nodes_in_group("ragdolls")` (`152`) — per explosion tick (explosions can pulse). The `"ragdolls"` group is now capped at **one corpse per player**: `_spawn_ragdoll` renames and queue-frees the previous `Ragdoll_<player>` before adding the new one, so repeated deaths no longer grow the set that every explosion pulse scans.

## Bot hearing (event-driven, server only)

- `GameManager.sound_made` is emitted from the existing sound sites (footsteps, weapon shots, reloads) only when `multiplayer.is_server()`. Each bot connects once and does a distance check when an event arrives — there is no per-frame audio scan. Crouched movement is suppressed in `player.gd:_update_footsteps`, so it produces neither a footstep sound nor a hearing event.
- **An accepted enemy sound now starts a SEARCH at the sound position**, not just a glance. `_on_sound_made` resolves the emitter with one `GameManager.find_player` lookup, rejects self/teammates/despawned/dev-hidden sources, and ignores a repeat within `HEARING_NEAREST_MARGIN` of the current hunt origin. That is one O(players) name lookup per accepted sound per bot, at footstep/shot cadence, not per frame. Emitter radii: footsteps 12 m, gunshots 35 m, reloads 12 m.
- **The last heard enemy position is remembered forever while no objective is nearby.** Every accepted enemy sound updates `_persistent_heard_position`/velocity/name, even while already fighting. When neither the bot nor the sound is within `OBJECTIVE_NEARBY_RADIUS` (20 m) of an active objective, the sound starts an **un-deadlined** search (`_search_persistent`); it loops the fan until a target is found, a new sound replaces it, or an objective comes nearby. The memory survives target acquisition and objective detours and is only reset by respawn or a newer sound. **An active objective outranks any search:** `_act_search` walks the bot back whenever it is outside the hold radius, and when it reaches the point with no visible target the search is ended; a sound heard while already on the point does not start a search at all. The 20 m radius ends the persistent state, so a heard lead cannot park attackers away from a cart or leave them staring at a wall. This is O(1) memory and state-entry work; the search itself uses the existing throttled fan.
- The approach and hunt timers are extended by `distance / WALK_SPEED`, so a 35 m gunshot remains reachable; a bot already in COMBAT/HEAL/COVER/RELOAD/FLEE keeps that priority. The hunt ring's floor check is relative to the sound's origin Y (not the bot's), so a sound on another floor is not rejected wholesale.

## Bot aim, lead and arc validation (Stage 6)

- **Aim drift** is six `sin`/`cos` calls per bot per physics tick (90 Hz) in `Mouse._update_aim_drift`; it replaces one `randf_range` every 0.4 s and adds no allocation, query or node lookup. For 20 bots this is ~11k trig calls/s, below noise; the trig is what removes the old stepped look.
- **Target velocity** is sampled once per 20 Hz think tick (one subtraction, one multiply, one lerp) and stored per bot. No group query, no extra raycast.
- **Arc validation** is capped at `ARC_VALIDATION_INTERVAL` (0.12 s) per bot and only runs when the bot is otherwise ready to fire *and* the crosshair is already near the aim gate. At worst that is ~10 world rays / 0.12 s per firing bot; a bot that is travelling, stunned, switching or reloading runs none.
- **Projectile speed measurement** is a one-off `get_tree().node_added` subscription per bot. Every projectile notifies each bot, but the shared static `_proj_speed_measurements`/`_learned_proj_speeds` dictionaries reject duplicates before any await; only the first unknown scene pays the two-frame sample. The subscription is disconnected in `_exit_tree`.
- **Weapon scoring** now reads the authored falloff curve (`_best_falloff_multiplier_at`) once per candidate on the existing 0.5 s/event-driven choice loop. Projectile DPS is taken from the cached `_get_proj_info` (impact/splash damage) rather than `hitscan_damage`, so it adds no new scene loads — the projectile scene is still instantiated at most once per path. No per-frame work.
- **Dev-menu bot skill/trait edits** call `BotController.set_bot_skill` / `set_bot_trait` only from control `value_changed`/`item_selected`; a redraw is one `Style.draw` plus at most eight override writes. There is no polling, no per-frame UI update, and no network traffic (bots simulate only on peer 1).

## Bot survival and hunt (Stage 7, server only)

Added 2026-10-25 with the `survival` trait, `FLEE`, and the aggression-scaled hunt.

- **Threat assessment is O(1) scalar work.** `_record_damage` is one add per 90 Hz tick when health drops; the leaky bucket decays with one `maxf`. `_threat_pressure` / `_cover_health_threshold` / `_flee_health_threshold` are a handful of multiplies, called from the 4 Hz `Decision` consideration and from damage events only. No queries, no allocations.
- **Explosive self-damage is gated by `_accept_self_damage`**, which is one subtraction and one compare against `_flee_health_threshold()`. It runs in the weapon-choice loop (0.5 s / event-driven) and in `_act_combat`'s fire gate, not per frame. A healthy bot keeps and fires a point-blank explosive; a blast that would leave it at/below the flee threshold falls back to the existing sidearm switch.
- **Enemy counts ride the existing full scan.** `_nearby_enemy_count` is incremented in the distance-only enemy branch of the 20 Hz rescan (every 0.25 s); `_visible_enemy_count` is `visible_names.size()`. No extra group query.
- **Cover search is two-pass, not wider per pass.** The near ring still costs 8 directions × 3 distances; the far ring `[9, 12]` runs only when the near ring finds nothing and `survival >= 0.55`. Queries are the existing `_steer_query` / `_los_query`; no new `PhysicsRayQueryParameters3D` objects.
- **Cover is not a firing lockout.** The wait phase returns fire when the current target is actually visible (the same condition `_think` uses), so a bot whose cover no longer blocks the shot does not stand there watching. That check is O(1) — `_current_target` is already resolved.
- **FLEE destination search runs once per destination**, not per tick: 8 directions × 3 distances, each one floor ray + one path ray + one LOS ray (~72 rays), plus a one-ray backoff fallback. `_flee_repath_timer` gates re-searches. A visible enemy inside `FLEE_FIGHT_BACK_RANGE` (10 m) converts the assessment to COVER/COMBAT before FLEE runs, so the ray work is skipped in that case.
- **Hunt seeding runs once per search**, on arrival at the last-seen point (or after `HUNT_APPROACH_TIMEOUT` = 4 s if that point is unreachable): a lead point plus 3 radii × 8 angles × (floor + headroom) ≈ 48 rays, one `sort_custom`, and a cap of 2–8 points. The ring is rebuilt only if the hunt origin moves more than 3 m. An empty ring falls back to standing and scanning — it is **not** reseeded per tick.
- **Hunt duration scales by aggression** (`3.5–15 s`); the lead extension scales `6–14 m`. Both are pure arithmetic.
- All of the above is `BotController`-local and server-only. Nothing new is replicated and there is no RPC.

Watch for a frame spike when many bots lose a target in the same tick (concurrent hunt seeds) or drop below the flee threshold together (concurrent flee searches). Both are state-entry-only and capped; see `05-known-issues.md` #108 if it regresses with 12+ bots.

## Bot target memory and combat movement (server only)

Added 2026-10-27. A lost target is no longer erased on the first failed LOS tick.

- **Memory is O(1) per bot.** The last visible enemy's identity, position and smoothed velocity are frozen on the visible→unseen edge; the normal tick keeps one LOS ray for a visible target and does no new scanning while the target is remembered. The 4 Hz full scan remains the only group scan; `_targets_valid` was folded into the identity/visibility split so an unseen target cannot force an O(N) scan at 20 Hz.
- **Grace and memory are wall-clock**, not state-tick counters: `TARGET_LOST_GRACE` = 0.75 s before the chase starts, identity/recognition memory 5–8 s style-scaled. A reacquisition inside the 140° recall cone skips recognition. A 4 Hz scan cannot restart the same chase (`_memory_search_started`).
- **Predicted pursuit** leads the frozen last-known position by at most 2 s of velocity, capped at 20 m, and ground-clamps the point once. A directional fan of 3 radii × 5 angles (≈30 floor/headroom rays) replaces the old lead+ring seed; it is state-entry-only and still not route-validated (#111). The sweep's per-point timeout is distance-scaled (2–8 s) and a partial nav approach is abandoned after 0.5 s instead of burning the full timeout.
- **Combat patterns are chosen at the strafe boundary, not per tick.** WIDE/JIGGLE/HOLD come from the previously unused `Style.peek_style_weights`; HOLD stops movement, settles for 0.08–0.16 s, then fires. The range deadband is 2.5 m / 22% with 1.2 m hysteresis, so a bot in range strafes instead of orbiting. Random combat jumps/crouches were removed.
- **Combat safety is cached**: four direction probes every 0.25 s (steer + floor) replace the old lateral-only check; a 0.6 s local stall check changes direction instead of leaning on geometry. Tactical cover reuses the existing cover/peek state, gated by a large recent hit and a cooldown; no per-tick cover search.
- **Held movement keys** are released on the combat/heal/reload/cover early returns via `_release_movement()`, closing the main #118 movement leak.

## Bot objective intent (server only)

Added 2026-10-27. Bots now have an explicit "what should I be doing right now?" model instead of treating the objective as the idle fallback.

- **Priority order:** survival (`FLEE`/`HEAL`/`COVER`/`RELOAD`/`UNSTUCK`) → hold/capture/defend the live objective → engage a visible enemy → search near the objective → wander only when the mode has no objective. `_update_intent()` runs at 20 Hz after Decision, reads `GameModeComponent` state (but adds no raycasts), and caches the objective position/radius/leash for the act layer.
- **Objective anchoring:** outside the hold radius, `_act_combat` routes to the objective with `Traversal` **while still aiming/firing** at the visible target (world-space movement, because COMBAT owns the look). It cancels a chase whose target leaves the objective leash (12 m) and holds the angle instead. `_act_search` returns to the objective whenever the bot is outside the **hold** radius, and once it arrives with no visible target the search is ended; reaching the point calls `_act_hold_objective()` instead of `_act_wander()`. This is what stops a heard sound behind a wall from leaving a bot staring at masonry instead of capturing/defending/pushing.
- **Safe objective drops are a last resort.** When an active objective is 1–12 m below the bot and the nav/graph route is only partial/direct, `_maybe_objective_drop` switches to `Traversal.drop_to`, which allows stepping off a ledge; fall damage starts at 15 m, so the routed fall is safe. It still cannot pass a wall or a closed route — that is map connectivity, not pathing.
- **Holds are bot-side radii:** a control point's capture volume is a brush with no exposed radius, so the hold radius is `OBJECTIVE_HOLD_RADIUS` (3 m). A payload hold is derived from the actual `PushZone` BoxShape3D through `PayloadNode.get_push_zone_horizontal_radius()` (0.95× its short half-extent); `push_radius` is not the trigger shape, and using it left bots just outside the box so attackers never pushed. Objective `Traversal.move_to` uses `_objective_arrival_radius()` (0.7× hold, minimum 0.5 m), not the old 1.5 m floor, so a payload hold actually lands inside the push box. Contact with the actual `PushZone` (`PayloadNode.has_pusher`) also counts as at-objective, so a bot stopped by the cart body holds and pushes instead of pathing into it forever. The leash is 12 m. Tune the constants per project if a map's trigger brush is much smaller.
- **Debug cost:** the intent is O(objective points) at 20 Hz and the label refreshes at the existing 10 Hz overlay cadence. `GameManager.dev_show_bot_paths` now creates the bot label for the intent text; `debug_draw` adds the same line to the full overlay. No per-frame raycasts.

## Bot pathfinding (navmesh, server only)

Added 2026-10-26. `Traversal` prefers the map's baked `NavigationRegion3D`; the old `TravelGraph` bake is now a fallback.

- **Queries are throttled, not per tick.** `_query_path` runs from `move_to` at the 20 Hz decision rate, and `_follow_path` re-queries only when the path is empty, `_force_repath` is set, the 0.55 s `REPATH_INTERVAL` expires, or the goal moves >3 m. For 20 bots that is roughly 36 `NavigationServer3D.map_get_path` calls/s, each preceded by two `map_get_closest_point` calls. Wander validation adds up to 8 random-point + path queries per target pick, on arrival only.
- **A route is preferred over direct steering above `DIRECT_ROUTE_MIN` (2.5 m), even with clear line of sight**, so the navmesh is the primary source rather than an obstacle-only fallback (that is also what makes the route debug lines common). The exception is a **partial** nav route: when the direct line is clear, `_follow_path` discards the partial and steers directly, so a fragmented mesh cannot park a bot at a gap it could simply walk across. Short hops stay direct and cost no query.
- **Low-ledge probing adds nothing on open floor.** `_perceive` already casts the knee/chest/full rays. A **vertical** knee face with chest/full clear is approached by walking; within `JUMP_TAKEOFF` (1.68 m), `_ledge_jump_state` casts two short downward landing rays and, on a candidate, one capsule `intersect_shape` for headroom. Farther out there is no extra probe. A successful check returns `JUMP` with W still held, not a reroute.
- **The `TravelGraph` bake is suppressed on navmesh maps.** `TravelGraph.shared_for` still creates the cheap cache object, but `tick_bake()` runs only when the map has no baked region, a nav query hard-failed, or stage-4 stuck forced the fallback. On `death_castle` this removes the 1.5 ms/frame, multi-second bake entirely.
- **Nav queries never touch the rollback tick or the network.** All of it is inside the server-only `BotController`; results reach clients as the existing rollback input broadcast.
- **Map-load timing:** `NavRoutes` treats a freshly added map's region as `PENDING` for two physics frames, then queries. The map itself can take longer to sync (the headless probe measured ~0.5 s for `death_castle`); a single hard failure only retries on the next 0.55 s repath and does **not** start the graph bake. Two consecutive failures set a 1.2 s nav retry cooldown and start the graph fallback. The normal 1 s respawn after a map swap covers the window.
- **The graph is the drop fallback.** A navmesh cannot represent a descent off a battlement (Recast only links walkable surfaces), so `TravelGraph` owns drops; `DROP_MAX` is 12 m, below the 15 m `fall_damage_min_distance`, so a connected drop is safe. On ESC castle the SCI spawn is ~9 m above the cart; without this the nav path is partial, the graph has no edge, and defenders stop at the wall. Raising the cap above fall-damage distance would make bots take damage from routed drops.
- **Route drawing is opt-in and cheap.** With a bot's `debug_draw` on, or the dev menu's **Show nav paths** for every bot, `Traversal.get_debug_path()` copies only the remaining waypoints into one small `Array[Vector3]` and the bot rebuilds one `ImmediateMesh` ribbon (0.18 m wide, unshaded, no depth test) at the existing 10 Hz overlay refresh. No physics or nav queries are added; with both flags off the path code never runs. Server-local, so no client cost.
- **Fidelity settings trade bake time and polygon count for outline accuracy.** On the lobby, the coarse defaults bake 563 polygons / 649 vertices; the `edge_max_error` / `detail_sample_*` preset in `navmesh_generator.gd` bakes 2793 / 2173 in ~0.4 s. A 0.125 m cell bake gives 6408 / 4544 in ~4 s and requires the navigation-map cell size to match project-wide. Query cost stays on the existing 20 Hz throttle; these are one-off bake/memory costs, not per-frame work.

## Charged-weapon draw (per-frame, all peers) — negligible

Added 2026-09-25 with the `Weapon.charged` feature. Recorded here so it is not mistaken for a new hot path later.

- **Per tick, per peer, only while a draw is running:** a null/bounds check and one `minf`/`+` on `_charge_time` inside the existing `_tick_timers` (`player/weapon_controller.gd:515`, the new block after the scoped-amp accumulator). No allocation, no node lookup, no physics query. Zero cost when nothing is drawing.
- **`get_active_fire_speed_mult()` (`714`)** gained one comparison and one multiply. This function is called **twice per player per tick** (`player/player.gd:1127` in `_noclip_move`, `:1736` inside `_apply_movement_from_input`, i.e. *inside the rollback tick*) — so the multiply is multiplied by the re-simulation count. It is a multiply on a value already in registers, which is why it was chosen over any per-peer state lookup.
- **HUD:** the left-hand charge bar (`player/player_ui.gd`) is updated from `_process` (line 732) rather than the 10 Hz `_on_ui_tick`, because a stepped fill looks broken. Two property writes plus one `%.2f` format per rendered frame **for the owner only, while drawing** — the same shape and cost as the scoped bar beside it. If the HUD ever becomes the bottleneck, this pair is the thing to dirty-flag (see #11 in `05-known-issues.md`).
- **Per shot:** one extra multiply on the launch-speed line and one on the damage scalar in `_spawn_projectile` (`2674`), plus one on each of the two hitscan damage sites.
- **Deliberately NOT in the rollback path.** `_charge_active`/`_charge_time` are broadcast state, never `RollbackSynchronizer` properties — the same rule as the fire flags (`02-netcode.md` §1). Adding them there would re-simulate the draw and multiply this cost by the tick count for no benefit.

## Third-person recoil view kick (per-frame, owner only) — negligible

`Player._apply_third_person_recoil` runs only while `third_person` is true (the flag is per-peer and
only the owner turns it on) from the existing `Player._process` → `_update_third_person_aim`, which
was already doing a per-frame aim correction there. Cost: two basis reads (the body one
orthonormalised), one `inverse()`, four `Basis` multiplies and one global-basis write on the camera. No allocation, no raycast (the camera's
existing child RayCast3D supplies the aim target). The parent `ThirdPersonPitch`/`Root` rotations
are unchanged — the kick is rebuilt on the camera each frame, so it cannot accumulate. See
`02-netcode.md` §3.

## Dev-menu status line (per-frame, owner only) — negligible

Added 2026-10-24 with the expanded dev menu. `PlayerUI._update_dev_status()` composes
`"GOD MODE · NOCLIP · BOTS IGNORE ME"` from three booleans and compares it with a cached string;
the `Label` is only rewritten when the composed text changes. It runs on the existing per-frame HUD
`_process`, for the owning player only, and every flag defaults to false. The damage-number canvas
is toggled event-driven (`DamageNumberManager.set_dev_hidden`), not polled. `Player.has_noclip()`
replaces the inline `has_effect("noclip")` checks at the same sites (one extra function call per
tick in the movement path, no allocation or lookup change).

## Ability charge pool (per-frame, owner only) — negligible

Added 2026-09-25 with the charged-ability feature (`Ability.max_charges` / `charge_interval`).
Recorded here so it is not mistaken for a new hot path later. See `02-netcode.md`.

- **`AbilityManager` still does zero `_process` work.** This was the design constraint, and it is
  why the pool is derived lazily from `_charge_stamp_ms` rather than accumulated: a peer that never
  casts or reads pays nothing at all, and no per-player `_process` was added for a feature most
  abilities do not use.
- **`_bank_at` is O(1)**, with a full-pool early-out before any arithmetic. Deliberately *not* a
  step loop — `cooldown = 0.0` is legal and would spin forever. An hour-long gap costs the same as a
  millisecond.
- **HUD, owner only:** `_update_ability_cooldowns` gained three O(1) getter calls per slot per
  frame (no allocation, no Dictionary return — it already ran per frame, so this is added work on
  an existing path, not a new one).
- **Drawing:** up to `max_charges` `draw_rect` pairs inside `AbilityCircle._draw()`, which already
  ran every frame — the bars add no `queue_redraw` and no child nodes. The strip is skipped
  entirely (`charge_count < 2`, or a bar under 1 px wide) so an absurd `max_charges` degrades to
  "draw nothing" rather than sub-pixel noise.
- **`max_charges == 1` is explicitly zero extra cost:** `set_charges` early-returns before touching
  any state, so every existing ability draws exactly what it drew before.

### Metered-ability pool (per-frame, owner only) — negligible, and off unless used

Added 2026-09-25 with `MeteredAbility` / the noclip rework. Same reasoning as above.

- **The `_physics_process` exists but is disarmed by default.** It is the *only* per-frame callback
  `AbilityManager` has ever had, and it does one thing: end a metered ability whose pool has run dry.
  `_refresh_meter_tick()` recomputes `set_physics_process(any_meter_running)` on every transition, so
  a peer using no metered ability — which is every ability in the game except noclip — still costs
  **nothing at all**, and a peer that is not mid-noclip costs the same.
- **Every writer must end with that call**, including the ones that clear the whole array
  (`_resize_state`, `reset_meters`). One that forgets leaves the callback armed for the rest of the
  session, which is the failure mode to watch for if this ever shows up in a profile.
- **`_meter_at` is O(1)** in both directions, with an early-out at each end — a full pool and an
  empty one both return before any arithmetic. Deliberately *not* a step loop, for the same reason
  `_bank_at` is not.
- **While a meter is running**, the callback walks at most four booleans and calls `_meter_at` on the
  ones that are set. `Time.get_ticks_msec()` derives everything, so the `delta` argument is unused
  and the check is identical at 30 fps and 300.
- **HUD, owner only:** `_update_ability_cooldowns` gained two more O(1) getter calls per slot per
  frame (`get_meter_fraction`, `is_meter_active`) on a path that already ran per frame.
- **Drawing:** one `draw_rect` pair inside `AbilityCircle._draw()` for a metered slot — no child
  nodes, no extra `queue_redraw` (`set_meter` early-returns when nothing changed, which is what keeps
  it off the per-frame redraw list). A charged slot draws no meter bar and vice versa.

### Calligraphy canvas (owner only, only while raised) — one texture upload per drawn frame

Added 2026-09-30 with the calligraphy ability. Recorded because it *is* a real per-frame cost, unlike
everything else in this section — the difference is that it only exists while a player is actively
painting, and only on the peer doing the painting.

- **Nothing runs when the canvas is down.** `CalligraphySphere` is created once per local player and
  starts with `set_physics_process(false)`; visibility and the callback are toggled together from
  `StatusEffectManager.client_effects_changed`, which a *permanent* effect fires exactly twice per
  toggle (no 10 Hz re-broadcast — `status_effect_manager.gd:131-138`). So the steady-state cost of
  owning the ability is zero, and so is the cost of having the effect up but not drawing.
- **The draw cost is one `ImageTexture.update()` per painted frame.** This is the notable one: the
  whole 256×256 RGBA map (~256 KB) is re-uploaded whenever a dab lands, capped at once per physics
  frame regardless of how many dabs that frame produced. A brush stamp is ~30 `set_pixel` calls on a
  packed `Image` (CPU-side, no GPU sync), so the upload dominates. It is bounded and it stops the
  instant the button is released, which is why it is acceptable — but it is the first thing to shrink
  if this ever shows up in a profile: `CANVAS_SIZE` is a one-line change, and the map is only ever
  read by a human eye. Note the map is scoped to the drawable patch rather than the whole sphere,
  which is *why* it is only 256×256 — the same budget spread over a full-sphere equirect map would
  leave the 15° patch at 21×21 px. See #79 in `05-known-issues.md`.
- **The stroke is capped at `MAX_STROKE_STEPS` (64) dabs.** A fast flick across the canvas would
  otherwise interpolate hundreds of stamps in a single frame; the cap degrades that to a dotted line
  rather than a spike.
- **No allocation per frame.** The `Image`, the `ImageTexture`, both meshes and both materials are
  built once in `_ready()` and mutated in place, following `weapon/tracer.gd`'s `_ready()` rather
  than the per-shot construction that #4 used to do.
- **Three meshes on the canvas, all built once, none rebuilt per frame.** `_bubble` is a stock
  `SphereMesh` (64×32, untextured, a faint film); `_patch` is the drawable sheet, a 32×32-cell
  spherical section emitted as an **unindexed** `ArrayMesh` via `SurfaceTool` (~6k vertices for ~2k
  triangles); `_guide` is a *second `MeshInstance3D` sharing that same ArrayMesh* with its own
  `material_override`, scaled 1 % outward so it sorts behind the ink. Three draw calls, owner's screen
  only, no per-frame geometry work. The patch is unindexed rather than a shared grid because that is
  the shape of func_godot's own `SurfaceTool` use
  (`addons/func_godot/src/util/func_godot_util.gd:447-460`), the project's only other `SurfaceTool`
  precedent. It is authored rather than a slice of the sphere grid for *resolution* — a 15° patch is
  under three cells of a 64-segment sphere — and the tangent texcoords that come with authoring it are
  what make the ink land under the crosshair; see #78/#79. Note the shared mesh carries **no surface
  material**, or `_patch` and `_guide` would be forced to look identical.
- **The carried card is one quad plus a `Label3D`**, created once with the canvas and merely
  re-`global_transform`ed per tick while held. It shares the ink `ImageTexture` with the sheet rather
  than copying it, so the drawing costs nothing extra to carry.
- **`_frame_patch()` runs once per activation**, not per frame: it aims the sheet at the view
  direction the player cast from and is deliberately not repeated, since a sheet that tracked the view
  would stop the crosshair sweeping across it.
- **The per-glyph work is the real cost, and it is cached — see #80.** Decoding a 150×150 PNG and
  dilating ~3.5k stroke pixels into a scoring mask is a few hundred thousand operations; both are done
  once per glyph per process in `_glyph_data()` and kept in a `static` cache, so the first cast that
  draws a given character pays for it (a frame or two) and every cast after that is free.
- **Scoring is two bulk passes over `PackedByteArray`s, never `get_pixel`.** `Image.get_data()` copies
  the 256×256 map once and both loops index the bytes directly — the same reason the paint path avoids
  per-pixel API calls. Pass 1 walks the ink (65k) and dilates it; pass 2 walks the 150×150 glyph
  (22k). The ink dilation in pass 1 is new with the F1 score and is the larger of the two costs, on the
  order of a hundred thousand writes. It runs once per cast, on dismissal, so the worst case is one
  frame at the moment the canvas closes.
- **Deliberately owner-only and client-side.** Nothing about the canvas, the guide or the ink is
  networked — see `02-netcode.md` §7. What replicates is the two phase effects; what crosses the wire
  on a throw is a glyph index and a score.

### Ability icons (static per circle) — one draw call, no child nodes

Added 2026-09-27 with `Ability.icon`. Recorded here so the new draw call is not mistaken for a
hot path later.

- **One extra `draw_texture_rect` inside `AbilityCircle._draw()`** — a method that already ran per
  redraw for the disc, pie, and bars. No new callback, no new node.
- **`set_icon()` early-returns when the texture is unchanged**, so the empty-slot branch of
  `_update_ability_cooldowns` calling it for every empty slot every frame costs one pointer
  compare each. A populated slot is never touched per frame at all: icons are assigned in
  `_rebuild_abilities` (on character change) and nowhere else.
- **No child node, so nothing to lay out.** The icon draws inside `_draw()` from the same
  `center`/`radius` the bars use, which is what keeps it welded to the disc through the
  64 → 76 px resize — the same rule the charge bars follow. A `TextureRect` child would have
  needed its rect recomputed on resize, and would have defaulted to `MOUSE_FILTER_STOP`, eating
  the loadout screen's hover tooltip.
- **`icon_rect()` is split out of `_draw()`** (like `charge_bar_geometry`) so the contain-fit can
  be asserted without a renderer. The same fit is duplicated in
  `player/hud/targeted_ability_icon.gd`'s `_fit_rect` — deliberately, not by oversight; see the
  comment there and `05-known-issues.md` #57.

## Segmented health bar (per-viewer, only while revealed) — negligible

Added 2026-09-27, replacing the numeric health readout with a drawn bar
(`player/segmented_health_bar.gd`). Recorded here so the per-frame push is not mistaken for a
new hot path later.

- **One `set_health()` call per other player per rendered frame**, from `player/player.gd`
  `_update_visibility` (`2514`) — the same loop that already drove the old `Label`. The old path
  formatted a string (`str(int(health))`) and re-shaped text on every change; the new one
  compares two ints and usually returns untouched.
- **Hidden bars cost one bool check.** `set_health()` returns before any arithmetic when
  `visible` is false, and `queue_redraw()` is never reached while hidden — so a peer with no
  reveal active pays nothing at all.
- **Revealed bars redraw on the quantized pixel, not per frame.** The gate compares the drawn
  width and fill *in whole pixels*, so a regenerating target costs a redraw per pixel of fill
  (~2/s for 10 HP/s on a 100-max bar) rather than one per frame, and a full-health target
  redraws zero times. A target whose health is only drifting (the sync interpolating) never
  redraws at all.
- **No child nodes, no allocation.** `_draw()` issues at most `2 + N + 1` `draw_rect` calls
  (N = dividers, one per 100 HP) and derives everything from `size` — the same shape as
  `AbilityCircle`'s charge bars, which this widget deliberately mirrors.
- **The width scales with max health by design** — 20 px per 100 max HP — and NOT with distance:
  the bar is projected with `unproject_position`, like the damage numbers.

## Practice targets and the timed range — event-driven

- **Practice targets are full `Player` nodes but do no per-frame work of their own.** `BotController` is removed before they enter the tree, `AttributeComponent._process` returns immediately for them (no regen), and the server only touches them on a hit. A lobby with a dummy costs the same as an idle player.
- **No ragdoll per kill.** `Player.no_health()` skips `_spawn_ragdoll.rpc(...)` for practice targets. A 30-kill run would otherwise leave up to 30 corpse bodies (each `RAGDOLL_LIFETIME = 25 s`) in the lobby.
- **The range has no polls beyond a cheap prompt check.** `PracticeRange._process` only accumulates the HUD timer while a run is live and updates the label at 10 Hz; it compares the desired prompt string each frame, rewriting the `InteractionPrompt` only on change (the prompt's own `_process` is one bool compare for the `ui_open` hide). Spawn points are one raycast per kill, not per frame. No group scans, no per-frame `find_player` loop — the only `find_player` calls are in `_set_range_ammo`, once per player entry/exit (or per grant/revoke at run start and end), never per tick.
- **Run state is an RPC per kill, not a synced property.** One reliable broadcast at start, per kill, and at finish; there is nothing to interpolate and no per-frame bandwidth.

## Spectator mode (local only, only while watching) — negligible

- `world/spectator_controller.gd::_process` exists on every peer but early-returns unless the local player's `is_spectating` is true. The local `Player` is cached (no per-frame `find_player`). While active, the steady-state cost is one camera-transform copy, one FOV copy, and an idempotent loop over the target's handful of head meshes.
- `_collect_targets()` is O(players) with a small name sort, and runs only on entry, when the current target becomes invalid, and on a cycle key — **not** every frame.
- The watched player's `PlayerBodyUI` is built **once** on first bind and persists, so cycling back reuses it. Only one is visible at a time; every target watched in a session keeps its HUD nodes (see `05-known-issues.md` #115).
- `Player._update_visibility` keeps its existing cost and 10 Hz occlusion cadence — only the `viewer` it evaluates from changes.
- The leaderboard rebuilds on `Leaderboard.roster_changed`, and still early-returns when `_lb_canvas` is not visible, so a closed scoreboard costs nothing.

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
- `player/rim_pivot.gd` `_process` (`24`): `get_viewport().get_camera_3d()` + `look_at` every frame per non-own model. Since #51 this actually drives lit geometry on the normal path (it previously did nothing unless the character had no `character_scene`), so the cost is no longer hypothetical — still small, since it is one `look_at` per remote player.
- `world/payload/payload.gd` `_physics_process` (`121`): `_update_label()` string formats every frame; `_tick_healing` (`217`) calls `p.change_health(...)` every frame per pusher (feeding hotspot #3). The zone lookup added for TrenchBroom routes is a linear scan of a handful of dictionaries — a route has one entry per waypoint, so this is tens of comparisons, not a hotspot. It does run per tick on the server only.
- **The railroad track is one merged mesh — 2 draw calls for a route of any length, against ~500 for the same length tiled by hand.** `PayloadTrackBuilder.build_mesh()` sweeps the two metal rails and every wooden tie into a single `ArrayMesh` with two surfaces (rails, ties), carried by one `MeshInstance3D` under the `PayloadTrack` container. The alternative the user was doing by hand — one 2 m `PayloadTrackStraight` prop per 2 m of route, 10 `MeshInstance3D` each — is ~500 draw calls for a 100 m route. Measured on the verify harness's straight fixture: a 30 m route is **2 904 vertices** (rails) + **2 904** (121 ties × 24 verts), two surfaces, one node. **The whole bake is editor-only** — it runs from the Map's tool button and its save hook, never in a game — so a running peer pays nothing for it at all, only the two draw calls.
- **The glowing route line is built once and never rebuilt — `_update_path_line()` (`payload.gd`) costs one `set_shader_parameter` call.** `PayloadPathLine.rebuild()` walks the baked curve once at map load and emits a tube (8 sides per sample, capped at 512 samples), and "show only the part still ahead of the cart" is a `discard` on a per-vertex arc-length in `assets/materials/payload_path_line.gdshader` rather than any geometry change. That is deliberate: the obvious alternative — rebuilding the mesh, or hiding one `MeshInstance3D` per segment — either allocates per sync or quantises the line to whole waypoints. The fragment `discard` is the only runtime cost, on one narrow tube, and it disables early-Z for those pixels alone.
- `assets/materials/painted_toon.gdshader` computes its painted field and rim **once per fragment**. `paint_pattern()` (3 `sin`) and `compute_rim()` (pow + smoothstep) are light-independent, so they are assigned to `varying float v_paint` / `v_rim` in `fragment()` and read by `light()`. `light()` runs once per light — up to three on a character (directional + its two rim spotlights) — so the old per-light recomputation multiplied both by the light count. The stylised highlight lobe (`normalize` + `pow`) is skipped entirely when `toon_specular_strength == 0.0`, which is every shipped preset. A normal-mapped material still recomputes the rim in `light()`, because `fragment()` sees the pre-normal-map normal (none ship today).
- `assets/materials/painted_toon.gdshader` is **not** additive cost. Overriding `light()` sets `LIGHT_CODE_USED`, which *replaces* the engine's built-in direct-lighting branch rather than running alongside it — the shader does a ramp and one Blinn-Phong lobe where the default does Burley + Schlick-GGX. Ambient / sky / reflection-probe work is untouched and remains the dominant per-fragment cost.
- **Every character now shades through that shader.** All nine `assets/character_models/characters/*.tscn` carry authored `surface_material_override/N` entries (125 surfaces) pointing at `assets/materials/character_toon/*.tres`, so the per-fragment cost above applies to every character on screen rather than to nothing. Applying the materials is now **free at runtime** — they are scene data, not built in code — so the only cost is the shader itself.
- **Weapon models are re-shaded at spawn, on every peer, and the pass is bounded by distinct materials — not surfaces.** `WeaponController.spawn_weapon_model()` calls `WeaponToonMaterials.apply()` once per (re)spawn (weapon switch, respawn, loadout change), which walks that one model's meshes and CSGs and builds one `ShaderMaterial` per distinct source material; a weapon whose parts share one GLB material collapses to one. Nothing runs per frame and nothing is networked — it is a spawn-time pass over tens of surfaces. The character materials, by contrast, stay free because they are authored scene data. The `light()` cost above now applies to weapon surfaces as well.

- **The painted-toon WORLD feature is removed (2026-11-19).** `painted_toon_world.gdshader`, its `.tres`, the unreferenced FreeStylized duplicate, `ToonMaterialConverter`, `Map`'s two tool buttons and preset poll, and `tools/verify_toon_world_swap.*` are gone; `main_menu_world`, `esc_castle` and `hyb_castle` no longer set `toon_world_enabled`, so they render their authored materials. `painted_toon.gdshader` is still the character and weapon shader. `esc_castle` opaque pass went 0.48 → 0.38 ms; lobby 0.35 → 0.26 ms.
- **Status borders skip their noise outside the visible band.** Both `flame_border.gdshader` and `status_border.gdshader` cover the whole screen but only draw a 5–7 % edge strip; the interior now takes an `else` branch that writes transparent before any `hash`/`fbm`/pulse work (flame went from 14 `sin`/px to 0 there). The flame fbm is 2 octaves instead of 3. Animation now uses the canvas `TIME` built-in, so the per-frame `u_time` uniform write and the per-overlay material duplicate are gone; one material is shared by all overlays of an effect.
- **Explosion particles use `StandardMaterial3D`, not five embedded shaders.** The old auto-converted shaders sampled albedo + metallic + roughness (three texture taps) under `render_mode unshaded`, so two were wasted. `GenericExplosion` no longer scans GLSL source for parameter names; it duplicates a `StandardMaterial3D` and tints its albedo/emission. Particle counts, lifetimes, blend modes and process materials are unchanged.
- **Muzzle flash light lifetime is a deadline, not a coroutine per shot.** `MuzzleFlash.fire()` used to allocate a `SceneTreeTimer` and `await` it for every shot, and an older shot's timer could hide a newer shot's light. It now stores `_light_until_msec` (`maxi`, so a new shot extends it) and runs `_process` only while the light is on.
- **3D status particles share their resources per effect id.** `ParticleProcessMaterial`, `QuadMesh`, `StandardMaterial3D` and the fade curve are now `static` caches keyed by effect id; only the `GPUParticles3D` node (emitting/visibility/transform) is per player. The culling AABB now extends downward for `bleed`, whose particles fall.

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

## Post-processing & render cost (measured 2026-11-19)

Profiled with `godot_console.exe --path . --disable-vsync --print-fps --gpu-profile -- --test-host-local --test-host-map=res://maps/<map>.tscn` on an RTX 4070 Laptop at 1920×1080 (windowed), vsync disabled.

**The whole screen-space stack is now off in every map.** All 14 `maps/*.tscn` Environment blocks had `ssao_enabled`, `ssil_enabled`, `ssr_enabled`, `glow_enabled` and `volumetric_fog_enabled` set to `true`, even though SDFGI itself is disabled — pure cost. The enabling lines are removed; the engine defaults are `false`, so there is nothing to re-set. The tuning keys those features left behind (`volumetric_fog_density`, `glow_bloom`, …) are inert while disabled and were deliberately kept, so re-enabling one feature needs a single `*_enabled = true` line.

| scene | before | after |
|---|---|---|
| `castle` GPU frame | 2.03 ms | 0.84 ms |
| `castle` removed post FX | SSAO+SSIL+SSR 0.66 ms, glow 0.19 ms, fog 0.13 ms | 0 |
| `bind` GPU frame | 2.30 ms | 0.76 ms |
| lobby staging (before) | 1.77 ms | — |

FPS figures are **not** recorded here: spawn pose is randomised per run and other Godot instances on the machine contend for the same CPU/GPU, so uncapped FPS varied by >30 % between identical runs (castle measured 420–600 FPS across runs). Compare GPU pass totals, which are stable to ~0.05 ms.

Remaining GPU budget on `castle` (0.75 ms after the 2026-11-19 shader pass): opaque 0.28, canvas 0.07, shadows 0.06, depth 0.02, tonemap 0.04, sky 0.02, culls 0.06. `esc_castle` is 0.88 ms (opaque 0.38, no VoxelGI); the lobby is 1.40 ms, of which the VoxelGI bucket is 0.62. **VoxelGI sampling is now the largest single GPU cost** on the maps that carry it; the toon/effect work sits inside the opaque pass and is no longer per-light.

Draw calls are not the limiter on this hardware: `bind.tscn` is 1233 `StaticBody3D` with one collision shape each, ~2400 calls, at 0.76 ms GPU. It is the first metric to watch on a weaker CPU.

### Debug HUD metrics

`Performance.TIME_PROCESS` is **not** current-frame CPU time. The engine reports the **largest value from the last second** and it includes render-draw/GPU-fence waits, so it routinely reads several times the real frame time (measured: 7.4 ms average beside a 1.67 ms / 600 FPS window; a single load spike reads 1269 ms for a whole second). `hud_controller.gd::_process` no longer prints it. The debug line now prints:

- `frame` — wall-clock `1000 / fps`, averaged over the same 1 s window,
- `phys max` — `TIME_PHYSICS_PROCESS`, labelled as a peak because it has the same last-second-max semantics.

Do not profile CPU from the HUD line; use `--gpu-profile` for GPU and the editor profiler for CPU.

## Frame rate & vsync

The rendered FPS is capped only by **VSync**, and that is Godot's *default* — this project sets no vsync key at all. `project.godot`'s `[display]` section contains only `window/size/viewport_width`, `window/size/viewport_height` and `window/stretch/mode`; there is no `display/window/vsync/vsync_mode` anywhere in the repo, so the effective value is Godot's default `1` (vsync **on**, locking FPS to the display refresh rate). `application/run/max_fps` and `Engine.max_fps` are likewise unset (default `0`, uncapped).

So there is already a refresh-rate cap in place. Setting `window/vsync/vsync_mode=1` explicitly would be a no-op; setting it to `0` would *remove* the cap and let the two local test instances contend for the GPU harder. If you want a tighter cap for local two-instance testing, set `Engine.max_fps` — it is independent of vsync.

*(Two earlier revisions of this doc claimed the project set the key, once as `0` and once as `1`. Neither was ever true.)*

## Cost of the tick-domain watchdog

`NetworkManager._process` runs every frame on every peer. In release it does one float add plus a 4 Hz integer comparison on clients (and a 1 Hz RPC on the host, ~4 bytes/s/peer); its debug logging is behind `OS.is_debug_build()`. The expensive part — `_reset_rollback_history()` — only runs on a re-seed, which is cooldown-limited to one per 5 s and should be rare now that the root cause is fixed.
