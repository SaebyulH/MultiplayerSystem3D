# 02 — Netcode: Rollback vs Server-Authoritative Split

The project deliberately splits simulation responsibility. Getting this wrong (e.g. putting a fire flag in the `RollbackSynchronizer`, or reading `global_position` inside `_rollback_tick`) produces subtle desyncs and "look/shoot works but movement doesn't" bugs.

## Topology

- Peer 1 is always the server (and the host player). Humans connect with ENet ids > 1. `network/network_manager.gd:27-55`.
- Autoloads: `NetworkManager`, `Leaderboard`, `NetworkTime`, `NetworkTimeSynchronizer`, `NetworkRollback`, `NetworkEvents`, `NetworkPerformance`, `GameManager` (`project.godot:22-32`).
- `[netfox] time/tickrate = 90`, `time/sync_to_physics = false` (`project.godot:217-220`); Jolt physics; collision layers WORLD=1, PLAYER_COLLISION=2, HURTBOX=3, HITBOX=4, RAGDOLLS=8 (`project.godot:208-214`). `time/tickrate` is only the **default**: the live rate is a per-session, server-chosen value applied by `NetworkManager.apply_tick_rate()`. See §8.

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

> **Tick desync** (`05-known-issues.md` #18): the two peers' `NetworkTime.tick` counters
> drift apart and nothing re-converges them, so one peer's inputs are stamped outside the
> other's 64-tick history window, get rejected, and movement renders seconds late. The
> cause is *when the joiner starts its clock sync*, not the tick loop's catch-up rate —
> the 2026-09-21 `max_ticks_per_frame` bump was aimed at the wrong thing. See §8.

### Determinism requirements (explicit in code)

- **Rising-edge detection** so presses replay deterministically: `_apply_movement_from_input` (`player.gd:1493`) computes `jump_pressed`/`dash_pressed`/`crouch_pressed` against `*_held_prev` and updates those held-prev flags — which are themselves in `state_properties`.
- **State that persists across re-simulation**: `_spawn_pending_position` is consumed only in `_physics_process`, never inside `_rollback_tick`, so re-simulated ticks see the same flag (declared `player.gd:321`, consumed `883-885`, safely re-read `998-1002`). Same pattern for `pinned_charger_name` (`328`, re-read `1027-1039`) and `_size_scale` (`334-340`).
- **`scale` re-derived every tick**: because netfox re-applies `global_transform` from rollback history each tick, `_rollback_tick` sets `scale = Vector3.ONE * _size_scale` at the top (`player.gd:995`). That multiplier is the only copy of the size-change state that survives — a one-off `scale` write anywhere else (`set_size_scale` also sets `scale` directly, `1395-1397`, for the current frame) is lost on the next tick.
- **Real-frame-only work** (sound, footsteps, fall damage) is kept **out** of `_rollback_tick` and placed in `_physics_process` (`player.gd:896-898, 901-905`).
- **`NetworkTime.physics_factor` must wrap everything `move_and_slide()` integrates — and nothing else.** `move_and_slide()` advances by whatever delta is current when it is called, and the rollback tick runs from `_process`, so it integrates with the *frame* delta (`network-time.gd:248-253` returns `ticktime / _process_delta` outside a physics frame; `move_and_slide()` reads the same delta). Every velocity term fed into it must therefore be multiplied by the factor, and the persistent `velocity` divided back out — otherwise that term is silently scaled by the client's frame rate. Knockback is the term that got this wrong historically; see §8.

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
- HITSCAN: raycast from the shooter's camera, `_flash_muzzle_flash.rpc` (2147), then on hit `_on_hitscan_hit.rpc(...)` (2188) which spawns decal/tracer/impact **on every peer** (`_on_hitscan_hit`, 2466-2504). Damage: server path `_apply_damage_direct` (2213-2220) → `change_health`; client path `_change_health_on_server.rpc_id(1, ...)` (2222).
- PROJECTILE: `_spawn_projectile_on_server.rpc_id(1, ...)` (2251-2254) → `_spawn_projectile` (2349-2376) instantiates under the **world's** `ProjectilesParent` (server-authoritative) and the world's `ProjectileSpawner` replicates it — see §6.

Ammo correction to clients: `_sync_mag` (2015) clamps and re-emits `mag_changed`. Reload completion uses `_confirm_reload_done` (1595-1610).

### Which targets a projectile can hit

A projectile's `HitboxComponent` (`components/hitbox_component.gd`, an `Area3D` on the projectile) is the **single** gate that turns an overlap into damage or healing — `_process_hurtbox_hit` (`hitbox_component.gd:42-73`), reached from `area_entered` (shield / shape hurtboxes) and from `body_entered` (a living player's physical-bone hurtbox, or a ragdoll corpse bone, which is knocked instead). Nothing downstream re-checks teams, so this is the only place to change targeting.

Four **per-scene** exports on that node decide eligibility, and they are set in the `.tscn`, never at runtime (`_spawn_projectile` writes only `hit_knockback` / `status_effects` / the damage amp onto the hitbox, `weapon_controller.gd:2393-2405`):

| Export | Default | Meaning |
|---|---|---|
| `can_hit_shooter` | `false` | whether the projectile may hit the player who fired it |
| `can_hit_other_teamates` | `false` | whether it may hit *allied* players (explicitly not the shooter) |
| `can_hit_enemy` | `true` | whether it may hit the opposing team at all |
| `enemy_delta_multiplier` | `1.0` | scales `health_delta` for enemy hits (Crusader's-Crossbow-style reversal at `-2.0`) |

- `hit_self` is `get_parent().shooter_name == owner_player.name`. `shooter_name` is stamped by `WeaponController._spawn_projectile` **before** `add_child` (`weapon_controller.gd:2363`), which is what makes the very first overlap check valid on every peer.
- `hit_ally` is `owner_player.team == shooter_team`, except in FFA where same-team isn't friendly, so it degrades to name equality with the shooter.
- The **sign** is on `health_delta` in the same node: positive heals, negative damages.
- The syringe (`weapon/projectiles/scenes/syringe.tscn`) is the worked example: `health_delta = 5.0`, `can_hit_other_teamates = true`, `enemy_delta_multiplier = -2.0` — heals allies, damages enemies, and (since 2026-09-25) `can_hit_shooter` is left at its `false` default so a medic's own syringe passes through them instead of self-healing. The `healthpack` and `poisoned_healthpack` scenes still set `can_hit_shooter = true` deliberately.
- The gate itself has **no** authority check, so it runs on every peer holding a copy of the projectile — but only one of them can act on it. `HurtboxComponent.hurt_or_heal` is consumed by `HurtComponent._on_hurt_or_heal` (`hurt_component.gd:14`), which returns early unless it has authority, and `HurtComponent2` is a direct child of the Player root whose authority `Player._enter_tree` pins to `1` (`player.gd:434`). So the damage/heal lands on the **server**; on a client the overlap fires, the emitted result is dropped, and the projectile's own free/stick path is likewise server-gated (`SimpleProjectile._on_hit_hurtbox`, `simple_projectile.gd:142`), leaving the despawn to the `ProjectileSpawner`. `_on_ragdoll_body_entered` is the one branch that checks `is_multiplayer_authority()` itself.

### Hitscan targeting: a body you cannot hurt does not stop the bullet

Hitscan never resolves through `HurtComponent` at all — the shot is a single `intersect_ray` in `_fire_single_shot` (`weapon_controller.gd:2122-2298`) that names its victim directly. **The shooter's own hurtboxes, and a teammate's, are travelled *through* rather than stopped on.** A bullet is never blocked by a body it could not damage:

| Collider | Behaviour |
|---|---|
| The shooter's own hurtboxes | passed through, always |
| A teammate's hurtboxes — `victim.team == shooter.team` and not `FFA` | passed through, **only while `Player.FRIENDLY_FIRE_MULTIPLIER` is 0.0** |
| Same team value in **FFA** | **stops and deals full damage** — same team isn't friendly there |
| An enemy | stops |
| A deployed shield | stops (a physical barrier; it still absorbs) |
| World geometry | stops |

Two mechanisms produce that, and both are load-bearing:

1. **`query.exclude`, rebuilt every shot from the shooter's own subtree** (`weapon_controller.gd:2195-2199`): the player's body RID plus **every** `CollisionObject3D` under it — all 20 physical-bone hurtboxes, the deployed shield's area, and the weapon models with their authoring `BoundingBox` areas. This is the cheap first-line filter, and it is what lets the shot fly past the shooter *without* a re-cast. It was a hand-written list of just the registered hurtboxes until 2026-09-25, when an unlisted area on the weapon model turned out to be stopping shots — see `05-known-issues.md` #40, which also records why the registry version was a trap.
2. **A re-cast loop driven by `_hitscan_passes_through()`** (`weapon_controller.gd:2209-2236`, predicate at `:2462`): `intersect_ray` only returns the *first* hit, so the loop adds each ignored collider's RID to the exclude list and casts again, until it finds something it can hurt or runs out. Bounded by `MAX_HITSCAN_PASSES = 16` (`weapon_controller.gd:194`) — each pass excludes one more body, so the loop is already bounded by the queue of bodies in the line; the constant only guards against a collider whose RID fails to take effect.

The predicate is deliberately derived from the *damage* rule rather than duplicating a team check (`weapon_controller.gd:2266`, `2325`), so "travelled through" and "would have dealt nothing" can never disagree — if friendly fire is ever turned back on, bullets stop on teammates again with no second edit.

Mechanism (2) is what catches a collider that (1) missed. That mattered when (1) was a hand-maintained registry of the 20 hurtboxes (`05-known-issues.md` #39) and it still matters for anything parented under the player *after* the walk — and for a hurtbox whose owner resolves to the shooter by player rather than by parentage.

Contrast with **projectiles**, whose targeting is a *per-scene* `HitboxComponent.can_hit_shooter` flag — a weapon can deliberately opt in to hitting its own shooter (the `healthpack` scenes do). Hitscan has no such flag.

**How it was verified (2026-09-25, Godot 4.7.2, real rigs, real ENet server peer).** Because a friendly hit already deals nothing (`FRIENDLY_FIRE_MULTIPLIER` = 0.0), "the teammate took no damage" cannot tell *stopped on them* from *travelled through them* — so each case aimed at a second body aligned bone-exactly behind the first, and asserted which one the server registered:

| Case | Expected | Measured |
|---|---|---|
| Teammate in line, enemy behind (both controls confirm geometry) | enemy hit | `_hit_player='3'`, mate ±0.0, enemy −33 |
| Same, in **FFA** | teammate hit | `_hit_player='2'`, mate −33, enemy untouched |
| Shot at one's **own** hurtbox, registry emptied so only the predicate can catch it | travels through | travelled through **3** of the shooter's own hurtboxes, `_hit_player=''`, shooter ±0.0 |

**Not covered:** teammate *ragdoll corpses* still stop a bullet. They are on the RAGDOLLS layer (which the hitscan mask includes) and `player.gd:676` strips their `HurtboxComponent`, so they are neither damageable nor identifiable as a teammate by owner — passing through them needs a `find_ragdoll_corpse` check, which nobody has asked for yet.

Two things do change the *shooter's own* health when a shot lands, and both look like a self-hit if you are watching your HP bar — see #39 for the full note: `WeaponFire.self_health_delta_on_hit` (Katana +35, Poison Syringe +100, applied to the shooter) and `Character.lifesteal_percent` (Stalker 0.3, applied to the shooter per landed hit).

### Damage amp (`Character.damage_amp_mult`)

`Character.damage_amp_mult` (`player/character.gd:48`; Stalker `0.17`, Nerd `0.9`, everyone else `1.0`) scales everything the shooter hits, and reaches damage by **two different routes** depending on how the shot resolves:

- **Hitscan** — `_apply_damage_direct` multiplies the delta inline (`weapon_controller.gd:2461`), and also derives lifesteal from the amped value.
- **Projectiles** — folded into the projectile's **base** damage at spawn in `_spawn_projectile` (`weapon_controller.gd:2406-2419`): `hb.health_delta` and `ec.splash_health_delta` are each multiplied by the amp. A projectile never passes through `_apply_damage_direct`, so without this it dealt fully un-amped damage — which is exactly what made a `0.17` Stalker's Shurikens and Bow hit like anyone else's.

Both go through `_damage_amp_of(player)` (`weapon_controller.gd:2426`), which returns `1.0` when the shooter or its character can't be resolved.

Rules that fall out of where the stamp is applied:

- **Damage only.** A positive delta is a heal (syringe, healthpack, heal grenade), so the guard is `if hb.health_delta < 0.0` — a damage amp must never shrink a heal.
- **It must precede `add_child()`.** `SimpleProjectile._ready()` snapshots `health_delta` as `_base_hitbox_damage` and rewrites it every frame as `base * falloff` (`simple_projectile.gd:132-138`); an amp applied after `_ready()` is wiped on the first physics frame. This is the same ordering the existing `hit_knockback` / `status_effects` copies already rely on.
- **Per-target scaling composes on top.** `enemy_delta_multiplier`, `self_health_delta_multiplier`, headshot/backshot and both falloffs all multiply afterwards, so an amped rocket's self-damage and splash falloff are amped too — the same blanket rule hitscan already follows.
- **Both damage fields must be `float`.** `HitboxComponent.health_delta` always was; `ExplosionComponent.splash_health_delta` was declared `:= -75`, which infers **`int`**, so `-90 × 0.17` was stored as `-15` instead of `-15.3` (a 2 % under-count, and worse for smaller amps). It is now `: float = -75.0`; the `.tscn` values stay written as integer literals and coerce fine. Any new per-projectile damage export must be explicitly typed `float` for the same reason.
- **`PlayerShield` reads the amped value for free**, because `shield.gd:207` absorbs `hitbox.health_delta` directly. That is a consistency win on the server and a divergence on clients — see `05-known-issues.md` #38.
- **It is not replicated.** The projectile's `MultiplayerSynchronizer` carries only `global_transform` and `shooter_name`, so a client's copy holds the authored damage. Irrelevant for player damage (server-authoritative), but see #38 for the shield.

**How this was verified (2026-09-25).** A throwaway headless harness drove the real chain — `_spawn_projectile` → `HitboxComponent._on_hurtbox_entered` / `ExplosionComponent.explode` → `HurtComponent._on_hurt_or_heal` → `AttributeComponent.apply_health_delta` — against real `Player` nodes and real weapon resources, once per character, comparing a Mannequin (`1.0`) shooter against a Stalker (`0.17`):

| Case | amp 1.0 | amp 0.17 | ratio |
|---|---|---|---|
| Shuriken direct hit (−30) | −30.00 | −5.10 | **0.170** |
| Rocket splash (−90 @ 1.0 m) | −75.00 | −12.75 | **0.170** |
| Syringe on an ally (+5) | +5.00 | +5.00 | 1.000 |
| Syringe on an enemy (×−2.0) | −10.00 | −10.00 | 1.000 |

The `amp 0.17` column is the fix: it read full damage before. The harness also asserted `health_delta` is unchanged after 5 physics frames (the falloff-rewrite ordering above) and, re-run with the amp forced to `1.0`, reproduced the original bug exactly — the two damage rows fail while the two heal rows still pass.

**Not exercised:** the `Area3D`/`PhysicalBone3D` overlap itself (the handler was called directly), `PlayerShield` absorption, and a real two-peer session.

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
- **Resolution is by scene file path, not by index arithmetic.** `MultiplayerSpawner` matches the spawned node's `scene_file_path` against each entry's `Resource.get_path()` to pick the index that goes on the wire. A scene that is not a file on disk — notably an **inline `SubResource` `PackedScene`** — can never match, so it either fails to replicate or resolves to whatever its base scene is. That is known-issues #28: `rocket_launcher.tres` and `syringe_gun.tres` stored their projectiles as inline bundles whose base was the mesh-less `simple_projectile.tscn`, so remote peers instantiated an invisible projectile.
- **Projectiles** are replicated by a **single world-level** `MultiplayerSpawner`: `world/world1.tscn` `ProjectilesParent/ProjectileSpawner` (`spawn_path = ".."`, 17 uids), reached through `GameManager.projectile_parent` (set in `world_1.gd:_ready()`, resolved in `WeaponController._projectile_parent()`). Projectiles are **not** parented to the Player that fired them — `Player.despawn()`'s `hide()` would cascade to them and a disconnect would free them.
- The tracer / bullet-decal / bullet-impact nodes from `_on_hitscan_hit` ride the **same** parent. They are local, non-networked nodes; their scenes are absent from `_spawnable_scenes`, so the spawner ignores them (true before this change too).
- `player/auto_projectile_spawner.gd` extends `MultiplayerSpawner` to auto-scan the projectiles folder — it is a `@tool` script, inert at runtime.
- The `ProjectilesParent`/`ProjectileSpawner` pair that still exists in all 10 maps is **dead** — nothing parents under it. See known-issues #29.

---

## 7. StatusEffectManager (server ticks, client mirror via RPC)

`components/status_effect/status_effect_manager.gd`:
- Header (4-15): effects applied and ticked **entirely on the server**; clients do no local ticking; remaining times pushed on apply/remove and at ~10 Hz.
- `TICK_INTERVAL = 0.1` (50). `_on_tick_timeout` (65-72) returns unless `multiplayer.is_server()`. `_tick_server` (75-133) decrements `remaining`, fires `_on_tick` at `tick_interval`, removes expired, and calls `_sync_to_clients()` only if a timed effect exists or one just expired (avoids re-broadcasting permanent wallhack/health markers).
- **Expiry is checked before the tick**, so the last tick of any duration is *not* delivered — a 5 s / 0.5 s effect fires 9 times, not 10. Effects that must pay out an exact total have to reconcile the remainder in `_on_remove`; `HealOverTimeEffect` does (see below). Do not assume `base_duration / tick_interval` ticks reach `_on_tick`.
- **An effect is deregistered *before* its `_on_remove` runs** — in both `_tick_server` (natural expiry) and `remove_effect` (forced). This is load-bearing, not stylistic: `_on_remove` can re-enter the manager, and a still-registered id would run the teardown again, unbounded. `SizeChangeEffect._on_remove` writes the player's health back, and `AttributeComponent.health`'s setter emits `no_health` at `<= 0` → `clear_all_effects()` → back into the same teardown. That was the stack overflow at 1024 frames (known-issues #31). `_tick_server` also walks a `keys()` snapshot for the same reason.
- `apply_effect` (138-168): server-only; negative effects extend duration; permanent effects use `INF`; calls `_on_apply` then `_sync_to_clients`. Note it inserts into `_active_effects` *before* `_on_apply`, so a teardown triggered from `_on_apply` sees the new effect as already registered. Re-applying a **non-negative** effect of the same id *replaces* the entry without running the outgoing one's `_on_remove` — so a positive effect holding per-cast state (a queued remainder payout, say) loses it on recast. That is accepted, not an oversight: a recast is a fresh channel.
- `_sync_to_clients` (272-290) rebuilds the client mirror and pushes via `_rpc_sync_effects` (`@rpc("authority","call_remote","reliable")`, 313-324) — four parallel arrays: `effect_ids`, `effect_names`, `remaining_times`, and `blocks_actions`. Poison hidden until `drain_started` (296-309).
- `has_effect`/`is_stunned`/`is_pinned` read the client mirror `_client_effects` (29, 196-236).
- **The action lock (`StatusEffect.blocks_actions`) travels with that same sync.** The gate that consumes it — `PlayerInput._gather` / `._input`, `AbilityManager._input`, `BotController._physics_process` — runs on the *owning client*, which holds no effect resources, so the boolean is mirrored into `_client_blocks_actions` and read through `is_action_blocked()` (239-243), which is an O(1) compare against `_client_blocking_count`. Do not collapse `blocks_actions` into an effect *id* the gates check by name (the way `stun`/`pinned` work): the flag is per-cast data (`HealAbility.block_actions_during_heal`), not per-effect-type. See known-issues #33 for the latency window this creates.
- Late joiners get an explicit `_sync_to_clients(peer_id)` from `SpawnManager._sync_existing_players_to_peer` (`spawn_manager.gd:44-45`).

### HealAbility — instant vs. channeled (`player/abilities/heal_ability.gd`)

`HealAbility` has two modes, switched by `heal_over_time` (default **false** = the original instant heal; `heal.tres`, `breacher.tres` and `governess.tres` all keep that default, so this changed nothing for existing characters).

- **Instant:** `change_health(heal_amount, player.name)` — one `apply_health_delta`, one self-heal credit.
- **Over time:** builds a `HealOverTimeEffect.new()` **per cast** and hands it to `apply_effect`. It is not authored as a `.tres` under `defaults/status_effects/`: `total_heal`, `base_duration`, `tick_interval` and `blocks_actions` are per-cast values taken off the ability, and an ability is a `Resource` shared by every player of that class (CLAUDE.md — duplicate mutable per-instance state).
- Past that point it is an ordinary effect: server-ticked, client-mirrored, so the HUD countdown and the effect list pick it up with no extra work, and `clear_all_effects()` on death/respawn tears it down. A lock can therefore never outlive a life.
- **`_on_remove` reconciles the dropped final tick** (see the expiry bullet above) — `total_heal` is paid out exactly, not `ticks × per_tick`. It is guarded on `attribute_component.health > 0.0` because `no_health()` runs `clear_all_effects()` *while health is still <= 0*, and a positive write there would revive the player and re-enter the death path (#32). On respawn the reset has already restored full health, so the write clamps to a zero delta — it can never credit a heal that was not received.
- Degenerate configs degrade rather than break: `heal_duration = 0` or `heal_tick_interval = 0` pays the whole amount out at once via `_on_remove`. That is intended, not a bug to "fix".
- **`activate()` must stay server-side** (`Ability.CastMode.SERVER`, the default — do not flip it). `apply_effect` is a silent no-op off-server, so a `CLIENT` cast mode would burn the cooldown and heal nothing.
- The action lock (`block_actions_during_heal`) is enforced in **six** places, all reading `is_action_blocked()`: `PlayerInput._gather` (movement/jump/crouch/dash), `PlayerInput._input` (fire + weapon switch/reload), `BotController._physics_process` (bots) — all client-side, and the two **server backstops** `AbilityManager._cast_ability` (casting) and `WeaponController.fire_intent` (firing), which are the ones that actually hold. Both backstops are one guard in a function that already rejected on a gameplay condition, which is why they were cheap to add; both mirror the existing `spawned` check directly above them. See #33 for the one thing it does *not* cover — movement.

**The ally-targeted twin** is `HealAllyAbility` (`player/abilities/heal_ally_ability.gd`, resource `heal_ally.tres`) — same `HealOverTimeEffect`, same per-cast build, but applied to *other* players through a `TargetedAbility`. Two things differ from the self-heal, both deliberate:

- **`blocks_actions` is left false.** The target is someone else; an action lock there would be a griefing tool rather than a commitment.
- **The applier is the medic, not the target.** `apply_health_delta` routes `changee != changer` into `Leaderboard.request_add_heal_other`, so the heal credits the medic's scoreboard line — which is also why the effect's `_on_remove` remainder uses the applier stored in its state rather than `player.name`.

### TargetedAbility — the `target_team` filter

`player/abilities/targeted_ability.gd` used to hardcode an enemy test in **two** places — its own
`find_candidates` (client-side preview) and `AbilityManager._resolve_targets` (server-side
validation). Ally targeting needs both, so they now share one predicate,
`TargetedAbility.is_valid_target(caster, other)`, selected by `target_team` (`ENEMIES` /
`ALLIES` / `BOTH`, defaulting to `ENEMIES` so every existing offensive ability is unaffected):

- **Never re-inline the team test into either call site.** If the two disagree the failure is
  silent and confusing in a specific way: the HUD previews a target the server then rejects
  (cast refused, no cooldown burned, nothing visible happens), or the reverse.
- `ALLIES` uses the existing `Player.is_teammate_of()` (`player.gd:2356`), which is
  `team != FFA and other.team == team` — so **an ally-only ability has no valid targets in FFA
  mode at all** and cannot be cast there. That is intended, and falls out of the predicate rather
  than a special case.
- The filter is also what keeps the Shrink Enemy ability honest: it stays `ENEMIES`, so an
  ally-targeted heal and an enemy-targeted shrink on the same character can't cross wires.

### SizeChangeEffect — one effect, both directions

`components/status_effect/effects/size_change_effect.gd` scales the player's root node and max
health. `size_mult` and `health_mult` are plain `@export`s, so **enlarging and shrinking are one
code path** — there is no separate shrink effect, just `size_mult < 1.0`. The two authored ends
live in `defaults/status_effects/`: `size_change.tres` (2.0, what Rampage used to be) and
`shrink.tres` (0.5).
- **`is_negative` and `effect_id` are per-`.tres`, not per-class**, precisely because the effect is
  bidirectional. `size_change.tres` is the buff (`enlarge`, `is_negative = false`) and `shrink.tres`
  is the debuff (`shrink`, `is_negative = true`) — which is what makes a shrink cleansable by
  `InvincibleEffect` and makes a re-cast extend the duration instead of replacing it. Do not
  "simplify" either by hardcoding it in `_init()`: `_init`'s `is_negative = false` is invisible in a
  `.tres` that agrees with it, which is exactly how the field medic's inline shrink ended up as a
  non-cleansable buff that took the replace path.

- **The effect never touches health.** It registers two multipliers —
  `Player.add_size_multiplier(key, size_mult)` and
  `AttributeComponent.add_max_health_multiplier(key, health_mult)` — and those two systems derive
  the scale and the live max from them. This is the whole design, and it is load-bearing: the
  previous version captured `attribute_component.starting_health` as its "base" and wrote the scaled
  value back into it, which corrupted max health **permanently** whenever a second size effect
  replaced the first without the first's teardown running. With no captured state there is nothing
  to lose, so that failure mode is impossible rather than merely unlikely — known-issues **#36**.
- **Multipliers are registries, keyed by effect id, and they compose.** Shrunk to 0.25 then grown by
  2.0 leaves the player at 0.5 scale and 0.5× max health; removing either factor leaves the other
  exactly as it was. Both removals are idempotent, so a teardown that runs twice is harmless.
- **`max_health` is DERIVED, never assigned.** `AttributeComponent` computes
  `max_health = starting_health * product`, and `starting_health` is the character's base — written
  only by `Player.set_character()`. Its setter recomputes, so `_ready()` and `set_character()` are
  the only two entry points that need to think about it. **Do not write `max_health` from outside.**
- **Health follows the ratio, not the absolute.** `recompute_max_health()` scales current health by
  `new_max / old_max`, so the bar never jumps:
  `100/100 --shrink--> 50/50 --25 dmg--> 25/50 --expire--> 50/100`. It writes only when the value
  actually moves, and **never while `health <= 0`** — the `health` setter emits `no_health` on every
  assignment landing at `<= 0`, so a resize of a dead player would re-enter the whole death path
  (#31/#32).
- **The scale is rollback state, not a one-off write.** `_recompute_size_scale()` calls
  `Player.set_size_scale()`, which stores `Player._size_scale`, re-derived as
  `scale = Vector3.ONE * _size_scale` at the top of `_rollback_tick` (`player.gd:995`) — netfox
  re-applies `global_transform` from history every tick, so anything else is lost.
- **The sync is a one-shot RPC** (`Player._rpc_size_change(scale_mult, health_mult)`, `@rpc("authority")`)
  carrying the server's already-multiplied **results**, not factors — a client holds no registry,
  because effects never tick off-server. It carries multipliers rather than absolutes so each peer
  derives max health from its own `starting_health`, which `set_character()` has already set
  identically, so the two cannot drift. A late joiner never sees this RPC, which is why
  `rpc_sync_full_state` carries the same two values — known-issues #34, and #35 for why that RPC is
  `authority` rather than `any_peer`.
- **A shrink needs a different `effect_id` from an enlarge** (`shrink` vs `enlarge`).
  `StatusEffectManager._active_effects` is keyed by id, so two effects sharing one would replace
  each other instead of stacking — that collision is what turned the old corruption into a loop.
  *Different* effects stack by having different ids; *repeat applications of the same effect* stack
  through the `stacks` flag below.
- **`stacks` — repeating the same effect compounds rather than extends.** `SizeChangeEffect` sets
  `StatusEffect.stacks = true` in `_init()`, so two shrinks give `0.25 × 0.25 = 0.0625` instead of
  one merely lasting longer. In `apply_effect` the check sits **before** the negative-effect merge
  branch (which would otherwise swallow every application after the first), duplicates the effect,
  and stamps a per-application id (`shrink#<instance_id>`) — the id is what `_on_apply` passes to
  `add_size_multiplier`, so each application owns its own registry key and its own duration.
  - **Duplicate before stamping, never after.** Stamping a shared `.tres` in place would rewrite the
    resource on disk for a weapon that applies its `status_effects` entry directly.
  - Ids with a suffix must be looked up by base id: `has_effect()` falls back to a base-id match and
    the HUD material lookup normalizes through `StatusEffectManager.base_effect_id()`. Write new
    lookups the same way.
  - Everything that does *not* opt in keeps the old behaviour — one id, extend on re-apply — which is
    what `burn`, `slow`, `poison` and `stun` all want.
- Applied by the generic `SelfEffectAbility` (`player/abilities/self_effect_ability.gd`) via
  `player/abilities/size_change.tres`; the ability duplicates the effect resource per cast, so the
  `.tres` is never mutated by a caster. Any other effect can be applied to yourself the same way.
- The **enemy** direction is `ShrinkEnemyAbility` (`player/abilities/shrink_enemy_ability.gd`, resource
  `shrink_enemy.tres`) — a `TargetedAbility` like `BurnAbility`, so it inherits crosshair-based
  candidate selection, the HUD preview, and server-side re-validation for free. It duplicates
  `shrink.tres` **per target** and stamps `shrink_duration` onto the copy, for the same
  shared-resource reason. Net effect is a temporary nerf, not a permanent cut — the damage the target
  takes while shrunk is kept in proportion:

  ```
  100/100 --cast--> 50/50 --25 dmg--> 25/50 --expires--> 50/100
  ```

---

## 8. The tick domain and the session tick rate

`NetworkTime.tick` is the shared clock every rollback stamp is written against, but it is **not** synchronised between peers — it is a local counter, and netfox only ever sets it absolutely in three places (`network-time.gd:427`, `:440`, `:552`). Everything else is `_tick += 1`.

- **The host** starts at `_tick = 0` when `NetworkTime.start()` runs, at the same instant `NetworkTimeSynchronizer.start()` zeroes the reference clock (`network-time-synchronizer.gd:141`). So the host's tick is always `seconds_to_ticks(its reference clock)`.
- **A client** seeds itself once, at `network-time.gd:440`, from that same reference clock — and the sample it uses carries **no RTT or elapsed-time compensation** (`network-time-synchronizer.gd:267-276`). The periodic NTP-style ping/pong that *is* properly compensated only begins afterwards.
- **Nothing re-converges the two.** The only coupling is the clock-stretch servo (`network-time.gd:523-537`), which pulls at most ±25 %, so a 10 s offset needs ~40 s to heal. `NetworkTime.tick` is monotonic; the only way to move it is `NetworkTime.stop()` + `NetworkTime.start()`.

### The host↔client tick bias (measured)

Worth knowing when reasoning about the rollback window: **the host's tick does not track its own reference clock.** Measured on a solo host at 90 Hz, `[NTSYNC]` settles at a steady `offset ≈ +23` — i.e. `NetworkTime.tick` sits ~23 ticks (0.26 s) *below* `seconds_to_ticks(reference clock)` — and stays there. The clock-stretch servo ran at `0.800` through boot, the tick accumulator followed it down, and nothing repays the deficit (netfox's `_was_paused` re-anchor only fires on a frame longer than `stall_threshold`, 1 s).

Since a client is seeded to `seconds_to_ticks(reference clock)`, a **correctly-seeded client therefore runs ~23 ticks ahead of the host's actual tick** — a third of the 63-tick window at 90 Hz, before any real divergence. Rollback still works (the client's stamps are inside the host's window and vice versa), but this is netfox's inherent bias, not something the project can fix from outside the addon.

It is also why **the watchdog measures drift against the reference clock, not against the host's tick**: comparing against the host's reported tick would read a constant `+23` in a perfectly healthy session. See `NetworkManager.get_tick_offset_ticks()`.

**Consequence: the client's seed is only as good as the moment it is measured.** If the clock-sync round trip spans a stall, the client's whole tick origin is short by the stall — and until it heals, `history_start = tick - history_limit` has moved past the host's live inputs, so they are discarded as too old, the host sees no input for those ticks, stops sending state for that player, and `RollbackSynchronizer._notify_resim()` pins `_resim_from` to a frozen cursor — the `Trying to run rollback for ticks X to Y, past the history limit` warning, thousands of frames of it. This is why `NetworkManager` now owns the client's start (see `03-event-flow.md`), and why it waits for the join to settle first.

### Session tick rate

The rate is a property of the session, chosen by the host and adopted by clients:

- `NetworkManager.server_tick_rate`, applied by `apply_tick_rate(rate)`.
- netfox **latches** its rate from `ProjectSettings` when the autoload is constructed (`network-time.gd:368`) and its `tickrate` setter is a `push_error` no-op (`:17-18`), so `apply_tick_rate()` writes `NetworkTime._tickrate` directly. Nothing caches a rate at `_ready` — `ticktime`, `tick_factor` and `physics_factor` are all derived per use — so the write is complete.
- **It must happen before `NetworkTime.start()`.** The client's seed is `seconds_to_ticks(...)` evaluated with the live rate, and the tick is monotonic, so a wrong multiplier at seed time can only be undone by a full re-seed. That is why `_rpc_set_tick_rate(rate, restart = false)` is only allowed to apply while the client's loop is still down, and does a real restart otherwise.
- netfox's own `NetworkTickrateHandshake` cannot do this job: its `ADJUST` branch calls `ProjectSettings.set_setting` long after the latch, which is inert (`network-tickrate-handshake.gd:87-88`), and it only raises the mismatch signal when the rates *differ* — so a peer whose default happens to match would never be told the value.
- Changing the rate mid-session stops the loop on every peer, applies, and restarts (`NetworkManager._reinit_time`). Clients restart after the host, so they seed from the host's already-running clock. Expect a brief movement freeze.
- **Tick-count limits are derived from seconds.** `history_limit` and `max_ticks_per_frame` are counts of ticks, so their wall-clock meaning scales with the rate (netfox's default 64 is 2.13 s at 30 Hz but 0.71 s at 90 Hz). `NetworkManager.HISTORY_SECONDS` / `CATCHUP_SECONDS` are the single source of truth and `apply_tick_rate()` computes the counts — do not also set them in `project.godot`.

### Knockback is tick-rate independent by construction

`knockback_multiplier` (`player/character.gd:65`) is a pure per-character feel knob, default `1.0`. It carries **no** tick-rate compensation. The impulse is converted where it is integrated:

- `_apply_movement_from_input` (`player.gd:1764-1772`) adds `knockback_velocity * NetworkTime.physics_factor` **inside** the `physics_factor` sandwich, alongside `velocity`, so `move_and_slide()` integrates it with the same delta as everything else and the factor cancels exactly.
- `_noclip_move` (`player.gd:1107-1113`) integrates manually with the tick delta, so it applies **no** `physics_factor` at all.
- `knockback_decay = velocity.length() ** 2 * 10` is applied as `decay * delta` with `delta == ticktime`, so `tickrate × ticktime == 1` — it is already tick-rate independent. Do not "fix" it.

History: the old `0.667` default was not really `60 / tickrate`. Adding knockback *outside* the sandwich made `move_and_slide()` scale it by the frame delta, and `0.667` happened to cancel that at a nominal 60 fps — which is why the constant looked like a tick-rate compensation and why it survived. It was 1.5× too strong at 60 fps and 3.6× at 25 fps before the fix.

---

## Consolidated fragility list (cross-referenced to `05-known-issues.md`)

1. **Camera-relative movement with unsynced camera** (`player.gd:1493, 1864`; `body.gd:26-57` + commented `sync_rotation`).
2. **`_sync_mag` unreliable** (`weapon_controller.gd:2015`).
3. **`fire_intent` lacks sender validation** (`weapon_controller.gd:1948`) vs `request_reload` (`1459`).
4. **Health regen simulates on every peer** (`attribute_component.gd:160-180`, no `is_server()` gate) and calls `apply_health_delta`, triggering kill/score bookkeeping. The server's value wins via `MultiplayerSynchronizer` (always), but the client duplicate-simulates death/score side effects on negative regen. **`[FIXED 2026-09-20]` — regen is now `is_server()`-gated and self-heal stat reporting is throttled.**
5. **Two overlapping 10 Hz control-point syncs** — `ControlPoint._rpc_sync_state` unreliable (`control_point.gd:242`) vs `GameModeComponent._rpc_sync_state` reliable (`game_mode_component.gd:128`). Intentional redundancy, easy to mistake for a duplicate.
6. **Manual state kept in sync against netfox rollback** — `scale` re-derived each tick (`player.gd:969-972`); `_spawn_pending_position`/`pinned_charger_name` persist across re-sim.
7. **Server-side randomness is fine, rollback randomness is not** — `_get_spawn_position` uses `randi()` but runs server-side via RPC; fire spread `randf()` runs only in server-side `_fire_single_shot`. Neither is inside `_rollback_tick`.
8. **Map swap ordering** — `remove_child` + `queue_free` (not `free`) so the spawner emits the removal event; teardown+rehost deferred a frame (`network_manager.gd:return_to_lobby`).
9. **The client's `NetworkTime` start is project-owned, not netfox-owned** — `NetworkManager._take_over_client_time()` disconnects netfox's `on_client_start` listener, so anything else relying on that signal (including a future listener) is on its own. `03-event-flow.md`.
10. **The tick domain is monotonic and only repairable by a full re-seed** — never apply a tick rate after `NetworkTime.start()`, and never let the watchdog resync the host. §8, `05-known-issues.md` #18.
