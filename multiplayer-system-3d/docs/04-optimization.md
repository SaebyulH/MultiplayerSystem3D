# 04 — Optimization: Performance Model & Hot Paths

This explains *why* the game can drop frames and where the pressure is, so you can reason about new code. The actionable "fix this" backlog lives in [`05-known-issues.md`](05-known-issues.md) — this doc gives the mental model and the catalog behind it.

## Frame budget model

There is no profiler-friendly budget configured; the game runs `_process` (render frame), `_physics_process` (fixed Jolt physics step), **and** netfox's rollback re-simulation (multiple `_rollback_tick` calls per frame) on the **same single core**. Three pressures stack:

> **Tickrate is per-session and scales rollback cost linearly (2026-09-24):** the rollback tick loop runs at `NetworkManager.server_tick_rate` (default 90 Hz, `netfox/time/tickrate=90`, up from the addon default 30), so `_rollback_tick` fires **3×** as often per player at 90 than at 30. Movement-sim cost is proportional to the rate; the rollback hot paths below (`player/player.gd:968`, `_apply_movement_from_input` at `1503`) are the ones most sensitive. A server that picks a high rate pays for it on every peer, and `NetworkManager.MAX_TICK_RATE` is the cap for that reason.

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
- `weapon/projectiles/explosion_component.gd` `_apply_explosion_tick` (`74`): group query (`78`), per-player raycast (`98`,`104`), `find_player` scans via `apply_health_delta` (`129`), and `get_nodes_in_group("ragdolls")` (`152`) — per explosion tick (explosions can pulse).

## Charged-weapon draw (per-frame, all peers) — negligible

Added 2026-09-25 with the `Weapon.charged` feature. Recorded here so it is not mistaken for a new hot path later.

- **Per tick, per peer, only while a draw is running:** a null/bounds check and one `minf`/`+` on `_charge_time` inside the existing `_tick_timers` (`player/weapon_controller.gd:515`, the new block after the scoped-amp accumulator). No allocation, no node lookup, no physics query. Zero cost when nothing is drawing.
- **`get_active_fire_speed_mult()` (`714`)** gained one comparison and one multiply. This function is called **twice per player per tick** (`player/player.gd:1127` in `_noclip_move`, `:1736` inside `_apply_movement_from_input`, i.e. *inside the rollback tick*) — so the multiply is multiplied by the re-simulation count. It is a multiply on a value already in registers, which is why it was chosen over any per-peer state lookup.
- **HUD:** the left-hand charge bar (`player/player_ui.gd`) is updated from `_process` (line 732) rather than the 10 Hz `_on_ui_tick`, because a stepped fill looks broken. Two property writes plus one `%.2f` format per rendered frame **for the owner only, while drawing** — the same shape and cost as the scoped bar beside it. If the HUD ever becomes the bottleneck, this pair is the thing to dirty-flag (see #11 in `05-known-issues.md`).
- **Per shot:** one extra multiply on the launch-speed line and one on the damage scalar in `_spawn_projectile` (`2674`), plus one on each of the two hitscan damage sites.
- **Deliberately NOT in the rollback path.** `_charge_active`/`_charge_time` are broadcast state, never `RollbackSynchronizer` properties — the same rule as the fire flags (`02-netcode.md` §1). Adding them there would re-simulate the draw and multiply this cost by the tick count for no benefit.

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
- `world/payload/payload.gd` `_physics_process` (`121`): `_update_label()` string formats every frame; `_tick_healing` (`217`) calls `p.change_health(...)` every frame per pusher (feeding hotspot #3).
- `assets/materials/painted_toon.gdshader` `light()` (`280`): recomputes `paint_pattern()` (`291`, 3 `sin`) **once per light**, not once per fragment. This is forced, not an oversight — Godot has no mutable global shader variables ("Global non-constant variables are not supported"), so there is no way to compute the field once in `fragment()` and hand it to `light()`. A `varying` is the only cross-stage channel and per-vertex resolution is far too coarse for a terminator wobble. Cost is 3 sines per light per fragment, on lit surfaces only, and only for materials using this shader. If it ever profiles hot, bake the field to a texture and sample it.
- `assets/materials/painted_toon.gdshader` is **not** additive cost. Overriding `light()` sets `LIGHT_CODE_USED`, which *replaces* the engine's built-in direct-lighting branch rather than running alongside it — the shader does a ramp and one Blinn-Phong lobe where the default does Burley + Schlick-GGX. Ambient / sky / reflection-probe work is untouched and remains the dominant per-fragment cost.
- **Every character now shades through that shader.** All nine `assets/character_models/characters/*.tscn` carry authored `surface_material_override/N` entries (125 surfaces) pointing at `assets/materials/character_toon/*.tres`, so the per-light `paint_pattern()` cost above applies to every character on screen rather than to nothing. Applying the materials is now **free at runtime** — they are scene data, not built in code — so the only cost is the shader itself.

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

The rendered FPS is capped only by **VSync**, and that is Godot's *default* — this project sets no vsync key at all. `project.godot`'s `[display]` section contains only `window/size/viewport_width`, `window/size/viewport_height` and `window/stretch/mode`; there is no `display/window/vsync/vsync_mode` anywhere in the repo, so the effective value is Godot's default `1` (vsync **on**, locking FPS to the display refresh rate). `application/run/max_fps` and `Engine.max_fps` are likewise unset (default `0`, uncapped).

So there is already a refresh-rate cap in place. Setting `window/vsync/vsync_mode=1` explicitly would be a no-op; setting it to `0` would *remove* the cap and let the two local test instances contend for the GPU harder. If you want a tighter cap for local two-instance testing, set `Engine.max_fps` — it is independent of vsync.

*(Two earlier revisions of this doc claimed the project set the key, once as `0` and once as `1`. Neither was ever true.)*

## Cost of the tick-domain watchdog

`NetworkManager._process` runs every frame on every peer. In release it does one float add plus a 4 Hz integer comparison on clients (and a 1 Hz RPC on the host, ~4 bytes/s/peer); its debug logging is behind `OS.is_debug_build()`. The expensive part — `_reset_rollback_history()` — only runs on a re-seed, which is cooldown-limited to one per 5 s and should be rare now that the root cause is fixed.
