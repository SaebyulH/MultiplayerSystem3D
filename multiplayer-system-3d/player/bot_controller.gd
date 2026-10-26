extends Node
class_name BotController

## ============================================================================
## BOT NOTES — living context.  Update this block every stage.
## ============================================================================
##
## VERIFIED FACTS (Stage 0, with file:line).  These are facts, not guesses;
## everything else in this file that still guesses is marked below.
##
## INPUT / TIMING
## - `PlayerInput.input_dir` is CAMERA-relative, not body- or world-space:
##   x = right, y = +1 for BACKWARD (Input.get_vector convention).  Consumed at
##   player.gd:1709-1715 as `forward * input_dir.y + right * input_dir.x`.
##   World-space steering written straight into it is rotated by the body yaw
##   (KNOWN ISSUE D is real).
## - `PlayerInput._gather()` is bound to `NetworkTime.before_tick_loop` and
##   RETURNS EARLY FOR BOTS (player_input.gd:66-72).  A bot's rollback inputs are
##   therefore exactly what BotController writes; nothing overwrites them.
## - Firing is NOT rollback input.  WeaponController._physics_process polls the
##   three `*_fire_held` booleans every physics frame
##   (weapon_controller.gd:535-544), and for bots calls `_process_fire()`
##   directly on the server.
## - Tick rate = physics rate = 90 Hz (project.godot:229-235,
##   `netfox/time/sync_to_physics=true`).  One tick = 11.1 ms.
## - Node order: BotController precedes WeaponController in player.tscn
##   (lines 455 vs 462), so a flag written in BotController's
##   `_physics_process` is visible to `_process_fire` the same frame.
## - KNOWN ISSUE A2 IS NOT REAL for firing: a 50 ms press spans 4-5 physics
##   frames and the fire path is not sampled from rollback history.  Movement
##   edges ARE per-tick (`jump_held_prev` in the rollback tick), so a future
##   writer must hold jump/input for >= 2 ticks (22.2 ms) to guarantee an edge.
##
## FIRING / WEAPONS
## - Fire flags are LEVEL-triggered.  Semi-auto is edge-detected by
##   `_fired_this_press[index]`: latched on a successful shot and cleared only
##   when the flag is read false (weapon_controller.gd:1916-1926, 1991-1992).
##   Charged weapons fire on the true->false edge (1923-1924).  KNOWN ISSUE A is
##   real: `_clear_fire_inputs()` every 50 ms releases the trigger, so a
##   semi-auto gets exactly one shot per ~2.15 s pulse cycle.
## - A shot is accepted only when: `spawned`, `_is_ready()` (:297-302), not
##   `is_switching()`, not `_is_reloading`, `_fire_cooldown <= 0`,
##   not `_pending_fire`, not `_is_firing`, magazine >= ammo cost, not
##   `_fire_is_blocked()`, not charging/bashing, no ability equipped.
## - Semi-auto also requires a false read between shots (`_fired_this_press`),
##   so a hold-to-fire bot must pulse: true for >= 1 frame, false for >= 1 frame.
## - Weapon switch: assigning `current_weapon_index` runs the real state machine
##   (`_on_weapon_index_changed` -> `_begin_switch`) and is replicated by the
##   WeaponController MultiplayerSynchronizer.  Cost is outgoing `put_away_time`
##   + incoming `pullout_time` (every weapon: 0.1 + 0.8 = 0.9 s).  Gate on
##   `is_switching()`, not a bot-local timer.
## - Reload: `start_reload()` (:1689) -> server timer `reload_time /
##   character.reload_speed_mult`.  Switching cancels it; firing does not
##   (except an individual-reload queued interrupt).  Gate on `_is_reloading`.
## - `WeaponFire` has NO `max_range`, `range`, `is_melee`, `projectile_speed`
##   or `speed` property.  The old probes are all misses (now warned + logged
##   by `_read_prop`).  Real melee rule in production code:
##   `bullet_type == HITSCAN && hitscan_range < 10`
##   (weapon_controller.gd:2657).
## - `has_infinite_ammo` weapons: Bow, Katana, Poison Syringe, Knife,
##   Backstab Knife, Ball Gun.
##
## PROJECTILES
## - Launch speed is authored as `linear_velocity` in the projectile `.tscn`
##   and read before entering the tree: WeaponController._spawn_projectile
##   (:2898-2906) does `speed = projectile_scene.linear_velocity.length() *
##   charge_mult`, then `world_dir * speed + forward_boost`.  The old comment
##   claiming this reads 0 is WRONG for this project's scenes.
## - Projectiles are `RigidBody3D` (`SimpleProjectile`); gravity comes from
##   `gravity_scale` (rocket 0.0, arrow 1.0, gravity_rocket 1.5, flame -0.5).
## - Exact root child names: `HitboxComponent` (Area3D) and
##   `ExplosionComponent` (Node3D).  `splash_radius` (default 3.0) lives on the
##   ExplosionComponent, NOT on the projectile root.
## - Authored launch speeds (m/s): arrow 50, flame/water 50, ball 30,
##   grenade/heal_grenade/mine/molotov/poison_jar 27, syringe 25, rocket/rock 20,
##   gravity_rocket/redirectable_rocket 20/18, shuriken 20, wood 12,
##   simple_projectile 10, healthpack 5, nuke 5.  Bow scales this by
##   `uncharged_projectile_speed_mult` 0.2 -> 1.0.
## - TRAP: every projectile scene instances `simple_projectile.tscn`, which
##   SHIPS an ExplosionComponent (`splash_health_delta = -100`).  Node presence
##   therefore says "explosive" for arrows, syringes, balls, etc.  Real
##   detonation is `hurtbox_hit_mode == EXPLODE (2)`,
##   `world_hit_mode == EXPLODE`, or `explode_on_timeout`.  Mine detonates only
##   on the weapon's SIGNAL fire.  The current `_get_proj_info` false-positives
##   on all of them (see OPEN QUESTIONS).
## - `heals_allies` (positive hitbox `health_delta` + `can_hit_other_teamates`)
##   is true only for Syringe Gun and Medpack Launcher.  Heal Grenade Launcher
##   heals through its EXPLOSION (`splash -45` x self/team multiplier -1.0), so
##   the current heal detection misses it.
##
## AIM / DAMAGE / WORLD
## - `%Head` = `Body/Recoil/Head`.  Fire direction = `Body/Recoil/Head/Camera3D`
##   global basis (weapon_controller.gd:2399, 2618, 2895); projectile spawn
##   transform = `%Head.global_transform`.  The targeting head-bone path exists
##   at `Body/Mannequin/mannequin/Skeleton3D/PhysicalBoneSimulator3D/
##   Physical Bone DEF-spine_006` (player.tscn:734-1062).
## - Recoil is the `Body/Recoil` node's rotation, added on top of Body yaw and
##   Head pitch (recoil.gd:21).  Shots add POSITIVE pitch/yaw
##   (weapon_controller.gd:2163-2170, 3131-3139), so subtracting
##   `recoil.rotation` (scaled by skill) is the correct sign.
## - Collision: WORLD = layer 1, PLAYER_COLLISION = layer 2 (Player root
##   layer = 2), HURTBOX = layer 4, HITBOX = layer 8, RAGDOLLS = layer 128.
##   Bot LOS/steer rays use mask 1 -> world geometry only; they pass through
##   players and hurtboxes, so a target never blocks its own LOS.
## - Movement: CharacterBody3D, no step-up helper (stairs need a jump), default
##   45 deg floor angle / 0.1 snap, jump 5 m/s, gravity 9.8 via `get_gravity()`,
##   walk 3 m/s, ADS 1.5, crouch 1.3333 vs stand 2.0, dash 11, 1 air jump and
##   1 air dash per airtime, stamina 3 bars.
## - Damage observation: `AttributeComponent.health` + `health_changed` (no
##   args), `last_attacker` / `last_enemy_attacker` (entity-name Strings),
##   `last_hit_direction`.  Compare a stored health value per think tick.
## - Map: the spawned root is named "Map" (Map.gd).  Geometry is StaticBody3D
##   + ConcavePolygonShape3D, CSGCombiner3D (`use_collision`), or a
##   FuncGodotMap.  DYNAMIC colliders to exclude from any bake:
##   AnimatableBody3D (PayloadNode, MovingBrush, RotatingBrush), RigidBody3D
##   (PhysicsBrush), Players, projectiles.
## - Lifecycle: SpawnManager._spawn_bot (world/spawn_manager.gd:138) ->
##   `rpc_reset` -> 1 s respawn_timer -> `Player.spawn()`.  Death ->
##   `no_health()` -> `rpc_reset`.  BotController state is NOT reset by any of
##   this; later stages must reset it on a false->true `player.spawned` edge.
##
## STAGE STATUS
## - Stage 0 (recon + diagnostics): COMPLETE.
## - Stage 1 (Trigger / aim gate / deterministic fire modes / idle rescan):
##   COMPLETE.  `Trigger` is now the only writer of the fire flags; it runs at
##   90 Hz with semi tap+gap, automatic hold, charged draw/release.  Aim error
##   is measured from the real head ray; `is_explosive` is mode-based; fire-mode
##   choice is event-driven and SHOOT-only; `_targets_valid` returns true when
##   there is nothing to validate.
##   Verified headlessly with two auto-spawned bots: both acquired targets and
##   pressed the trigger repeatedly, with aim error ~1-2 deg against a ~5 deg
##   gate.  In-game cadence/charged checks remain manual.
##   Follow-up tuning: `skill` now defaults to 1.0.  (Stage 2 later replaced the
##   exponential aim smoothing entirely — see below.)  Explosive self-damage is now read from
##   `splash_health_delta * self_health_delta_multiplier`, so the Heal Grenade
##   Launcher (which heals its shooter) is no longer blocked point-blank.
##   Special-weapon layer: `_refresh_weapon_specialty()` classifies a weapon
##   from its SIGNAL fire + the SHOOT projectile's signal handler:
##   `simple_projectile.gd` -> EXPLODE (mines / remote grenades); a projectile
##   declaring `_initial_speed` -> REDIRECT (arrows / redirectable rockets);
##   anything else -> OTHER and the signal is left alone.  Trigger arms the
##   sequence after the shot: EXPLODE waits the skill-scaled arm delay (1-2 s)
##   AND the target being near one of this bot's live projectiles, then signals;
##   REDIRECT waits 0.1-0.35 s and signals while aimed.  Verified headlessly:
##   Mine Layer -> EXPLODE (signal ~0.9-1.05 s), Redirectable Rocket Launcher ->
##   REDIRECT (signal ~0.11 s), AK/Pistol -> NONE.
##   NOTE: the Bow is deliberately charged-only (one SHOOT fire, no SIGNAL), so
##   it is classified CHARGED and never presses alt-fire.  Redirect support is
##   exercised by the Redirectable Rocket Launcher.  The classifier is the
##   in-file equivalent of a `Weapon.get_ai_fire_profile()` helper; it can be
##   moved verbatim if desired.
##   Follow-up fixes: the charged release threshold is clamped to 1.0 — at
##   skill 1 a 1.001 threshold could never be reached because
##   `get_charge_ratio_for()` clamps at 1.0, so the bow held its draw forever.
##   Aim points: grenades/molotovs/poison jars pass through world geometry
##   (`explodes_on_world == false`) and now aim at the target's MID-BODY; only
##   projectiles that explode on world contact (rockets, heal grenade) aim at
##   the feet.  Sticky signal mines aim at mid-body.  A self-damaging explosive
##   is used point-blank while the bot is healthy; when the blast would leave it
##   at/below the survival flee threshold, it switches to the first safe sidearm
##   instead of standing still aiming at the ground.
##   Verified headlessly: bow charge reaches 1.0 and releases (cooldown starts).
##   Medic: the Heal Grenade Launcher is now classified as heal-like because its
##   blast heals allies (`team_heal = splash x team multiplier > 0`) even though
##   its hitbox does not.  A medic below MEDIC_SELF_HEAL_THRESHOLD uses a
##   self-healing weapon on its own feet first — the Heal Grenade Launcher's
##   positive self_damage, or a healthpack whose hitbox has can_hit_shooter —
##   and does not switch away from it while low.  MEDIC_HEAL_THRESHOLD is 0.9:
##   injured teammates are topped up before fighting, and the bot switches to a
##   heal weapon from ANY slot (it scans the whole loadout, not just the held
##   weapon).  Priority order is self-heal below 0.5, then teammate heal below
##   0.9, then combat.  With no teammate below 0.9 (or none nearby/visible) it
##   switches to a damage weapon and fights — medics are not pacifists.
##   Safe top-off: after SAFE_TOP_OFF_DELAY (3 s) with no visible enemy and none
##   within SAFE_TOP_OFF_RADIUS (30 m), the threshold becomes 1.0 and teammates
##   are healed all the way to full; in combat it stays 0.9.  _enemy_nearby is
##   refreshed on each target rescan and counts enemies through walls/FOV.
##   Verified headlessly: a 70%-HP SCI teammate made the medic switch from its
##   Pistol to the Heal Grenade Launcher, heal, then switch back.
## - Stage 2 (human input emulation): COMPLETE.
##   `Style` is drawn per spawn from skill + variance (strafe holds, pause rate,
##   jump/crouch rates, peek weights, reaction, mouse speed/accuracy/lag, click
##   tap/hz, key min-hold/flip-rate, vocabulary gates, aim jitter).  Same-skill
##   bots therefore differ.
##   `Keyboard` is the ONLY writer of `input_dir` / `jump_input` / `crouch` /
##   `dash_input`.  Values are -1/0/1 keys, never analog; keys are held for a
##   per-bot 60-120 ms minimum and direction flips are capped at 6-8/s.  A
##   zero->nonzero request starts a reaction delay.  Jump is a short tap with a
##   cooldown; counter_strafe taps the opposite key.  `keys_for_world_dir()` is
##   the rare world->8-way adapter (navigation/stuck); combat and heal movement
##   are built in the local frame and never round-trip through world space, so
##   the old world/local mismatch (Known Issue D) is gone.
##   `Mouse` is the ONLY writer of facing, through `Body._apply_mouse_look`
##   (the real look path, including the pitch clamp).  Requests carry priorities
##   COMBAT > REACT_DAMAGE > TRAVEL_LOOKAHEAD > SCAN and a TTL.  A new stimulus
##   waits a skill-scaled reaction, then a Fitts-like bell-shaped flick (duration
##   grows with log distance; landing error scales with 1-accuracy), followed by
##   1-3 corrective submovements (3 at low skill, 1 at high), then second-order
##   pursuit tracking with skill-scaled lag and jitter.  Vertical moves are
##   slower/less accurate.  Integer mouse counts carry a residual.  Idle holds
##   yaw and settles pitch to eye level with a small drift; travel looks along
##   movement.  `current_aim_error_to()` exposes the real head-ray error.
##   `Buttons` is the single reload/switch helper: human reaction delay, then
##   `start_reload()` / `current_weapon_index` (the real equip state machine).
##   `ManeuverRunner` executes `ManeuverStep` timelines with randomized
##   durations, priority preemption, and abort on new target/damage/stun.
##   `_weighted_choice()` supplies repeat-penalised, per-bot-biased entropy.
##   Verified headlessly with two fighting bots: every sampled `input_dir`
##   component was exactly -1/0/1; keys moved between W/A/S/D; mouse modes showed
##   idle/track/flick/corr; both fired and damaged each other; aim error settled
##   sub-degree.  The in-game overlay now shows key states + mouse delta; a
##   manual visual check of flick feel remains.
##
## - Stage 3 (human traversal): IMPLEMENTED; cross-floor route validation is
##   still manual (see the verification note at the end of this block).
##   All non-combat movement (objective, last-seen pursuit, wander, heal
##   approach) now goes through `Traversal.move_to(goal, urgency, arrival,
##   caution)`.  It holds W and steers with the mouse via TRAVEL_LOOKAHEAD, uses
##   short A/D taps for cross-track correction, and never emits analog input or
##   rotates the body itself.
##   Local perception (20 Hz) uses knee/chest/full-height rays, a forward capsule
##   cast, a ledge probe, and side probes only when forward is blocked.  It emits
##   discrete actions: continue, tap left/right, jump, crouch, stop, back up,
##   re-route.  Counters are shown as `rays/s` in the overlay.
##   `TravelGraph` is a shared, static, time-sliced AStar3D cache keyed by Map
##   instance id.  Bake: recursive visual/collision AABB scan, 2.5 m columns,
##   repeated downward casts for stacked floors, capsule headroom (stand vs
##   crouch), dynamic-body RID exclusion.  Edges are typed WALK / JUMP / CROUCH /
##   DROP / STAIRS; ramps are detected by sampling the surface, staircases by
##   intermediate surfaces.  Node lookup is vertical-first; AStar3D supplies the
##   path and temporary point weights provide flat-route preference, recent-route
##   penalties and per-bot goal bias.  Bake cost is capped at 1.5 ms/frame.
##   Stuck recovery escalates: jump -> open-side strafe -> back up + re-aim ->
##   graph re-route with blocked/recent positions penalized -> turn around.
##   Positions are remembered for 10 s; no body rotation is ever written.
##   Verified headlessly on `castle`: graph baked ~1600 nodes / ~10k edges in
##   ~2-3 s with no frame errors; bots held long W with short A/D taps, followed
##   graph paths when direct line failed, and did not leave the playable floor.
##   Cross-floor route validation is still manual; the tested maps' extreme nodes
##   sit in separate decorative/roof islands, so a low-to-high query there is not
##   a fair staircase test.
##
## - Stage 4 (decision / combat movement / search / damage): COMPLETE.
##   `Decision` owns TRAVEL / SEARCH / COMBAT / HEAL / RELOAD_SAFE /
##   RETREAT_COVER / STUCK_RECOVER / FLEE.  It considers at 4 Hz, every state
##   has a minimum duration, and new targets, damage, and traversal recovery use
##   interrupts.  `_act()` is now a dispatch through it.
##   Target selection scores angle-to-crosshair, distance, visible time, recent
##   damage source, low-health bonus and stickiness, with a switch margin and a
##   switch re-aim cost.  New detections need a recognition time scaled by
##   distance/FOV edge/skill; the current target can be tracked outside the cone.
##   Combat movement is event-driven: damage and shot counts force strafe
##   changes, counter-strafing is still used, pauses are rare/short, range
##   keeping uses a wide soft band with approach angle, close range circles, and
##   jump/crouch are probabilistic and suppressed for precision/tight aim.
##   Cover (`ENABLE_COVER`) searches nearby ray-verified LOS breaks, moves there,
##   waits, peeks/fires, ducks back, and times out/falls back after a
##   survival-scaled hold (6-14 s) or when no cover exists.
##   SEARCH goes to the last-seen point, extends along remembered velocity, then
##   sweeps a ring of ray-verified standing positions around that point; its
##   duration and sweep size scale with `aggression`.  Damage awareness records
##   the source, estimated direction, forces a strafe change, turns with a
##   skill-scaled REACT_DAMAGE look, and can enter SEARCH, RETREAT_COVER or FLEE.
##   Objective travel gets a light per-bot `aggression`/`flank_bias` offset.
##   Verified headlessly on `castle` with SPI vs SCI bots: damage caused a cover
##   state and a healer state, target-loss produced SEARCH, and combat/search/
##   heal/stuck states alternated without runtime errors.  Debug overlay shows
##   `decide:` alongside travel.
##
## - Stage 5 (arsenal / reload / fire modes / explosion jump): COMPLETE.
##   `_get_weapon_profile()` caches one profile per weapon resource: verified
##   hitscan/falloff/projectile ranges, ideal band, melee, explosive, heal roles,
##   charged/automatic, cooldown, DPS proxy, mag/reload/switch times, infinite
##   ammo.  `_get_proj_info` remains the only projectile scene instantiation.
##   Weapon choice scores every ready weapon at the target distance against the
##   profile (falloff effective range, melee only inside real reach, explosive
##   self-splash, heal penalties, DPS, switch cost), re-evaluates on a 0.5 s
##   timer plus new-target/empty-mag/distance-band events, and requires a score
##   margin.  `Buttons` now adds a 0.2-0.5 s human switch decision delay; the
##   switch guard is derived from put-away + pullout, not a fixed 1.0 s.
##   Reload policy is tactical: threshold rises with skill, only when safe or the
##   target is far/out of LOS/covered; trigger released first; ready sidearms are
##   preferred under pressure; melee only inside its verified reach.
##   Fire-mode scoring now uses each mode's effective/ideal range and falloff
##   band, with melee/automatic/shotgun/burst role bonuses.
##   Medic switching has persistence/absence hysteresis (1.0 s / 1.5 s) and never
##   fires a heal-only weapon at an enemy while waiting.
##   Explosion jump is now aim -> fire -> jump: phase 1 requests the ground look
##   and waits for <=5 deg error, phase 2 fires through Trigger and waits ~0.08 s
##   before pressing jump.  Visible enemies, heal targets, stuns, weapon changes,
##   low health with self-damage, or timeout abort and release everything.
##   Verified headlessly on `castle` with forced Knife/Pistol and Rocket/Pistol
##   loadouts: Knife profile reports 2.0 m, far targets switch to Pistol, close
##   targets switch to Knife, and switches respect the decision/equip delay.  A
##   live explosion-jump launch and reload-policy check remain manual.
##
## - Stage 6 (aim feel / lead / skill traits / weapon preference): COMPLETE.
##   `SKILL_TRAIT_TABLE` maps skill 0 / 0.5 / 1 to reaction, tracking_speed,
##   accuracy, aggression, lead_quality, movement_quality, awareness and
##   survival; `Style`
##   applies per-bot variance from a seed drawn ONCE per bot (`random_seed`, 0 =
##   draw one now).  It is deliberately not re-rolled by the skill slider or a
##   respawn, so a bot keeps its personality while the general Skill dial moves.
##   Aim noise is continuous (two low sines + micro tremor) and widens with
##   target speed; flicks/corrections/tracking read the accuracy and
##   tracking_speed traits.  Low accuracy aims centre mass, high accuracy takes
##   the head bone only when visible.  Target velocity is sampled at the 20 Hz
##   think rate, smoothed over 0.18 s, and reversal-damped.  Projectiles use a
##   quadratic intercept (gravity 0) or a 4-iteration low-arc ballistic solve,
##   with high arc as fallback; the chosen arc is validated with world rays only
##   when the bot is about to fire.  Unreadable projectile speeds are measured
##   from two physics-frame samples and cached statically.  Recoil compensation
##   is scaled by accuracy and controlled by `RECOIL_COMP_SIGN`.
##   Slot 0 (primary) gets a large preference bonus while viable at the range;
##   `_primary_viable_at` reads the authored falloff curve, so a sniper at knife
##   range loses the bonus (knife/sidearm wins) but a grenade launcher keeps it
##   instead of being abandoned for a higher nominal-DPS pistol.  Projectile DPS
##   now reads the spawned scene's hitbox/splash damage (a grenade no longer
##   looks like 10 damage), and the explosive self-splash penalty uses the real
##   splash radius instead of 45% of the ideal range, so secondary explosives are
##   scored fairly too.  Self-splash is only penalised/avoided when
##   `_accept_self_damage` says the blast would put the bot at/below the survival
##   flee threshold; a healthy bot takes the damage and keeps the explosive.
##   Explosion jump now requires `explodes_on_world`; grenade/molotov/poison-jar
##   arcs can no longer be used as a "rocket jump".
##   Dev-menu integration: `set_bot_skill`, `set_bot_trait`, `clear_bot_traits`,
##   `set_bot_trait_overrides` and `randomize_bot_skill` are the runtime skill
##   API used by the Bots list (`world/spawn_bot_menu.gd`).  General skill is
##   forced to 1.0 for every newly spawned bot (`SpawnManager.DEFAULT_BOT_SKILL`);
##   the Randomize button is the only thing that rolls it.  Manual bots persist
##   team/skill/overrides through `GameManager.lobby_bots`; auto-fill bots do not.
##   Verified headlessly: traits interpolate correctly at skill 0/0.5/1;
##   grenade (27 m/s, g=9.8, t=0.22/0.56/1.13 s at 6/15/30 m) and rocket
##   (20 m/s, g=0, straight-line t=1.00 s at 20 m) solve as expected; low
##   accuracy chooses centre, high accuracy chooses the visible head bone;
##   grenade-primary kept its slot against a pistol at 6/12/25 m while a
##   sniper@8 m lost to the pistol and sniper@2 m lost to the knife; live
##   grenade-vs-pistol bots acquired, aimed and damaged each other with no
##   script errors.  Heal projectiles use `_predict_aim_point()` (the launch
##   direction), never the impact point: at 15 m a syringe solution aimed
##   2.34 m above the impact point and a live healer restored an ally from
##   63 to 125 HP.  Visual flick/drift feel and a real wall-blocked arc still
##   need manual checks.
##
## - Stage 7 (self-preservation / threat assessment / hunt): IMPLEMENTED.
##   `survival` (0.25 / 0.55 / 0.85 by skill) reads a 2.5 s leaky damage bucket,
##   the nearby-enemy count, distance to the threat, and whether the current
##   target is much weaker, producing a 0..1 `_threat_pressure()`.  That drives
##   two thresholds: RETREAT_COVER (26-50 % HP + pressure) and a new FLEE state
##   (14-30 % HP + pressure).  FLEE is movement-only: it picks a ray-verified
##   spot that breaks the threat's LOS or simply gains distance, never peeks or
##   fires, and is entered instead of fighting when cover search fails.  Its
##   cooldown hands control to self-heal/cover so it cannot ping-pong.  A visible
##   enemy inside FLEE_FIGHT_BACK_RANGE turns the decision into COVER/COMBAT
##   instead: do not run with the trigger released at knife range.
##   Cover waits/peeks and its total hold scale with survival; a bot at the flee
##   threshold hunkers instead of peeking.  If the target is visible at any
##   point in the wait phase, the bot returns fire rather than staring over the
##   wall — cover only helps while it actually blocks the shot.
##   SEARCH is now an aggression-scaled hunt: 3.5-15 s, lead extension 6-14 m,
##   then a 2-8 point ring around the last-known spot (floor + headroom only;
##   deliberately no LOS requirement, so the far side of the pillar is included)
##   with a short dwell and a look back at the origin.  Search points are built
##   once per hunt on state entry, reuse `_steer_query`/`_los_query`, and are
##   abandoned after a per-point timeout.
##   All of this is server-local like the rest of the AI; nothing new is
##   replicated.  The debug overlay shows `surv:` and `hunt:` lines.
##
## - Stage 8 (navmesh traversal): IMPLEMENTED.
##   Locomotion prefers the map's baked `NavigationRegion3D`, queried through
##   `NavRoutes`/`NavigationServer3D` inside `Traversal`: travel, objective,
##   search, flee, cover and long-range chase approach.  A full navmesh route
##   wins; the runtime `TravelGraph` is the fallback for maps without a baked
##   region and for unreachable routes (its 1.5 ms/frame bake does not run
##   while the navmesh succeeds); direct raycast steering is last.  A nav path
##   ending short of the goal is followed only to the closest reachable point,
##   so hunt/cover points across a gap no longer push a wall.  Stairs connect
##   because `AGENT_MAX_CLIMB` is 0.5 m and the knee probe still jumps each
##   riser.  Crouch-only and jump-gap routes are not in the mesh.  Combat
##   inside `COMBAT_CHASE_EXIT` is still local strafe/peek; beyond
##   `COMBAT_CHASE_ENTER` (or 2 m vertically) it hands locomotion to Traversal
##   while continuing to aim/fire.  Navmesh queries are server-only and write
##   only the existing rollback input fields — never position/velocity or
##   `_rollback_tick`.
##
## - Stage 9 (hearing-driven search): IMPLEMENTED.
##   An enemy sound now starts a SEARCH at the sound position instead of only a
##   GLANCE.  `_on_sound_made` resolves the emitter (`GameManager.find_player`),
##   ignores self/teammates/despawned/dev-hidden sources, and skips a restart if
##   the bot is already hunting within `HEARING_NEAREST_MARGIN` of that sound.
##   The approach/search timers are extended by `dist / WALK_SPEED`, so a 35 m
##   gunshot is actually reachable.  A bot already in COMBAT/HEAL/COVER/RELOAD/
##   FLEE keeps that priority.  Also fixed in this pass: MAIN_MENU/DEATHMATCH
##   wander no longer heads to `Vector3.ZERO` (the target is picked on spawn);
##   long-range chase steers the waypoint in world space so the COMBAT look
##   cannot bend W off the route; a chase stuck on a navmesh partial route gives
##   up after `COMBAT_CHASE_STALL_TIME`; and target-loss no longer force-enters
##   SEARCH over HEAL/COVER/FLEE.
##
## OPEN QUESTIONS / HAZARDS FOR LATER STAGES
## - `_get_proj_info().heals_allies` is accurate (positive `health_delta` +
##   `can_hit_other_teamates`): Syringe Gun and Medpack Launcher only.
## - Projectile lead uses a full 3D intercept/ballistic solve, but the actual
##   launch inherits the shooter's forward velocity (`forward_boost` in
##   WeaponController._spawn_projectile); the solver ignores that boost, so a
##   fast-moving shooter can slightly over-lead.
## - The `_get_engagement_range` probes are dead (no range property).  Real
##   numbers must come from `hitscan_range` (hitscan) or projectile speed x
##   lifetime / engagement preference (projectile).
## - Projectile DPS is a single-target proxy: it uses `max(impact, splash)` from
##   the spawned scene and does not value hitting multiple enemies with one
##   blast.  A future scoring pass should treat splash area/count separately.
## - Bots never cast abilities, and `AbilityManager.is_equipped()` is false for
##   them; only input-driven movement tech (dash/jump) is currently usable.
## ============================================================================

## Server-only bot AI.  Locomotion prefers the map's baked NavigationRegion3D
## (synchronous NavigationServer3D queries inside `Traversal`).  Maps without a
## baked region, and routes the navmesh cannot reach, fall back to the runtime
## `TravelGraph`, then to direct raycast steering.  Facing is requested through
## `Mouse`; movement only writes the rollback input fields, so clients replay it
## normally.  Also seeks objectives (control points, payload) when no enemy is
## visible.
##
## Target priority:
##   1. Heal an injured teammate when holding a heal weapon (or when a teammate
##      is critically hurt and a heal weapon is available in the loadout).
##   2. Engage the nearest visible enemy.
##   3. Pursue the last-seen enemy position.
##   4. Seek the objective or wander.

@export var player: Player

## 0.0 = completely useless (huge aim spread, no projectile lead, no recoil
## compensation, sluggish tracking, slow to react to a freshly spotted enemy).
## 1.0 = aimbotter (zero spread, full projectile lead, perfect recoil
## compensation, instant tracking and reactions).
@export_range(0.0, 1.0) var skill: float = 1.0

## Optional deterministic trait roll.  0 draws one seed for this bot and keeps
## it for its lifetime (so moving the skill slider does not re-roll its
## personality); any other value reproduces the same per-bot variance.
@export var random_seed: int = 0

## The editable traits exposed by the dev menu's expandable Advanced panel.  Keys are
## Style field names so the menu can read/write them without a parallel table.
const BOT_TRAIT_KEYS: Array[String] = [
	"reaction_time", "tracking_speed", "accuracy", "aggression",
	"lead_quality", "movement_quality", "awareness", "survival",
]

## Draws a live state label above this bot (action, target, fire mode, trigger
## flags, aim error, weapon/ammo), the steering rays it just cast, and its
## remaining travel route (green navmesh, orange partial, blue TravelGraph, red
## direct).  Server side only, like the rest of the AI.  The dev menu's "Show
## nav paths" turns on just the route lines for every bot without the label or
## rays.  With both off this creates no nodes and does no per-frame work.
@export var debug_draw: bool = false:
	set(value):
		debug_draw = value
		if not value:
			_hide_debug_nodes()

## Prints one line of weapon/projectile introspection the first time this bot
## uses a weapon resource.  Independent of [member debug_draw] so the log can be
## collected in a headless run without rendering the overlay.  Shared across
## bots (static), so N bots on the same weapon log once.
@export var debug_log_weapons: bool = false

## Cached head node.  This is the bot's OWN aim origin + pitch node — the camera
## head (`%Head` = Body/Recoil/Head), NOT the physical head bone.  The Mouse
## emulator drives it through `Body._apply_mouse_look`, so pitch rotates the
## camera/weapon ray, not a ragdoll bone.  (The *target's* head bone is resolved
## separately in `_get_head_position()`.)
@onready var _head_node: Node3D = player.get_node("%Head") as Node3D

## Reused raycast queries — avoids allocating a fresh PhysicsRayQueryParameters3D
## for every ray (thousands/sec when many bots are fighting).
var _steer_query: PhysicsRayQueryParameters3D
var _los_query: PhysicsRayQueryParameters3D
## World-only ray used by shot-arc validation.  Separate from LOS/steer so a
## validation pass cannot disturb a perception query mid-flight.
var _shot_query: PhysicsRayQueryParameters3D

## Cache of projectile-scene introspection: resource_path -> {
##   "speed": float, "speed_source": String, "gravity": float,
##   "heals_allies": bool, "is_explosive": bool }.  `speed_source` names the
##   property the value came from, for the one-shot introspection log.
## Avoids instantiating a projectile every think just to read its HitboxComponent.
var _proj_cache: Dictionary = {}
## Speeds actually observed in flight, keyed by projectile scene path.  Shared
## across every bot: a projectile only has to be measured once per scene.
static var _learned_proj_speeds: Dictionary = {}
static var _proj_speed_measurements: Dictionary = {}
## Shot-arc validation throttle.  Only armed when the bot is otherwise ready to
## fire; it never runs every physics tick.
var _arc_validation_timer: float = 0.0
var _arc_validation_blocked: bool = false
var _arc_validation_high: bool = false
## Stable style roll + explicit dev-menu overrides.  The seed is chosen once,
## so dragging the skill slider redraws the derived stats without changing the
## bot's random variance.  Overrides survive respawns until cleared.
var _style_seed: int = 0
var _trait_overrides: Dictionary = {}


func _ready() -> void:
	# Stagger each bot's think phase so N bots don't all cast their steering and
	# line-of-sight raycasts on the same physics frame (spikes the frame time).
	_timer = randf_range(0.0, PROCESS_INTERVAL)

	_steer_query = PhysicsRayQueryParameters3D.new()
	_steer_query.exclude = [player.get_rid()]
	_steer_query.collision_mask = 1 << 0
	_steer_query.collide_with_bodies = true
	_steer_query.collide_with_areas = false

	_los_query = PhysicsRayQueryParameters3D.new()
	_los_query.exclude = [player.get_rid()]
	_los_query.collision_mask = 1 << 0
	_los_query.collide_with_bodies = true
	_los_query.collide_with_areas = false

	_shot_query = PhysicsRayQueryParameters3D.new()
	_shot_query.exclude = [player.get_rid()]
	_shot_query.collision_mask = 1 << 0
	_shot_query.collide_with_bodies = true
	_shot_query.collide_with_areas = false

	_fov_dot_threshold = cos(deg_to_rad(FOV_DEGREES * 0.5))
	_recall_fov_dot_threshold = cos(deg_to_rad(TARGET_RECALL_FOV_DEGREES * 0.5))

	_style_seed = random_seed if random_seed != 0 else randi()
	_style = Style.new()
	_style.draw(skill, _style_seed)
	_apply_trait_overrides()
	if player.is_bot:
		add_to_group("bot_controllers")
	_keyboard = Keyboard.new(self)
	_mouse = Mouse.new(self)
	_buttons = Buttons.new(self)
	_maneuvers = ManeuverRunner.new(self)
	_traversal = Traversal.new(self)
	_decision = Decision.new(self)
	_trigger = Trigger.new(self)
	if player.is_bot and not GameManager.sound_made.is_connected(_on_sound_made):
		GameManager.sound_made.connect(_on_sound_made)
	# Runtime speed measurement is a fallback for projectile scenes whose authored
	# launch speed is not readable statically (Stage 0 says all current scenes are,
	# but custom scenes need not be).  Server-only, shared cache.
	if player.is_bot and multiplayer.is_server() \
			and not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	_los_exclude_rids.clear()
	_los_exclude_rids.append(player.get_rid())
	_los_query.exclude = _los_exclude_rids
	_shot_query.exclude = _los_exclude_rids


func _exit_tree() -> void:
	if get_tree() != null and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


# ── Dev-menu skill editing (server-local; bots only simulate on peer 1) ──

## Set the master skill and redraw the derived style immediately.  The stable
## per-bot seed keeps the random variance from changing while the slider moves.
func set_bot_skill(value: float) -> void:
	skill = clampf(value, 0.0, 1.0)
	if _style != null:
		_style.draw(skill, _style_seed)
		_apply_trait_overrides()


## Current value of one editable trait, in its native unit (seconds for
## reaction_time, 0..1 for the rest).
func get_bot_trait(key: String) -> float:
	if _style == null or not BOT_TRAIT_KEYS.has(key):
		return 0.0
	return float(_style.get(key))


## Override one trait independently of the master skill.  The override is
## reapplied on every master-skill redraw and survives respawns.
func set_bot_trait(key: String, value: float) -> void:
	if _style == null or not BOT_TRAIT_KEYS.has(key):
		return
	var lo := KEY_REACTION_MIN if key == "reaction_time" else 0.0
	var hi := KEY_REACTION_MAX if key == "reaction_time" else 1.0
	var clamped := clampf(value, lo, hi)
	_trait_overrides[key] = clamped
	_apply_trait_override(key, clamped)


func clear_bot_traits() -> void:
	_trait_overrides.clear()
	if _style != null:
		_style.draw(skill, _style_seed)


func has_bot_trait_override(key: String) -> bool:
	return _trait_overrides.has(key)


func get_bot_trait_overrides() -> Dictionary:
	return _trait_overrides.duplicate()


func set_bot_trait_overrides(overrides: Dictionary) -> void:
	_trait_overrides.clear()
	for key in overrides.keys():
		if BOT_TRAIT_KEYS.has(str(key)):
			_trait_overrides[str(key)] = float(overrides[key])
	if _style != null:
		_style.draw(skill, _style_seed)
		_apply_trait_overrides()


## Dev-menu "Randomize bot skills": new master skill, new variance roll, and no
## stale overrides from the previous personality.
func randomize_bot_skill() -> void:
	skill = randf()
	_style_seed = randi()
	_trait_overrides.clear()
	if _style != null:
		_style.draw(skill, _style_seed)


func _apply_trait_overrides() -> void:
	for key in _trait_overrides.keys():
		_apply_trait_override(str(key), float(_trait_overrides[key]))


func _apply_trait_override(key: String, value: float) -> void:
	if _style == null:
		return
	_style.apply_trait(key, value)

# Tuning constants

const SHOOT_RANGE: float          = 100.0
const HEAL_RANGE: float           = 60.0
const WANDER_RANGE: float         = 15.0
const CLOSE_ENOUGH: float         = 5.0
const PROCESS_INTERVAL: float     = 0.05
## How often the bot does a full re-scan for a new target.  Between scans it only
## re-verifies its current target's line-of-sight (1 raycast instead of N).
const RETARGET_INTERVAL: float    = 0.25
## A teammate below this HP fraction makes the bot switch to a heal weapon —
## and is the only kind of teammate it will heal while already holding one.
## 0.9 means "top people up unless they are nearly full": a medic that only
## reacts below 50% ignores a teammate who is merely injured, which is what
## prompted this value.  Self-heal below still uses its own threshold.
const MEDIC_HEAL_THRESHOLD: float = 0.9
## Below this HP fraction a medic with a self-healing weapon fires it at its own
## feet before healing anyone else or fighting.  Kept separate from the teammate
## threshold so the two can be tuned independently.
const MEDIC_SELF_HEAL_THRESHOLD: float = 0.5
## Safe top-off: after this many seconds with no enemy visible and none within
## SAFE_TOP_OFF_RADIUS, medics heal teammates all the way to 100% instead of
## stopping at MEDIC_HEAL_THRESHOLD (0.9).  In combat the 90% cap stays, so a
## medic never ignores a fight just to top someone off.
const SAFE_TOP_OFF_DELAY: float = 3.0
## Any living enemy inside this radius counts as "around" even through walls.
const SAFE_TOP_OFF_RADIUS: float = 30.0

# Objective intent model.  A control point's capture volume is a TrenchBroom
# trigger brush, so there is no authored radius to read; this is the bot-side
# "close enough to touch the objective" radius.  The leash is how far a bot may
# chase a target away from the objective before it returns to the point.
const OBJECTIVE_HOLD_RADIUS: float = 3.0
const OBJECTIVE_LEASH_RADIUS: float = 12.0
## "An objective is nearby" for persistent hearing: within this radius the
## objective outranks an old sound and the endless heard-memory search ends.
const OBJECTIVE_NEARBY_RADIUS: float = 20.0
## Stand this far inside the payload's real push radius so a "hold" actually
## pushes the cart instead of parking just outside it.
const OBJECTIVE_PAYLOAD_RADIUS_INSET: float = 0.75
## Bots detect enemies within the same horizontal cone a human camera renders.
## `player.tscn` sets `Camera3D.fov = 90`, so the bot FOV is 90° too.
const FOV_DEGREES: float = 90.0
## Human mouse model (Stage 2).  The old exponential aim smoothing is gone;
## these describe a ballistic flick plus a pursuit tracker, both scaled by the
## per-bot Style drawn at spawn.
const LOOK_FLICK_START_DEG: float = 6.0
const LOOK_CORRECTION_DEG: float = 1.2
const LOOK_FLICK_BASE_TIME: float = 0.06
const LOOK_FLICK_LOG_TIME: float = 0.045
const LOOK_FLICK_MIN_TIME: float = 0.07
const LOOK_FLICK_MAX_TIME: float = 0.32
const LOOK_TRACK_GAIN: float = 7.0
const LOOK_TRACK_ACCEL: float = 60.0
const LOOK_TRACK_MAX_SPEED: float = 14.0
## How long a look request survives without being refreshed by the 20 Hz think
## tick.  A lost target keeps the old aim for a fraction of a second, like a
## human who has not yet reacted to the target disappearing.
const LOOK_REQUEST_TTL: float = 0.30
## Idle pitch drift (radians).  The crosshair rests near eye level; this is the
## small breathing motion around it, never a snap to the floor or sky.
const LOOK_IDLE_DRIFT: float = 0.012
## Head pitch limit, matching Body._apply_mouse_look's clamp.  Kept here so the
## request never aims beyond what the real look path can actually reach.
const LOOK_PITCH_LIMIT: float = PI * 0.5 - 0.001
## Optional mouse-count quantisation.  One count is one physical mouse step;
## the residual is carried to the next tick so slow tracking still moves.
const MOUSE_COUNT_STEP: float = 1.0

## Keyboard human limits.  A key must stay down long enough to be registered by
## the rollback tick (Stage 0: >= 2 ticks = 22.2 ms; 60 ms is a safe floor), and
## direction changes are rate-limited to a fast human's A/D cadence.
const KEY_MIN_HOLD_MIN: float = 0.06
const KEY_MIN_HOLD_MAX: float = 0.12
const KEY_FLIP_RATE_MIN: float = 6.0
const KEY_FLIP_RATE_MAX: float = 8.0
const KEY_REACTION_MIN: float = 0.04
## Skill 0 is deliberately allowed to be slow here; the trait table gives it a
## 0.38 s reaction, which must not be silently clamped back to a 0.25 s floor.
const KEY_REACTION_MAX: float = 0.45
## Verified Stage 0: input_dir is CAMERA-relative.  The camera's yaw follows the
## body yaw horizontally, so camera-local keys are body-local keys for WASD.
## If the camera ever decouples from the body, flip this and route every
## set_move through keys_for_world_dir.
const INPUT_DIR_IS_BODY_LOCAL: bool = true

## Human click timing.  A semi-auto press is a real click, not a one-frame flag;
## the click rate cap is the fastest a human can mash at high skill.
const FIRE_TAP_MIN: float = 0.04
const FIRE_TAP_MAX: float = 0.10
const FIRE_CLICK_HZ_MIN: float = 6.0
const FIRE_CLICK_HZ_MAX: float = 9.0

## Reload / weapon-switch reaction before the action is committed.  The equip
## time itself is still the WeaponController's real switch state machine.
const RELOAD_REACTION_MIN: float = 0.06
const RELOAD_REACTION_MAX: float = 0.25
## Weapon choice includes a human decision delay before the equip starts.
const SWITCH_REACTION_MIN: float = 0.20
const SWITCH_REACTION_MAX: float = 0.50

# Arsenal (Stage 5)
const WEAPON_CHOICE_INTERVAL: float = 0.5
const WEAPON_SWITCH_MARGIN: float = 22.0
const WEAPON_MELEE_ONLY_MARGIN: float = 0.5
const WEAPON_RELOAD_RATIO_MIN: float = 0.30
const WEAPON_RELOAD_RATIO_MAX: float = 0.58
const MEDIC_HEAL_PERSIST: float = 1.0
const MEDIC_HEAL_ABSENT: float = 1.5
const EXPLOSION_JUMP_AIM_TIMEOUT: float = 1.0
const EXPLOSION_JUMP_FIRE_WAIT: float = 0.08
## Preferred slot 0 must be genuinely useful at the current distance to keep its
## bonus.  A sniper's close-range falloff value is ~0.095, so it drops out and a
## sidearm/knife wins; a grenade launcher (no falloff) keeps the bonus and is not
## abandoned for a higher-DPS pistol.
const PRIMARY_WEAPON_PREFERENCE: float = 95.0
const PRIMARY_MIN_DAMAGE_MULT: float = 0.35
const MELEE_USELESS_PRIMARY_BONUS: float = 45.0

# Stage 6 — skill traits, aim feel, lead, recoil.
#
# ONE TABLE, interpolated at the bot's skill.  Every skill-scaled decision reads
# a trait from here (with per-bot variance) rather than raw `skill`, so tuning
# the whole difficulty curve means editing these three rows only.
##   reaction          seconds before reacting (lower is better)
##   tracking_speed    0..1 pursuit gain (higher is better)
##   accuracy          0..1 flick/aim-point/recoil/noise quality
##   aggression        0..1 target/approach flavour and hunt persistence
##   lead_quality      0..1 trust in the target-velocity estimate
##   movement_quality  0..1 strafe/jump/explosion-jump competence
##   awareness         0..1 recognition/hearing/scan quality
##   survival          0..1 self-preservation: earlier cover, longer flee
const SKILL_TRAIT_TABLE := [
	{
		"skill": 0.0, "reaction": 0.38, "tracking_speed": 0.25,
		"accuracy": 0.30, "aggression": 0.30, "lead_quality": 0.0,
		"movement_quality": 0.25, "awareness": 0.35, "survival": 0.25,
	},
	{
		"skill": 0.5, "reaction": 0.18, "tracking_speed": 0.62,
		"accuracy": 0.70, "aggression": 0.50, "lead_quality": 0.65,
		"movement_quality": 0.62, "awareness": 0.68, "survival": 0.55,
	},
	{
		"skill": 1.0, "reaction": 0.07, "tracking_speed": 0.98,
		"accuracy": 0.97, "aggression": 0.65, "lead_quality": 1.0,
		"movement_quality": 1.0, "awareness": 1.0, "survival": 0.85,
	},
]
## Continuous aim wander, in radians at zero accuracy.  Two low-frequency
## sines plus micro-jitter replace the old 0.4 s random step.
const AIM_DRIFT_BASE: float = 0.045
const AIM_MICRO_MAX: float = 0.008
const AIM_DRIFT_RATE_A_MIN: float = 0.22
const AIM_DRIFT_RATE_A_MAX: float = 0.48
const AIM_DRIFT_RATE_B_MIN: float = 0.7
const AIM_DRIFT_RATE_B_MAX: float = 1.25
const AIM_MICRO_RATE_MIN: float = 7.0
const AIM_MICRO_RATE_MAX: float = 12.0
## Moving targets widen the drift; this is the speed at which the factor doubles
## (roughly a strafing player at walk speed).
const AIM_TARGET_SPEED_REF: float = 6.0
## Above this accuracy a bot trusts the head bone when it is visible; below it,
## it aims at centre mass.  This is the main skill-0 vs skill-1 visual difference.
const AIM_HEAD_ACCURACY: float = 0.80
## Projectile lead.  The velocity estimate is smoothed over this window; a
## direction reversal damps the old estimate so a strafe does not overshoot.
const VELOCITY_ESTIMATE_SMOOTH: float = 0.18
const VELOCITY_REVERSAL_DAMP: float = 0.25
## Long enough for a slow rocket at the far edge of its engagement band, while
## still refusing physically absurd lofted arcs (a 27 m/s grenade high arc can
## take >5 s and would outlive its fuse).
const LEAD_TIME_MAX: float = 3.0
## Ballistic solve quality/validation.  The solver refines the target position
## 4x; validation samples the arc 6x and runs at most every 0.12 s per bot.
const BALLISTIC_ITERATIONS: int = 4
const ARC_VALIDATION_SAMPLES: int = 6
const ARC_VALIDATION_INTERVAL: float = 0.12
## Conservative muzzle speed until a projectile's speed has actually been
## measured at runtime (only used when the scene exposes no readable speed).
const PROJECTILE_FALLBACK_SPEED: float = 20.0

# Bot hearing.  The emitter supplies the radius; the bot only checks distance.
const HEARING_LOOK_TIME: float = 1.0
const HEARING_NEAREST_MARGIN: float = 2.0
## Path to the target's head bone — the `Physical Bone DEF-spine_006` hurtbox with
## `is_head = true` in player.tscn.  Bots aim at this bone's live world position
## rather than a fixed height, so headshots track the model's actual head.
const HEAD_BONE_PATH: String = "Body/Mannequin/mannequin/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-spine_006"
## Recoil compensation sign.  Shots add POSITIVE pitch/yaw to Body/Recoil
## (weapon_controller.gd:2163-2170), so the camera must counter-rotate by
## subtracting it.  Flip to -1.0 to prove the opposite in game.
const RECOIL_COMP_SIGN: float = 1.0

# Traversal (Stage 3).  The graph is baked at 2.5 m and time-sliced; these
# numbers come from the verified Player physics (capsule 0.4243 r, stand 2.0,
# crouch 1.3333, jump v=5 under g=9.8 -> 1.27 m high / ~3 m long).
const TRAVEL_GRID: float = 2.5
const TRAVEL_BOUNDS_MARGIN: float = 8.0
const TRAVEL_MAX_COLUMNS: int = 20000
const TRAVEL_MAX_FLOORS_PER_COLUMN: int = 8
const BAKE_BUDGET_USEC: int = 1500
const WALK_STEP_MAX: float = 0.4
const JUMP_STEP_MAX: float = 1.1
const DROP_MAX: float = 6.0
const NODE_LOOKUP_RADIUS: float = 1.5
const DIRECT_LINE_MAX_RISE: float = 1.0
const LOOKAHEAD_MIN: float = 3.0
const LOOKAHEAD_MAX: float = 6.0
const CROSS_TRACK_TAP: float = 0.55
const CORNER_SLOW_RADIUS: float = 1.5
const REPATH_INTERVAL: float = 0.55
const STUCK_TIME: float = 0.5
const STUCK_DISTANCE: float = 0.25
const STUCK_MEMORY: float = 10.0
const CAPSULE_RADIUS: float = 0.4243164
const STAND_HEIGHT: float = 2.0
const CROUCH_HEIGHT: float = 1.3333
const FLOOR_MAX_ANGLE_DEG: float = 45.0
const JUMP_VELOCITY: float = 5.0
const GRAVITY: float = 9.8
const WALK_SPEED: float = 3.0
## Horizontal distance covered while a running jump clears a riser.  Used both
## for explicit JUMP path edges and for approaching a low vertical ledge.
const JUMP_TAKEOFF: float = WALK_SPEED * (2.0 * JUMP_VELOCITY / GRAVITY) * 0.55
const PROBE_KNEE_HEIGHT: float = 0.45
const PROBE_CHEST_HEIGHT: float = 1.1
const PROBE_FULL_HEIGHT: float = 1.75
const LEDGE_PROBE_AHEAD: float = 1.5
const LEDGE_DROP_DANGER: float = 2.5
const SIDE_PROBE_DISTANCE: float = 2.5
const TRAVEL_ARRIVE_DEFAULT: float = 1.0
## Travel look points are floor positions; add eye height so the bot looks
## where it is going, not down at its own feet.
const TRAVEL_EYE_HEIGHT: float = 1.5

# Navmesh traversal (server-only).  The layer mask matches the NavigationRegion3D
# default; queries only choose Keyboard verbs, never position/velocity/rollback state.
const NAV_LAYERS: int = 1
const NAV_SYNC_FRAMES: int = 2
const NAV_START_SNAP_MAX: float = 2.0
## Generous: a freshly spawned bot can be a spawn-drop above the mesh.
const NAV_START_SNAP_Y: float = 3.0
const NAV_GOAL_SNAP_MAX: float = 2.0
const NAV_GOAL_SNAP_Y: float = 2.0
const NAV_ENDPOINT_TOL: float = 1.0
const NAV_PARTIAL_MIN_GAIN: float = 2.0
const NAV_FAILURE_RETRY_MS: int = 1200
const NAV_STUCK_RETRY_MS: int = 5000
const NAV_WALK_STEP: float = 0.15
const NAV_WANDER_ATTEMPTS: int = 8
const NAV_WANDER_MAX_Y: float = 8.0
## Goals closer than this stay on direct steering.  Above it a usable route is
## preferred even when the straight line is clear, so the navmesh (and the debug
## line) is the primary path source rather than an obstacle-only fallback.
const DIRECT_ROUTE_MIN: float = 2.5

# Steering — a reduced fan (7 rays instead of 11) keeps wall-following smooth
# while cutting the steering raycast cost by ~40%.  Still used by combat only;
# all non-combat travel goes through Traversal.
const STEER_DISTANCE: float       = 8.0
const STEER_ANGLES: Array[float]  = [-55, -35, -20, 0, 20, 35, 55]
const STEER_RAY_HEIGHT: float     = 0.5
const WALL_FOLLOW_DISTANCE: float = 3.0

# Look-request priorities.  Higher wins; a lower-priority request cannot steal
# the crosshair from a live higher-priority one.  GLANCE sits between travel and
# damage so an idle/travel bot can check a corridor without losing the path look.
enum LookPriority { SCAN, TRAVEL_LOOKAHEAD, GLANCE, REACT_DAMAGE, COMBAT }

# Decision state machine (Stage 4).  Cover is behind a switch so an unstable
# build can ship with it off without deleting the code.
const ENABLE_COVER: bool = true
const DECISION_INTERVAL: float = 0.25
## How long a lost target's identity/recognition is remembered.  Style-scaled
## inside `_target_memory_window()`.
const TARGET_MEMORY_MIN: float = 5.0
const TARGET_MEMORY_MAX: float = 8.0
## Short no-search grace after LOS loss: the bot holds its last-known angle
## instead of immediately snapping into a hunt, but the chase starts at once
## when it expires.
const TARGET_LOST_GRACE: float = 0.75
const RECOGNITION_TIME_MIN: float = 0.08
const RECOGNITION_TIME_MAX: float = 0.55
const TARGET_SWITCH_MARGIN: float = 0.35
const TARGET_STICKINESS: float = 0.85
## Extra score for a visible target inside the recall cone while its memory is
## still alive, so a reacquired runner beats a freshly noticed bystander.
const TARGET_RECALL_STICKINESS: float = 1.10
## A remembered target may be reacquired outside the normal 90° FOV.
const TARGET_RECALL_FOV_DEGREES: float = 140.0
## While a target is lost, any visible enemy this close (or the recent attacker)
## wins immediately; otherwise the bot commits to the chase.
const TARGET_RETARGET_CLOSE_RANGE: float = 12.0
const TARGET_EMERGENCY_RANGE: float = 5.0
const TARGET_SWITCH_COOLDOWN: float = 0.6
const TARGET_PROXIMITY_REF: float = 18.0
const TARGET_PROXIMITY_BONUS: float = 1.25
## Pursuit prediction: lead by at most this many seconds of frozen velocity and
## clamp the resulting lead distance.
const CHASE_PREDICT_MAX_TIME: float = 2.0
const CHASE_LEAD_MAX_DIST: float = 20.0
const COMBAT_STRAFE_SHOT_MIN: int = 3
const COMBAT_STRAFE_SHOT_MAX: int = 6
const COMBAT_JUMP_MIN_INTERVAL: float = 1.8
const COMBAT_CROUCH_MIN_INTERVAL: float = 3.0
## Engagement distance deadband and hysteresis.  Inside the band the bot holds
## range (strafe only) instead of orbiting a continuously normalized radial.
const COMBAT_RANGE_BAND_SCALE: float = 0.22
const COMBAT_RANGE_HYSTERESIS: float = 1.2
## Combat safety probes are cached; four directions every quarter second.
const COMBAT_PROBE_INTERVAL: float = 0.25
const COMBAT_STALL_TIME: float = 0.6
const COMBAT_STALL_DISTANCE: float = 0.2

# Stage 7 — self-preservation and the hunt.
#
# Retreat is driven by a threat assessment, not just raw HP: recent damage,
# enemy numbers, distance, and whether the bot is actually winning the trade.
# `survival` sets how early the bot acts on that reading.
enum RetreatNeed { NONE, COVER, FLEE }
const RETREAT_NEED_NAMES: Array[String] = ["none", "cover", "flee"]
## Damage pressure is a leaky fraction of max HP: it decays back to zero over
## this window, so one old hit cannot keep a healthy bot in cover.
const SURVIVAL_DAMAGE_WINDOW: float = 2.5
## Fraction of max HP in the window that saturates the damage-pressure term.
const SURVIVAL_DAMAGE_REF: float = 0.35
const SURVIVAL_PRESSURE_DAMAGE_WEIGHT: float = 0.5
const SURVIVAL_PRESSURE_NUMBERS_WEIGHT: float = 0.2
const SURVIVAL_PRESSURE_CLOSE_WEIGHT: float = 0.3
## Winning the trade removes this much pressure (0..1), so a bot finishes a
## nearly-dead enemy instead of backing off.
const SURVIVAL_WINNING_RELIEF: float = 0.6
const SURVIVAL_WINNING_REF: float = 0.45
const SURVIVAL_CLOSE_NEAR: float = 6.0
const SURVIVAL_CLOSE_FAR: float = 24.0
## How long a resolved enemy keeps counting as a threat for survival purposes.
## Deliberately shorter than the hunt: a 15 s search must not force cover.
const SURVIVAL_THREAT_MEMORY: float = 5.0
const COVER_HEALTH_MIN: float = 0.26
const COVER_HEALTH_MAX: float = 0.50
const COVER_PRESSURE_BONUS: float = 0.10
const FLEE_HEALTH_MIN: float = 0.14
const FLEE_HEALTH_MAX: float = 0.30
const FLEE_PRESSURE_BONUS: float = 0.06
## Do not turn your back on an enemy you can see this close: take cover (and
## return fire if still visible) or fight instead of FLEEing.
const FLEE_FIGHT_BACK_RANGE: float = 10.0
const COVER_NEAR_DISTANCES: Array[float] = [3.0, 5.0, 7.0]
const COVER_FAR_DISTANCES: Array[float] = [9.0, 12.0]
const COVER_FAR_MIN_SURVIVAL: float = 0.55
const COVER_TOTAL_TIME_MIN: float = 6.0
const COVER_TOTAL_TIME_MAX: float = 10.0
const COVER_ROUNDS_MAX: int = 3
const FLEE_TIME_MIN: float = 2.0
const FLEE_TIME_MAX: float = 5.0
const FLEE_COOLDOWN_MIN: float = 1.0
const FLEE_COOLDOWN_MAX: float = 2.5
const FLEE_BASE_DISTANCES: Array[float] = [8.0, 12.0, 16.0]
const FLEE_DISTANCE_SCALE_MIN: float = 0.7
const FLEE_DISTANCE_SCALE_MAX: float = 1.25
const FLEE_ARRIVE_RADIUS: float = 1.5
const FLEE_REPATH_INTERVAL: float = 1.5
const HUNT_DURATION_MIN: float = 3.5
const HUNT_DURATION_MAX: float = 15.0
## Directional fan radii used when the lost target's escape direction is known;
## the full ring uses the same radii.
const HUNT_SWEEP_RADII: Array[float] = [5.0, 10.0, 18.0]
const HUNT_FAN_ANGLES: Array[float] = [-55.0, -30.0, 0.0, 30.0, 55.0]
const HUNT_ANGLES: int = 8
## Brief checks while moving; only the terminal point gets a longer dwell.
const HUNT_DWELL_MIN: float = 0.35
const HUNT_DWELL_MAX: float = 0.9
const HUNT_ARRIVE_RADIUS: float = 1.5
const HUNT_ORIGIN_MOVE: float = 3.0
const HUNT_LEAD_MIN: float = 6.0
const HUNT_LEAD_MAX: float = 14.0
const HUNT_MIN_POINTS: int = 2
const HUNT_MAX_EXTRA_POINTS: int = 6
## Fallback per-point timeout.  The actual timeout is distance-scaled in
## `_act_search` (`HUNT_POINT_TIMEOUT_MIN/MAX`).
const HUNT_POINT_TIMEOUT: float = 3.5
const HUNT_POINT_TIMEOUT_MIN: float = 2.0
const HUNT_POINT_TIMEOUT_MAX: float = 8.0
const HUNT_PARTIAL_ABANDON: float = 0.5
## If the exact last-seen point cannot be reached this quickly, seed the sweep
## from where the bot is and clear what it can reach.
const HUNT_APPROACH_TIMEOUT: float = 4.0

# Strafing.  The actual hold time now comes from the per-bot Style; this is only
# the fallback used before a Style has been drawn.
const STRAFE_CHANGE_INTERVAL: float = 1.5

# Trigger — the only writer of the fire flags.  See class Trigger.
## Frames a semi-auto trigger stays down.  3 frames at 90 Hz = 33 ms, i.e. two
## full network ticks plus margin, so the press is guaranteed to be sampled by
## WeaponController and to produce a rising edge even under rollback.
const SEMI_PRESS_FRAMES: int = 3
## Extra human gap AFTER the weapon's real cooldown, in seconds.  A skill-1 bot
## clicks at the cooldown limit; a skill-0 bot is visibly slower and more
## variable.
const SEMI_GAP_MIN: float = 0.02
const SEMI_GAP_MAX: float = 0.35
## Delay between "the crosshair is on target" and pulling the trigger.  Separate
## from REACTION_TIME_MAX, which is about noticing a newly acquired target.
const TRIGGER_DELAY_MIN: float = 0.02
const TRIGGER_DELAY_MAX: float = 0.22
## A charged shot may leave below full draw at low skill, and may be held a
## little longer at full draw.
const CHARGE_RELEASE_MIN: float = 0.85
const CHARGE_OVERHOLD_MAX: float = 0.15

# Aim points for direct-fire projectiles.
## HEAD = head bone (hitscan, ordinary projectiles).
## CENTER = mid-body; required for projectiles that pass through world geometry
## and only detonate on a hurtbox (grenades, molotovs), and for stickies.
## FEET = ground; best for projectiles that explode on world contact (rockets),
## where a ground near-miss still splashes.
enum AimPoint { HEAD, CENTER, FEET }
## Mid-body height above the Player root (the root is at the feet).
const AIM_CENTER_HEIGHT: float = 1.0

# Aim gate
## Approximate radius of the target's hittable volume, in metres.  The player
## capsule radius is 0.424; hurtboxes spread a little wider than the capsule.
const AIM_TARGET_RADIUS: float = 0.65
const AIM_TOL_MIN_DEG: float = 1.5
const AIM_TOL_MAX_DEG: float = 12.0
## Low skill fires when roughly on target; high skill waits for tight alignment.
const AIM_SKILL_MULT_MIN: float = 0.65
const AIM_SKILL_MULT_MAX: float = 1.8
const AIM_HITSCAN_MULT: float = 1.0
const AIM_PROJECTILE_MULT: float = 1.6
const AIM_EXPLOSIVE_MULT: float = 2.5

# Fire-mode selection
## Re-score the chosen fire mode after this much distance change (or another
## event: new target, weapon switch, magazine change).
const FIRE_MODE_DIST_HYSTERESIS: float = 6.0
## A new mode must beat the current one by this score margin before switching.
const FIRE_MODE_SCORE_HYSTERESIS: float = 15.0
## Splash weapons are penalised when the target is this close beyond the blast
## radius — the bot would damage itself.
const EXPLOSIVE_SAFE_MARGIN: float = 2.0

# Special firing mechanisms.  Classification lives in _refresh_weapon_specialty
# and is derived from the projectile's SIGNAL handler, not from weapon names.
## Signal-detonated projectiles (mines, remote grenades): minimum time after
## placing before the bot will detonate its own projectile.
const SIGNAL_ARM_DELAY_MIN: float = 1.0
const SIGNAL_ARM_DELAY_MAX: float = 2.0
## If the target never comes near, detonate anyway after this long.
const SIGNAL_MAX_HOLD: float = 5.0
## Detonate when the target is within splash_radius + this.  Negative on
## purpose: the blast only reaches splash_radius, so trigger slightly inside the
## edge to allow for the 1-2 frame delay between the check and the explosion.
const SIGNAL_BLAST_MARGIN: float = -0.5
## Redirect-on-signal projectiles (arrows, redirectable rockets): wait this
## long after firing, then signal while the crosshair is on the target.
const REDIRECT_DELAY_MIN: float = 0.1
const REDIRECT_DELAY_MAX: float = 0.35
## One-shot SIGNAL press length.  The action fires on the press edge; three
## frames guarantee WeaponController samples it, then release clears the latch.
const SIGNAL_PRESS_FRAMES: int = 3
## How often the special sequence scans the projectile parent.  Only while a
## special is pending, and only until it fires/cancels.
const SPECIAL_SCAN_INTERVAL: float = 0.1

# Weapon range / engagement distance
## A weapon is only ever treated as "melee" if its configured range is at or
## below this. Also used as "close enough that melee is even worth pulling out".
const MELEE_CONSIDER_RANGE: float  = 4.0
## Distance a bot actually tries to close a melee weapon to before it's happy.
const MELEE_ENGAGE_RANGE: float    = 1.8
## Fallback preferred fighting distance for a ranged weapon with no readable
## range info at all (roughly matches the old hardcoded 3-8 unit banding).
const DEFAULT_RANGED_ENGAGE_DIST: float = 8.0
## Clamp for a weapon's configured range before it's used to derive a fighting
## distance, so a sniper-tier range doesn't send bots halfway across the map.
const MAX_SENSIBLE_RANGE: float    = 40.0
## Random per-bot wobble added to the preferred fighting distance, rerolled
## every couple of seconds, so bots don't all hold an identical, robotic
## "exactly N units away" gap from their target.
const PREFERRED_DIST_JITTER: float           = 3.0
const PREFERRED_DIST_REROLL_INTERVAL: float  = 2.5
## Beyond this flat distance combat hands locomotion to Traversal's route
## follower (navmesh -> graph -> direct) so the bot clears walls and floors.
## EXIT is lower so the boundary cannot oscillate.
const COMBAT_CHASE_ENTER: float = 20.0
const COMBAT_CHASE_EXIT: float = 14.0
## A target this far above/below also needs a route, even at close flat range.
const COMBAT_CHASE_VERTICAL: float = 2.0
## A nav partial route parked at the closest reachable point for this long means
## the target is effectively unreachable; give the chase up.
const COMBAT_CHASE_STALL_TIME: float = 1.5

# Reaction time
## Worst-case delay (skill 0) before a bot pulls the trigger on a target it
## *just* acquired. Aiming/steering start immediately; only firing is gated,
## so it reads as "noticing and raising the gun" rather than "went blind".
const REACTION_TIME_MAX: float = 0.4

# Explosion jumping
const EXPLOSION_JUMP_COOLDOWN: float  = 4.0
## Only worth rocket-jumping if there's actually meaningful ground to cover.
const EXPLOSION_JUMP_MIN_GAP: float   = 6.0

# Debug overlay.  All of this is inert unless `debug_draw` (or the dev menu's
# "Show nav paths", which draws routes only) is on.
## How often the label text, steering-ray mesh and route line are rebuilt.  The
## AI thinks at 20 Hz; redrawing at that rate would just churn strings for
## nothing.
const DEBUG_REFRESH_INTERVAL: float = 0.1
## Height of the state label above the bot's origin, in metres.
const DEBUG_LABEL_HEIGHT: float = 2.4
const DEBUG_LABEL_FONT_SIZE: int = 32
const DEBUG_LABEL_PIXEL_SIZE: float = 0.004
const DEBUG_RAY_MISS_COLOR := Color(0.2, 1.0, 0.25, 0.8)
const DEBUG_RAY_HIT_COLOR := Color(1.0, 0.2, 0.2, 0.9)
## Safety cap on the steering-ray vertex queue.  At 20 Hz x 7 rays a 0.1 s
## refresh produces ~28 vertices; this only matters if the refresh stalls.
const DEBUG_MAX_RAY_VERTICES: int = 512
## Route lines are lifted slightly so the floor does not z-fight them.
const DEBUG_PATH_LIFT: float = 0.08
## ImmediateMesh line primitives are one pixel wide at any distance, which is
## easy to miss across a map.  Routes are flat ribbons instead.
const DEBUG_PATH_WIDTH: float = 0.18
const DEBUG_NAV_PATH_COLOR := Color(0.25, 1.0, 0.45, 1.0)
const DEBUG_NAV_PARTIAL_COLOR := Color(1.0, 0.7, 0.15, 1.0)
const DEBUG_GRAPH_PATH_COLOR := Color(0.2, 0.7, 1.0, 1.0)
const DEBUG_DIRECT_PATH_COLOR := Color(1.0, 0.3, 0.3, 0.8)

# Duck-typed property name lists.  These are the candidate names the original
# ad-hoc `.get("...")` chains probed.  Kept identical so this stage does not
# change behaviour; Stage 1 replaces the guesses with the verified fields.
const PROP_FIRE_LAUNCH_SPEED: Array[String] = ["projectile_speed", "speed"]
const PROP_PROJECTILE_LAUNCH_SPEED: Array[String] = ["speed", "projectile_speed"]
const PROP_LINEAR_VELOCITY: Array[String] = ["linear_velocity"]
const PROP_GRAVITY_SCALE: Array[String] = ["gravity_scale"]
const PROP_RANGE: Array[String] = ["max_range", "range"]
const PROP_IS_MELEE: Array[String] = ["is_melee"]
const PROP_SPLASH_RADIUS: Array[String] = ["splash_radius"]
const PROP_LIFETIME: Array[String] = ["lifetime"]
const PROP_HURTBOX_HIT_MODE: Array[String] = ["hurtbox_hit_mode"]
const PROP_WORLD_HIT_MODE: Array[String] = ["world_hit_mode"]
const PROP_EXPLODE_ON_TIMEOUT: Array[String] = ["explode_on_timeout"]
const PROP_SPLASH_HEALTH_DELTA: Array[String] = ["splash_health_delta"]
const PROP_SELF_HEALTH_MULT: Array[String] = ["self_health_delta_multiplier"]
const PROP_TEAM_HEALTH_MULT: Array[String] = ["team_health_delta_multiplier"]

# Runtime state

var _strafe_dir: float   = 0.0
var _strafe_timer: float = 0.0
## Long-range combat has handed locomotion to Traversal's route follower.
var _combat_chasing: bool = false
var _combat_chase_stall: float = 0.0

## Stage 3: per-bot route/perception/stuck state.  All non-combat movement
## (objective, pursue, wander, heal approach) goes through this.
var _traversal: Traversal = null

## Stage 4 decision state machine.  `_act` dispatches through it; the state has a
## minimum duration and only a new visible enemy or a hit interrupts it.
var _decision: Decision = null

## Target-selection memory.  `_seen_since` is player name -> first-visible time,
## so recognition is a duration, not a single ray hit.
var _seen_since: Dictionary = {}
var _last_damage_source_name: String = ""
var _last_damage_time: float = -999.0
var _last_damage_position: Vector3 = Vector3.INF
var _last_damage_direction: Vector3 = Vector3.ZERO
## Rolling damage pressure (fraction of max HP) and the enemy-count snapshot
## that feed `_threat_pressure()`.  Server-local, like the rest of the AI.
var _recent_damage: float = 0.0
var _nearby_enemy_count: int = 0
var _visible_enemy_count: int = 0
## Last moment `_last_seen_position` was refreshed from a visible target.
var _last_seen_time: float = -999.0
var _heard_position: Vector3 = Vector3.INF
var _heard_distance: float = INF
var _heard_timer: float = 0.0
var _heard_kind: StringName = &""
## The last accepted enemy sound, retained until a newer sound or respawn.  When
## no objective is nearby this drives an un-deadlined search back to the sound.
var _persistent_heard_position: Vector3 = Vector3.INF
var _persistent_heard_velocity: Vector3 = Vector3.ZERO
var _persistent_heard_direction: Vector3 = Vector3.ZERO
var _persistent_heard_name: String = ""
var _last_seen_velocity: Vector3 = Vector3.ZERO
## Target-velocity estimator (Stage 6).  Samples the target position at the
## 20 Hz think rate and smooths over ~0.18 s; a sign reversal damps the old
## estimate so a strafing player does not get over-led.
var _est_velocity: Vector3 = Vector3.ZERO
var _est_last_position: Vector3 = Vector3.ZERO
var _est_last_time: float = 0.0
var _est_target_name: String = ""
## True when the current target was visible on this think tick.  All firing and
## live-position reads go through this; a remembered target is never tracked
## through a wall.
var _target_visible: bool = false
## Last engaged enemy, kept alive across a line-of-sight break.  This identity is
## server-local and is never read from the hidden Player while unseen.
var _memory_target: Player = null
var _memory_target_name: String = ""
var _memory_last_position: Vector3 = Vector3.INF
var _memory_last_velocity: Vector3 = Vector3.ZERO
var _memory_last_seen_ms: int = 0
var _memory_expires_ms: int = 0
var _memory_seen_time: float = 0.0
var _memory_grace_until_ms: int = 0
var _memory_chasing: bool = false
## One predicted chase per loss; prevents the 4 Hz scan from restarting the
## search every time it finds no visible target.
var _memory_search_started: bool = false
var _target_lock_until_ms: int = 0
var _target_lost_timer: float = 0.0
var _search_timer: float = 0.0
var _search_active: bool = false
var _search_deadline_ms: int = 0
## True when the active search is the endless heard-memory search.  Cleared when
## a target is acquired, an objective comes nearby, or a new search starts.
var _search_persistent: bool = false
## Predicted escape direction for the directional search fan.  Zero falls back
## to a full ring around the search origin.
var _search_direction: Vector3 = Vector3.ZERO
## Stable centre of the current hunt (survives `_last_seen_position` being
## cleared when search expires) plus the sweep around it.
var _search_origin: Vector3 = Vector3.INF
var _hunt_points: Array[Vector3] = []
var _hunt_index: int = 0
var _hunt_dwell: float = 0.0
var _hunt_origin: Vector3 = Vector3.INF
var _hunt_seeded: bool = false
var _hunt_dwelling: bool = false
var _hunt_point_timer: float = 0.0
## Index whose distance-scaled timeout is currently armed, and a short timer
## that abandons a point when the route only reaches a partial approach.
var _hunt_timed_index: int = -1
var _hunt_partial_timer: float = 0.0
var _glance_timer: float = 0.0

## Combat movement is event-driven, not a 1.5 s dice roll.
var _strafe_force_change: bool = false
var _strafe_reason: String = ""
var _shots_since_strafe: int = 0
var _last_mag_for_strafe: int = -1
var _combat_jump_timer: float = 0.0
var _combat_crouch_timer: float = 0.0

## Combat locomotion shape.  A committed pattern is chosen at each strafe
## boundary; HOLD is the stop-to-shoot beat.
enum CombatRangeState { HOLD, APPROACH, RETREAT }
enum CombatPattern { WIDE, JIGGLE, HOLD }
var _combat_range_state: CombatRangeState = CombatRangeState.HOLD
var _combat_pattern: CombatPattern = CombatPattern.WIDE
var _combat_settle_timer: float = 0.0
var _combat_probe_timer: float = 0.0
var _combat_block_left: bool = false
var _combat_block_right: bool = false
var _combat_block_forward: bool = false
var _combat_block_backward: bool = false
var _combat_stall_timer: float = 0.0
var _combat_stall_position: Vector3 = Vector3.ZERO

## Cover/peek state shared by Decision and _act_retreat_cover.
var _cover_position: Vector3 = Vector3.INF
var _cover_threat_pos: Vector3 = Vector3.INF
var _cover_phase: int = 0
var _cover_timer: float = 0.0
var _cover_total_timer: float = 0.0
var _cover_cooldown: float = 0.0
var _cover_peek_side: float = 1.0
var _cover_rounds: int = 0

## FLEE: break contact when the trade is lost and cover is not available.
var _flee_position: Vector3 = Vector3.INF
var _flee_threat_pos: Vector3 = Vector3.INF
var _flee_timer: float = 0.0
var _flee_cooldown: float = 0.0
var _flee_repath_timer: float = 0.0

## Sole owner of the fire flags.  Assigned in _ready; ticked every physics
## frame, independently of the 20 Hz think loop.
var _trigger: Trigger = null

## The point `_act_combat`/`_act_heal` want the head ray to point at.  The aim
## gate measures the REAL head ray against this, not the angles the Mouse is
## currently trying to reach.
var _desired_aim_point: Vector3 = Vector3.ZERO
var _has_desired_aim: bool = false
## Public for the debug overlay and for Trigger's gate.
var aim_error_deg: float = -1.0
var aim_tolerance_deg: float = AIM_TOL_MAX_DEG

## Scan counter for the debug label — proves the idle-rescan fix (Issue I).
var _full_scan_count: int = 0

## Cached LOS exclude array (bot + current targets).  Rebuilt only when the
## target pair changes, never per ray.
var _los_exclude_rids: Array[RID] = []
var _los_targets_key: String = ""

## Fire-mode selection state.  `_chosen_fire_index` is -1 when no SHOOT mode is
## valid; selection is event-driven, not a 2 s dice roll.
var _chosen_fire_index: int = -1
var _fire_mode_dirty: bool = true
var _fire_mode_target_name: String = ""
var _fire_mode_weapon_key: String = ""
var _fire_mode_mag: int = -1
var _fire_mode_dist: float = -1.0
var _shoot_indices_cache: Dictionary = {}

## Stage 5: resource-keyed weapon profiles and the slow weapon-choice loop.
var _weapon_profile_cache: Dictionary = {}
var _weapon_choice_timer: float = 0.0
var _weapon_choice_target_name: String = ""
var _weapon_choice_band: int = -999
var _weapon_choice_reason: String = ""

## Medic switch hysteresis: the candidate must persist before committing, and
## the absence must persist before putting the heal gun away.
var _heal_candidate_name: String = ""
var _heal_candidate_time: float = 0.0
var _heal_absent_time: float = 0.0

## Explosion-jump sub-sequence (Stage 5, fixes K).
var _explosion_jump_phase: int = 0
var _explosion_jump_timer: float = 0.0
var _explosion_jump_fire_wait: float = 0.0
var _explosion_jump_fire_index: int = -1
var _explosion_jump_weapon_index: int = -1

## What the current weapon's SIGNAL fire does to its projectiles.  Classified
## from the projectile's own `_on_weapon_signal` implementation, never from the
## weapon's name, so a new weapon with a standard or redirect projectile is
## handled automatically.
enum SignalMode { NONE, EXPLODE, REDIRECT, OTHER }
var _signal_mode: SignalMode = SignalMode.NONE
## Index of the SIGNAL fire mode, or -1 when the weapon has none.
var _signal_index: int = -1
## Scene path of the SHOOT projectile the signal acts on ("" = none).
var _signal_projectile_path: String = ""
var _signal_blast_radius: float = 0.0
## Weapon whose specialty is currently cached; reclassify only on a switch.
var _specialty_weapon_key: String = ""

## Spawn edge tracking so BotController state resets on respawn.
var _was_spawned: bool = false

var _timer: float              = 0.0
var _wander_target: Vector3    = Vector3.ZERO
var _current_target: Player    = null
var _heal_target: Player       = null
var _last_seen_position: Vector3 = Vector3.INF

## "What should I be doing right now?" — the top-level intent model.  It is
## recomputed after each Decision update; the debug label shows it and the
## objective fields drive combat/search anchoring.
enum Intent {
	NONE, WANDER, FIGHT, MOVE_TO_OBJECTIVE, CAPTURE, DEFEND, HOLD,
	FIGHT_ON_OBJECTIVE, RETURN_TO_OBJECTIVE, SEARCH, HEAL, COVER, FLEE,
	RELOAD, UNSTUCK,
}
var _intent: Intent = Intent.NONE
var _intent_text: String = "—"
## Cached objective info for this tick.  Populated by `_update_intent()`.
var _objective_position: Vector3 = Vector3.INF
var _objective_hold_radius: float = OBJECTIVE_HOLD_RADIUS
var _objective_leash_radius: float = OBJECTIVE_LEASH_RADIUS
var _objective_name: String = ""
var _objective_active: bool = false
var _objective_owned: bool = false
var _objective_contested: bool = false
var _objective_kind: String = ""
var _objective_attacking: bool = false

## Seconds since an enemy was last visible or within SAFE_TOP_OFF_RADIUS.
## Drives the out-of-combat "heal to full" threshold only.
var _safe_top_off_timer: float = 0.0
## Set by the target rescan when a living enemy is within that radius.
var _enemy_nearby: bool = false

var _retarget_timer: float        = 0.0
var _weapon_switch_guard: float   = 0.0
var _fov_dot_threshold: float     = 0.5  # cos(FOV_DEGREES / 2), set in _ready
## Wider cone for reacquiring a remembered target (see TARGET_RECALL_FOV_DEGREES).
var _recall_fov_dot_threshold: float = 0.5

## Stage 2 verb layer.  These are the ONLY writers of movement keys, jump,
## crouch, facing and (through Trigger) fire flags.  Decisions in _act_* call
## their intent-level APIs; they never poke PlayerInput or body/head rotations.
var _style: Style = null
var _keyboard: Keyboard = null
var _mouse: Mouse = null
var _buttons: Buttons = null
var _maneuvers: ManeuverRunner = null

## Per-bot entropy state: last weighted choice per decision key, plus a small
## strafe preference so two bots at the same skill do not mirror each other.
var _choice_history: Dictionary = {}
var _strafe_bias: float = 0.0

## Counts down after acquiring a new target; firing is held off until it hits
## zero (see REACTION_TIME_MAX). Aiming/steering are never gated by this.
var _reaction_timer: float = 0.0

## Last observed health, used to abort a running maneuver the moment the bot is
## hit.  -1 until the first sample after respawn.
var _last_health: float = -1.0

## Rerolled periodically so the "ideal" fighting distance isn't a fixed number.
var _preferred_dist_offset: float = 0.0
var _preferred_dist_timer: float  = 0.0

var _explosion_jump_cooldown_timer: float = 0.0

# Wall-following state
var _wall_hug_side: int     = 0
var _wall_hug_timer: float  = 0.0
var _last_steer_dir: Vector2 = Vector2.ZERO

# Debug overlay state.  All null until debug_draw first turns on.
var _debug_label: Label3D = null
var _debug_ray_instance: MeshInstance3D = null
var _debug_ray_mesh: ImmediateMesh = null
var _debug_ray_material: StandardMaterial3D = null
var _debug_path_material: StandardMaterial3D = null
var _debug_refresh_timer: float = 0.0
## World-space line pairs collected since the last refresh (2 vertices per ray).
var _debug_ray_lines: PackedVector3Array = PackedVector3Array()
var _debug_ray_colors: PackedColorArray = PackedColorArray()

## One-shot warnings, keyed by a stable context string.  Dictionary rather than
## a Set: GDScript has no Set type, and only membership is ever read.
var _warned_once: Dictionary = {}

## Weapon resources already introspected by ANY bot.  Static so a 12-bot match
## logs each weapon once instead of once per bot.
static var _introspected_weapons: Dictionary = {}

# Main loop

func _physics_process(delta: float) -> void:
	if not player.is_bot:
		return
	if not multiplayer.is_server():
		return
	if not player.spawned:
		# The fire flags are plain bools that survive death, and the key state
		# would otherwise resume on respawn.  Release everything.
		_trigger.release_all()
		_keyboard.release_all()
		_mouse.cancel()
		_buttons.cancel()
		_maneuvers.abort()
		_abort_explosion_jump()
		_has_desired_aim = false
		aim_error_deg = -1.0
		_was_spawned = false
		return
	if not _was_spawned:
		_was_spawned = true
		_reset_for_spawn()

	# A bot can be queue_free'd while another bot is targeting it.  A freed
	# object compares == null but still fails the typed-parameter check, so clear
	# the caches before any tick phase can touch them.
	if not is_instance_valid(_current_target):
		_current_target = null
	if not is_instance_valid(_heal_target):
		_heal_target = null

	# Dev-menu "freeze all bots": park them exactly like a stun.  Going through
	# the emulators keeps them the only writers of input/facing state.
	if GameManager.dev_freeze_bots:
		_keyboard.release_all()
		_trigger.release_all()
		_mouse.cancel()
		_maneuvers.abort()
		_abort_explosion_jump()
		_has_desired_aim = false
		_debug_sync(delta)
		return

	# Stunned, pinned, or mid-channel bots cannot move, aim, or fire.
	if player.status_effect_manager and (player.status_effect_manager.is_stunned() or player.status_effect_manager.is_pinned() or player.status_effect_manager.is_action_blocked()):
		_keyboard.release_all()
		_trigger.release_all()
		_mouse.cancel()
		_maneuvers.abort()
		_abort_explosion_jump()
		_has_desired_aim = false
		_debug_sync(delta)
		return

	# Physics-rate verb layer.  Mouse movement, aim measurement, fire state and
	# keyboard state run every physics frame; only decisions wait for 20 Hz.
	_buttons.tick(delta)
	_maneuvers.tick(delta)
	_mouse.tick(delta)
	_update_aim_error()
	_tick_explosion_jump(delta)
	_trigger.tick(delta)
	_keyboard.tick(delta)
	_traversal.tick(delta)

	# A hit is a higher-priority event than whatever maneuver is running.
	var ac: AttributeComponent = player.attribute_component
	var health_now: float = ac.health if ac != null else 0.0
	if _last_health >= 0.0 and health_now < _last_health - 1.0:
		_maneuvers.abort()
		_record_damage(_last_health - health_now, ac)
		_react_to_damage(ac)
	_last_health = health_now

	if _reaction_timer > 0.0:
		_reaction_timer = maxf(_reaction_timer - delta, 0.0)
	if _explosion_jump_cooldown_timer > 0.0:
		_explosion_jump_cooldown_timer = maxf(_explosion_jump_cooldown_timer - delta, 0.0)
	if _cover_cooldown > 0.0:
		_cover_cooldown = maxf(_cover_cooldown - delta, 0.0)
	if _flee_cooldown > 0.0:
		_flee_cooldown = maxf(_flee_cooldown - delta, 0.0)
	# Leaky bucket: an old hit stops mattering after SURVIVAL_DAMAGE_WINDOW.
	_recent_damage = maxf(0.0, _recent_damage - delta / SURVIVAL_DAMAGE_WINDOW)

	# Safe-top-off clock: reset as long as an enemy is visible or nearby.
	if _current_target != null or _enemy_nearby:
		_safe_top_off_timer = 0.0
	else:
		_safe_top_off_timer = minf(_safe_top_off_timer + delta, SAFE_TOP_OFF_DELAY)

	_debug_sync(delta)

	if _weapon_switch_guard > 0.0:
		_weapon_switch_guard -= delta
	if _arc_validation_timer > 0.0:
		_arc_validation_timer = maxf(_arc_validation_timer - delta, 0.0)

	_timer += delta
	if _timer < PROCESS_INTERVAL:
		return
	_timer = 0.0

	_tick_strafe()
	_tick_preferred_distance()

	_think()
	_decision.update(PROCESS_INTERVAL)
	_update_intent()
	if not _maneuvers.is_running():
		_act()

# Steering

func _steer_toward(target_pos: Vector3) -> Vector2:
	var origin := player.global_position + Vector3(0, STEER_RAY_HEIGHT, 0)
	var to_target := target_pos - player.global_position
	var flat_desired := Vector2(to_target.x, to_target.z)
	if flat_desired.length() < 0.1:
		return Vector2.ZERO
	flat_desired = flat_desired.normalized()

	# Score the straight-ahead direction first. If it is clear, no wall is within
	# STEER_DISTANCE, so the 6 side raycasts are wasted — the common case in open
	# space, where this turns steering from 7 raycasts/tick into 1.
	var center_score := _score_direction(origin, flat_desired)
	if center_score >= STEER_DISTANCE:
		_last_steer_dir = flat_desired
		_wall_hug_timer = 0.0
		_wall_hug_side = 0
		return flat_desired

	var best_dir := flat_desired
	var best_score := center_score + 2.0  # center's forward bias, matches loop below

	for angle in STEER_ANGLES:
		if angle == 0.0:
			continue
		var rad := deg_to_rad(angle)
		var test_dir := flat_desired.rotated(rad)
		var score := _score_direction(origin, test_dir)
		score += (1.0 - abs(angle) / 90.0) * 2.0
		if score > best_score:
			best_score = score
			best_dir = test_dir

	_last_steer_dir = best_dir

	if center_score < STEER_DISTANCE * 0.3:
		# A visible target needs a short deflection, not a three-second wall
		# crawl; keep the longer hug for travel/unseen steering.
		var sees_target := _current_target != null and _target_visible
		var hug_angle := 35.0 if sees_target else 70.0
		var hug_time := 1.0 if sees_target else 3.0
		if _wall_hug_timer <= 0.0:
			_wall_hug_side = 1 if randf() > 0.5 else -1
			_wall_hug_timer = hug_time
		_wall_hug_timer -= PROCESS_INTERVAL
		var hug_dir := flat_desired.rotated(deg_to_rad(hug_angle * _wall_hug_side))
		var hug_score := _score_direction(origin, hug_dir)
		if hug_score > center_score + 1.0:
			best_dir = hug_dir
	else:
		_wall_hug_timer = 0.0
		_wall_hug_side = 0

	return best_dir

func _score_direction(origin: Vector3, dir: Vector2) -> float:
	var end := origin + Vector3(dir.x, 0.0, dir.y) * STEER_DISTANCE
	_steer_query.from = origin
	_steer_query.to = end
	var hit := player.get_world_3d().direct_space_state.intersect_ray(_steer_query)
	if debug_draw and _debug_ray_lines.size() < DEBUG_MAX_RAY_VERTICES:
		# Draw to the obstruction when there is one, so a red line ends exactly
		# where the bot stopped scoring the direction.
		var drawn_end: Vector3 = end
		if not hit.is_empty():
			drawn_end = hit.position
		var color: Color = DEBUG_RAY_MISS_COLOR if hit.is_empty() else DEBUG_RAY_HIT_COLOR
		_debug_ray_lines.append(origin)
		_debug_ray_lines.append(drawn_end)
		_debug_ray_colors.append(color)
		_debug_ray_colors.append(color)
	if hit.is_empty():
		return STEER_DISTANCE
	return -hit.position.distance_to(origin)

## World-space movement adapter, retained for the few combat/heal fallbacks that
## naturally think in world space.  Normal travel never uses it: Traversal holds
## W and turns the mouse.  `keys_for_world_dir` converts to the nearest 8-way key
## combination using the current camera yaw.
func _apply_movement(sd: Vector2) -> void:
	_keyboard.set_move_world(sd)


## Camera/body-local movement (x = strafe, y = +1 backward, exactly the
## `input_dir` convention).  Quantised to keys inside the Keyboard.
func _move_local(local: Vector2) -> void:
	_keyboard.set_move_input_vector(local)


## Release latched movement keys.  Every act early-return that can be reached
## with a previous movement intent must call this; the Keyboard otherwise keeps
## walking the bot unguided (known issue #118).
func _release_movement() -> void:
	_keyboard.set_move(0, 0)

# Strafing

func _tick_strafe() -> void:
	_strafe_timer -= PROCESS_INTERVAL
	_combat_settle_timer = maxf(_combat_settle_timer - PROCESS_INTERVAL, 0.0)
	_combat_probe_timer = maxf(_combat_probe_timer - PROCESS_INTERVAL, 0.0)
	var forced := _strafe_force_change
	if _strafe_timer > 0.0 and not forced:
		return
	_strafe_force_change = false

	var style: Style = _style
	if style == null:
		_strafe_timer = STRAFE_CHANGE_INTERVAL
		_strafe_dir = float([-1, 0, 1][randi() % 3])
		return

	var in_combat := _current_target != null and _target_visible
	if not in_combat:
		# Out of combat: the old relaxed cadence is fine.
		var spread := clampf(style.strafe_hold_spread, 0.0, 0.9)
		_strafe_timer = maxf(
			0.16,
			style.strafe_hold_median * randf_range(1.0 - spread, 1.0 + spread)
		)
		if not style.allow_strafe or randf() < style.pause_probability:
			if _strafe_dir != 0.0:
				_keyboard.counter_strafe()
			_strafe_dir = 0.0
			return
		_pick_strafe_direction()
		_combat_pattern = CombatPattern.WIDE
		return

	if forced:
		# A hit or a burst asks for a new direction now; a human does not wait
		# out the old strafe timer after being shot.
		_combat_pattern = CombatPattern.WIDE
		_combat_settle_timer = 0.0
		_strafe_timer = randf_range(0.25, 0.55)
		_pick_strafe_direction()
		_strafe_reason = "damaged"
		return

	# Choose a committed combat pattern.  The style weights were authored for
	# exactly this purpose but were previously unused.
	var weights := style.peek_style_weights
	var w_wide := maxf(0.1, weights[0] if weights.size() > 0 else 0.5)
	var w_jiggle := maxf(0.1, weights[1] if weights.size() > 1 else 0.3)
	var w_hold := maxf(0.1, weights[2] if weights.size() > 2 else 0.2)
	var wc: WeaponController = player.weapon_controller
	var movement_spread := 0.0
	if wc != null and wc._is_ready():
		var weapon := wc._weapons[wc.current_weapon_index]
		if weapon != null and _chosen_fire_index >= 0 \
				and _chosen_fire_index < weapon.weapon_fires.size():
			var fire: WeaponFire = weapon.weapon_fires[_chosen_fire_index]
			if fire != null:
				movement_spread = fire.movement_spread
	var target_pos := _target_position_for_ai()
	var target_dist := player.global_position.distance_to(target_pos) \
		if target_pos != Vector3.INF else 999.0
	if movement_spread > 0.0 and target_dist > 6.0:
		w_hold *= 1.7
	if target_dist < 6.0:
		w_hold *= 0.6
	if _combat_pattern == CombatPattern.HOLD:
		w_hold *= 0.5

	var pattern_weights: Array[float] = [w_wide, w_jiggle, w_hold]
	var pick := _weighted_choice(pattern_weights, "combat_pattern")
	if pick == 2:
		_combat_pattern = CombatPattern.HOLD
		if _strafe_dir != 0.0:
			_keyboard.counter_strafe()
		_strafe_dir = 0.0
		_strafe_timer = randf_range(0.35, 0.7)
		_combat_settle_timer = randf_range(0.08, 0.16)
		_strafe_reason = "hold"
		return

	_combat_pattern = CombatPattern.JIGGLE if pick == 1 \
		else CombatPattern.WIDE
	_pick_strafe_direction()
	if pick == 0:
		_strafe_timer = randf_range(0.6, 1.2)
	else:
		_strafe_timer = randf_range(0.15, 0.3)
		if randf() < style.pause_probability * 0.5:
			_strafe_dir = 0.0
			_strafe_timer = randf_range(0.1, 0.25)
			_strafe_reason = "pause"


## Weighted left/right with a repeat penalty and a per-bot bias.  The bias makes
## one bot prefer right peeks and another prefer left, so same-skill bots do not
## look like copies.
func _pick_strafe_direction() -> void:
	var old_dir := _strafe_dir
	var weights: Array[float] = [
		maxf(0.05, 1.0 - _strafe_bias),
		maxf(0.05, 1.0 + _strafe_bias),
	]
	var pick := _weighted_choice(weights, "strafe")
	var new_dir := -1.0 if pick == 0 else 1.0
	if old_dir != 0.0 and not is_equal_approx(old_dir, new_dir):
		# A short opposite tap stops the current lateral velocity before the new
		# key takes over.
		_keyboard.counter_strafe()
	_strafe_dir = new_dir
	_strafe_reason = "pattern"

## Rerolls the per-bot preferred-fighting-distance wobble every couple of
## seconds so combat movement doesn't lock onto one exact, robotic distance.
func _tick_preferred_distance() -> void:
	_preferred_dist_timer -= PROCESS_INTERVAL
	if _preferred_dist_timer <= 0.0:
		_preferred_dist_timer = PREFERRED_DIST_REROLL_INTERVAL + randf_range(-0.5, 0.5)
		_preferred_dist_offset = randf_range(-PREFERRED_DIST_JITTER, PREFERRED_DIST_JITTER)

# Aim error

## Angle (degrees) between the head's REAL forward ray and the desired aim
## point.  The Mouse exposes this from the real camera ray, not from the angles
## it is trying to reach, so the Trigger gates on what the gun will actually do.
func _update_aim_error() -> void:
	aim_tolerance_deg = _current_aim_tolerance()
	if not _has_desired_aim:
		aim_error_deg = -1.0
		return
	aim_error_deg = _mouse.current_aim_error_to(_desired_aim_point)


## Reflex look toward whoever just shot us.  REACT_DAMAGE sits below COMBAT, so
## a live target keeps the crosshair; this only steers a bot that was looking
## elsewhere (travel/idle) when it gets hit.
func _react_to_damage(ac: AttributeComponent) -> void:
	if ac == null:
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	_last_damage_time = now
	_last_damage_direction = ac.last_hit_direction
	_glance_timer = 0.0
	# A hit is an event, not a timer tick: change strafe direction now.
	_strafe_force_change = true
	_strafe_reason = "damaged"
	var rejected_source := false

	var attacker_name := str(ac.last_enemy_attacker)
	if attacker_name.is_empty() or attacker_name == "NONE":
		attacker_name = str(ac.last_attacker)
	if not attacker_name.is_empty() and attacker_name != "NONE":
		var attacker := GameManager.find_player(attacker_name)
		var hidden_attacker := attacker != null and is_instance_valid(attacker) \
			and (attacker.dev_hidden_from_bots \
				or (attacker.status_effect_manager \
					and attacker.status_effect_manager.has_effect("invisible")))
		if hidden_attacker:
			rejected_source = true
		if attacker != null and is_instance_valid(attacker) and attacker.spawned \
				and attacker != player and _is_enemy_of(attacker) \
				and not hidden_attacker:
			_last_damage_source_name = attacker_name
			_last_damage_position = attacker.global_position
			_mouse.request_look_at_point(
				_get_head_position(attacker),
				LookPriority.REACT_DAMAGE,
				1.0,
				"damage:" + attacker_name
			)
			if _current_target == null:
				_begin_search(attacker.global_position, attacker.velocity)
				# A committed escape owns the next few seconds; do not drag the
				# bot into a hunt it is about to run away from.
				if _assess_retreat() != RetreatNeed.FLEE:
					_decision.interrupt(Decision.State.SEARCH)
			_maybe_cover_after_damage()
			return

	# A direction with no enemy attribution may be self-splash or ally fire.
	# Keep the reflex look, but do not launch a hunt at our own explosion.
	var friendly_source := attacker_name == str(player.name)
	if not friendly_source and not attacker_name.is_empty() \
			and attacker_name != "NONE":
		var source_player := GameManager.find_player(attacker_name)
		if source_player != null and is_instance_valid(source_player) \
				and not _is_enemy_of(source_player):
			friendly_source = true

	var direction: Vector3 = ac.last_hit_direction
	if direction.length_squared() > 0.001:
		# last_hit_direction points attacker -> victim, so flip it to look back.
		var source_dir := -direction.normalized()
		_last_damage_position = player.global_position + source_dir * 8.0
		_mouse.request_look_direction(source_dir, LookPriority.REACT_DAMAGE, 1.0)
		if _current_target == null and not friendly_source and not rejected_source:
			_begin_search(_last_damage_position, Vector3.ZERO)
			if _assess_retreat() != RetreatNeed.FLEE:
				_decision.interrupt(Decision.State.SEARCH)
	_maybe_cover_after_damage()


## A hit is the fastest read on whether the trade is being lost.  FLEE takes
## precedence; a bot already fleeing is never downgraded to a fair fight.
func _maybe_cover_after_damage() -> void:
	var need := _assess_retreat()
	if need == RetreatNeed.FLEE and _flee_cooldown <= 0.0:
		_decision.interrupt(Decision.State.FLEE)
		return
	if ENABLE_COVER and _cover_cooldown <= 0.0 \
			and (need == RetreatNeed.COVER or need == RetreatNeed.FLEE):
		_decision.interrupt(Decision.State.RETREAT_COVER)
		return
	if _decision.state == Decision.State.FLEE:
		return
	if _current_target != null:
		_decision.interrupt(Decision.State.COMBAT)


func _current_aim_tolerance() -> float:
	var wc: WeaponController = player.weapon_controller
	if wc == null or not is_instance_valid(wc) or not wc._is_ready():
		return AIM_TOL_MAX_DEG
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon == null or weapon.weapon_fires.is_empty():
		return AIM_TOL_MAX_DEG
	var index := _chosen_fire_index
	if index < 0 or index >= weapon.weapon_fires.size():
		var indices := _shoot_indices_for(weapon)
		if indices.is_empty():
			return AIM_TOL_MAX_DEG
		index = indices[0]
	return aim_tolerance_for(weapon, weapon.weapon_fires[index])


## Angular size of the target's hittable volume at [param dist], widened for
## projectiles and splash and narrowed by skill.  Low skill fires when roughly
## on target; high skill waits for a tight line.
func aim_tolerance_for(_weapon: Weapon, fire: WeaponFire) -> float:
	var dist := 1.0
	if _current_target != null and is_instance_valid(_current_target):
		var tp := _target_position_for_ai()
		if tp != Vector3.INF:
			dist = player.global_position.distance_to(tp)
	elif _heal_target != null and is_instance_valid(_heal_target):
		dist = player.global_position.distance_to(_heal_target.global_position)
	dist = maxf(dist, 0.1)

	var base := rad_to_deg(atan(AIM_TARGET_RADIUS / dist))
	var kind := AIM_HITSCAN_MULT
	if fire != null and fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		kind = AIM_PROJECTILE_MULT
		var info := _get_proj_info(fire)
		# Signal-detonated mines count as splash for aim forgiveness even though
		# they do not explode on impact.
		if bool(info.get("is_explosive", false)) or _signal_mode == SignalMode.EXPLODE:
			var splash := float(info.get("splash_radius", 0.0))
			base = maxf(base, rad_to_deg(atan(splash / dist)))
			kind = AIM_EXPLOSIVE_MULT
	var accuracy := _style.accuracy if _style != null else lerpf(0.3, 0.97, skill)
	var skill_mult := lerpf(AIM_SKILL_MULT_MAX, AIM_SKILL_MULT_MIN, accuracy)
	return clampf(base * kind * skill_mult, AIM_TOL_MIN_DEG, AIM_TOL_MAX_DEG)

# Think

## Recognition time before a newly visible enemy becomes a target.  Distance and
## FOV-edge position both lengthen it; skill shortens the whole scale.  An
## already-acquired target skips this (it is tracking, not recognising).
func _recognition_time(target: Player, dist: float, in_fov: bool) -> float:
	var edge := 0.6
	if in_fov:
		var fwd := player.horizontal_forward()
		var to := target.global_position - player.global_position
		to.y = 0.0
		if to.length_squared() > 0.0001:
			var angle := rad_to_deg(fwd.angle_to(to.normalized()))
			edge = clampf(angle / maxf(FOV_DEGREES * 0.5, 1.0), 0.0, 1.0)
	var awareness := _style.awareness if _style != null else lerpf(0.35, 1.0, skill)
	var base := lerpf(RECOGNITION_TIME_MAX, RECOGNITION_TIME_MIN, awareness)
	return base * (
		0.7 + clampf(dist / SHOOT_RANGE, 0.0, 1.0) * 0.9 + edge * 0.7
	)


## Human target score: what the crosshair is near, how close, how long it has
## been visible, and whether it just hurt us.  Stickiness is added by the caller
## for the current target, and the switch margin is applied after scoring.
func _score_target(target: Player, dist: float, seen_time: float, now: float) -> float:
	var fwd := player.horizontal_forward()
	var to := target.global_position - player.global_position
	to.y = 0.0
	var angle := 0.0
	if to.length_squared() > 0.0001:
		angle = rad_to_deg(fwd.angle_to(to.normalized()))
	var score := 1.3 * (1.0 - clampf(angle / 90.0, 0.0, 1.0))
	score += 1.1 * (1.0 - clampf(dist / SHOOT_RANGE, 0.0, 1.0))
	# Nearby enemies are more urgent when the previous target has just vanished.
	score += TARGET_PROXIMITY_BONUS \
		* (1.0 - clampf(dist / TARGET_PROXIMITY_REF, 0.0, 1.0))
	score += 0.8 * clampf(seen_time / 2.0, 0.0, 1.0)
	if str(target.name) == _last_damage_source_name and now - _last_damage_time < 5.0:
		score += 1.0
	if _style != null:
		score += _style.aggression * 0.12
	var ac := target.attribute_component
	if ac != null and ac.max_health > 0.0 and ac.health / ac.max_health < 0.4:
		score += 0.15
	return score


## A sound event from GameManager.  Footsteps, shots and reloads carry their own
## hearing radius.  Sound is a distance check only (no FOV/LOS): an enemy noise
## starts an investigation at that position, while a bot already engaging an
## enemy keeps fighting.
func _on_sound_made(position: Vector3, radius: float, source_name: String,
		kind: StringName) -> void:
	if not player.is_bot or not multiplayer.is_server() or not player.spawned:
		return
	if source_name == str(player.name):
		return
	var dist := player.global_position.distance_to(position)
	# Awareness scales how far a sound carries for this bot; the emitter's radius
	# is still the maximum, so two bots hear the same shot at different ranges.
	var awareness := _style.awareness if _style != null else 0.6
	if dist > radius * lerpf(0.65, 1.1, awareness):
		return

	# Resolve the emitter BEFORE storing the glance.  A friendly footstep must
	# not turn the bot's head or displace an enemy sound.
	var source := GameManager.find_player(source_name)
	if source == null or not is_instance_valid(source) or not source.spawned:
		return
	if source.dev_hidden_from_bots or not _is_enemy_of(source):
		return
	if source.status_effect_manager \
			and source.status_effect_manager.has_effect("invisible"):
		return

	# Record "last heard" even while already fighting.  This is a fact, not a new
	# order; it is what lets a bot resume the sound later if it loses the fight.
	_persistent_heard_position = position
	_persistent_heard_velocity = source.velocity
	_persistent_heard_name = source_name
	var heard_dir := Vector3(
		source.velocity.x, 0.0, source.velocity.z
	)
	if heard_dir.length_squared() < 0.01:
		heard_dir = Vector3(
			position.x - player.global_position.x,
			0.0,
			position.z - player.global_position.z
		)
	_persistent_heard_direction = heard_dir.normalized() \
		if heard_dir.length_squared() > 0.01 else Vector3.ZERO

	if _is_engaging_enemy():
		return

	# A new sound only replaces an existing curiosity target if it is closer.
	if _heard_timer > 0.0 and dist > _heard_distance + HEARING_NEAREST_MARGIN:
		return
	_heard_position = position
	_heard_distance = dist
	_heard_timer = HEARING_LOOK_TIME
	_heard_kind = kind

	# A heard enemy is a lead, not just a glance.  Follow the emitter's motion,
	# not the listener's facing, so a runner is chased in the right direction.
	# Footsteps repeat every ~0.5 s; do not reset the same hunt forever while the
	# bot is already walking to that spot.
	if _search_active \
			and position.distance_to(_search_origin) < HEARING_NEAREST_MARGIN:
		return
	# No objective nearby means the sound stays actionable until it is found or
	# replaced; near an objective, this is an ordinary finite search.
	var persistent := not _objective_is_near(player.global_position) \
		and not _objective_is_near(position)
	_begin_search(
		position, source.velocity, _persistent_heard_direction, persistent
	)
	var travel_time := dist / WALK_SPEED
	_hunt_point_timer = maxf(HUNT_APPROACH_TIMEOUT, travel_time + 1.0)
	_decision.interrupt(Decision.State.SEARCH)


func _is_engaging_enemy() -> bool:
	if _current_target != null and is_instance_valid(_current_target):
		return true
	if _decision != null and _decision.state in [
			Decision.State.COMBAT, Decision.State.HEAL,
			Decision.State.RETREAT_COVER, Decision.State.RELOAD_SAFE,
			Decision.State.FLEE]:
		return true
	return false


## Refresh the curiosity look while the sound is recent.  GLANCE beats the travel
## look but never combat/damage aim.
func _tick_hearing(delta: float) -> void:
	if _heard_timer <= 0.0:
		return
	_heard_timer = maxf(_heard_timer - delta, 0.0)
	if _heard_timer <= 0.0 or _heard_position == Vector3.INF:
		return
	if _is_engaging_enemy():
		_heard_timer = 0.0
		return
	_mouse.request_look_at_point(
		_heard_position + Vector3.UP * TRAVEL_EYE_HEIGHT,
		LookPriority.GLANCE,
		0.3,
		"heard:" + str(_heard_kind)
	)


## Idle/travel glance.  It uses GLANCE so it briefly beats the travel look but
## never a damage reaction or combat aim.
func _tick_glance(delta: float) -> void:
	# A recent sound is the more interesting thing to look at.
	if _heard_timer > 0.0:
		return
	if _glance_timer > 0.0:
		_glance_timer = maxf(_glance_timer - delta, 0.0)
		return
	if _current_target != null or _heal_target != null:
		_glance_timer = randf_range(1.5, 3.0)
		return
	_glance_timer = randf_range(1.8, 3.8)
	var pos := player.global_position
	var look := Vector3.ZERO
	if _last_seen_position != Vector3.INF:
		look = _last_seen_position - pos
	elif _last_damage_position != Vector3.INF \
			and float(Time.get_ticks_msec()) / 1000.0 - _last_damage_time < 8.0:
		look = _last_damage_position - pos
	else:
		var fwd := player.horizontal_forward()
		look = fwd.rotated(Vector3.UP, deg_to_rad(randf_range(45.0, 80.0) * (1.0 if randf() > 0.5 else -1.0)))
	look.y = 0.0
	if look.length_squared() > 0.01:
		_mouse.request_look_direction(
			look.normalized(), LookPriority.GLANCE, 0.22
		)


## How long this bot keeps a lost target's identity/recognition.  Aware and
## aggressive bots hold a grudge longer; range is 5–8 s.
func _target_memory_window() -> float:
	var awareness := _style.awareness if _style != null else lerpf(0.35, 1.0, skill)
	var aggression := _style.aggression if _style != null else lerpf(0.3, 0.65, skill)
	return lerpf(
		TARGET_MEMORY_MIN,
		TARGET_MEMORY_MAX,
		clampf(0.6 * awareness + 0.4 * aggression, 0.0, 1.0)
	)


## Identity check shared by the visible target and the remembered target.
## Deliberately does not require LOS; visibility is tracked separately.
func _target_identity_valid(target: Player) -> bool:
	return target != null and is_instance_valid(target) and target.spawned \
		and not target.dev_hidden_from_bots and _is_enemy_of(target) \
		and not (target.status_effect_manager \
			and target.status_effect_manager.has_effect("invisible"))


func _memory_target_valid() -> bool:
	return _target_identity_valid(_memory_target)


func _heal_target_valid() -> bool:
	var t := _heal_target
	if t == null or not is_instance_valid(t) or not t.spawned \
			or t.dev_hidden_from_bots:
		return false
	var ac: AttributeComponent = t.attribute_component
	return ac != null and ac.max_health > 0.0 \
		and ac.health < ac.max_health * _medic_heal_threshold() \
		and _has_line_of_sight_to_player(t)


## A medic may only keep healing when the area is actually safe.  Being shot or
## having a live enemy nearby aborts the heal and gets the damage weapon out.
func _heal_is_safe() -> bool:
	if _heal_target == null or not is_instance_valid(_heal_target):
		return false
	if _recent_damage_fraction() > 0.03:
		return false
	var threat := _current_threat_position()
	if threat != Vector3.INF \
			and player.global_position.distance_to(threat) < 12.0:
		return false
	return true


func _clear_memory() -> void:
	if not _memory_target_name.is_empty():
		_seen_since.erase(_memory_target_name)
	_memory_target = null
	_memory_target_name = ""
	_memory_last_position = Vector3.INF
	_memory_last_velocity = Vector3.ZERO
	_memory_last_seen_ms = 0
	_memory_expires_ms = 0
	_memory_seen_time = 0.0
	_memory_grace_until_ms = 0
	_memory_chasing = false
	_memory_search_started = false
	_target_lost_timer = 0.0


## Freeze the last genuinely visible values and start the memory/grace clocks.
## Never call this with a target that has never been visible.  A scan that loses
## the target passes the values captured before the scan so the live, now-hidden
## body is not consulted.
func _mark_target_unseen(target: Player, now_ms: int,
		position: Vector3 = Vector3.INF,
		velocity: Vector3 = Vector3.INF) -> void:
	if target == null or not is_instance_valid(target):
		return
	var name_key := str(target.name)
	var now_s := float(now_ms) / 1000.0
	var first_seen := float(_seen_since.get(name_key, now_s - 1.0))
	_memory_target = target
	_memory_target_name = name_key
	_memory_last_position = position if position != Vector3.INF \
		else target.global_position
	_memory_last_velocity = velocity if velocity != Vector3.INF \
		else _estimated_velocity_for(target)
	_memory_last_seen_ms = now_ms
	_memory_seen_time = clampf(now_s - first_seen, 0.0, 2.0)
	_memory_expires_ms = now_ms + int(_target_memory_window() * 1000.0)
	_memory_grace_until_ms = now_ms + int(TARGET_LOST_GRACE * 1000.0)
	_memory_search_started = false
	_target_lost_timer = TARGET_LOST_GRACE
	_last_seen_position = _memory_last_position
	_last_seen_velocity = _memory_last_velocity
	_last_seen_time = now_s
	_target_visible = false
	# Freeze the estimator until the enemy is visible again; otherwise the old
	# baseline would interpolate across the hidden gap.
	_est_target_name = ""
	_est_velocity = Vector3.ZERO


## Wall-clock memory/search bookkeeping.  Runs at the top of every think tick so
## a hunt expires even while the bot is healing, taking cover, or fleeing.
func _tick_target_memory(now_ms: int) -> void:
	if _memory_target != null and not is_instance_valid(_memory_target):
		_clear_memory()
	if _memory_expires_ms > 0 and now_ms >= _memory_expires_ms:
		if _current_target != null and not _target_visible:
			_current_target = null
		_clear_memory()

	if _memory_grace_until_ms > 0:
		if now_ms >= _memory_grace_until_ms:
			_memory_grace_until_ms = 0
			_target_lost_timer = 0.0
			if _current_target != null and not _target_visible:
				_current_target = null
				# A sound/damage search already owns a fresher lead; do not
				# overwrite it with the older predicted point.
				if not _search_active:
					_begin_memory_search(now_ms)
		else:
			_target_lost_timer = maxf(
				float(_memory_grace_until_ms - now_ms) / 1000.0, 0.0
			)

	if _search_persistent:
		# The heard-memory search has no clock.  It ends when a target is found,
		# a new search starts, or an objective comes nearby.
		_search_timer = INF
		if _objective_is_near(player.global_position):
			_end_search()
	elif _search_active and _search_deadline_ms > 0:
		if now_ms >= _search_deadline_ms:
			_end_search()
		else:
			_search_timer = maxf(
				float(_search_deadline_ms - now_ms) / 1000.0, 0.0
			)

	# Resume the last heard enemy when nothing else owns the bot.  The memory is
	# never timed out; only a newer sound or respawn replaces it.
	if not _search_active and _current_target == null \
			and not _memory_target_valid() \
			and _persistent_heard_position != Vector3.INF \
			and not _objective_is_near(player.global_position):
		_begin_search(
			_persistent_heard_position,
			_persistent_heard_velocity,
			_persistent_heard_direction,
			true
		)


func _end_search() -> void:
	_search_active = false
	_search_persistent = false
	_search_timer = 0.0
	_search_deadline_ms = 0
	_search_direction = Vector3.ZERO
	_memory_chasing = false
	_last_seen_position = Vector3.INF
	_last_seen_time = -999.0
	_clear_hunt()


## Predicted position a runner would occupy now: frozen last-seen point plus up
## to two seconds of frozen horizontal velocity, capped at 20 m.  If there was no
## usable velocity, assume they kept going away from the bot.
func _predicted_last_known(now_ms: int) -> Vector3:
	if _memory_last_position == Vector3.INF:
		return Vector3.INF
	var age := clampf(
		float(now_ms - _memory_last_seen_ms) / 1000.0, 0.0, CHASE_PREDICT_MAX_TIME
	)
	var vel := Vector3(_memory_last_velocity.x, 0.0, _memory_last_velocity.z)
	var point := _memory_last_position
	if vel.length_squared() > 0.25:
		point += vel * age
	else:
		var away := Vector3(
			_memory_last_position.x - player.global_position.x,
			0.0,
			_memory_last_position.z - player.global_position.z
		)
		if away.length_squared() > 0.01:
			point += away.normalized() * (age * WALK_SPEED * 0.5)
	var lead := Vector2(point.x - _memory_last_position.x, point.z - _memory_last_position.z)
	if lead.length() > CHASE_LEAD_MAX_DIST:
		lead = lead.normalized() * CHASE_LEAD_MAX_DIST
		point = _memory_last_position + Vector3(lead.x, 0.0, lead.y)
	var ground := _ground_point(
		player.get_world_3d().direct_space_state, point, _memory_last_position.y
	)
	if ground == Vector3.INF:
		return _memory_last_position
	return ground


func _memory_search_direction() -> Vector3:
	var vel := Vector3(_memory_last_velocity.x, 0.0, _memory_last_velocity.z)
	if vel.length_squared() > 0.25:
		return vel.normalized()
	var away := Vector3(
		_memory_last_position.x - player.global_position.x,
		0.0,
		_memory_last_position.z - player.global_position.z
	)
	if away.length_squared() > 0.01:
		return away.normalized()
	return Vector3.ZERO


func _begin_memory_search(now_ms: int) -> void:
	if _memory_target == null or _memory_last_position == Vector3.INF:
		return
	if _memory_search_started:
		return
	_memory_search_started = true
	_memory_grace_until_ms = 0
	_target_lost_timer = 0.0
	_current_target = null
	_target_visible = false
	_memory_chasing = true
	var predicted := _predicted_last_known(now_ms)
	_begin_search(predicted, _memory_last_velocity, _memory_search_direction())


func _is_recent_attacker(target: Player) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	return str(target.name) == _last_damage_source_name \
		and float(Time.get_ticks_msec()) / 1000.0 - _last_damage_time < 5.0


## A visible enemy close enough (or threatening enough) to steal focus from a
## lost target's chase.
func _is_retarget_override(target: Player, dist: float) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	return dist <= TARGET_RETARGET_CLOSE_RANGE \
		or dist <= TARGET_EMERGENCY_RANGE \
		or _is_recent_attacker(target)


func _is_in_recall_cone(target: Player) -> bool:
	var forward := -player.body.global_transform.basis.z
	forward.y = 0.0
	var to_target := target.global_position - player.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return true
	return forward.normalized().dot(to_target.normalized()) >= _recall_fov_dot_threshold


func _think() -> void:
	var now := float(Time.get_ticks_msec()) / 1000.0
	var now_ms := Time.get_ticks_msec()
	# Never pass a freed cached target to a typed Player parameter.
	if not is_instance_valid(_current_target):
		_current_target = null
	if not is_instance_valid(_heal_target):
		_heal_target = null
	if _memory_target != null and not is_instance_valid(_memory_target):
		_clear_memory()

	# Wall-clock memory/search bookkeeping runs before any early return so a
	# hunt expires even while the bot is healing, taking cover, or fleeing.
	_tick_target_memory(now_ms)
	if _target_visible and _current_target != null:
		_update_target_velocity_estimate(_current_target, now)
	_tick_hearing(PROCESS_INTERVAL)
	_tick_glance(PROCESS_INTERVAL)
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		# A switch/reload must not erase target memory.  Release the trigger and
		# resume from the same identity when the weapon is ready again.
		_trigger.release_all()
		_has_desired_aim = false
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if debug_draw or debug_log_weapons:
		_log_weapon_once(weapon)
	var holding_heal := _weapon_heals_allies(weapon)
	var heal_index := _find_heal_weapon_index(wc)  # -1 if none in loadout

	# Target lock: between full re-scans, only re-verify the current VISIBLE
	# target (one LOS raycast) instead of the O(N) scan.  A lost-but-remembered
	# target already has frozen values and must not force a scan every tick.
	var need_rescan := _retarget_timer <= 0.0
	if not need_rescan and _heal_target != null and not _heal_target_valid():
		need_rescan = true
	if not need_rescan and _current_target != null:
		if not _target_identity_valid(_current_target):
			need_rescan = true
		elif _target_visible and not _has_line_of_sight_to_player(_current_target):
			_mark_target_unseen(_current_target, now_ms)
			need_rescan = true

	if not need_rescan:
		_retarget_timer -= PROCESS_INTERVAL
		if _current_target != null and _target_visible:
			_last_seen_position = _current_target.global_position
			_last_seen_velocity = _estimated_velocity_for(_current_target)
			_last_seen_time = now
		return

	_retarget_timer = RETARGET_INTERVAL
	_full_scan_count += 1
	var prev_target := _current_target if is_instance_valid(_current_target) else null
	var prev_visible := _target_visible and prev_target != null
	var prev_last_position := _last_seen_position
	var prev_last_velocity := _last_seen_velocity
	var memory := _memory_target if _memory_target_valid() else null
	var memory_active := memory != null and _memory_expires_ms > now_ms
	var memory_name := _memory_target_name
	var memory_visible := false
	var grace_active := memory_active and now_ms < _memory_grace_until_ms
	_current_target = null
	_target_visible = false
	_heal_target = null

	var heal_dist_sq := HEAL_RANGE * HEAL_RANGE
	var heal_best_ratio := 2.0
	_enemy_nearby = false
	_nearby_enemy_count = 0
	var visible_names: Dictionary = {}
	var visible_seen: Dictionary = {}
	var best_target: Player = null
	var best_score := -INF

	for node in get_tree().get_nodes_in_group("players"):
		var p := node as Player
		if p == null or p == player or not p.spawned:
			continue
		# Dev-menu "bots ignore me": skip both combat and heal targeting.  Bots
		# simulate only on the server, so this reads the server's copy.
		if p.dev_hidden_from_bots:
			continue
		var is_enemy := player.team == Player.Team.FFA or p.team != player.team
		var dist_sq := player.global_position.distance_squared_to(p.global_position)
		if is_enemy and dist_sq <= SAFE_TOP_OFF_RADIUS * SAFE_TOP_OFF_RADIUS:
			# A nearby enemy keeps the medic in "combat" healing mode even if
			# it is currently behind a wall or outside the FOV cone.
			_enemy_nearby = true
			# Counted before the heal-weapon continue below: a medic still feels
			# outnumbered even while holding a gun that cannot shoot.
			_nearby_enemy_count += 1

		if is_enemy:
			# A medic must still see enemies while holding the heal gun; the
			# weapon/heal state decides whether it can fire, not perception.
			# Invisible players are untargetable.
			if p.status_effect_manager and p.status_effect_manager.has_effect("invisible"):
				continue
			var name_key := str(p.name)
			var recalled := memory_active and p == memory
			var in_fov := _is_in_view_cone(p) \
				or (recalled and _is_in_recall_cone(p))
			# Already-acquired targets stay trackable outside the cone, but NEW
			# detections still require the FOV.  A remembered target gets the
			# wider recall cone instead.
			var trackable := in_fov or p == prev_target
			var visible := trackable and _has_line_of_sight_to_player(p)
			if not visible:
				# Keep recognition credit for the remembered enemy; ordinary
				# unseen players still lose theirs.
				if not recalled:
					_seen_since.erase(name_key)
				continue
			if not _seen_since.has(name_key):
				# Re-acquiring a remembered target keeps its old recognition
				# progress; the already-valid current target skips it too.
				var prior := 0.0
				if p == prev_target:
					prior = 2.0
				if recalled and _memory_seen_time > 0.0:
					prior = maxf(prior, _memory_seen_time)
				_seen_since[name_key] = now - prior
			var seen_time := now - float(_seen_since[name_key])
			visible_names[name_key] = true
			visible_seen[name_key] = seen_time
			if recalled:
				memory_visible = true
			var dist := sqrt(dist_sq)
			if not recalled:
				var recognition := _recognition_time(p, dist, in_fov)
				if seen_time < recognition:
					continue
			var score := _score_target(p, dist, seen_time, now)
			if p == prev_target:
				score += TARGET_STICKINESS
			if recalled:
				score += TARGET_RECALL_STICKINESS
			# While committed to a chase, only a close/threatening enemy may
			# steal focus; a distant bystander is not worth abandoning the runner.
			if _memory_chasing and not recalled \
					and dist > TARGET_RETARGET_CLOSE_RANGE \
					and not _is_recent_attacker(p):
				continue
			if score > best_score:
				best_score = score
				best_target = p
		elif holding_heal or heal_index >= 0:
			# Friendly heal candidate — only CRITICAL teammates.  Healing anyone
			# merely below max HP kept the medic on the heal gun forever, which
			# is why Dr. Schweizerstein never shot back.
			var ac := p.attribute_component
			if ac == null or ac.max_health <= 0.0:
				continue
			var ratio := ac.health / ac.max_health
			if ratio >= _medic_heal_threshold():
				continue
			if dist_sq < heal_dist_sq and ratio < heal_best_ratio and _has_line_of_sight_to_player(p):
				heal_best_ratio = ratio
				_heal_target = p

	_visible_enemy_count = visible_names.size()

	# Drop recognition clocks for anyone no longer visible, except the remembered
	# target: it keeps its identity/recognition until the memory expires.
	for key in _seen_since.keys():
		if visible_names.has(key):
			continue
		if memory_active and key == memory_name:
			continue
		_seen_since.erase(key)

	# The timer-driven scan can discover that the old target was lost even when
	# the between-scan LOS check was not the one that noticed it.
	if prev_target != null and prev_visible \
			and not visible_names.has(str(prev_target.name)):
		if _target_identity_valid(prev_target):
			_mark_target_unseen(
				prev_target, now_ms, prev_last_position, prev_last_velocity
			)
			memory = _memory_target if _memory_target_valid() else null
			memory_active = memory != null and _memory_expires_ms > now_ms
			memory_name = _memory_target_name
			grace_active = memory_active and now_ms < _memory_grace_until_ms
			memory_visible = false
		else:
			_clear_memory()
			memory = null
			memory_active = false
			grace_active = false

	# A heal under fire is not a heal.  Abort it before the hysteresis so the
	# damage weapon can come back out immediately.  `best_target` is this scan's
	# visible enemy; `_current_target` is not assigned yet.
	var enemy_close := best_target != null and is_instance_valid(best_target) \
		and player.global_position.distance_to(best_target.global_position) < 12.0
	if _heal_target != null and (not _heal_is_safe() or enemy_close):
		_heal_target = null
		_heal_candidate_name = ""
		_heal_candidate_time = 0.0
		_heal_absent_time = maxf(_heal_absent_time, MEDIC_HEAL_ABSENT)
		if holding_heal:
			var damage_index := _first_damage_weapon_index(wc)
			if damage_index >= 0 and _switch_weapon(wc, damage_index):
				holding_heal = false

	# Medic behaviour with hysteresis: a heal candidate must persist before the
	# heal gun comes out, and must be absent for a while before it goes away.
	var needs_self_heal := _health_ratio() < MEDIC_SELF_HEAL_THRESHOLD
	var has_self_heal_weapon := _find_self_heal_weapon_index(wc) >= 0
	var heal_name := ""
	if _heal_target != null and is_instance_valid(_heal_target):
		heal_name = str(_heal_target.name)
	if heal_name.is_empty():
		_heal_candidate_name = ""
		_heal_candidate_time = 0.0
		_heal_absent_time = minf(_heal_absent_time + RETARGET_INTERVAL, 10.0)
	else:
		_heal_absent_time = 0.0
		if _heal_candidate_name == heal_name:
			_heal_candidate_time = minf(_heal_candidate_time + RETARGET_INTERVAL, 10.0)
		else:
			_heal_candidate_name = heal_name
			_heal_candidate_time = 0.0
	var self_heal_exception := needs_self_heal and has_self_heal_weapon
	if holding_heal and _heal_target == null and heal_index >= 0 \
			and _heal_absent_time >= MEDIC_HEAL_ABSENT \
			and not self_heal_exception:
		_switch_weapon(wc, _first_damage_weapon_index(wc))
	elif not holding_heal and heal_index >= 0 and _heal_target != null \
			and _heal_candidate_time >= MEDIC_HEAL_PERSIST \
			and _heal_is_safe():
		var ac := _heal_target.attribute_component
		if ac != null and ac.health / ac.max_health < _medic_heal_threshold():
			if _switch_weapon(wc, heal_index):
				best_target = null  # don't fight while healing

	if _heal_target != null and _heal_is_safe():
		var healing_weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if _weapon_heals_allies(healing_weapon):
			best_target = null

	# Switch cost: keep the current target unless the new one is clearly better.
	# Only a target that was visible when the scan started can be compared; an
	# unseen remembered target has no live score.
	if best_target != null and prev_target != null and best_target != prev_target \
			and prev_visible and visible_names.has(str(prev_target.name)):
		var prev_name := str(prev_target.name)
		var prev_seen := float(visible_seen.get(prev_name, 0.5))
		var prev_score := _score_target(
			prev_target,
			player.global_position.distance_to(prev_target.global_position),
			prev_seen,
			now
		) + TARGET_STICKINESS
		if best_score < prev_score + TARGET_SWITCH_MARGIN:
			best_target = prev_target
			best_score = prev_score

	# While the old target is only remembered, a visible enemy steals focus only
	# when it is close/threatening.  Otherwise commit to the chase.
	if best_target != null and memory != null and memory_active and not memory_visible:
		var best_dist := player.global_position.distance_to(best_target.global_position)
		if (grace_active or _memory_chasing) \
				and not _is_retarget_override(best_target, best_dist):
			best_target = null

	# Anti-ping-pong: a target acquired very recently keeps focus unless a
	# challenger is an emergency or just shot us.  This is evaluated only while
	# the previous target is still visible; an unseen target does not lock out a
	# real threat.
	if best_target != null and best_target != prev_target and prev_visible \
			and visible_names.has(str(prev_target.name)) \
			and now_ms < _target_lock_until_ms:
		var best_dist := player.global_position.distance_to(best_target.global_position)
		if best_dist > TARGET_EMERGENCY_RANGE and not _is_recent_attacker(best_target):
			best_target = prev_target

	if best_target != null:
		_current_target = best_target
		_target_visible = true
		var switched := best_target != prev_target
		if switched:
			_target_lock_until_ms = now_ms + int(TARGET_SWITCH_COOLDOWN * 1000.0)
		var name_key := str(best_target.name)
		_memory_target = best_target
		_memory_target_name = name_key
		_memory_last_position = best_target.global_position
		_memory_last_velocity = _estimated_velocity_for(best_target)
		_memory_last_seen_ms = now_ms
		_memory_seen_time = maxf(float(visible_seen.get(name_key, 0.0)), 0.0)
		_memory_expires_ms = now_ms + int(_target_memory_window() * 1000.0)
		_memory_grace_until_ms = 0
		_memory_chasing = false
		_memory_search_started = false
		_target_lost_timer = 0.0
		_search_active = false
		_search_persistent = false
		_search_timer = 0.0
		_search_deadline_ms = 0
		_search_direction = Vector3.ZERO
		_clear_hunt()
		_last_seen_position = best_target.global_position
		_last_seen_velocity = _estimated_velocity_for(best_target)
		_last_seen_time = now
		if switched or not prev_visible:
			# Restart the velocity baseline after a hidden gap; it would otherwise
			# interpolate across the gap and produce a bogus lead.
			_est_target_name = ""
			_update_target_velocity_estimate(best_target, now)
		if switched:
			# A newly acquired/switched target outranks any scripted maneuver and
			# pays a small re-aim cost on top of the normal reaction time.
			_maneuvers.abort()
			_combat_range_state = CombatRangeState.HOLD
			_combat_pattern = CombatPattern.WIDE
			_combat_settle_timer = 0.0
			_combat_stall_timer = 0.0
			_combat_stall_position = player.global_position
			var reaction := REACTION_TIME_MAX * (1.0 - skill)
			if _style != null:
				reaction = _style.reaction_time
			var switch_cost := 0.0 if prev_target == null else reaction * randf_range(0.6, 1.2)
			_reaction_timer = maxf(_reaction_timer, reaction * randf_range(0.8, 1.2) + switch_cost)
			if _decision.state != Decision.State.FLEE:
				_decision.interrupt(Decision.State.COMBAT)
		elif not prev_visible and _decision.state != Decision.State.FLEE:
			# Re-spotted the same enemy after a hidden gap: no full recognition,
			# but leave a stale SEARCH immediately.
			_decision.interrupt(Decision.State.COMBAT)
	elif memory != null and memory_active:
		if grace_active:
			# Hold the alert against the last-known angle.  `_act_combat` sees
			# `_target_visible == false` and will not fire or track the live body.
			_current_target = memory
			_target_visible = false
		elif not _search_active:
			_begin_memory_search(now_ms)
	else:
		_current_target = null
		_target_visible = false

	_refresh_los_excludes()


## Smoothed target velocity sampled from position over time.  Deliberately not
## `target.velocity`: that is the simulation's instantaneous value (and can be a
## rollback-corrected value), while a human reads motion over ~0.2 s.
func _update_target_velocity_estimate(target: Player, now: float) -> void:
	if target == null or not is_instance_valid(target) or not target.spawned:
		_est_target_name = ""
		_est_velocity = Vector3.ZERO
		return
	var target_name := str(target.name)
	var pos := target.global_position
	if target_name != _est_target_name:
		_est_target_name = target_name
		_est_last_position = pos
		_est_last_time = now
		_est_velocity = Vector3.ZERO
		return
	var dt := now - _est_last_time
	if dt < 0.025 or dt > 0.6:
		# Too soon for a stable sample, or the stale gap (target lost/reacquired)
		# makes the old velocity meaningless.
		_est_last_position = pos
		_est_last_time = now
		if dt > 0.6:
			_est_velocity = Vector3.ZERO
		return
	var sample := (pos - _est_last_position) / dt
	# Reversal damping: a strafe change makes the single-frame sample point the
	# other way.  Bleed the stale estimate first instead of averaging through
	# the turn, which would keep aiming where the target no longer is.
	if sample.length_squared() > 0.01 and _est_velocity.length_squared() > 0.01 \
			and sample.dot(_est_velocity) < 0.0:
		_est_velocity *= VELOCITY_REVERSAL_DAMP
	var alpha := 1.0 - exp(-dt / VELOCITY_ESTIMATE_SMOOTH)
	_est_velocity = _est_velocity.lerp(sample, alpha)
	# Guard against teleports/respawns producing an absurd lead.
	if _est_velocity.length() > 20.0:
		_est_velocity = _est_velocity.normalized() * 20.0
	_est_last_position = pos
	_est_last_time = now


func _estimated_velocity_for(target: Player) -> Vector3:
	if target != null and is_instance_valid(target) \
			and str(target.name) == _est_target_name:
		return _est_velocity
	if target != null and is_instance_valid(target):
		return target.velocity
	return Vector3.ZERO


func _current_lead_quality() -> float:
	return _style.lead_quality if _style != null else 0.5

# Line-of-sight

## True if the bot can see any reasonable part of [param target] — checks the
## head bone first (same point the bot aims at), then falls back to a chest-
## height point. A single fixed chest-height check was too strict: a target
## peeking with just their head over cover, or one whose chest happens to
## clip a thin bit of geometry, would wrongly count as "not visible" even
## though a human could plainly see them.
func _has_line_of_sight_to_player(target: Player) -> bool:
	var space := player.get_world_3d().direct_space_state
	var origin := _head_node.global_position

	_los_query.from = origin
	_los_query.to = _get_head_position(target)
	if space.intersect_ray(_los_query).is_empty():
		return true

	# Fallback is a standing body centre, not shin height: the old 0.5 m point
	# let bots see over low cover that a human could not see through.
	var body_pos := target.global_position + Vector3.UP * AIM_CENTER_HEIGHT
	_los_query.from = origin
	_los_query.to = body_pos
	return space.intersect_ray(_los_query).is_empty()


## Rebuild the LOS query's exclude array only when the target pair changes.
## The current collision mask is world-only (players cannot block LOS), but this
## keeps the query safe if a future map or mask change makes player bodies
## occluders — and it never allocates per ray.
func _refresh_los_excludes() -> void:
	var key := ""
	if _current_target != null and is_instance_valid(_current_target):
		key += str(_current_target.get_instance_id())
	key += "|"
	if _heal_target != null and is_instance_valid(_heal_target):
		key += str(_heal_target.get_instance_id())
	if key == _los_targets_key:
		return
	_los_targets_key = key

	_los_exclude_rids.clear()
	_los_exclude_rids.append(player.get_rid())
	if _current_target != null and is_instance_valid(_current_target):
		_los_exclude_rids.append(_current_target.get_rid())
	if _heal_target != null and is_instance_valid(_heal_target) and _heal_target != _current_target:
		_los_exclude_rids.append(_heal_target.get_rid())
	_los_query.exclude = _los_exclude_rids
	_shot_query.exclude = _los_exclude_rids


## Whether [param target] is on an opposing team (or everyone, in FFA).
func _is_enemy_of(target: Player) -> bool:
	return player.team == Player.Team.FFA or target.team != player.team


## True when [param target] is inside the bot's forward field-of-view cone
## (horizontal only — pitch is ignored so bots still notice enemies on ledges).
func _is_in_view_cone(target: Player) -> bool:
	var forward := -player.body.global_transform.basis.z
	forward.y = 0.0
	var to_target := target.global_position - player.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return true  # directly overhead/underfoot — don't reject
	return forward.normalized().dot(to_target.normalized()) >= _fov_dot_threshold


## True if any fire mode on [param weapon] fires a projectile that heals allies.
func _weapon_heals_allies(weapon: Weapon) -> bool:
	if weapon == null:
		return false
	for fire in weapon.weapon_fires:
		if _fire_heals_allies(fire):
			return true
	return false


func _fire_heals_allies(fire: WeaponFire) -> bool:
	if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT or fire.bullet_type != WeaponFire.BulletType.PROJECTILE:
		return false
	var info := _get_proj_info(fire)
	if bool(info.get("heals_allies", false)):
		return true
	# Explosion-based team heal.  The Heal Grenade Launcher's hitbox does no
	# healing; its blast is `splash -45 x team multiplier -1` = +45 to allies.
	return float(info.get("team_heal", 0.0)) > 0.0


## True when [param fire] can restore the SHOOTER's health: either a positive
## explosion self-heal (Heal Grenade Launcher) or a positive hitbox heal that is
## allowed to hit the shooter (healthpack).
func _fire_can_heal_shooter(fire: WeaponFire) -> bool:
	if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT \
			or fire.bullet_type != WeaponFire.BulletType.PROJECTILE:
		return false
	var info := _get_proj_info(fire)
	return float(info.get("self_damage", -1.0)) > 0.0 \
		or bool(info.get("heals_shooter", false))


func _weapon_can_heal_shooter(weapon: Weapon) -> bool:
	if weapon == null:
		return false
	for fire in weapon.weapon_fires:
		if _fire_can_heal_shooter(fire):
			return true
	return false


## Index of a loaded weapon that can heal its own shooter, or -1.
func _find_self_heal_weapon_index(wc: WeaponController) -> int:
	for i in wc._weapons.size():
		var weapon: Weapon = wc._weapons[i]
		if weapon == null or not _weapon_can_heal_shooter(weapon):
			continue
		if not wc.weapon_has_infinite_ammo(weapon) and weapon.mag_current <= 0:
			continue
		return i
	return -1


## Fire-mode index on [param weapon] that heals the shooter (Medpack Launcher's
## healthpack, not its poisoned variant; the Heal Grenade Launcher's single
## channel).
func _select_self_heal_fire_index(weapon: Weapon) -> int:
	for index in _shoot_indices_for(weapon):
		var fire: WeaponFire = weapon.weapon_fires[index]
		if _fire_can_heal_shooter(fire):
			return index
	return -1


func _health_ratio() -> float:
	var ac := player.attribute_component
	if ac == null or ac.max_health <= 0.0:
		return 1.0
	return ac.health / ac.max_health


## Teammate heal threshold: 90% in combat, 100% once the area has been quiet
## long enough to safely top someone off.
func _medic_heal_threshold() -> float:
	return 1.0 if _safe_to_top_off() else MEDIC_HEAL_THRESHOLD


func _safe_to_top_off() -> bool:
	return _safe_top_off_timer >= SAFE_TOP_OFF_DELAY


func _find_heal_weapon_index(wc: WeaponController) -> int:
	for i in wc._weapons.size():
		if _weapon_heals_allies(wc._weapons[i]):
			return i
	return -1


func _first_damage_weapon_index(wc: WeaponController) -> int:
	for i in wc._weapons.size():
		if not _weapon_heals_allies(wc._weapons[i]):
			return i
	return wc.current_weapon_index


## Introspect a projectile/fire once (cached by scene path) for its muzzle
## speed, whether its hitbox heals allies, and whether it splashes/explodes.
## Never instantiates the same scene twice.
##
## THE PROJECTILE-LEAD BUG: this used to read `linear_velocity` off a
## freshly-instantiated, never-added-to-tree projectile. A RigidBody3D's
## linear_velocity is 0 until gameplay code sets it *after* the projectile is
## actually fired (typically once it's added to the tree) — instantiate()
## alone never reaches that point, and _ready() doesn't even run on a node
## that's never entered the tree. So `speed` was reading 0.0 on every single
## call, `speed > 1.0` in the old prediction helper was always false, and no lead
## was ever applied — bots aimed straight at the target's current position
## with zero prediction, which reads exactly like "leading doesn't work"
## against anyone strafing. Fixed by preferring a value that's actually
## available at construction time: an exported speed on the WeaponFire
## resource itself, or failing that an exported default on the projectile's
## own script (verify the property names below match your actual
## WeaponFire/projectile scripts — adjust if they differ).
func _get_proj_info(fire: WeaponFire) -> Dictionary:
	if fire == null or fire.projectile_scene == null:
		return {}
	var path := fire.projectile_scene.resource_path
	if _proj_cache.has(path):
		return _proj_cache[path]

	# `speed_source` records WHICH probe actually answered, so debug_log_weapons
	# can report the truth instead of leaving the next stage to guess again.
	var info := {
		"speed": 0.0,
		"speed_source": "none",
		## World-space downward acceleration at launch.  Read from the scene's
		## `gravity_scale`; rockets are 0, grenades/arrows use 9.8, gravity rocket 14.7.
		"gravity": float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)),
		"lifetime": 20.0,
		"splash_radius": 0.0,
		## Damage dealt by a direct hit / by the blast.  These are read from the
		## projectile's own HitboxComponent and ExplosionComponent because a
		## projectile's WeaponFire has no damage field of its own.  Used only for
		## the AI's DPS proxy, so a grenade is not judged by the default 10 damage
		## `hitscan_damage` value it never fires.
		"impact_damage": 0.0,
		"splash_damage": 0.0,
		## Negative = the blast hurts the shooter, positive = it heals them.
		## Heal Grenade Launcher is +45; every rocket/grenade is negative.
		"self_damage": -1.0,
		"script_path": "",
		## True for projectile scripts that redirect on SIGNAL (they store the
		## authored speed in `_initial_speed`); false for the base exploder.
		"has_redirect_marker": false,
		## How the projectile can detonate.  A grenade that passes through world
		## geometry (explodes_on_world == false) must hit the body; a rocket that
		## explodes on contact can be aimed at the ground for splash.
		"explodes_on_world": false,
		## WorldHitMode.NOTHING: the round passes through geometry, so a wall is
		## not an obstruction to validate against.
		"world_passthrough": false,
		"explodes_on_hurtbox": false,
		"explodes_on_timeout": false,
		"heals_allies": false,
		## Positive hitbox heal that may hit the shooter (healthpack), or a
		## positive explosion team-heal (Heal Grenade Launcher).
		"heals_shooter": false,
		"team_heal": 0.0,
		"is_explosive": false,
	}

	# Prefer speed declared on the fire config itself — it's the value the
	# weapon actually fires with and needs no scene instantiation at all.
	var fire_speed_info := _read_prop_ex(fire, PROP_FIRE_LAUNCH_SPEED, null, "WeaponFire launch speed")
	var fire_speed: Variant = fire_speed_info["value"]

	var proj := fire.projectile_scene.instantiate() as Node3D
	if proj != null:
		var proj_script := proj.get_script() as Script
		if proj_script != null:
			info["script_path"] = proj_script.resource_path
		# Redirect projectiles (arrow.gd / redirectable_rocket.gd) capture their
		# authored speed in `_initial_speed` and write it back on SIGNAL.  That
		# is the behavioural marker separating them from the base
		# SimpleProjectile handler, which explodes instead.
		info["has_redirect_marker"] = proj.get("_initial_speed") != null
		if fire_speed != null:
			info["speed"] = float(fire_speed)
			info["speed_source"] = "WeaponFire." + str(fire_speed_info["source"])
		else:
			var proj_speed_info := _read_prop_ex(proj, PROP_PROJECTILE_LAUNCH_SPEED, null, "Projectile launch speed")
			var exported_speed: Variant = proj_speed_info["value"]
			if exported_speed != null:
				info["speed"] = float(exported_speed)
				info["speed_source"] = "Projectile." + str(proj_speed_info["source"])
			else:
				# Last-resort fallback — kept only so this doesn't regress to
				# a hard 0 if nothing above matched.  This is the only read that
				# sees a RigidBody3D's authored `linear_velocity` from the .tscn,
				# which is where most of this project's launch speeds live.
				var lv_info := _read_prop_ex(proj, PROP_LINEAR_VELOCITY, null, "Projectile.linear_velocity")
				var lv: Variant = lv_info["value"]
				if lv is Vector3:
					info["speed"] = (lv as Vector3).length()
					info["speed_source"] = "Projectile.linear_velocity"

			var gravity_scale_info := _read_prop_ex(
				proj, PROP_GRAVITY_SCALE, 1.0, "Projectile.gravity_scale"
			)
			var gravity_scale: float = float(gravity_scale_info["value"])
			var world_gravity: float = float(
				ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
			)
			info["gravity"] = world_gravity * gravity_scale

		# A scene with no statically readable speed uses the runtime measurement
		# (shared across bots), and a conservative value until that lands.
		if float(info["speed"]) <= 1.0:
			var learned: Variant = _learned_proj_speeds.get(path)
			if learned != null:
				info["speed"] = float(learned)
				info["speed_source"] = "measured"
			else:
				info["speed"] = PROJECTILE_FALLBACK_SPEED
				info["speed_source"] = "conservative fallback"

		var hb := proj.get_node_or_null("HitboxComponent") as HitboxComponent
		if hb != null:
			info["heals_allies"] = hb.health_delta > 0.0 and hb.can_hit_other_teamates
			info["heals_shooter"] = hb.health_delta > 0.0 and hb.can_hit_shooter
			# Positive health_delta is a heal, not damage; do not score it as DPS.
			info["impact_damage"] = maxf(-hb.health_delta, 0.0)

		# Flight time, used for a projectile mode's effective range.
		var lifetime: Variant = _read_prop(proj, PROP_LIFETIME, 20.0, "Projectile.lifetime")
		if lifetime != null:
			info["lifetime"] = float(lifetime)

		# TRAP verified in Stage 0: every projectile scene inherits
		# simple_projectile.tscn, which SHIPS an ExplosionComponent.  Node
		# presence is therefore not evidence of explosion — an arrow, ball,
		# syringe and rock all carry one.  A projectile only really explodes
		# when a hit mode says EXPLODE or it explodes on timeout.  (A mine
		# sticks and detonates only from the weapon's SIGNAL fire, so it is
		# deliberately not "explosive" for aiming/self-damage purposes.)
		var explosion_node := proj.get_node_or_null("ExplosionComponent")
		if explosion_node == null:
			explosion_node = proj.get_node_or_null("SplashComponent")
		if explosion_node != null:
			var splash_radius: Variant = _read_prop(explosion_node, PROP_SPLASH_RADIUS, null, "ExplosionComponent.splash_radius")
			if splash_radius != null:
				info["splash_radius"] = float(splash_radius)
			var splash_delta: Variant = _read_prop(explosion_node, PROP_SPLASH_HEALTH_DELTA, null, "ExplosionComponent.splash_health_delta")
			var self_mult: Variant = _read_prop(explosion_node, PROP_SELF_HEALTH_MULT, null, "ExplosionComponent.self_health_delta_multiplier")
			if splash_delta != null and self_mult != null:
				info["self_damage"] = float(splash_delta) * float(self_mult)
			var team_mult: Variant = _read_prop(explosion_node, PROP_TEAM_HEALTH_MULT, null, "ExplosionComponent.team_health_delta_multiplier")
			if splash_delta != null and team_mult != null:
				info["team_heal"] = float(splash_delta) * float(team_mult)
			var hurt_mode: Variant = _read_prop(proj, PROP_HURTBOX_HIT_MODE, null, "Projectile.hurtbox_hit_mode")
			var world_mode: Variant = _read_prop(proj, PROP_WORLD_HIT_MODE, null, "Projectile.world_hit_mode")
			var timeout: Variant = _read_prop(proj, PROP_EXPLODE_ON_TIMEOUT, null, "Projectile.explode_on_timeout")
			var on_hurtbox: bool = hurt_mode != null \
				and int(hurt_mode) == SimpleProjectile.HurtboxHitMode.EXPLODE
			var on_world: bool = world_mode != null \
				and int(world_mode) == SimpleProjectile.WorldHitMode.EXPLODE
			var on_timeout: bool = timeout is bool and timeout
			info["explodes_on_hurtbox"] = on_hurtbox
			info["explodes_on_world"] = on_world
			info["world_passthrough"] = world_mode != null \
				and int(world_mode) == SimpleProjectile.WorldHitMode.NOTHING
			info["explodes_on_timeout"] = on_timeout
			info["is_explosive"] = on_hurtbox or on_world or on_timeout
			# Only count splash damage for a projectile that actually detonates.
			# Every projectile inherits an ExplosionComponent, so presence is not
			# enough (arrows, syringes and balls carry one but never use it).
			if info["is_explosive"] and splash_delta != null:
				info["splash_damage"] = maxf(-float(splash_delta), 0.0)

		proj.free()
	_proj_cache[path] = info
	return info


## Watch projectiles entering the world and measure their muzzle speed from two
## physics-frame position samples.  This is a fallback only: every current
## projectile scene exposes `linear_velocity`, but a future custom scene may not.
## The cache is static, so the first projectile of a given scene pays the cost and
## every bot afterwards uses the learned value.
func _on_node_added(node: Node) -> void:
	if not multiplayer.is_server() or not player.spawned:
		return
	if not node is SimpleProjectile:
		return
	var proj := node as SimpleProjectile
	var path := proj.scene_file_path
	if path.is_empty() or _learned_proj_speeds.has(path) \
			or _proj_speed_measurements.has(path):
		return
	_proj_speed_measurements[path] = true
	_measure_projectile_speed(proj, path)


func _measure_projectile_speed(proj: SimpleProjectile, path: String) -> void:
	var start := proj.global_position
	var start_us := Time.get_ticks_usec()
	# Two physics frames gives a baseline long enough to beat per-frame jitter
	# without letting gravity dominate the horizontal launch speed.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(proj) and not proj.is_queued_for_deletion():
		var dt := float(Time.get_ticks_usec() - start_us) / 1_000_000.0
		var distance := start.distance_to(proj.global_position)
		if dt > 0.005 and distance > 0.01:
			_learned_proj_speeds[path] = distance / dt
			# Any bot that cached the conservative default must refresh.
			for bot in get_tree().get_nodes_in_group("bot_controllers"):
				if bot is BotController:
					(bot as BotController)._proj_cache.clear()
	_proj_speed_measurements.erase(path)


## Range/role facts for one SHOOT fire mode.  Verified fields only:
## `hitscan_range`, the damage-falloff band, `bullet_type`, `automatic`,
## `post_shoot_delay`, and the cached projectile info.
func _fire_range_info(fire: WeaponFire) -> Dictionary:
	if fire == null:
		return {}
	var info := {
		"melee": false,
		"explosive": false,
		"hitscan": fire.bullet_type == WeaponFire.BulletType.HITSCAN,
		"projectile": fire.bullet_type == WeaponFire.BulletType.PROJECTILE,
		"automatic": fire.automatic,
		"range_hard": 0.0,
		"range_effective": 0.0,
		"range_ideal": 0.0,
		"cooldown": maxf(fire.post_shoot_delay, 0.05),
		"dps": 0.0,
		"splash_radius": 0.0,
		"self_damage": 0.0,
		"heals_allies": false,
		"heals_shooter": false,
		"falloff_start": fire.falloff_start,
		"falloff_end": fire.falloff_end,
	}
	var is_melee: bool = fire.bullet_type == WeaponFire.BulletType.HITSCAN \
		and fire.hitscan_range <= MELEE_CONSIDER_RANGE
	info["melee"] = is_melee

	if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		var proj := _get_proj_info(fire)
		var speed := float(proj.get("speed", 0.0))
		var lifetime := float(proj.get("lifetime", 20.0))
		var hard := clampf(speed * lifetime, 2.0, SHOOT_RANGE)
		info["range_hard"] = hard
		info["range_effective"] = hard
		info["range_ideal"] = clampf(
			minf(hard, MAX_SENSIBLE_RANGE) * 0.72, 3.0, 45.0
		)
		info["explosive"] = bool(proj.get("is_explosive", false))
		info["splash_radius"] = float(proj.get("splash_radius", 0.0))
		info["self_damage"] = float(proj.get("self_damage", 0.0))
		info["heals_allies"] = bool(proj.get("heals_allies", false)) \
			or float(proj.get("team_heal", 0.0)) > 0.0
		info["heals_shooter"] = float(proj.get("self_damage", 0.0)) > 0.0 \
			or bool(proj.get("heals_shooter", false))
	elif is_melee:
		var hard := maxf(fire.hitscan_range, 0.5)
		info["range_hard"] = hard
		info["range_effective"] = hard
		info["range_ideal"] = MELEE_ENGAGE_RANGE
	elif fire.has_damage_falloff and fire.falloff_end > fire.falloff_start:
		var hard := SHOOT_RANGE
		if fire.hitscan_range < 1.0e8:
			hard = clampf(fire.hitscan_range, 2.0, SHOOT_RANGE)
		info["range_hard"] = hard
		info["range_effective"] = clampf(fire.falloff_end, 2.0, SHOOT_RANGE)
		info["range_ideal"] = clampf(
			lerpf(fire.falloff_start, fire.falloff_end, 0.65), 2.0, 45.0
		)
	else:
		var hard := SHOOT_RANGE
		if fire.hitscan_range < 1.0e8:
			hard = clampf(fire.hitscan_range, 2.0, SHOOT_RANGE)
		info["range_hard"] = hard
		info["range_effective"] = hard
		info["range_ideal"] = clampf(
			minf(hard, MAX_SENSIBLE_RANGE) * 0.72, 2.0, 45.0
		)

	var shots := 1
	if fire.multishot_mode == WeaponFire.MultishotMode.SHOTGUN:
		shots = maxi(1, fire.multishot_data.size())
	# A projectile does not use `hitscan_damage`; its damage lives on the spawned
	# scene.  Take the larger of a direct hit and the blast so a grenade/rocket is
	# scored on what it actually does rather than on the 10-damage default.
	var damage_per_shot := fire.hitscan_damage
	if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		var proj := _get_proj_info(fire)
		damage_per_shot = maxf(
			float(proj.get("impact_damage", 0.0)),
			float(proj.get("splash_damage", 0.0))
		)
	info["dps"] = damage_per_shot * float(shots) \
		/ maxf(float(info["cooldown"]), 0.05)
	return info


func _weapon_profile_key(weapon: Weapon) -> String:
	if weapon == null:
		return ""
	if not weapon.resource_path.is_empty():
		return weapon.resource_path
	return "instance:" + str(weapon.get_instance_id())


## Cached, scene-free weapon profile.  This is the single place weapon-choice,
## reload, fire-mode and explosion-jump decisions read range/role data from.
func _get_weapon_profile(weapon: Weapon) -> Dictionary:
	if weapon == null:
		return {}
	var key := _weapon_profile_key(weapon)
	if _weapon_profile_cache.has(key):
		return _weapon_profile_cache[key]

	var profile := {
		"melee": false,
		"explosive": false,
		"hitscan": false,
		"projectile": false,
		"charged": weapon.charged,
		"automatic": false,
		"heals_allies": false,
		"heals_shooter": false,
		"range_hard": 0.0,
		"range_effective": 0.0,
		"range_ideal": 0.0,
		"cooldown": 0.5,
		"dps": 0.0,
		"mag_size": weapon.mag_size,
		"reload_time": weapon.reload_time,
		"switch_time": weapon.pullout_time + weapon.put_away_time,
		"infinite_ammo": weapon.has_infinite_ammo,
		"fire_count": 0,
		"best_fire_index": -1,
		"splash_radius": 0.0,
		"self_damage": 0.0,
	}
	var best_dps := -INF
	var all_melee := true
	for i in weapon.weapon_fires.size():
		var fire: WeaponFire = weapon.weapon_fires[i]
		if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
			continue
		var info := _fire_range_info(fire)
		if info.is_empty():
			continue
		profile["fire_count"] = int(profile["fire_count"]) + 1
		all_melee = all_melee and bool(info["melee"])
		profile["explosive"] = bool(profile["explosive"]) or bool(info["explosive"])
		profile["hitscan"] = bool(profile["hitscan"]) or bool(info["hitscan"])
		profile["projectile"] = bool(profile["projectile"]) or bool(info["projectile"])
		profile["automatic"] = bool(profile["automatic"]) or bool(info["automatic"])
		profile["heals_allies"] = bool(profile["heals_allies"]) or bool(info["heals_allies"])
		profile["heals_shooter"] = bool(profile["heals_shooter"]) or bool(info["heals_shooter"])
		profile["range_hard"] = maxf(float(profile["range_hard"]), float(info["range_hard"]))
		profile["range_effective"] = maxf(
			float(profile["range_effective"]), float(info["range_effective"])
		)
		profile["cooldown"] = minf(float(profile["cooldown"]), float(info["cooldown"]))
		var dps := float(info["dps"])
		if dps > best_dps:
			best_dps = dps
			profile["dps"] = dps
			profile["range_ideal"] = float(info["range_ideal"])
			profile["best_fire_index"] = i
			profile["splash_radius"] = float(info["splash_radius"])
			profile["self_damage"] = float(info["self_damage"])
	if int(profile["fire_count"]) == 0 or float(profile["range_effective"]) <= 0.0:
		profile["range_hard"] = DEFAULT_RANGED_ENGAGE_DIST
		profile["range_effective"] = DEFAULT_RANGED_ENGAGE_DIST
		profile["range_ideal"] = DEFAULT_RANGED_ENGAGE_DIST
	profile["melee"] = int(profile["fire_count"]) > 0 and all_melee
	_weapon_profile_cache[key] = profile
	return profile


## Damage multiplier a hitscan mode still has at [param dist].  Reads the
## authored falloff curve exactly like WeaponController._compute_falloff_multiplier.
## A rising curve (the sniper's 0.095 -> 1.0) means "bad up close", not "bad far".
func _best_falloff_multiplier_at(weapon: Weapon, dist: float) -> float:
	if weapon == null:
		return 1.0
	var best := 0.0
	var found := false
	for i in weapon.weapon_fires.size():
		var fire: WeaponFire = weapon.weapon_fires[i]
		if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
			continue
		found = true
		if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
			return 1.0
		if not fire.has_damage_falloff or fire.falloff_curve == null \
				or fire.falloff_curve.curve == null:
			return 1.0
		var t := 0.0
		if fire.falloff_end != fire.falloff_start:
			t = (dist - fire.falloff_start) / (fire.falloff_end - fire.falloff_start)
		t = clampf(t, 0.0, 1.0)
		best = maxf(best, fire.falloff_curve.curve.sample(t))
	return best if found else 1.0


## "Viable" means the weapon can reach the target AND still deals a meaningful
## fraction of its peak damage there.  A sniper at knife range (0.095x) fails;
## a grenade launcher (no falloff) passes.  This is per-weapon so the choice loop
## can also tell that the *current* gun is the one that became useless.
func _weapon_damage_viable_at(weapon: Weapon, dist: float) -> bool:
	if weapon == null or _weapon_heals_allies(weapon):
		return false
	if not _weapon_can_engage(weapon, dist):
		return false
	if _is_melee_weapon(weapon):
		return true
	var profile := _get_weapon_profile(weapon)
	if bool(profile.get("explosive", false)) \
			and float(profile.get("self_damage", 0.0)) < 0.0 \
			and not _accept_self_damage(profile) \
			and dist < float(profile.get("splash_radius", 0.0)) + EXPLOSIVE_SAFE_MARGIN:
		# Point-blank with an explosive that would put us near death is not
		# "viable", even though DPS/range look fine.  A healthy bot keeps it.
		return false
	if bool(profile.get("projectile", false)):
		# Projectile damage falloff is handled by SimpleProjectile itself and is
		# not the hitscan curve; range alone is the useful test here.
		return true
	return _best_falloff_multiplier_at(weapon, dist) >= PRIMARY_MIN_DAMAGE_MULT


## Is the slot-0 weapon worth keeping out?  A grenade launcher keeping the bonus
## is what stops a bot abandoning it for a nominally higher-DPS pistol.
func _primary_viable_at(dist: float) -> bool:
	var wc: WeaponController = player.weapon_controller
	if wc == null or not is_instance_valid(wc) or wc._weapons.is_empty():
		return false
	return _weapon_damage_viable_at(wc._weapons[0], dist)


## Score a weapon for the current target distance.  Higher is better.  Melee is
## only ever viable inside its real hitscan reach; falloff makes a huge
## `hitscan_range` irrelevant past `falloff_end`.
func _weapon_situation_score(weapon: Weapon, dist: float, has_target: bool,
		slot: int = -1) -> float:
	var profile := _get_weapon_profile(weapon)
	if profile.is_empty():
		return -INF
	var score := 40.0
	var primary_viable := _primary_viable_at(dist)
	if bool(profile["melee"]):
		var reach := float(profile["range_effective"]) + WEAPON_MELEE_ONLY_MARGIN
		if not has_target:
			score -= 80.0
		elif dist > reach:
			score -= 500.0 + (dist - reach) * 10.0
		else:
			score += 35.0
			# The sniper's close-range tail is weaker than a knife; reward the
			# melee swap only while the primary is genuinely bad at this range.
			if slot != 0 and not primary_viable:
				score += MELEE_USELESS_PRIMARY_BONUS
	else:
		var effective := float(profile["range_effective"])
		var ideal := float(profile["range_ideal"])
		if has_target:
			if dist > effective:
				score -= 120.0 + (dist - effective) * 3.0
			else:
				var fit := 1.0 - clampf(
					absf(dist - ideal) / maxf(ideal, 1.0), 0.0, 1.0
				)
				score += 45.0 * fit
			# Self-splash safety uses the projectile's actual blast radius, not a
			# fraction of its ideal range.  The old `dist < ideal * 0.45` check
			# treated a 3 m grenade as dangerous out to ~13 m and made every
			# secondary explosive look worthless at normal combat distance.
			if bool(profile["explosive"]) \
					and float(profile["self_damage"]) < 0.0 \
					and not _accept_self_damage(profile):
				var danger := float(profile["splash_radius"]) + EXPLOSIVE_SAFE_MARGIN
				if dist < danger:
					score -= 300.0 + (danger - dist) * 20.0
	if not bool(profile["infinite_ammo"]) and weapon.mag_current <= 0:
		score -= 400.0
	if bool(profile["heals_allies"]):
		# A heal-only weapon is a poor combat pick when a damage weapon exists.
		score -= 70.0
	score += clampf(float(profile["dps"]) * 0.08, 0.0, 30.0)
	score -= float(profile["switch_time"]) * 6.0
	# Slot 0 is the class primary.  Humans do not constantly juggle to a sidearm
	# just because its DPS number is better; they switch when the primary cannot
	# do the job at this range.
	if has_target and slot == 0 and primary_viable:
		score += PRIMARY_WEAPON_PREFERENCE
	return score


## Per-fire-mode reach check for the actual mode Trigger is about to use.  This
## is what stops a long-range profile on a mixed weapon from firing a melee
## alt-mode at range, and stops a falloff pistol firing past its useful tail.
func _can_fire_mode(fire: WeaponFire, dist: float) -> bool:
	var info := _fire_range_info(fire)
	if info.is_empty():
		return false
	if bool(info["melee"]):
		return dist <= float(info["range_effective"]) + WEAPON_MELEE_ONLY_MARGIN
	var reach := minf(float(info["range_hard"]), float(info["range_effective"]) * 1.5)
	return dist <= reach + 1.0


func _weapon_can_engage(weapon: Weapon, dist: float) -> bool:
	var profile := _get_weapon_profile(weapon)
	if profile.is_empty():
		return false
	if bool(profile["melee"]):
		return dist <= float(profile["range_effective"]) + WEAPON_MELEE_ONLY_MARGIN
	# Falloff can still land weak shots past `falloff_end`; allow a short tail,
	# but not the entire authored hitscan range.
	var reach := minf(
		float(profile["range_hard"]),
		float(profile["range_effective"]) * 1.5
	)
	return dist <= reach + 1.0


## Slow weapon-choice loop.  It re-scores on a timer plus events (new target,
## empty mag, distance band change) and uses a large score margin so a bot does
## not flip-flop between two similar guns.
func _update_weapon_choice(wc: WeaponController, dist: float, has_target: bool) -> void:
	if wc == null or not wc._is_ready():
		return
	var current := wc.current_weapon_index
	var current_weapon: Weapon = wc._weapons[current]
	if current_weapon == null:
		return
	# Never override the medic's heal weapon while it is healing, and keep it
	# out through the absence hysteresis even when nobody is hurt right now.
	if _weapon_heals_allies(current_weapon):
		if _heal_target != null and is_instance_valid(_heal_target) \
				and _heal_is_safe():
			return
		if _heal_absent_time < MEDIC_HEAL_ABSENT:
			return
	# Do not cancel a reload just to shuffle guns; if the enemy is on top of us,
	# the out-of-ammo path can still swap below.
	if wc._is_reloading and dist > MELEE_CONSIDER_RANGE * 2.0:
		return

	var target_name := ""
	if _current_target != null and is_instance_valid(_current_target):
		target_name = str(_current_target.name)
	var band := int(floor(dist / 8.0))
	var current_cost := 1
	if _chosen_fire_index >= 0:
		current_cost = wc._get_fire_ammo_cost(current_weapon, _chosen_fire_index)
	var empty_now := not current_weapon.has_infinite_ammo \
		and current_weapon.mag_current < current_cost
	var event := target_name != _weapon_choice_target_name \
		or band != _weapon_choice_band or empty_now

	_weapon_choice_timer = maxf(_weapon_choice_timer - PROCESS_INTERVAL, 0.0)
	if _weapon_choice_timer > 0.0 and not event:
		return
	_weapon_choice_timer = WEAPON_CHOICE_INTERVAL
	_weapon_choice_target_name = target_name
	_weapon_choice_band = band

	var current_score := _weapon_situation_score(current_weapon, dist, has_target, current)
	var best_score := current_score
	var best_index := current
	var best_reason := "keep"
	for i in wc._weapons.size():
		if i == current:
			continue
		var candidate: Weapon = wc._weapons[i]
		if candidate == null:
			continue
		if not candidate.has_infinite_ammo and candidate.mag_current <= 0:
			continue
		if _weapon_heals_allies(candidate) \
				and _heal_candidate_time < MEDIC_HEAL_PERSIST:
			continue
		var candidate_score := _weapon_situation_score(candidate, dist, has_target, i)
		if candidate_score > best_score:
			best_score = candidate_score
			best_index = i
			best_reason = "range" if not _weapon_can_engage(current_weapon, dist) else "value"
	# Switch hysteresis exists to stop two similar guns flip-flopping, not to
	# keep a gun that has become useless.  A viable primary is worth drawing
	# even for a small gain; a primary whose falloff has made it a pea-shooter
	# at this range loses to any genuinely better option.
	var required_margin := WEAPON_SWITCH_MARGIN
	if best_index == 0 and _primary_viable_at(dist):
		required_margin = 2.0
	elif not _weapon_damage_viable_at(current_weapon, dist):
		required_margin = 2.0
	if best_index != current and best_score >= current_score + required_margin:
		if _switch_weapon(wc, best_index):
			_weapon_choice_reason = best_reason
			_weapon_choice_timer = 1.0


func _weapon_reload_threshold(weapon: Weapon) -> float:
	if weapon == null or weapon.mag_size <= 0:
		return 0.0
	var accuracy := _style.accuracy if _style != null else skill
	return lerpf(WEAPON_RELOAD_RATIO_MIN, WEAPON_RELOAD_RATIO_MAX, accuracy)


func _is_weapon_safe_to_reload(weapon: Weapon) -> bool:
	if _current_target == null or not is_instance_valid(_current_target):
		return true
	if _decision != null and _decision.state == Decision.State.RETREAT_COVER:
		return true
	var tp := _target_position_for_ai()
	if tp == Vector3.INF:
		return true
	var dist := player.global_position.distance_to(tp)
	var profile := _get_weapon_profile(weapon)
	var effective := float(profile.get("range_effective", DEFAULT_RANGED_ENGAGE_DIST))
	return dist > maxf(15.0, effective * 0.95) and not _enemy_nearby


## Reload only when it is cheap and safe, and never while the trigger is held.
func _maybe_tactical_reload(wc: WeaponController) -> bool:
	if wc == null or not wc._is_ready() or wc._is_reloading:
		return false
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon == null or weapon.has_infinite_ammo or weapon.mag_size <= 0:
		return false
	var ratio := float(weapon.mag_current) / float(weapon.mag_size)
	if ratio > _weapon_reload_threshold(weapon):
		return false
	if not _is_weapon_safe_to_reload(weapon):
		return false
	_trigger.release_all()
	if _buttons.request_reload():
		_weapon_choice_reason = "reload"
		return true
	return false


## Best ready weapon for the current distance, excluding heal-only picks when a
## damage option exists.  Returns -1 when nothing can engage.
func _best_ready_weapon_index(wc: WeaponController, dist: float) -> int:
	var best := -1
	var best_score := -INF
	for i in wc._weapons.size():
		var weapon: Weapon = wc._weapons[i]
		if weapon == null:
			continue
		if not weapon.has_infinite_ammo and weapon.mag_current <= 0:
			continue
		var profile := _get_weapon_profile(weapon)
		if bool(profile.get("heals_allies", false)):
			continue
		var score := _weapon_situation_score(weapon, dist, true, i)
		if score > best_score:
			best_score = score
			best = i
	return best


## The target's head-bone world position (`Physical Bone DEF-spine_006`, the
## `is_head` hurtbox).  Falls back to a fixed height above the origin if a custom
## model lacks the standard mannequin skeleton path.
func _get_head_position(target: Player) -> Vector3:
	var head := target.get_node_or_null(HEAD_BONE_PATH) as Node3D
	if head != null:
		return head.global_position
	return target.global_position + Vector3(0, 1.6, 0)


## Base aim point for [param aim_point].  `ground_aim` projects an explosive
## shot onto the floor below the target (an airborne target gets the floor
## beneath them, which is what a rocket/grenade splash wants).
func _aim_base_position(target: Player, aim_point: int,
		ground_aim: bool) -> Vector3:
	if ground_aim:
		return _ground_below(target.global_position)
	match aim_point:
		AimPoint.FEET:
			return target.global_position
		AimPoint.CENTER:
			return target.global_position + Vector3(0.0, AIM_CENTER_HEIGHT, 0.0)
		_:
			return _get_head_position(target)


func _ground_below(position: Vector3) -> Vector3:
	_shot_query.from = position + Vector3.UP * 0.25
	_shot_query.to = position - Vector3.UP * 8.0
	var hit := player.get_world_3d().direct_space_state.intersect_ray(_shot_query)
	if not hit.is_empty():
		return hit.position
	return position - Vector3.UP * 1.0


func _lead_velocity_for(target: Player, ground_aim: bool) -> Vector3:
	var velocity := _estimated_velocity_for(target) * _current_lead_quality()
	if ground_aim:
		# Predicting a floor point: only horizontal motion moves the impact.
		velocity.y = 0.0
	return velocity


func _lead_point(base: Vector3, velocity: Vector3, time: float,
		ground_aim: bool, ground_y: float) -> Vector3:
	var point := base + velocity * time
	if ground_aim:
		point.y = ground_y
	return point


## True when there is a clear ray from the bot's eye to [param point].
func _is_aim_point_visible(point: Vector3) -> bool:
	_shot_query.from = _head_node.global_position
	_shot_query.to = point
	return player.get_world_3d().direct_space_state.intersect_ray(_shot_query).is_empty()


## Pick centre mass vs the head bone.  Low-accuracy bots aim at the body;
## high-accuracy bots trust the head bone only when it is actually visible (a
## target behind low cover still gets a centre-mass shot).
func _choose_aim_point(target: Player, _fire: WeaponFire,
		proj_info: Dictionary) -> Dictionary:
	var aim_point := AimPoint.CENTER
	var ground_aim := false
	var explosive := bool(proj_info.get("is_explosive", false))
	if explosive:
		# A rocket that detonates on world contact wants the floor; a grenade
		# that passes through geometry only hurts on a direct hurtbox hit and
		# must stay on the body.  Sticky signal mines are body shots too.
		ground_aim = bool(proj_info.get("explodes_on_world", false)) \
			and _signal_mode != SignalMode.EXPLODE
	else:
		var accuracy := _style.accuracy if _style != null else skill
		if accuracy >= AIM_HEAD_ACCURACY \
				and _is_aim_point_visible(_get_head_position(target)):
			aim_point = AimPoint.HEAD
	return {"point": aim_point, "ground": ground_aim}


## Solve the launch direction for [param fire] against a moving target.
## Non-gravity projectiles use the quadratic intercept; gravity projectiles use
## a low-arc ballistic solve refined 4x, with the high arc available as a
## fallback when the low arc is blocked.
func _solve_projectile_solution(target: Player, fire: WeaponFire,
		aim_point: int, ground_aim: bool, high_arc: bool = false) -> Dictionary:
	var info := _get_proj_info(fire)
	var speed := float(info.get("speed", PROJECTILE_FALLBACK_SPEED))
	var gravity := maxf(float(info.get("gravity", 0.0)), 0.0)
	var lifetime := float(info.get("lifetime", 20.0))
	# The projectile must still be alive when it arrives.  This is what rejects
	# a huge lofted grenade arc that would burst in mid-air long before impact.
	var max_time := minf(LEAD_TIME_MAX, maxf(lifetime - 0.05, 0.1))
	var origin := _head_node.global_position
	var base := _aim_base_position(target, aim_point, ground_aim)
	var target_velocity := _lead_velocity_for(target, ground_aim)
	if gravity <= 0.05:
		return _solve_linear_lead(
			origin, base, target_velocity, speed, ground_aim, max_time
		)
	return _solve_ballistic_lead(
		origin, base, target_velocity, speed, gravity, ground_aim, high_arc, max_time
	)


func _solve_linear_lead(origin: Vector3, target_point: Vector3,
		target_velocity: Vector3, speed: float, ground_aim: bool,
		max_time: float) -> Dictionary:
	var to_target := target_point - origin
	var time := 0.0
	if speed > 0.5:
		var a := target_velocity.dot(target_velocity) - speed * speed
		var b := 2.0 * to_target.dot(target_velocity)
		var c := to_target.dot(to_target)
		if absf(a) < 0.0001:
			if absf(b) > 0.0001:
				time = -c / b
		else:
			var disc := b * b - 4.0 * a * c
			if disc >= 0.0:
				var root := sqrt(disc)
				var t1 := (-b - root) / (2.0 * a)
				var t2 := (-b + root) / (2.0 * a)
				if t1 > 0.0 and t2 > 0.0:
					time = minf(t1, t2)
				else:
					time = maxf(t1, t2)
		if time <= 0.0:
			# No intercept inside the model (e.g. the target outruns the round).
			# A straight shot at the predicted position is still better than
			# aiming at where it used to be.
			time = clampf(to_target.length() / speed, 0.0, max_time)
	time = clampf(time, 0.0, max_time)
	var predicted := _lead_point(
		target_point, target_velocity, time, ground_aim, target_point.y
	)
	var dir := predicted - origin
	if dir.length_squared() < 0.0001:
		dir = -_head_node.global_transform.basis.z
	dir = dir.normalized()
	return {
		"ok": true, "arc": false, "high": false, "origin": origin,
		"dir": dir, "point": predicted, "target_point": predicted,
		"time": time, "speed": speed, "gravity": 0.0, "ground": ground_aim,
	}


func _solve_ballistic_lead(origin: Vector3, target_point: Vector3,
		target_velocity: Vector3, speed: float, gravity: float,
		ground_aim: bool, high_arc: bool, max_time: float) -> Dictionary:
	if speed < 1.0:
		return {}
	var predicted := target_point
	var direction := Vector3.ZERO
	var time := 0.0
	var horizontal_unit := Vector3.ZERO
	for _i in BALLISTIC_ITERATIONS:
		var to_target := predicted - origin
		horizontal_unit = Vector3(to_target.x, 0.0, to_target.z)
		var x := horizontal_unit.length()
		if x < 0.25:
			return {}
		horizontal_unit /= x
		var y := to_target.y
		var v2 := speed * speed
		var gx := gravity * x
		var disc := 1.0 - 2.0 * gravity * y / v2 - (gx / v2) * (gx / v2)
		if disc < 0.0:
			return {}
		var root := sqrt(disc)
		var u := (v2 / maxf(gravity * x, 0.0001)) * (1.0 + (root if high_arc else -root))
		var theta := atan(u)
		var cos_theta := cos(theta)
		if cos_theta <= 0.03:
			return {}
		time = x / (speed * cos_theta)
		if time <= 0.0 or time > max_time:
			return {}
		predicted = _lead_point(
			target_point, target_velocity, time, ground_aim, target_point.y
		)
		direction = horizontal_unit * cos_theta + Vector3.UP * sin(theta)
	# Aim the mouse along the launch direction, not at the target point: for a
	# lofted arc those are different directions.
	var aim_distance := maxf(origin.distance_to(predicted) * 1.5, 12.0)
	return {
		"ok": true, "arc": true, "high": high_arc, "origin": origin,
		"dir": direction.normalized(), "point": origin + direction.normalized() * aim_distance,
		"target_point": predicted, "time": time, "speed": speed,
		"gravity": gravity, "ground": ground_aim,
	}


## Aim point for the simple callers (heal targeting).  Combat uses
## [_solve_projectile_solution] directly because it also validates the arc.
##
## Return the point ALONG THE LAUNCH DIRECTION, not the predicted impact point:
## a gravity projectile must be fired above the target.  Looking at
## `target_point` made the syringe/heal-grenade bots aim flat and fall short.
func _predict_aim_point(target: Player, fire: WeaponFire, _flat_dist: float,
		aim_point: int = AimPoint.HEAD) -> Vector3:
	var base := _aim_base_position(target, aim_point, false)
	if fire == null or fire.bullet_type != WeaponFire.BulletType.PROJECTILE:
		return base
	var choice := _choose_aim_point(target, fire, _get_proj_info(fire))
	var solution := _solve_projectile_solution(
		target, fire, int(choice["point"]), bool(choice["ground"])
	)
	if solution.is_empty():
		return base
	return solution["point"]


## Sample the predicted path with world-only rays.  Only called when the bot is
## otherwise ready to fire, and at most once per ARC_VALIDATION_INTERVAL.
func _shot_arc_blocked(solution: Dictionary, allow_impact_radius: float) -> bool:
	if solution.is_empty() or not bool(solution.get("ok", false)):
		return true
	var origin: Vector3 = solution["origin"]
	var dir: Vector3 = solution["dir"]
	var speed: float = solution["speed"]
	var gravity: float = solution["gravity"]
	var time: float = solution["time"]
	var target_point: Vector3 = solution["target_point"]
	var previous := origin
	var space := player.get_world_3d().direct_space_state
	for i in range(1, ARC_VALIDATION_SAMPLES + 1):
		var t := time * float(i) / float(ARC_VALIDATION_SAMPLES)
		var point := origin + dir * speed * t \
			- Vector3.UP * 0.5 * gravity * t * t
		_shot_query.from = previous
		_shot_query.to = point
		var hit := space.intersect_ray(_shot_query)
		if not hit.is_empty():
			var hit_pos: Vector3 = hit.position
			# Hitting the floor at the target is the intended splash impact, not
			# an obstruction.
			if hit_pos.distance_to(target_point) > allow_impact_radius + 0.35:
				return true
		previous = point
	return false


## Melee is verified data, not a guess: a MELEE action or a hitscan fire whose
## authored `hitscan_range` is inside melee reach (Knife = 2 m, Bat = 3 m).
## The old `WeaponFire.range` probe never existed.
func _is_melee_weapon(weapon: Weapon) -> bool:
	if weapon == null or weapon.weapon_fires.is_empty():
		return false
	return bool(_get_weapon_profile(weapon).get("melee", false))


## Rough "ideal distance to be at" for the currently-held weapon: melee wants
## to be right on top of the target; everything else uses whatever range info
## can be found on its WeaponFire(s), fighting at roughly half of it, and
## otherwise falls back to a sane default rather than SHOOT_RANGE (which is a
## target-acquisition radius, not a comfortable fighting distance).
func _get_engagement_range(weapon: Weapon) -> float:
	return float(_get_engagement_range_info(weapon)["range"])


## Same decision as [method _get_engagement_range], plus _why_ it chose that
## number (which property answered, or the fallback).  Only the debug log reads
## the extra fields; the movement code still calls the plain float getter.
func _get_engagement_range_info(weapon: Weapon) -> Dictionary:
	if weapon == null:
		return {"range": DEFAULT_RANGED_ENGAGE_DIST, "source": "default (null weapon)"}
	var profile := _get_weapon_profile(weapon)
	if profile.is_empty():
		return {"range": DEFAULT_RANGED_ENGAGE_DIST, "source": "default (no profile)"}
	return {
		"range": clampf(float(profile["range_ideal"]), 1.0, MAX_SENSIBLE_RANGE),
		"source": "profile (hard %.1f, effective %.1f)" % [
			float(profile["range_hard"]), float(profile["range_effective"])
		],
	}


## Ask the button emulator for a weapon switch.  The request is accepted now but
## committed after the per-bot human reaction delay; the WeaponController's real
## switch state machine still owns the equip time.  Returning true means "a
## switch to this slot is in flight", so callers stop acting on the old weapon.
func _switch_weapon(wc: WeaponController, index: int) -> bool:
	if index < 0 or index >= wc._weapons.size() or index == wc.current_weapon_index:
		return false
	if _buttons != null and _buttons.is_switch_pending():
		return _buttons.pending_index() == index
	if _weapon_switch_guard > 0.0:
		return false
	_trigger.release_all()
	if not _buttons.request_switch(index):
		return false
	var old_weapon: Weapon = wc._weapons[wc.current_weapon_index]
	var new_weapon: Weapon = wc._weapons[index]
	_weapon_switch_guard = old_weapon.put_away_time + new_weapon.pullout_time \
		+ SWITCH_REACTION_MAX + 0.1
	_chosen_fire_index = -1
	_fire_mode_dirty = true
	_last_mag_for_strafe = -1
	_shots_since_strafe = 0
	_arc_validation_timer = 0.0
	_arc_validation_blocked = false
	_arc_validation_high = false
	return true

# Objective seeking

func _get_objective_target() -> Vector3:
	var info := _get_objective_info()
	if info.is_empty():
		return Vector3.INF
	var pos: Vector3 = info.get("pos", Vector3.INF)
	return pos


## Rich objective descriptor used by the intent model:
## { pos, radius, leash, name, kind, owned, contested, attacking, active }.
## `_get_objective_target()` remains a position-only convenience wrapper.
func _get_objective_info() -> Dictionary:
	var gmc := GameManager.game_mode_component
	if gmc == null or not is_instance_valid(gmc):
		return {}

	match gmc.game_mode:
		GameModeComponent.GameMode.KOTH, GameModeComponent.GameMode.CONTROL:
			if gmc.koth_mode and not gmc.koth_mode._control_points.is_empty():
				return _control_point_info(gmc.koth_mode._control_points[0])

		GameModeComponent.GameMode.DOMINATION:
			if gmc.domination_mode:
				var best: ControlPoint = null
				var best_score := -INF
				for cp in gmc.domination_mode._control_points:
					var score := _objective_point_urgency(cp)
					if score > best_score:
						best_score = score
						best = cp
				if best != null:
					return _control_point_info(best)

		GameModeComponent.GameMode.ESCORT:
			var payload := _get_payload_node(gmc)
			if payload:
				return _payload_info(payload)

		GameModeComponent.GameMode.HYBRID:
			if gmc.hybrid_mode:
				if not gmc.hybrid_mode.point_is_captured \
						and not gmc.hybrid_mode._control_points.is_empty():
					return _control_point_info(
						gmc.hybrid_mode._control_points[0]
					)
				var payload := _get_payload_node(gmc)
				if payload:
					return _payload_info(payload)

	return {}


func _control_point_info(cp: ControlPoint) -> Dictionary:
	if cp == null or not is_instance_valid(cp):
		return {}
	var point_name := cp.targetname
	if point_name.is_empty():
		point_name = "POINT"
	var owned := player.team != Player.Team.FFA \
		and cp.owning_team == player.team
	var contested := cp.is_contested \
		or (cp.capture_progress > 0.0 and cp.capture_team != cp.owning_team)
	return {
		"pos": cp.global_position,
		"radius": OBJECTIVE_HOLD_RADIUS,
		"leash": OBJECTIVE_LEASH_RADIUS,
		"name": point_name,
		"kind": "point",
		"owned": owned,
		"contested": contested,
		"attacking": false,
		"active": not cp.is_locked,
	}


func _payload_info(payload: PayloadNode) -> Dictionary:
	if payload == null or not is_instance_valid(payload):
		return {}
	var attacking := player.team == payload.attacking_team
	var radius := maxf(payload.push_radius - OBJECTIVE_PAYLOAD_RADIUS_INSET, 2.0)
	return {
		"pos": payload.global_position,
		"radius": radius,
		"leash": OBJECTIVE_LEASH_RADIUS,
		"name": "PAYLOAD",
		"kind": "payload",
		"owned": attacking,
		"contested": payload.is_contested,
		"attacking": attacking,
		"active": not payload.is_locked and not payload.is_delivered,
	}


func _objective_point_urgency(cp: ControlPoint) -> float:
	if cp == null or not is_instance_valid(cp):
		return -INF
	var score := 0.0
	if cp.owning_team != player.team:
		score += 8.0
	if cp.is_contested:
		score += 6.0
	if cp.capture_progress > 0.0 and cp.capture_team != cp.owning_team:
		score += 4.0
	score -= player.global_position.distance_to(cp.global_position) / 30.0
	return score


func _objective_action_text(info: Dictionary) -> String:
	if String(info.get("kind", "")) == "payload":
		return "PUSH" if bool(info.get("attacking", false)) else "DEFEND"
	if not bool(info.get("owned", false)):
		return "CAPTURE"
	return "DEFEND" if bool(info.get("contested", false)) else "HOLD"


## Top-level "what should I be doing?" model, recomputed after each Decision
## update.  Priority: survival, then the objective (fight from it, don't chase
## beyond its leash), then a visible enemy, then search near it, then wander.
## The cached objective fields drive `_act_combat`, `_act_search` and
## `_act_seek_objective_or_wander`; `_intent_text` is the debug label.
func _update_intent() -> void:
	var survival_text := ""
	var survival_intent := Intent.NONE
	if _decision != null:
		match _decision.state:
			Decision.State.FLEE:
				survival_text = "FLEE"
				survival_intent = Intent.FLEE
			Decision.State.HEAL:
				survival_text = "HEAL"
				survival_intent = Intent.HEAL
			Decision.State.RETREAT_COVER:
				survival_text = "COVER"
				survival_intent = Intent.COVER
			Decision.State.RELOAD_SAFE:
				survival_text = "RELOAD"
				survival_intent = Intent.RELOAD
			Decision.State.STUCK_RECOVER:
				survival_text = "UNSTUCK"
				survival_intent = Intent.UNSTUCK

	var info := _get_objective_info()
	if info.is_empty():
		_objective_active = false
		_objective_position = Vector3.INF
		_objective_name = ""
		_objective_hold_radius = OBJECTIVE_HOLD_RADIUS
		_objective_leash_radius = OBJECTIVE_LEASH_RADIUS
		_objective_owned = false
		_objective_contested = false
		_objective_kind = ""
		_objective_attacking = false
	else:
		_objective_position = info.get("pos", Vector3.INF)
		_objective_hold_radius = float(
			info.get("radius", OBJECTIVE_HOLD_RADIUS)
		)
		_objective_leash_radius = float(
			info.get("leash", OBJECTIVE_LEASH_RADIUS)
		)
		_objective_name = str(info.get("name", "OBJECTIVE"))
		_objective_active = bool(info.get("active", false))
		_objective_owned = bool(info.get("owned", false))
		_objective_contested = bool(info.get("contested", false))
		_objective_kind = str(info.get("kind", ""))
		_objective_attacking = bool(info.get("attacking", false))

	# Survival outranks the objective; the cached objective is where the bot
	# returns after FLEE/HEAL/COVER/RELOAD/UNSTUCK ends.
	if not survival_text.is_empty():
		_intent = survival_intent
		_intent_text = survival_text
		return

	if not _objective_active or _objective_position == Vector3.INF:
		if _current_target != null and _target_visible:
			_intent = Intent.FIGHT
			_intent_text = "FIGHT"
		elif _current_target != null:
			_intent = Intent.SEARCH
			_intent_text = "PURSUE"
		elif _search_active:
			_intent = Intent.SEARCH
			_intent_text = "HUNT" if _search_persistent else "SEARCH"
		else:
			_intent = Intent.WANDER
			_intent_text = "WANDER"
		return

	var dist := player.global_position.distance_to(_objective_position)
	var inside := dist <= _objective_hold_radius
	var action := _objective_action_text(info)

	if _current_target != null:
		if _target_visible:
			if inside:
				_intent = Intent.FIGHT_ON_OBJECTIVE
				_intent_text = "FIGHT ON %s" % _objective_name
			else:
				_intent = Intent.RETURN_TO_OBJECTIVE
				_intent_text = "RETURN TO %s" % _objective_name
		else:
			_intent = Intent.SEARCH
			_intent_text = "PURSUE"
		return

	if _search_active and _search_persistent:
		# No objective is nearby; the last heard enemy owns the bot.
		_intent = Intent.SEARCH
		_intent_text = "HUNT"
		return

	if _search_active:
		if _search_origin != Vector3.INF \
				and _search_origin.distance_to(_objective_position) \
					<= _objective_leash_radius:
			_intent = Intent.SEARCH
			_intent_text = "SEARCH %s" % _objective_name
		else:
			_intent = Intent.RETURN_TO_OBJECTIVE
			_intent_text = "RETURN TO %s" % _objective_name
		return

	if inside:
		if _objective_kind == "payload":
			_intent = Intent.CAPTURE if _objective_attacking else Intent.DEFEND
		elif not _objective_owned:
			_intent = Intent.CAPTURE
		elif _objective_contested:
			_intent = Intent.DEFEND
		else:
			_intent = Intent.HOLD
		_intent_text = "%s %s" % [action, _objective_name]
	else:
		_intent = Intent.MOVE_TO_OBJECTIVE
		_intent_text = "GO %s %s" % [action, _objective_name]


## "An objective is nearby" for the persistent-hearing rule.  Within this
## radius the objective outranks an old sound and the endless heard search ends.
func _objective_is_near(point: Vector3) -> bool:
	return _objective_active and _objective_position != Vector3.INF \
		and point.distance_to(_objective_position) <= OBJECTIVE_NEARBY_RADIUS


## True when the bot is outside the objective's hold radius and should be
## returning to it, even if it can still see/shoot its target.
func _objective_should_pull() -> bool:
	return _objective_active and _objective_position != Vector3.INF \
		and player.global_position.distance_to(_objective_position) \
			> _objective_hold_radius


## True when the current target is close enough to the objective that chasing it
## does not abandon the point.
func _target_within_objective_leash() -> bool:
	if not _objective_active or _current_target == null \
			or not is_instance_valid(_current_target):
		return true
	return _current_target.global_position.distance_to(_objective_position) \
		<= _objective_leash_radius

func _get_payload_node(gmc: GameModeComponent) -> PayloadNode:
	if gmc.escort_mode and gmc.escort_mode._payload:
		return gmc.escort_mode._payload
	if gmc.hybrid_mode and gmc.hybrid_mode._payload:
		return gmc.hybrid_mode._payload
	return null

## Rocket/grenade-jump: aim the explosive weapon straight down at our own feet
## and jump on the same tick as firing, launching the bot into the air. Only
## attempted while already holding an explosive weapon (never forces a weapon
## switch to do this), while there's real ground to cover, off cooldown, and
## — scaled by movement_quality — far more often at higher skill.  Only weapons
## whose projectile detonates on world contact qualify: a grenade that passes
## through the floor cannot launch anyone.  Returns true if it fired this tick
## (caller should skip normal movement for that tick).
func _try_explosion_jump(wc: WeaponController, travel_dist: float) -> bool:
	if _explosion_jump_phase != 0:
		return true
	if _explosion_jump_cooldown_timer > 0.0 or travel_dist < EXPLOSION_JUMP_MIN_GAP:
		return false
	if not wc._is_ready() or wc._is_reloading or wc._fire_cooldown > 0.0 \
			or wc._pending_fire or wc._is_firing or wc._fire_is_blocked():
		return false
	# Prefer fighting to self-launching when a target is visible/close.
	if _current_target != null and is_instance_valid(_current_target) \
			and _current_target.spawned:
		return false

	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty() or weapon.charged:
		return false
	var fire_index := _select_explosive_fire_index(weapon)
	if fire_index < 0:
		return false
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire.bullet_type != WeaponFire.BulletType.PROJECTILE:
		return false
	var info := _get_proj_info(fire)
	if not bool(info.get("is_explosive", false)):
		return false
	# A rocket jump needs the blast to actually detonate on the floor it is fired
	# at.  Grenades, molotovs and poison jars pass through world geometry, so
	# firing one at our feet just wastes it and leaves the bot standing there.
	if not bool(info.get("explodes_on_world", false)):
		return false
	if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
		return false
	# A rocket jump is a normal trade while healthy; skip it only when the blast
	# would leave the bot at/below the survival threshold.
	if not _accept_self_damage(info):
		return false

	# Movement competence, not raw skill: a clumsy bot almost never chains
	# aim->fire->jump; a good one does it readily when there is ground to cover.
	var movement_quality := _style.movement_quality if _style != null else skill
	if randf() > lerpf(0.02, 0.35, movement_quality):
		return false

	_explosion_jump_phase = 1
	_explosion_jump_timer = 0.0
	_explosion_jump_fire_wait = 0.0
	_explosion_jump_fire_index = fire_index
	_explosion_jump_weapon_index = wc.current_weapon_index
	_trigger.release_all()
	_desired_aim_point = player.global_position
	_has_desired_aim = true
	_mouse.request_look_at_point(
		_desired_aim_point, LookPriority.COMBAT, 1.0, "explosion_jump"
	)
	return true


## (1) aim at the ground -> (2) fire through Trigger -> (3) jump.  Any visible
## target, weapon change, stun or timeout aborts and releases everything.
func _tick_explosion_jump(delta: float) -> void:
	if _explosion_jump_phase == 0:
		return
	if not player.spawned:
		_abort_explosion_jump()
		return
	if _current_target != null and is_instance_valid(_current_target):
		_abort_explosion_jump()
		return
	if _heal_target != null and is_instance_valid(_heal_target):
		_abort_explosion_jump()
		return
	if player.status_effect_manager and (
			player.status_effect_manager.is_stunned()
			or player.status_effect_manager.is_pinned()
			or player.status_effect_manager.is_action_blocked()):
		_abort_explosion_jump()
		return
	var wc: WeaponController = player.weapon_controller
	if wc == null or not wc._is_ready() or wc._is_reloading \
			or wc.is_switching() or wc.current_weapon_index != _explosion_jump_weapon_index:
		_abort_explosion_jump()
		return

	match _explosion_jump_phase:
		1:
			_explosion_jump_timer += delta
			_desired_aim_point = player.global_position
			_has_desired_aim = true
			_mouse.request_look_at_point(
				_desired_aim_point, LookPriority.COMBAT, 1.0, "explosion_jump"
			)
			if aim_error_deg >= 0.0 and aim_error_deg <= 5.0:
				_explosion_jump_phase = 2
				_explosion_jump_fire_wait = 0.0
				_trigger.request_fire(_explosion_jump_fire_index, true, true)
			elif _explosion_jump_timer >= EXPLOSION_JUMP_AIM_TIMEOUT:
				_abort_explosion_jump()
		2:
			_explosion_jump_fire_wait += delta
			if _explosion_jump_fire_wait >= EXPLOSION_JUMP_FIRE_WAIT:
				if player.is_on_floor():
					_keyboard.jump_tap(false)
					_explosion_jump_cooldown_timer = EXPLOSION_JUMP_COOLDOWN
				_abort_explosion_jump()


func _abort_explosion_jump() -> void:
	_explosion_jump_phase = 0
	_explosion_jump_timer = 0.0
	_explosion_jump_fire_wait = 0.0
	_explosion_jump_fire_index = -1
	_explosion_jump_weapon_index = -1
	_trigger.release_all()
	_has_desired_aim = false

# Act

func _act() -> void:
	# The explosion-jump sub-sequence owns aim/fire/jump until it finishes.
	if _explosion_jump_phase != 0:
		return
	# FLEE is movement-only and never fires.  A switching or unready weapon must
	# not freeze the escape, so it bypasses the readiness gate below.
	if _decision != null and _decision.state == Decision.State.FLEE:
		_decision.act()
		return
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		# Do not keep the previous act's keys held through a switch/pullout.
		_keyboard.set_move(0, 0)
		return
	_decision.act()

func _act_seek_objective_or_wander() -> void:
	if not _objective_active or _objective_position == Vector3.INF:
		_act_wander()
		return

	var dist := player.global_position.distance_to(_objective_position)
	if dist <= _objective_hold_radius * 0.85:
		# Reaching the point must not turn into a wander away from it.
		_act_hold_objective()
		return

	var wc: WeaponController = player.weapon_controller
	if _try_explosion_jump(wc, dist):
		return
	_update_weapon_choice(wc, 15.0, false)
	if _buttons.is_switch_pending() or wc.is_switching():
		_trigger.release_all()
		_keyboard.set_move(0, 0)
		return

	_trigger.release_all()
	_has_desired_aim = false
	var goal := _objective_position
	if _style != null and dist > _objective_hold_radius * 2.0:
		# Cautious bots approach from a slight flank; aggressive bots beeline.
		var to_obj := _objective_position - player.global_position
		var perp := Vector3(-to_obj.z, 0.0, to_obj.x)
		if perp.length_squared() > 0.01:
			goal += perp.normalized() * _style.flank_bias \
				* (1.0 - _style.aggression) * 6.0
	_traversal.move_to(
		goal, 0.6, maxf(_objective_hold_radius * 0.7, 1.5), 0.15
	)

	_maybe_tactical_reload(wc)


## At the objective with nothing to shoot: hold the point, push the cart, and
## scan.  This deliberately does not wander — a bot that reaches a control point
## and immediately wanders off is not contesting it.
func _act_hold_objective() -> void:
	_trigger.release_all()
	_has_desired_aim = false
	if _traversal != null:
		_traversal.cancel_goal()
	_release_movement()
	var wc: WeaponController = player.weapon_controller
	if wc != null and wc._is_ready():
		_maybe_tactical_reload(wc)
	_mouse.request_look_at_point(
		_objective_position + Vector3.UP * AIM_CENTER_HEIGHT,
		LookPriority.GLANCE, 0.25, "hold_objective"
	)

func _act_combat() -> void:
	if _current_target == null or not is_instance_valid(_current_target) \
			or not _current_target.spawned:
		_trigger.release_all()
		_release_movement()
		return
	if not _target_visible:
		# Grace window after losing sight: hold the last-known angle, do not
		# fire through the wall, and do not orbit a body we cannot see.
		_trigger.release_all()
		_has_desired_aim = false
		_release_movement()
		var point := _predicted_last_known(Time.get_ticks_msec())
		if point == Vector3.INF:
			point = _last_seen_position
		if point != Vector3.INF:
			_mouse.request_look_at_point(
				point + Vector3.UP * TRAVEL_EYE_HEIGHT,
				LookPriority.COMBAT, 0.6, "memory:" + _memory_target_name
			)
		return
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_trigger.release_all()
		_release_movement()
		return
	if wc.is_switching() or _buttons.is_switch_pending():
		_trigger.release_all()
		_release_movement()
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		_trigger.release_all()
		_release_movement()
		return

	var to_target := _current_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_update_weapon_choice(wc, dist, true)
	if _buttons.is_switch_pending() or wc.is_switching():
		_trigger.release_all()
		_release_movement()
		return
	weapon = wc._weapons[wc.current_weapon_index]
	_update_fire_mode(weapon, dist)
	var fire_index := _chosen_fire_index
	if fire_index < 0:
		_trigger.release_all()
		_has_desired_aim = false
		_release_movement()
		_bot_find_ammo_or_reload(wc)
		return
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
		_trigger.release_all()
		_release_movement()
		return

	# Aim point depends on skill and weapon role: body for low-accuracy bots and
	# for weapons whose headshot cannot be trusted, head bone only when a
	# high-accuracy bot can actually see it, floor for world-contact explosives.
	var proj_info := _get_proj_info(fire)
	var is_projectile: bool = fire.bullet_type == WeaponFire.BulletType.PROJECTILE
	var is_explosive: bool = bool(proj_info.get("is_explosive", false))
	var choice := _choose_aim_point(_current_target, fire, proj_info)
	var aim_point: int = int(choice["point"])
	var ground_aim := bool(choice["ground"])
	var aims := _aim_base_position(_current_target, aim_point, ground_aim)
	var shot_blocked := false

	# Only validate a projectile path once the bot is otherwise ready to pull the
	# trigger.  The result is cached for ARC_VALIDATION_INTERVAL: this is a
	# ray-heavy check, not a per-tick perception query.
	var heal_idle := _weapon_heals_allies(weapon) and _heal_target == null
	var wants_base := _reaction_timer <= 0.0 \
		and not heal_idle \
		and _can_fire_mode(fire, dist) \
		and not _too_close_for_explosive(fire, dist)
	if is_projectile:
		var high := false
		var can_validate := not bool(proj_info.get("world_passthrough", false))
		if can_validate and _arc_validation_timer > 0.0:
			high = _arc_validation_high
			shot_blocked = _arc_validation_blocked
		var solution := _solve_projectile_solution(
			_current_target, fire, aim_point, ground_aim, high
		)
		if solution.is_empty():
			# No ballistic solution (out of reach / impossible arc): keep looking
			# at a sensible point, but do not fire a shot that cannot arrive.
			aims = _aim_base_position(_current_target, AimPoint.CENTER, false)
			shot_blocked = true
			_arc_validation_blocked = true
			_arc_validation_high = false
		else:
			# Only spend the arc rays when the crosshair is close enough that the
			# Trigger could actually pull in the next few ticks.  Aiming and
			# travelling never validate.
			var about_to_fire := wants_base and aim_error_deg >= 0.0 \
				and aim_error_deg <= aim_tolerance_for(weapon, fire) * 1.25
			if about_to_fire and can_validate and _arc_validation_timer <= 0.0:
				_arc_validation_timer = ARC_VALIDATION_INTERVAL
				var impact_radius := 0.35
				if is_explosive:
					impact_radius = maxf(
						float(proj_info.get("splash_radius", 0.0)), impact_radius
					)
				var blocked := _shot_arc_blocked(solution, impact_radius)
				var chosen := solution
				if blocked and bool(solution.get("arc", false)):
					var high_solution := _solve_projectile_solution(
						_current_target, fire, aim_point, ground_aim, true
					)
					if not high_solution.is_empty() \
							and not _shot_arc_blocked(high_solution, impact_radius):
						chosen = high_solution
						high = true
						blocked = false
				shot_blocked = blocked
				_arc_validation_blocked = blocked
				_arc_validation_high = high
				solution = chosen
			aims = solution["point"]

	# Request, do not write.  The Mouse owns recoil compensation, the flick and
	# the tracking lag; the aim gate still measures the real head ray against
	# this point, so lead and recoil flow through automatically.
	_desired_aim_point = aims
	_has_desired_aim = true
	_mouse.request_look_at_point(
		aims, LookPriority.COMBAT, 1.0, str(_current_target.get_instance_id())
	)

	# Weapon-aware engagement distance with a deadband.  Inside the band the bot
	# holds range (strafe only); outside it approaches/retreats at a scaled
	# speed.  The old always-on normalized radial term caused permanent orbiting.
	var desired_dist := maxf(
		_get_engagement_range(weapon) + _preferred_dist_offset,
		MELEE_ENGAGE_RANGE * 0.5
	)
	var band := maxf(2.5, desired_dist * COMBAT_RANGE_BAND_SCALE)
	var hold_hi := desired_dist + band
	var hold_lo := maxf(1.0, desired_dist - band)
	if dist > hold_hi + COMBAT_RANGE_HYSTERESIS:
		_combat_range_state = CombatRangeState.APPROACH
	elif dist < hold_lo - COMBAT_RANGE_HYSTERESIS:
		_combat_range_state = CombatRangeState.RETREAT
	else:
		_combat_range_state = CombatRangeState.HOLD

	var objective_pull := _objective_should_pull()
	var chase_enter := maxf(COMBAT_CHASE_ENTER, desired_dist + band * 1.5)
	var chase_exit := maxf(COMBAT_CHASE_EXIT, desired_dist + band * 0.5)
	if _combat_chasing:
		if dist <= chase_exit and absf(to_target.y) <= COMBAT_CHASE_VERTICAL:
			_combat_chasing = false
			_combat_chase_stall = 0.0
			_traversal.cancel_goal()
	elif dist >= chase_enter or absf(to_target.y) > COMBAT_CHASE_VERTICAL:
		_combat_chasing = true
		_combat_chase_stall = 0.0

	# A partial nav route can park the bot at the closest reachable point.  Give
	# up the chase after a short stall and let the local combat block resume.
	if _combat_chasing:
		if _traversal.is_partial_approach():
			_combat_chase_stall += PROCESS_INTERVAL
			if _combat_chase_stall >= COMBAT_CHASE_STALL_TIME:
				_combat_chasing = false
				_combat_chase_stall = 0.0
				_traversal.cancel_goal()
		else:
			_combat_chase_stall = 0.0

	# Objective priority: a runner outside the objective leash does not pull the
	# bot off the point, and a point it is not touching pulls it back even while
	# it can see/shoot the target.  The COMBAT aim request above stays live.
	if _objective_active and not _target_within_objective_leash() \
			and _combat_chasing:
		_combat_chasing = false
		_combat_chase_stall = 0.0
		_traversal.cancel_goal()
	if objective_pull:
		_combat_chasing = false
		_combat_chase_stall = 0.0
		_traversal.move_to(
			_objective_position, 0.85,
			maxf(_objective_hold_radius * 0.7, 1.5), 0.05, true
		)

	if objective_pull:
		pass
	elif _combat_chasing:
		# The COMBAT look request above outranks Traversal's travel look.
		_traversal.move_to(_current_target.global_position, 0.9,
			maxf(desired_dist, 2.0), 0.05, true)
	else:
		var radial := 0.0  # positive = approach, negative = back off
		if _combat_range_state == CombatRangeState.APPROACH:
			radial = clampf((dist - hold_hi) / band, 0.0, 1.0)
		elif _combat_range_state == CombatRangeState.RETREAT:
			radial = -clampf((hold_lo - dist) / band, 0.0, 1.0)
		# A target outside the objective leash is not worth walking off the
		# point for; hold the angle and shoot what you can reach.
		if _objective_active and not _target_within_objective_leash():
			radial = 0.0

		if _combat_pattern == CombatPattern.HOLD:
			# Stop-to-shoot beat: no locomotion while this pattern owns the move.
			_keyboard.set_move(0, 0)
		else:
			var local := Vector2(_strafe_dir * 0.9, -radial * 0.85)
			# Obstacle steer is safety, not the primary motion; only mix it in
			# while actually closing or backing off.
			if absf(radial) > 0.01:
				var steer_world := _steer_toward(_current_target.global_position)
				var steer_local := _keyboard.world_to_input_local(steer_world)
				local += steer_local * 0.25
			if local.length() < 0.001:
				local = Vector2(_strafe_dir, 0.0)
			else:
				local = local.normalized()
			local = _combat_strafe_safe(local)
			_move_local(local)
			_tick_combat_stall()

		# Event-driven strafe trigger: shots fired, not a fixed dice roll.
		var mag := weapon.mag_current
		if _last_mag_for_strafe >= 0 and mag < _last_mag_for_strafe:
			_shots_since_strafe += _last_mag_for_strafe - mag
		_last_mag_for_strafe = mag
		if _shots_since_strafe >= COMBAT_STRAFE_SHOT_MAX:
			_strafe_force_change = true
			_strafe_reason = "shots"
			_shots_since_strafe = 0

	# Firing: the Trigger owns the flags and applies the aim gate.  `wants_base`
	# was computed before the arc test so validation only ran when the bot was
	# otherwise ready; a blocked arc vetoes the shot but does not make the bot
	# stand still holding the trigger.
	var wants := wants_base and not shot_blocked
	if _combat_pattern == CombatPattern.HOLD and _combat_settle_timer > 0.0:
		# Let the body actually stop before the first shot of the beat.
		wants = false
	if not wants and _reaction_timer <= 0.0 and _too_close_for_explosive(fire, dist):
		# Point-blank with a self-damaging explosive: draw a sidearm instead of
		# standing there aiming at the ground while backing away.
		var safe_index := _first_safe_weapon_index(wc, dist)
		if safe_index >= 0 and _switch_weapon(wc, safe_index):
			_trigger.release_all()
			_release_movement()
			return
	_trigger.request_fire(fire_index, wants)

func _act_heal() -> void:
	if _heal_target == null or not is_instance_valid(_heal_target) \
			or not _heal_target.spawned:
		_trigger.release_all()
		_release_movement()
		return
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_trigger.release_all()
		_release_movement()
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		_trigger.release_all()
		_release_movement()
		return

	var to_target := _heal_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_update_fire_mode(weapon, dist)
	var fire_index := _chosen_fire_index
	if fire_index < 0:
		_trigger.release_all()
		_has_desired_aim = false
		_release_movement()
		_bot_find_ammo_or_reload(wc)
		return
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
		_trigger.release_all()
		_release_movement()
		return

	var aim_pos := _predict_aim_point(_heal_target, fire, dist)
	_desired_aim_point = aim_pos
	_has_desired_aim = true
	_mouse.request_look_at_point(
		aim_pos, LookPriority.COMBAT, 0.9, str(_heal_target.get_instance_id())
	)

	# Move to a comfortable heal distance; back off if hugging the target.  The
	# route follower owns the approach, so a target on another floor is usable.
	if dist > HEAL_RANGE * 0.7:
		_traversal.move_to(
			_heal_target.global_position, 0.7, HEAL_RANGE * 0.7, 0.05
		)
	elif dist < 3.0:
		# Back away in the body-local frame (S), with a little steering if a wall
		# is in the way.
		_move_local(Vector2(_strafe_dir * 0.35, 1.0))
	else:
		_move_local(Vector2(_strafe_dir * 0.6, 0.0))

	_trigger.request_fire(fire_index, true)


## Low-health medic: fire a self-healing projectile at our own feet.  The
## weapon's own cooldown gates repeat shots; `_act` stops as soon as health
## rises above MEDIC_SELF_HEAL_THRESHOLD.
func _act_self_heal(wc: WeaponController, weapon: Weapon) -> void:
	if not wc._is_ready():
		_trigger.release_all()
		return
	var fire_index := _select_self_heal_fire_index(weapon)
	if fire_index < 0:
		_trigger.release_all()
		return

	_chosen_fire_index = fire_index
	var feet := player.global_position
	_desired_aim_point = feet
	_has_desired_aim = true
	_mouse.request_look_at_point(feet, LookPriority.COMBAT, 1.0, "self_heal")
	# A self-heal is a standstill action; the mouse pitches down.
	_move_local(Vector2.ZERO)
	_trigger.request_fire(fire_index, true)

func _act_pursue_last_seen() -> void:
	var to_last := _last_seen_position - player.global_position
	var flat := Vector3(to_last.x, 0, to_last.z)
	var dist := flat.length()

	if dist < CLOSE_ENOUGH:
		_last_seen_position = Vector3.INF
		_pick_wander_target()
		return

	var wc: WeaponController = player.weapon_controller
	if _try_explosion_jump(wc, dist):
		return

	_trigger.release_all()
	_has_desired_aim = false
	_traversal.move_to(_last_seen_position, 1.0, 1.0, 0.0)

func _act_wander() -> void:
	_trigger.release_all()
	_has_desired_aim = false

	var wc: WeaponController = player.weapon_controller
	if wc._is_ready():
		_update_weapon_choice(wc, 15.0, false)
		if _buttons.is_switch_pending() or wc.is_switching():
			_trigger.release_all()
			_keyboard.set_move(0, 0)
			return
		_maybe_tactical_reload(wc)

	# `_wander_target` defaults to Vector3.ZERO.  Without this guard a bot with no
	# objective (MAIN_MENU / DEATHMATCH) walks toward the world origin instead of
	# wandering locally.
	if _wander_target == Vector3.ZERO \
			or _wander_target.distance_to(player.global_position) > WANDER_RANGE * 2.0:
		_keyboard.set_move(0, 0)
		_pick_wander_target()
		return

	var to_wander := _wander_target - player.global_position
	var flat := Vector2(to_wander.x, to_wander.z)

	if flat.length() < 1.5:
		_keyboard.set_move(0, 0)
		_pick_wander_target()
		return
	if _try_explosion_jump(wc, flat.length()):
		return

	_traversal.move_to(_wander_target, 0.25, 1.2, 0.35)


# Hunt / SEARCH (Stage 7)

## Hunt length scales with aggression: a cautious bot gives up quickly, a
## bloodthirsty one keeps clearing angles for up to HUNT_DURATION_MAX.
func _search_duration() -> float:
	return lerpf(HUNT_DURATION_MIN, HUNT_DURATION_MAX, _aggression_trait())


## Start (or restart) a hunt at [param at].  The hunt owns a stable origin
## (`_search_origin`) because `_last_seen_position` is cleared on expiry.  The
## deadline is wall-clock so it keeps running through other Decision states.
func _begin_search(at: Vector3, velocity: Vector3 = Vector3.ZERO,
		direction: Vector3 = Vector3.ZERO, persistent: bool = false) -> void:
	if at == Vector3.INF:
		return
	var now_ms := Time.get_ticks_msec()
	var lost_distance := player.global_position.distance_to(at)
	_search_active = true
	_search_persistent = persistent
	_search_origin = at
	_last_seen_position = at
	_last_seen_velocity = velocity
	_last_seen_time = float(now_ms) / 1000.0
	if persistent:
		# Heard-memory search: no deadline.  It ends only on a target, a new
		# search, or an objective coming nearby.
		_search_timer = INF
		_search_deadline_ms = 0
	else:
		_search_timer = _search_duration()
		_search_deadline_ms = now_ms + int(
			(_search_duration() + minf(8.0, lost_distance / WALK_SPEED)) * 1000.0
		)
	var dir := Vector3(direction.x, 0.0, direction.z)
	if dir.length_squared() < 0.01:
		dir = Vector3(velocity.x, 0.0, velocity.z)
	if dir.length_squared() < 0.01:
		dir = Vector3(
			at.x - player.global_position.x,
			0.0,
			at.z - player.global_position.z
		)
	_search_direction = dir.normalized() if dir.length_squared() > 0.01 \
		else Vector3.ZERO
	_clear_hunt()
	_hunt_point_timer = HUNT_APPROACH_TIMEOUT


func _clear_hunt() -> void:
	_hunt_points.clear()
	_hunt_index = 0
	_hunt_dwell = 0.0
	_hunt_origin = Vector3.INF
	_hunt_seeded = false
	_hunt_dwelling = false
	_hunt_point_timer = 0.0
	_hunt_timed_index = -1
	_hunt_partial_timer = 0.0


## A standable point at [param candidate]'s horizontal position: floor within
## 3 m, walkable slope, no wall/low ceiling in the capsule.  INF when unusable.
func _ground_point(space: PhysicsDirectSpaceState3D,
		candidate: Vector3, reference_y: float = NAN) -> Vector3:
	_steer_query.from = candidate + Vector3.UP * 1.5
	_steer_query.to = candidate - Vector3.UP * 3.0
	var floor_hit := space.intersect_ray(_steer_query)
	if floor_hit.is_empty():
		return Vector3.INF
	var floor_pos: Vector3 = floor_hit.position
	# Hunt points are built around the target's last-known Y, which may be on a
	# floor the bot cannot share; compare the floor to that origin rather than to
	# the bot, or every ring candidate is rejected.
	var ref_y := player.global_position.y if is_nan(reference_y) else reference_y
	if absf(floor_pos.y - ref_y) > 4.0:
		return Vector3.INF
	if (floor_hit.normal as Vector3).angle_to(Vector3.UP) \
			> deg_to_rad(FLOOR_MAX_ANGLE_DEG):
		return Vector3.INF
	candidate.y = floor_pos.y
	# Reject a point inside a wall or under a low ceiling.
	_steer_query.from = candidate + Vector3.UP * 0.4
	_steer_query.to = candidate + Vector3.UP * 1.8
	if not space.intersect_ray(_steer_query).is_empty():
		return Vector3.INF
	return candidate


## Build the search fan around the last-known spot.  A known escape direction
## gets a directional fan (±55°) so a runner is followed rather than searched
## in a symmetrical ring; without a direction it falls back to the full ring.
## Deliberately no LOS-to-origin requirement: the far side of the pillar is
## exactly where the player may be hiding.
func _seed_hunt_points() -> void:
	_clear_hunt()
	_hunt_origin = _search_origin
	_hunt_seeded = true
	if _search_origin == Vector3.INF:
		return
	var space := player.get_world_3d().direct_space_state
	var fan: Array[Vector3] = []
	var direction := Vector3(
		_search_direction.x, 0.0, _search_direction.z
	)
	if direction.length_squared() > 0.01:
		direction = direction.normalized()
		for radius in HUNT_SWEEP_RADII:
			for angle_deg in HUNT_FAN_ANGLES:
				var angle := deg_to_rad(angle_deg)
				var candidate := _search_origin \
					+ direction.rotated(Vector3.UP, angle) * radius
				var ground := _ground_point(space, candidate, _search_origin.y)
				if ground == Vector3.INF \
						or ground.distance_to(_search_origin) < 1.5:
					continue
				fan.append(ground)
	else:
		for radius in HUNT_SWEEP_RADII:
			for i in HUNT_ANGLES:
				var angle := TAU * float(i) / float(HUNT_ANGLES)
				var candidate := _search_origin \
					+ Vector3(cos(angle), 0.0, sin(angle)) * radius
				var ground := _ground_point(space, candidate, _search_origin.y)
				if ground == Vector3.INF \
						or ground.distance_to(_search_origin) < 1.5:
					continue
				fan.append(ground)
	var origin := player.global_position
	fan.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.distance_squared_to(origin) < b.distance_squared_to(origin)
	)
	var limit := HUNT_MIN_POINTS \
		+ int(_aggression_trait() * float(HUNT_MAX_EXTRA_POINTS))
	for point in fan:
		if _hunt_points.size() >= limit:
			break
		_hunt_points.append(point)
	_hunt_timed_index = -1
	_hunt_partial_timer = 0.0


## Weapon upkeep shared by the travel-to-last-seen and sweep phases.
func _act_search_weapons() -> void:
	var wc: WeaponController = player.weapon_controller
	if wc == null or not wc._is_ready():
		return
	_update_weapon_choice(wc, 15.0, false)
	if _buttons.is_switch_pending() or wc.is_switching():
		return
	_maybe_tactical_reload(wc)


## SEARCH: go to the predicted last-known point, then clear a directional fan
## around it instead of walking straight past.  The wall-clock deadline is owned
## by `_tick_target_memory`; this function only performs the movement.
func _act_search() -> void:
	_trigger.release_all()
	_has_desired_aim = false
	if not _search_active or _last_seen_position == Vector3.INF:
		_clear_hunt()
		_act_seek_objective_or_wander()
		return

	# A distant hunt must not pull the bot off the objective.  Search around the
	# point instead; if the bot is already far and the lead is far, return.
	if _objective_active and _objective_position != Vector3.INF \
			and not _search_persistent:
		var obj_dist := player.global_position.distance_to(_objective_position)
		var origin_dist := _search_origin.distance_to(_objective_position)
		if obj_dist > _objective_leash_radius \
				and origin_dist > _objective_leash_radius:
			_traversal.move_to(
				_objective_position, 0.8,
				maxf(_objective_hold_radius * 0.7, 1.5), 0.1
			)
			_act_search_weapons()
			return

	var pos := player.global_position
	var flat_to := Vector2(
		_last_seen_position.x - pos.x, _last_seen_position.z - pos.z
	)

	# Phase 1: reach the predicted point.  If it is unreachable, seed the fan
	# from the closest reachable area instead of stalling.
	if not _hunt_seeded:
		if flat_to.length() > HUNT_ARRIVE_RADIUS:
			_hunt_point_timer = maxf(_hunt_point_timer - PROCESS_INTERVAL, 0.0)
			if _hunt_point_timer > 0.0:
				_traversal.move_to(
					_last_seen_position, 0.9, 1.2, 0.15, _memory_chasing
				)
				_act_search_weapons()
				return
		_seed_hunt_points()

	# Phase 2: sweep the fan/ring.  Rebuild only if the origin has moved.
	if not _hunt_points.is_empty() \
			and _search_origin.distance_to(_hunt_origin) > HUNT_ORIGIN_MOVE:
		_seed_hunt_points()
	if _hunt_points.is_empty():
		# No standable points (ledge/open pit): scan from the last-known point
		# and let the wall-clock deadline end the hunt.
		_keyboard.set_move(0, 0)
		_mouse.request_look_at_point(
			_search_origin + Vector3.UP * AIM_CENTER_HEIGHT,
			LookPriority.GLANCE, 0.5, "hunt_scan"
		)
		_act_search_weapons()
		return

	if _hunt_index >= _hunt_points.size():
		_hunt_index = 0
		_hunt_dwelling = false
		_hunt_dwell = 0.0
		_hunt_timed_index = -1
		_hunt_partial_timer = 0.0
	if _hunt_dwelling:
		_keyboard.set_move(0, 0)
		_hunt_dwell = maxf(_hunt_dwell - PROCESS_INTERVAL, 0.0)
		_mouse.request_look_at_point(
			_search_origin + Vector3.UP * AIM_CENTER_HEIGHT,
			LookPriority.GLANCE, 0.4, "hunt_scan"
		)
		if _hunt_dwell <= 0.0:
			_hunt_dwelling = false
			_hunt_index += 1
			_hunt_timed_index = -1
			_hunt_partial_timer = 0.0
		_act_search_weapons()
		return

	var point := _hunt_points[_hunt_index]
	var flat := point - player.global_position
	flat.y = 0.0
	if flat.length() <= HUNT_ARRIVE_RADIUS:
		_hunt_dwelling = true
		_hunt_dwell = randf_range(HUNT_DWELL_MIN, HUNT_DWELL_MAX)
		# Give the final hide/scan point a longer look.
		if _hunt_index == _hunt_points.size() - 1:
			_hunt_dwell *= 1.5
		_keyboard.set_move(0, 0)
	else:
		if _hunt_timed_index != _hunt_index:
			_hunt_timed_index = _hunt_index
			_hunt_point_timer = clampf(
				flat.length() / WALK_SPEED + 1.0,
				HUNT_POINT_TIMEOUT_MIN,
				HUNT_POINT_TIMEOUT_MAX
			)
			_hunt_partial_timer = 0.0
		_traversal.move_to(
			point, 1.0, HUNT_ARRIVE_RADIUS, 0.1, _memory_chasing
		)
		_hunt_point_timer = maxf(_hunt_point_timer - PROCESS_INTERVAL, 0.0)
		if _traversal.is_partial_approach():
			_hunt_partial_timer += PROCESS_INTERVAL
		else:
			_hunt_partial_timer = 0.0
		if _hunt_point_timer <= 0.0 \
				or _hunt_partial_timer >= HUNT_PARTIAL_ABANDON:
			# Blocked/unreachable: abandon this point rather than stall.
			_hunt_index += 1
			_hunt_timed_index = -1
			_hunt_partial_timer = 0.0
	_act_search_weapons()


## FLEE: movement-only break for contact.  The trigger stays released and the
## bot never calls `_act_combat()`; the decision state's job is distance and
## line-of-sight breaks, not trading shots.
func _act_flee() -> void:
	_trigger.release_all()
	_has_desired_aim = false

	_flee_timer = maxf(_flee_timer - PROCESS_INTERVAL, 0.0)
	var threat := _current_threat_position()
	if threat != Vector3.INF:
		_flee_threat_pos = threat
	if _flee_timer <= 0.0 \
			or _health_ratio() > _flee_health_threshold() \
			or not _has_survival_threat() \
			or _assess_retreat() != RetreatNeed.FLEE:
		_end_flee()
		return

	if _flee_repath_timer > 0.0:
		_flee_repath_timer = maxf(_flee_repath_timer - PROCESS_INTERVAL, 0.0)
	if _flee_position == Vector3.INF and _flee_repath_timer <= 0.0:
		_flee_position = _find_flee_position(_flee_threat_pos)
		_flee_repath_timer = FLEE_REPATH_INTERVAL
		if _flee_position == Vector3.INF:
			_flee_position = _pick_backoff_position(_flee_threat_pos)
		if _flee_position == Vector3.INF:
			# Cornered: every escape direction is blocked, so fight.
			_end_flee()
			return

	if _flee_position == Vector3.INF:
		# Waiting for the repath cooldown; hold still rather than run blind.
		_keyboard.set_move(0, 0)
		return

	_traversal.move_to(_flee_position, 1.0, FLEE_ARRIVE_RADIUS, 0.0)
	var flat := _flee_position - player.global_position
	flat.y = 0.0
	if flat.length() <= FLEE_ARRIVE_RADIUS:
		_flee_position = Vector3.INF
		_flee_repath_timer = 0.0


## Leave FLEE.  A critical bot keeps a cooldown so FLEE/COVER/COMBAT cannot
## ping-pong on every decision tick; cover is the holding pattern while it runs.
func _end_flee() -> void:
	_trigger.release_all()
	_has_desired_aim = false
	_keyboard.set_move(0, 0)
	var still_hurt := _health_ratio() <= _cover_health_threshold() \
		and _has_survival_threat()
	if still_hurt:
		_flee_cooldown = lerpf(
			FLEE_COOLDOWN_MIN, FLEE_COOLDOWN_MAX, _survival_trait()
		)
	else:
		_flee_cooldown = 0.0
	_flee_position = Vector3.INF
	_flee_timer = 0.0
	_flee_repath_timer = 0.0

	var next := Decision.State.TRAVEL
	if still_hurt:
		next = Decision.State.RETREAT_COVER if ENABLE_COVER else Decision.State.COMBAT
	elif _current_target != null and is_instance_valid(_current_target):
		next = Decision.State.COMBAT
	elif _search_active:
		next = Decision.State.SEARCH
	_decision.interrupt(next)


## RELOAD_SAFE: keep eyes on the threat, break line of sight if cover is near,
## and reload.  Falls back to backing up when no cover is found.
func _act_reload_safe() -> void:
	_trigger.release_all()
	_has_desired_aim = false
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_release_movement()
		return
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon != null and not weapon.has_infinite_ammo \
			and weapon.mag_current < weapon.mag_size and not wc._is_reloading:
		_buttons.request_reload()

	if _current_target == null or not is_instance_valid(_current_target):
		_act_seek_objective_or_wander()
		return

	var threat := _target_position_for_ai()
	if threat == Vector3.INF:
		threat = _last_seen_position
	if ENABLE_COVER:
		if _cover_position == Vector3.INF:
			_cover_position = _find_cover_position(threat)
		if _cover_position != Vector3.INF:
			_traversal.move_to(_cover_position, 1.0, 0.8, 0.0)
		else:
			_move_local(Vector2(_strafe_dir, 1.0))
	else:
		_move_local(Vector2(_strafe_dir, 1.0))
	var reload_look := _target_look_point_for_ai()
	if reload_look != Vector3.INF:
		_mouse.request_look_at_point(
			reload_look, LookPriority.COMBAT, 0.8,
			str(_current_target.get_instance_id())
		)


## RETREAT_COVER: move behind cover, wait, peek/fire, duck back.  It deliberately
## falls back to normal combat if no usable cover is found.
func _act_retreat_cover() -> void:
	if not ENABLE_COVER:
		_decision.interrupt(
			Decision.State.COMBAT if _current_target != null else Decision.State.TRAVEL
		)
		_act_context()
		return

	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_release_movement()
		return
	var surv := _survival_trait()

	if _current_target != null and is_instance_valid(_current_target):
		var threat_pos := _target_position_for_ai()
		if threat_pos != Vector3.INF:
			_cover_threat_pos = threat_pos
	if _cover_position == Vector3.INF:
		_cover_position = _find_cover_position(_cover_threat_pos)
		if _cover_position == Vector3.INF:
			_cover_cooldown = 6.0
			if _assess_retreat() == RetreatNeed.FLEE and _flee_cooldown <= 0.0:
				# No cover and critically hurt: break contact instead of fighting.
				_trigger.release_all()
				_has_desired_aim = false
				_decision.interrupt(Decision.State.FLEE)
				return
			_decision.interrupt(
				Decision.State.COMBAT if _current_target != null else Decision.State.TRAVEL
			)
			_act_context()
			return

	_cover_total_timer = maxf(_cover_total_timer - PROCESS_INTERVAL, 0.0)
	if _cover_total_timer <= 0.0:
		_cover_cooldown = 2.0
		if _assess_retreat() == RetreatNeed.FLEE and _flee_cooldown <= 0.0:
			_trigger.release_all()
			_has_desired_aim = false
			_decision.interrupt(Decision.State.FLEE)
			return
		_decision.interrupt(
			Decision.State.COMBAT if _current_target != null else Decision.State.TRAVEL
		)
		_act_context()
		return
	_cover_timer = maxf(_cover_timer - PROCESS_INTERVAL, 0.0)
	match _cover_phase:
		0:
			# Move behind the chosen cover.
			_trigger.release_all()
			_has_desired_aim = false
			_traversal.move_to(_cover_position, 1.0, 0.7, 0.0)
			var flat := _cover_position - player.global_position
			flat.y = 0.0
			if flat.length() <= 0.9:
				_cover_phase = 1
				_cover_timer = randf_range(
					lerpf(0.6, 1.0, surv), lerpf(1.4, 2.2, surv)
				)
				_keyboard.set_move(0, 0)
		1:
			# Catch breath behind cover; keep the threat watched.  A bot at the
			# flee threshold hunkers instead of peeking — unless the target is
			# ACTUALLY visible, in which case cover is not covering anything and
			# the bot should return fire instead of staring over the wall.
			#
			# Returning early only while the rest timer is still running is
			# load-bearing: `_cover_timer` is decremented above the match, so the
			# bot still advances to the peek phase when it expires.  Returning on
			# "target exists" alone kept this branch from ever reaching the timer
			# check, so RETREAT_COVER never waited, peeked or ducked.
			_keyboard.set_move(0, 0)
			var sees_target := _current_target != null \
				and is_instance_valid(_current_target) \
				and _current_target.spawned \
				and _has_line_of_sight_to_player(_current_target)
			if sees_target and _cover_timer > 0.0:
				_act_combat()
				return
			if not sees_target:
				# Do not carry a fire intent/aim from the last combat tick into
				# the catch-breath phase: the target is gone.
				_trigger.release_all()
				_has_desired_aim = false
			if _style != null and randf() < _style.crouch_rate * 0.5:
				_keyboard.crouch_hold(0.25)
			if _cover_threat_pos != Vector3.INF:
				_mouse.request_look_at_point(
					_cover_threat_pos + Vector3.UP * AIM_CENTER_HEIGHT,
					LookPriority.COMBAT, 0.6, "cover_wait"
				)
			if _cover_timer <= 0.0:
				if _health_ratio() <= _flee_health_threshold():
					_cover_timer = 0.5
					return
				_cover_phase = 2
				_cover_timer = randf_range(
					lerpf(0.55, 0.45, surv), lerpf(0.75, 0.65, surv)
				)
				_cover_peek_side = 1.0 if _strafe_bias >= 0.0 else -1.0
		2:
			# Step out only while the enemy is actually visible; a blind peek is
			# how a bot walks out of cover for nothing.
			var has_target := _current_target != null \
				and is_instance_valid(_current_target) and _target_visible
			if has_target:
				_act_combat()
				var peek_look := _target_look_point_for_ai()
				if peek_look != Vector3.INF:
					_mouse.request_look_at_point(
						peek_look, LookPriority.COMBAT, 0.9,
						str(_current_target.get_instance_id())
					)
				_move_local(Vector2(_cover_peek_side, -1.0))
			else:
				_keyboard.set_move(0, 0)
			_has_desired_aim = has_target
			if _cover_timer <= 0.0:
				_cover_phase = 3
				_cover_timer = randf_range(
					lerpf(0.30, 0.25, surv), lerpf(0.45, 0.35, surv)
				)
		3:
			# Duck back to cover.
			_trigger.release_all()
			_has_desired_aim = false
			_traversal.move_to(_cover_position, 1.0, 0.7, 0.0)
			if _cover_timer <= 0.0:
				_cover_rounds += 1
				if _cover_rounds >= COVER_ROUNDS_MAX and (
						_health_ratio() > _cover_health_threshold() + 0.1
						or _current_target == null):
					_decision.interrupt(
						Decision.State.COMBAT if _current_target != null else Decision.State.SEARCH
					)
				else:
					_cover_phase = 1
					_cover_timer = randf_range(
						lerpf(0.5, 0.8, surv), lerpf(1.2, 1.8, surv)
					)


## Shared fallback used by STUCK_RECOVER and by cover/reload exits.
func _act_context() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_release_movement()
		return
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if _health_ratio() < MEDIC_SELF_HEAL_THRESHOLD:
		var self_heal_index := _find_self_heal_weapon_index(wc)
		if self_heal_index >= 0:
			if wc.current_weapon_index == self_heal_index:
				_act_self_heal(wc, wc._weapons[self_heal_index])
				return
			if _switch_weapon(wc, self_heal_index):
				_trigger.release_all()
				return
	if _heal_target != null and is_instance_valid(_heal_target) \
			and _weapon_heals_allies(weapon) and _heal_is_safe():
		_act_heal()
	elif _current_target != null and is_instance_valid(_current_target) \
			and _current_target.spawned:
		_act_combat()
	elif _search_active:
		_act_search()
	else:
		_act_seek_objective_or_wander()


func _reload_while_travelling() -> void:
	var wc: WeaponController = player.weapon_controller
	if wc == null or not wc._is_ready() or wc._is_reloading:
		return
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon != null and not weapon.has_infinite_ammo \
			and weapon.mag_current < weapon.mag_size:
		_buttons.request_reload()


# Survival / threat assessment (Stage 7)

## Book `amount` of damage into the rolling pressure bucket.  Fraction of max HP,
## clamped, decayed in `_physics_process`; no allocation and no queries.
func _record_damage(amount: float, ac: AttributeComponent) -> void:
	if ac == null or ac.max_health <= 0.0 or amount <= 0.0:
		return
	_recent_damage = clampf(_recent_damage + amount / ac.max_health, 0.0, 1.0)


func _recent_damage_fraction() -> float:
	return clampf(_recent_damage, 0.0, 1.0)


func _survival_trait() -> float:
	return _style.survival if _style != null else lerpf(0.25, 0.85, clampf(skill, 0.0, 1.0))


func _aggression_trait() -> float:
	return _style.aggression if _style != null else clampf(skill, 0.0, 1.0)


## Position the AI may use for the current target.  While the target is unseen,
## this is the frozen last-known point, never the live hidden body.
func _target_position_for_ai() -> Vector3:
	if _current_target == null or not is_instance_valid(_current_target):
		return Vector3.INF
	if _target_visible:
		return _current_target.global_position
	if _memory_last_position != Vector3.INF:
		return _memory_last_position
	return _current_target.global_position


## Look point for the current target: the real head only while visible; a
## remembered target is looked at where it was last seen.
func _target_look_point_for_ai() -> Vector3:
	if _current_target == null or not is_instance_valid(_current_target):
		return Vector3.INF
	if _target_visible:
		return _get_head_position(_current_target)
	var known := _target_position_for_ai()
	if known == Vector3.INF:
		return Vector3.INF
	return known + Vector3.UP * TRAVEL_EYE_HEIGHT


## Where the bot believes the most urgent threat is.  A freshly resolved shooter
## outranks the bot's current target: being shot from behind is more urgent than
## whoever the crosshair happens to be on.
func _current_threat_position() -> Vector3:
	var now := float(Time.get_ticks_msec()) / 1000.0
	if not _last_damage_source_name.is_empty() \
			and now - _last_damage_time < 1.0 \
			and _last_damage_position != Vector3.INF:
		return _last_damage_position
	if _current_target != null and is_instance_valid(_current_target) \
			and _current_target.spawned:
		var known := _target_position_for_ai()
		if known != Vector3.INF:
			return known
	if _last_seen_position != Vector3.INF:
		return _last_seen_position
	return _last_damage_position


## Deliberately not an active-SEARCH test: with a 15 s hunt that would keep a
## healthy bot in cover for the whole hunt.  Survival only cares about an enemy
## the bot can actually account for.
func _has_survival_threat() -> bool:
	if _current_target != null and is_instance_valid(_current_target) \
			and _current_target.spawned:
		return true
	if _enemy_nearby:
		return true
	var now := float(Time.get_ticks_msec()) / 1000.0
	if not _last_damage_source_name.is_empty() \
			and now - _last_damage_time < SURVIVAL_THREAT_MEMORY \
			and _last_damage_position != Vector3.INF:
		return true
	return _search_active and _last_seen_time > 0.0 \
		and now - _last_seen_time < SURVIVAL_THREAT_MEMORY


## 0..1 reading of how badly the trade is going.  Damage rate dominates; being
## outnumbered and close adds; a much weaker enemy removes most of it so a bot
## finishes a kill instead of backing off.
func _threat_pressure() -> float:
	var damage_p := clampf(
		_recent_damage_fraction() / SURVIVAL_DAMAGE_REF, 0.0, 1.0
	)
	var numbers_p := clampf(float(maxi(_nearby_enemy_count - 1, 0)) / 2.0, 0.0, 1.0)
	var close_p := 0.0
	var threat := _current_threat_position()
	if threat != Vector3.INF:
		var dist := player.global_position.distance_to(threat)
		close_p = 1.0 - clampf(
			(dist - SURVIVAL_CLOSE_NEAR) / (SURVIVAL_CLOSE_FAR - SURVIVAL_CLOSE_NEAR),
			0.0, 1.0
		)
	var base := SURVIVAL_PRESSURE_DAMAGE_WEIGHT * damage_p \
		+ SURVIVAL_PRESSURE_NUMBERS_WEIGHT * numbers_p \
		+ SURVIVAL_PRESSURE_CLOSE_WEIGHT * close_p
	var winning := 0.0
	if _current_target != null and is_instance_valid(_current_target) \
			and _current_target.spawned:
		var ac := _current_target.attribute_component
		if ac != null and ac.max_health > 0.0:
			var enemy_hp: float = ac.health / ac.max_health
			winning = clampf(
				(_health_ratio() - enemy_hp + 0.10) / SURVIVAL_WINNING_REF,
				0.0, 1.0
			)
	return clampf(base * (1.0 - SURVIVAL_WINNING_RELIEF * winning), 0.0, 1.0)


func _cover_health_threshold() -> float:
	return clampf(
		lerpf(COVER_HEALTH_MIN, COVER_HEALTH_MAX, _survival_trait())
			+ _threat_pressure() * COVER_PRESSURE_BONUS,
		0.0, 0.85
	)


func _flee_health_threshold() -> float:
	var cover := _cover_health_threshold()
	var flee := lerpf(FLEE_HEALTH_MIN, FLEE_HEALTH_MAX, _survival_trait()) \
		+ _threat_pressure() * FLEE_PRESSURE_BONUS
	return clampf(flee, 0.0, maxf(0.0, cover - 0.02))


## `RetreatNeed.NONE / COVER / FLEE` for the current instant.
func _assess_retreat() -> int:
	if not _has_survival_threat():
		return RetreatNeed.NONE
	var hp := _health_ratio()
	if hp <= _flee_health_threshold():
		# A visible enemy at close range is a fight, not a footrace: running
		# with the trigger released just feeds them free damage.
		var fight_pos := _target_position_for_ai()
		if _target_visible and fight_pos != Vector3.INF \
				and player.global_position.distance_to(fight_pos) \
					<= FLEE_FIGHT_BACK_RANGE:
			return RetreatNeed.COVER if ENABLE_COVER else RetreatNeed.NONE
		return RetreatNeed.FLEE
	if hp <= _cover_health_threshold():
		return RetreatNeed.COVER if ENABLE_COVER else RetreatNeed.FLEE
	# Tactical cover while still healthy: a big recent hit is enough to make a
	# human break the angle, unless the shooter is already in their face.
	if ENABLE_COVER and hp < 0.9 and _recent_damage_fraction() >= 0.20 \
			and _survival_trait() >= 0.5 and _cover_cooldown <= 0.0:
		var threat := _current_threat_position()
		var threat_dist := player.global_position.distance_to(threat) \
			if threat != Vector3.INF else 999.0
		if not (_target_visible and threat_dist <= 8.0):
			return RetreatNeed.COVER
	return RetreatNeed.NONE


## Called by Decision on state entry for state-specific setup.
func _on_decision_enter(state: int) -> void:
	match state:
		Decision.State.COMBAT:
			_traversal.cancel_recovery()
			_strafe_force_change = true
			_shots_since_strafe = 0
			_combat_range_state = CombatRangeState.HOLD
			_combat_pattern = CombatPattern.WIDE
			_combat_settle_timer = 0.0
			_combat_probe_timer = 0.0
			_combat_stall_timer = 0.0
			_combat_stall_position = player.global_position
			_cover_position = Vector3.INF
			_cover_phase = 0
			_cover_rounds = 0
		Decision.State.SEARCH:
			# A live timer belongs to an already-running hunt; entering the state
			# must not restart it (or rebuild its sweep).
			if _search_timer <= 0.0:
				_begin_search(_last_seen_position, _last_seen_velocity)
			elif _search_origin == Vector3.INF:
				_search_origin = _last_seen_position
		Decision.State.RELOAD_SAFE:
			_traversal.cancel_recovery()
			_trigger.release_all()
			_cover_position = Vector3.INF
			_cover_phase = 0
			_cover_rounds = 0
			_buttons.request_reload()
		Decision.State.RETREAT_COVER:
			_traversal.cancel_recovery()
			_trigger.release_all()
			_has_desired_aim = false
			_cover_position = Vector3.INF
			_cover_phase = 0
			_cover_rounds = 0
			_cover_timer = 0.0
			_cover_total_timer = lerpf(
				COVER_TOTAL_TIME_MIN, COVER_TOTAL_TIME_MAX, _survival_trait()
			)
			_cover_threat_pos = _current_threat_position()
		Decision.State.FLEE:
			_traversal.cancel_recovery()
			_maneuvers.abort()
			_abort_explosion_jump()
			_trigger.release_all()
			_has_desired_aim = false
			_keyboard.set_move(0, 0)
			_flee_position = Vector3.INF
			_flee_threat_pos = _current_threat_position()
			_flee_timer = lerpf(FLEE_TIME_MIN, FLEE_TIME_MAX, _survival_trait())
			_flee_repath_timer = 0.0
		Decision.State.HEAL:
			_traversal.cancel_recovery()
			_trigger.release_all()
		_:
			pass


## Find a nearby spot that breaks line of sight from [param threat].  Conservative:
## requires a floor, a reasonably clear path, and a blocked threat->candidate ray.
## The far pass runs only when the near ring fails and the bot is careful enough
## to look further; it reuses the exact same rules.
func _find_cover_position(threat: Vector3) -> Vector3:
	if not ENABLE_COVER:
		return Vector3.INF
	var threat_pos := threat
	if threat_pos == Vector3.INF:
		threat_pos = _current_threat_position()
	if threat_pos == Vector3.INF:
		return Vector3.INF
	var space := player.get_world_3d().direct_space_state
	var best := _scan_cover_distances(space, threat_pos, COVER_NEAR_DISTANCES)
	if best != Vector3.INF:
		return best
	if _survival_trait() < COVER_FAR_MIN_SURVIVAL:
		return Vector3.INF
	return _scan_cover_distances(space, threat_pos, COVER_FAR_DISTANCES)


## One ring of cover candidates around the bot.
func _scan_cover_distances(space: PhysicsDirectSpaceState3D, threat_pos: Vector3,
		distances: Array[float]) -> Vector3:
	var origin := player.global_position
	var best := Vector3.INF
	var best_score := -INF
	for i in 8:
		var angle := TAU * float(i) / 8.0 + randf_range(-0.15, 0.15)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		for distance in distances:
			var candidate := origin + dir * distance
			# Must have floor under the candidate.
			_steer_query.from = candidate + Vector3.UP * 1.5
			_steer_query.to = candidate - Vector3.UP * 3.0
			var floor_hit := space.intersect_ray(_steer_query)
			if floor_hit.is_empty():
				continue
			var floor_pos: Vector3 = floor_hit.position
			if floor_pos.y < origin.y - 2.0:
				continue
			if (floor_hit.normal as Vector3).angle_to(Vector3.UP) \
					> deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				continue
			candidate.y = floor_pos.y
			# Path toward the spot must be broadly clear.
			var to_candidate := Vector2(candidate.x - origin.x, candidate.z - origin.z)
			if to_candidate.length() < 0.5:
				continue
			if _score_direction(origin + Vector3.UP * STEER_RAY_HEIGHT,
					to_candidate.normalized()) < minf(distance * 0.6, 4.0):
				continue
			# Covered from the threat?
			_los_query.from = threat_pos + Vector3.UP * 1.2
			_los_query.to = candidate + Vector3.UP * 1.0
			if space.intersect_ray(_los_query).is_empty():
				continue
			var score := candidate.distance_to(threat_pos) * 0.4 \
				- distance * 0.25 + randf_range(0.0, 0.25)
			if score > best_score:
				best_score = score
				best = candidate
	return best


## Where to break contact: prefer a spot that blocks the threat's line of sight,
## then distance that still moves away and remains walkable.  Unlike cover this
## does not require the spot to be hidden — open ground in the opposite direction
## is a valid escape.  Returns INF when nothing qualifies.
func _find_flee_position(threat: Vector3) -> Vector3:
	var threat_pos := threat
	if threat_pos == Vector3.INF:
		threat_pos = _current_threat_position()
	if threat_pos == Vector3.INF:
		return Vector3.INF
	var origin := player.global_position
	var space := player.get_world_3d().direct_space_state
	var distance_scale := lerpf(
		FLEE_DISTANCE_SCALE_MIN, FLEE_DISTANCE_SCALE_MAX, _survival_trait()
	)
	var threat_distance := origin.distance_to(threat_pos)
	var away := origin - threat_pos
	away.y = 0.0
	if away.length_squared() > 0.01:
		away = away.normalized()
	var best := Vector3.INF
	var best_score := -INF
	for i in 8:
		var angle := TAU * float(i) / 8.0 + randf_range(-0.2, 0.2)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		for base_distance in FLEE_BASE_DISTANCES:
			var distance: float = base_distance * distance_scale
			var candidate := origin + dir * distance
			_steer_query.from = candidate + Vector3.UP * 1.5
			_steer_query.to = candidate - Vector3.UP * 3.0
			var floor_hit := space.intersect_ray(_steer_query)
			if floor_hit.is_empty():
				continue
			var floor_pos: Vector3 = floor_hit.position
			if floor_pos.y < origin.y - 2.0:
				continue
			if (floor_hit.normal as Vector3).angle_to(Vector3.UP) \
					> deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				continue
			candidate.y = floor_pos.y
			# Never "flee" straight toward the shooter.
			if candidate.distance_to(threat_pos) < threat_distance - 1.0:
				continue
			var to_candidate := Vector2(candidate.x - origin.x, candidate.z - origin.z)
			if to_candidate.length() < 0.5:
				continue
			if _score_direction(origin + Vector3.UP * STEER_RAY_HEIGHT,
					to_candidate.normalized()) < minf(distance * 0.6, 4.0):
				continue
			_los_query.from = threat_pos + Vector3.UP * 1.2
			_los_query.to = candidate + Vector3.UP * 1.0
			var sheltered := not space.intersect_ray(_los_query).is_empty()
			var score := candidate.distance_to(threat_pos) * 0.4 \
				- to_candidate.length() * 0.2 \
				+ (8.0 if sheltered else 0.0) \
				+ dir.dot(away) * 2.0 \
				+ randf_range(0.0, 0.3)
			if score > best_score:
				best_score = score
				best = candidate
	return best


## Last-resort escape when no sampled point qualifies: a short step directly
## away from the threat, if the steering probe and floor allow it.
func _pick_backoff_position(threat: Vector3) -> Vector3:
	if threat == Vector3.INF:
		return Vector3.INF
	var away := player.global_position - threat
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = -player.horizontal_forward()
	if away.length_squared() < 0.01:
		return Vector3.INF
	away = away.normalized()
	var origin := player.global_position + Vector3.UP * STEER_RAY_HEIGHT
	# `_score_direction` returns the clear distance ahead (STEER_DISTANCE when
	# clear, negative on a hit).  Clamp the step to it: the previous fixed 8 m
	# point could sit inside the wall the bot had just probed, so a cornered bot
	# spent its whole FLEE pushing that wall.
	var clear := _score_direction(origin, Vector2(away.x, away.z))
	if clear < 2.0:
		return Vector3.INF
	if not _has_floor_side(away):
		return Vector3.INF
	var candidate := player.global_position + away * minf(8.0, clear * 0.8)
	# And require a standable endpoint (floor below, headroom above).
	return _ground_point(player.get_world_3d().direct_space_state, candidate)


## Precision weapons should not be jumping/crouching mid-shot.
func _is_precision_weapon(weapon: Weapon) -> bool:
	if weapon == null:
		return false
	if weapon.charged:
		return true
	for fire in weapon.weapon_fires:
		if fire != null and fire.bullet_type == WeaponFire.BulletType.HITSCAN \
				and fire.hitscan_range > 60.0:
			return true
	return false


## Keep a combat strafe from walking into a wall or off a ledge.
## Four-direction combat safety, refreshed on a timer rather than every tick.
## The old version only checked lateral motion; the radial component could walk
## a bot straight off a ledge or into a wall.
func _refresh_combat_safety() -> void:
	if _combat_probe_timer > 0.0:
		return
	_combat_probe_timer = COMBAT_PROBE_INTERVAL
	var forward := player.horizontal_forward()
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	forward = forward.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	var origin := player.global_position + Vector3.UP * STEER_RAY_HEIGHT
	_combat_block_forward = _dir_blocked(origin, forward)
	_combat_block_backward = _dir_blocked(origin, -forward)
	_combat_block_right = _dir_blocked(origin, right)
	_combat_block_left = _dir_blocked(origin, -right)


func _dir_blocked(origin: Vector3, dir: Vector3) -> bool:
	var flat := Vector2(dir.x, dir.z)
	return _score_direction(origin, flat) < 1.5 or not _has_floor_side(dir)


func _combat_strafe_safe(local: Vector2) -> Vector2:
	_refresh_combat_safety()
	if local.x > 0.0 and _combat_block_right:
		local.x = -local.x if not _combat_block_left else 0.0
	elif local.x < 0.0 and _combat_block_left:
		local.x = -local.x if not _combat_block_right else 0.0
	if local.y < 0.0 and _combat_block_forward:
		local.y = 0.0
	elif local.y > 0.0 and _combat_block_backward:
		local.y = 0.0
	return local


## Local combat stall handling: Traversal's recovery is deliberately skipped
## while a target is visible, so a held movement key against geometry needs its
## own escape.
func _tick_combat_stall() -> void:
	var pos := player.global_position
	if not _keyboard.is_moving():
		_combat_stall_timer = 0.0
		_combat_stall_position = pos
		return
	_combat_stall_timer += PROCESS_INTERVAL
	if _combat_stall_timer < COMBAT_STALL_TIME:
		return
	_combat_stall_timer = 0.0
	var moved := pos.distance_to(_combat_stall_position)
	_combat_stall_position = pos
	if moved >= COMBAT_STALL_DISTANCE:
		return
	_combat_probe_timer = 0.0
	_combat_pattern = CombatPattern.WIDE
	_strafe_timer = 0.0
	_strafe_force_change = true
	_strafe_reason = "stall"
	if absf(_strafe_dir) > 0.1:
		_strafe_dir = -_strafe_dir
	else:
		_strafe_dir = 1.0 if _strafe_bias >= 0.0 else -1.0


func _has_floor_side(side: Vector3) -> bool:
	var from := player.global_position + side * 1.2 + Vector3.UP * 0.6
	var to := from - Vector3.UP * 3.0
	var space := player.get_world_3d().direct_space_state
	_steer_query.from = from
	_steer_query.to = to
	var hit := space.intersect_ray(_steer_query)
	if hit.is_empty():
		return false
	return (hit.position as Vector3).y > player.global_position.y - 2.0


# Diagnostics
#
# Everything below is inert unless `debug_draw` (overlay) or `debug_log_weapons`
# (one-shot introspection log) is on.  Overlay nodes are created lazily, are
# parented to the Player so `despawn()` hides them with the bot, and are marked
# top_level so a size-change effect cannot scale the text or the lines.

## Show or hide the overlay nodes as the flags change.  `debug_draw`'s setter
## can hide them itself, but the dev-menu route toggle is global and flips
## without touching this bot.
func _debug_sync(delta: float) -> void:
	if _debug_visuals_enabled():
		_debug_tick(delta)
	elif _debug_label != null or _debug_ray_instance != null:
		_hide_debug_nodes()


## Per-bot inspector flag, or the dev menu's "Show nav paths" for routes only.
func _debug_visuals_enabled() -> bool:
	return debug_draw or GameManager.dev_show_bot_paths


func _debug_tick(delta: float) -> void:
	if not _debug_visuals_enabled():
		return
	_ensure_debug_nodes()
	if _debug_label != null:
		# Path-only mode uses this label for the intent line; the full overlay
		# uses it for the whole debug block.
		_debug_label.visible = true
	if _debug_ray_instance != null:
		_debug_ray_instance.visible = true

	_debug_refresh_timer += delta
	if _debug_refresh_timer < DEBUG_REFRESH_INTERVAL:
		return
	_debug_refresh_timer = 0.0
	_update_debug_label()
	_render_debug_lines()


func _ensure_debug_nodes() -> void:
	# The Player owns these nodes, so a freed Player takes them with it.  Clear
	# the cached references rather than touching a freed instance.
	if _debug_label != null and not is_instance_valid(_debug_label):
		_debug_label = null
	if _debug_ray_instance != null and not is_instance_valid(_debug_ray_instance):
		_debug_ray_instance = null
		_debug_ray_mesh = null
		_debug_ray_material = null
		_debug_path_material = null

	# Path-only mode creates the line mesh and the compact intent label.
	if _debug_visuals_enabled() and _debug_label == null:
		var label := Label3D.new()
		label.name = "BotDebugLabel"
		label.top_level = true
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.font_size = DEBUG_LABEL_FONT_SIZE
		label.pixel_size = DEBUG_LABEL_PIXEL_SIZE
		label.outline_size = 8
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
		player.add_child(label)
		_debug_label = label

	if _debug_ray_instance == null:
		var line_mesh := ImmediateMesh.new()
		var ray_material := StandardMaterial3D.new()
		ray_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ray_material.vertex_color_use_as_albedo = true
		ray_material.vertex_color_is_srgb = true
		ray_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var path_material := StandardMaterial3D.new()
		path_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		path_material.vertex_color_use_as_albedo = true
		path_material.vertex_color_is_srgb = true
		path_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# A debug route is useless if geometry hides it, and ribbons are viewed
		# from both sides (overhead and first person).
		path_material.no_depth_test = true
		path_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		var ray_instance := MeshInstance3D.new()
		ray_instance.name = "BotDebugRays"
		ray_instance.top_level = true
		ray_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ray_instance.mesh = line_mesh
		player.add_child(ray_instance)
		_debug_ray_mesh = line_mesh
		_debug_ray_material = ray_material
		_debug_path_material = path_material
		_debug_ray_instance = ray_instance


func _update_debug_label() -> void:
	if _debug_label == null or not is_instance_valid(player):
		return
	_debug_label.global_position = player.global_position + Vector3.UP * DEBUG_LABEL_HEIGHT

	if not debug_draw:
		# Path-only mode: one compact "what should I be doing?" line above the
		# head, so the objective intent is visible with the route overlay.
		var intent_text := _intent_text
		if _search_persistent and _persistent_heard_position != Vector3.INF:
			intent_text += "  %dm" % roundi(
				player.global_position.distance_to(_persistent_heard_position)
			)
		elif _objective_active and _objective_position != Vector3.INF:
			intent_text += "  %dm" % roundi(
				player.global_position.distance_to(_objective_position)
			)
		_debug_label.text = intent_text
		return

	var hp: float = 0.0
	if player.attribute_component != null:
		hp = player.attribute_component.health

	var target_name := _debug_target_name()
	var lines := PackedStringArray()
	lines.append("%s  hp=%.0f" % [_debug_state_text(), hp])
	lines.append("target: %s" % target_name)
	lines.append("intent: %s" % _intent_text)
	var memory_label := _memory_target_name if not _memory_target_name.is_empty() else "-"
	var memory_left := maxf(
		float(_memory_expires_ms - Time.get_ticks_msec()) / 1000.0, 0.0
	)
	var lock_left := maxf(
		float(_target_lock_until_ms - Time.get_ticks_msec()) / 1000.0, 0.0
	)
	lines.append("vis=%s mem=%s mem_t=%.1f grace=%.2f lock=%.1f" % [
		_target_visible, memory_label, memory_left, _target_lost_timer, lock_left,
	])
	lines.append("search=%s t=%.1f chase=%s dir=%s" % [
		_search_active, _search_timer, _memory_chasing, _search_direction,
	])
	if _memory_target != null and is_instance_valid(_memory_target):
		lines.append("pred: %s" % _predicted_last_known(Time.get_ticks_msec()))
	lines.append("fire: %d  trig: %s" % [_chosen_fire_index, _debug_trigger_text()])
	lines.append("aim err: %s deg" % _debug_aim_error(target_name != "-"))
	if _style != null:
		lines.append(
			"traits: acc=%.2f trk=%.2f lead=%.2f move=%.2f aware=%.2f aggr=%.2f surv=%.2f"
			% [
				_style.accuracy, _style.tracking_speed, _style.lead_quality,
				_style.movement_quality, _style.awareness, _style.aggression,
				_style.survival,
			]
		)
		var need_index := clampi(
			_assess_retreat(), 0, RETREAT_NEED_NAMES.size() - 1
		)
		lines.append(
			"surv: need=%s dmg=%.2f near=%d vis=%d coverT=%.2f fleeT=%.2f flee=%.1f"
			% [
				RETREAT_NEED_NAMES[need_index], _recent_damage_fraction(),
				_nearby_enemy_count, _visible_enemy_count,
				_cover_health_threshold(), _flee_health_threshold(), _flee_timer,
			]
		)
		lines.append("hunt: pts=%d idx=%d t=%.1f lead=%.1f" % [
			_hunt_points.size(), _hunt_index, _search_timer,
			lerpf(HUNT_LEAD_MIN, HUNT_LEAD_MAX, _aggression_trait()),
		])
	if _current_target != null and is_instance_valid(_current_target):
		var tv := _estimated_velocity_for(_current_target)
		lines.append("lead: v=(%.1f,%.1f) arc=%s%s" % [
			tv.x, tv.z,
			"high" if _arc_validation_high else "low",
			" BLOCKED" if _arc_validation_blocked else "",
		])
	lines.append("keys: %s  mouse: %s %s" % [
		_keyboard.get_state_text() if _keyboard != null else "-",
		_mouse.get_state_text() if _mouse != null else "-",
		_mouse.get_delta_text() if _mouse != null else "-",
	])
	lines.append("decide: %s" % (_decision.get_state_text() if _decision != null else "-"))
	lines.append("travel: %s" % (_traversal.get_debug_text() if _traversal != null else "-"))
	lines.append("weapon: %s" % _debug_weapon_text())
	lines.append("scans: %d" % _full_scan_count)
	_debug_label.text = "\n".join(lines)


func _debug_state_text() -> String:
	if GameManager.dev_freeze_bots:
		return "frozen"
	if _traversal != null and _traversal.is_recovering():
		return "unstuck"
	if _heal_target != null and is_instance_valid(_heal_target):
		return "heal"
	if _current_target != null and is_instance_valid(_current_target):
		return "combat"
	if _last_seen_position != Vector3.INF:
		return "pursue"
	return "objective/wander"


func _debug_target_name() -> String:
	# `is_instance_valid` before the property access: a freed Reference compares
	# equal to null, but `.name` on it raises (see CLAUDE.md).
	if _current_target != null and is_instance_valid(_current_target):
		return str(_current_target.name)
	if _heal_target != null and is_instance_valid(_heal_target):
		return str(_heal_target.name)
	return "-"


func _debug_trigger_text() -> String:
	var held := ""
	if player.player_input.primary_fire_held:
		held += "P"
	if player.player_input.secondary_fire_held:
		held += "S"
	if player.player_input.tertiary_fire_held:
		held += "T"
	if held.is_empty():
		held = "-"
	if _trigger != null:
		held += " " + _trigger.get_state_text()
	return held


## The REAL head-ray error (degrees) and the gate's tolerance.  Measured every
## physics frame by `_update_aim_error`, not derived from the smoothed-aim
## targets, so this is exactly what the Trigger gates on.
func _debug_aim_error(has_target: bool) -> String:
	if not has_target or aim_error_deg < 0.0:
		return "-"
	return "%.1f tol %.1f" % [aim_error_deg, aim_tolerance_deg]


func _debug_weapon_text() -> String:
	var wc: WeaponController = player.weapon_controller
	if wc == null or not is_instance_valid(wc) or not wc._is_ready():
		return "-"
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon == null:
		return "-"
	var ammo := "inf" if wc.weapon_has_infinite_ammo(weapon) else "%d/%d" % [weapon.mag_current, weapon.mag_size]
	return "%s %s" % [weapon.display_name, ammo]


func _render_debug_lines() -> void:
	if _debug_ray_mesh == null:
		return
	_debug_ray_mesh.clear_surfaces()
	_render_debug_ray_surface()
	_render_debug_path_surface()


func _render_debug_ray_surface() -> void:
	if _debug_ray_lines.size() < 2:
		return
	_debug_ray_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _debug_ray_material)
	var i := 0
	while i + 1 < _debug_ray_lines.size():
		_debug_ray_mesh.surface_set_color(_debug_ray_colors[i])
		_debug_ray_mesh.surface_add_vertex(_debug_ray_lines[i])
		_debug_ray_mesh.surface_set_color(_debug_ray_colors[i + 1])
		_debug_ray_mesh.surface_add_vertex(_debug_ray_lines[i + 1])
		i += 2
	_debug_ray_mesh.surface_end()
	_debug_ray_lines.clear()
	_debug_ray_colors.clear()


## The route the bot is actually following, drawn from its body through every
## waypoint it has not reached yet.  With no route, a direct-steering bot still
## gets a straight goal line so "no path" is visible as red, not as nothing.
func _render_debug_path_surface() -> void:
	if _traversal == null or not is_instance_valid(player):
		return
	var points: Array[Vector3] = _traversal.get_debug_path()
	if points.size() >= 2:
		_draw_debug_strip(points, _debug_path_color(_traversal.get_debug_path_source()))
		return
	var goal := _traversal.get_debug_goal()
	if goal == Vector3.INF:
		return
	var direct: Array[Vector3] = []
	direct.append(player.global_position + Vector3.UP * DEBUG_PATH_LIFT)
	direct.append(goal + Vector3.UP * DEBUG_PATH_LIFT)
	_draw_debug_strip(direct, DEBUG_DIRECT_PATH_COLOR)


func _draw_debug_strip(points: Array[Vector3], color: Color) -> void:
	if points.size() < 2:
		return
	var half := DEBUG_PATH_WIDTH * 0.5
	_debug_ray_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _debug_path_material)
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var seg := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var side := Vector3(half, 0.0, 0.0)
		if seg.length_squared() > 0.0001:
			seg = seg.normalized()
			side = Vector3(-seg.z, 0.0, seg.x) * half
		var left_a := a - side
		var right_a := a + side
		var left_b := b - side
		var right_b := b + side
		_add_debug_vertex(left_a, color)
		_add_debug_vertex(right_a, color)
		_add_debug_vertex(left_b, color)
		_add_debug_vertex(right_a, color)
		_add_debug_vertex(right_b, color)
		_add_debug_vertex(left_b, color)
	_debug_ray_mesh.surface_end()


func _add_debug_vertex(point: Vector3, color: Color) -> void:
	_debug_ray_mesh.surface_set_color(color)
	_debug_ray_mesh.surface_add_vertex(point)


func _debug_path_color(source: int) -> Color:
	match source:
		Traversal.PathSource.NAV:
			return DEBUG_NAV_PATH_COLOR
		Traversal.PathSource.NAV_PARTIAL:
			return DEBUG_NAV_PARTIAL_COLOR
		Traversal.PathSource.GRAPH:
			return DEBUG_GRAPH_PATH_COLOR
		_:
			return DEBUG_DIRECT_PATH_COLOR


func _hide_debug_nodes() -> void:
	if _debug_label != null and is_instance_valid(_debug_label):
		_debug_label.visible = false
	if _debug_ray_instance != null and is_instance_valid(_debug_ray_instance):
		_debug_ray_instance.visible = false


## Print [param msg] exactly once per [param key].  Duck-typed schema probes use
## this: a miss is worth reporting once, not 20x/sec from every bot.
func _warn_once(key: String, msg: String) -> void:
	if _warned_once.has(key):
		return
	_warned_once[key] = true
	var who := "?"
	if is_instance_valid(player):
		who = str(player.name)
	push_warning("[BotController:%s] %s" % [who, msg])


## Read the first non-null property in [param names], warning once (keyed on
## [param context]) when none exists, and falling back to [param default].
##
## A property whose legitimate value IS null is indistinguishable from a missing
## one here.  Every current probe looks for a number, vector or bool, so that
## distinction is not needed.
func _read_prop(obj: Object, names: Array[String], default: Variant, context: String) -> Variant:
	return _read_prop_ex(obj, names, default, context)["value"]


## [method _read_prop] plus the name that answered; `source` is empty when the
## default was used.  Only the introspection log reads the extra field.
func _read_prop_ex(obj: Object, names: Array[String], default: Variant, context: String) -> Dictionary:
	if is_instance_valid(obj):
		for property_name in names:
			var value: Variant = obj.get(property_name)
			if value != null:
				return {"value": value, "source": property_name}
	_warn_once(context, "none of %s is readable on %s (%s); using %s" % [
		str(names), _describe_object(obj), context, str(default)
	])
	return {"value": default, "source": ""}


func _describe_object(obj: Object) -> String:
	if not is_instance_valid(obj):
		return "<freed/null>"
	var object_script = obj.get_script()
	if object_script is Script:
		return "%s(%s)" % [obj.get_class(), (object_script as Script).resource_path]
	return obj.get_class()


## One-time per weapon RESOURCE (static, so 12 bots on one weapon log once):
## report what the duck-typed probes actually found, including which property
## answered.  This is the evidence the later stages use instead of guesses.
func _log_weapon_once(weapon: Weapon) -> void:
	if weapon == null:
		return
	var path := weapon.resource_path
	var key: String = path if not path.is_empty() else str(weapon.get_instance_id())
	if _introspected_weapons.has(key):
		return
	_introspected_weapons[key] = true

	var range_info := _get_engagement_range_info(weapon)
	var lines := PackedStringArray()
	lines.append("[BotController] weapon '%s' (%s) mag=%d reload=%.2f charged=%s melee=%s engage=%.1f via %s" % [
		weapon.display_name,
		path if not path.is_empty() else "<inline>",
		weapon.mag_size,
		weapon.reload_time,
		str(weapon.charged),
		str(_is_melee_weapon(weapon)),
		float(range_info["range"]),
		str(range_info["source"]),
	])
	for i in weapon.weapon_fires.size():
		var fire: WeaponFire = weapon.weapon_fires[i]
		if fire == null:
			continue
		var line := "  fire[%d] action=%d bullet=%d auto=%s pre=%.2f post=%.2f cost=%d" % [
			i,
			int(fire.action_type),
			int(fire.bullet_type),
			str(fire.automatic),
			fire.pre_shoot_delay,
			fire.post_shoot_delay,
			fire.ammo_cost,
		]
		if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
			var proj := _get_proj_info(fire)
			line += " | proj=%s speed=%.1f via %s explosive=%s heals=%s" % [
				fire.projectile_scene.resource_path if fire.projectile_scene != null else "<none>",
				float(proj.get("speed", 0.0)),
				str(proj.get("speed_source", "none")),
				str(proj.get("is_explosive", false)),
				str(proj.get("heals_allies", false)),
			]
		lines.append(line)
	print("\n".join(lines))

# Helpers

# Fire-mode selection
#
# Deterministic and event-driven — no 2 s dice roll.  The chosen mode is stable
# until the weapon, magazine, target or engagement distance changes enough to
# matter, so a bot does not flip modes mid-fight.

func _shoot_indices_for(weapon: Weapon) -> Array[int]:
	var key := weapon.resource_path if not weapon.resource_path.is_empty() else str(weapon.get_instance_id())
	var indices: Array[int] = []
	if _shoot_indices_cache.has(key):
		# Rebuild a typed copy: `as Array[T]` does not convert (see CLAUDE.md),
		# and a Dictionary value comes back as Variant.
		for value in _shoot_indices_cache[key]:
			indices.append(int(value))
		return indices
	for i in weapon.weapon_fires.size():
		var fire: WeaponFire = weapon.weapon_fires[i]
		if fire != null and fire.action_type == WeaponFire.ActionType.SHOOT:
			indices.append(i)
	_shoot_indices_cache[key] = indices.duplicate()
	return indices


func _update_fire_mode(weapon: Weapon, dist: float) -> void:
	if weapon == null:
		_chosen_fire_index = -1
		return
	var wc: WeaponController = player.weapon_controller
	var weapon_key := weapon.resource_path if not weapon.resource_path.is_empty() else str(weapon.get_instance_id())
	if weapon_key != _specialty_weapon_key:
		_specialty_weapon_key = weapon_key
		_refresh_weapon_specialty(weapon)
	var target_name := ""
	if _current_target != null and is_instance_valid(_current_target):
		target_name = str(_current_target.name)
	elif _heal_target != null and is_instance_valid(_heal_target):
		target_name = str(_heal_target.name)

	var current_valid := _chosen_fire_index >= 0 \
		and _chosen_fire_index < weapon.weapon_fires.size() \
		and weapon.weapon_fires[_chosen_fire_index] != null \
		and weapon.weapon_fires[_chosen_fire_index].action_type == WeaponFire.ActionType.SHOOT
	if current_valid and wc != null and not wc.weapon_has_infinite_ammo(weapon):
		current_valid = weapon.mag_current >= wc._get_fire_ammo_cost(weapon, _chosen_fire_index)

	var need_recalc := _fire_mode_dirty or not current_valid \
		or weapon_key != _fire_mode_weapon_key \
		or target_name != _fire_mode_target_name \
		or weapon.mag_current != _fire_mode_mag \
		or _fire_mode_dist < 0.0 \
		or absf(dist - _fire_mode_dist) > FIRE_MODE_DIST_HYSTERESIS
	if not need_recalc:
		return

	var candidate := _select_fire_mode(weapon, dist)
	var switch_to := candidate
	if current_valid and candidate >= 0 and candidate != _chosen_fire_index:
		var current_score := _score_fire_mode(weapon, _chosen_fire_index, dist)
		var candidate_score := _score_fire_mode(weapon, candidate, dist)
		if candidate_score < current_score + FIRE_MODE_SCORE_HYSTERESIS:
			switch_to = _chosen_fire_index
	_chosen_fire_index = switch_to
	_fire_mode_dirty = false
	_fire_mode_weapon_key = weapon_key
	_fire_mode_target_name = target_name
	_fire_mode_mag = weapon.mag_current
	_fire_mode_dist = dist


func _select_fire_mode(weapon: Weapon, dist: float) -> int:
	var wc: WeaponController = player.weapon_controller
	var best := -1
	var best_score: float = -INF
	for index in _shoot_indices_for(weapon):
		var fire: WeaponFire = weapon.weapon_fires[index]
		if fire == null:
			continue
		if wc != null and not wc.weapon_has_infinite_ammo(weapon):
			if weapon.mag_current < wc._get_fire_ammo_cost(weapon, index):
				continue
		var score := _score_fire_mode(weapon, index, dist)
		if score > best_score:
			best_score = score
			best = index
	return best


func _score_fire_mode(weapon: Weapon, index: int, dist: float) -> float:
	var fire: WeaponFire = weapon.weapon_fires[index]
	var range_info := _fire_range_info(fire)
	var effective := float(range_info.get("range_effective", _mode_effective_range(fire)))
	var ideal := float(range_info.get("range_ideal", effective * 0.75))
	var score := 100.0
	# Prefer the mode's ideal band; heavily punish a mode whose shots cannot
	# reach the target at all.  Falloff is already folded into `effective`.
	score -= 18.0 * absf(dist - ideal) / maxf(ideal, 1.0)
	if dist > effective:
		score -= 220.0
	if bool(range_info.get("melee", false)):
		score += 45.0 if dist <= effective + WEAPON_MELEE_ONLY_MARGIN else -420.0
	if bool(range_info.get("automatic", false)) and dist < effective * 0.75:
		score += 8.0
	if fire.has_damage_falloff and fire.falloff_end > fire.falloff_start:
		var falloff_t := clampf(
			(dist - fire.falloff_start) / (fire.falloff_end - fire.falloff_start),
			0.0, 1.0
		)
		score -= 24.0 * falloff_t

	var wc: WeaponController = player.weapon_controller
	var cost := 0
	if wc != null:
		cost = wc._get_fire_ammo_cost(weapon, index)
	score -= 1.5 * float(cost)

	var info := _get_proj_info(fire)
	if bool(info.get("is_explosive", false)):
		var splash := float(info.get("splash_radius", 0.0))
		# Only a blast that actually hurts the shooter is penalised, and only when
		# that self-damage would leave it about to die.  The Heal Grenade
		# Launcher's self multiplier is -1 x -45, i.e. a self-heal.
		if float(info.get("self_damage", -1.0)) < 0.0 \
				and not _accept_self_damage(info) \
				and dist < splash + EXPLOSIVE_SAFE_MARGIN:
			score -= 300.0

	# Alt-fire with a distinct purpose, expressed in the data rather than by
	# guessing from the weapon name.
	if fire.self_health_delta_on_shoot < 0.0:
		score -= 250.0 * absf(fire.self_health_delta_on_shoot)
	if fire.self_health_delta_on_hit > 0.0:
		score += 40.0
	if fire.multishot_mode == WeaponFire.MultishotMode.SHOTGUN \
			and fire.multishot_data.size() > 3 and dist < effective * 0.5:
		score += 20.0
	if fire.multishot_mode == WeaponFire.MultishotMode.BURST:
		if dist < effective * 0.8 and cost <= weapon.mag_current:
			score += 10.0
		else:
			score -= 20.0
	return score


## Effective engagement reach of one fire mode, in metres.  Hitscan uses its
## authored range (1e9 means "whole map" -> SHOOT_RANGE); projectiles use
## speed x lifetime, which is why a grenade (27 m/s, 2.3 s) is correctly short-
## ranged while a rocket (20 m/s, 20 s) is not.
func _mode_effective_range(fire: WeaponFire) -> float:
	if fire == null:
		return DEFAULT_RANGED_ENGAGE_DIST
	var info := _fire_range_info(fire)
	if info.is_empty():
		return DEFAULT_RANGED_ENGAGE_DIST
	return float(info["range_effective"])


func _select_explosive_fire_index(weapon: Weapon) -> int:
	for index in _shoot_indices_for(weapon):
		var fire: WeaponFire = weapon.weapon_fires[index]
		if fire != null and fire.bullet_type == WeaponFire.BulletType.PROJECTILE \
				and bool(_get_proj_info(fire).get("is_explosive", false)):
			return index
	return -1


## Explosives are a tool, not a hazard: a healthy bot accepts its own splash as
## a cost of doing damage.  It refuses only a blast that would leave it at or
## below the same "about to die" threshold that drives FLEE.  `self_damage` is
## negative for a damaging blast, positive for a healing one.
func _accept_self_damage(info: Dictionary) -> bool:
	var self_damage := float(info.get("self_damage", 0.0))
	if self_damage >= 0.0:
		return true
	if player == null or not is_instance_valid(player):
		return true
	var ac := player.attribute_component
	if ac == null or ac.max_health <= 0.0:
		return true
	return ac.health + self_damage > ac.max_health * _flee_health_threshold()


## True when firing [param fire] would splash the bot itself *and* that splash is
## no longer acceptable.  Explosive modes aim at the feet, so this is a
## self-damage guard, not a "don't shoot" rule: movement backs the bot off while
## the trigger is held.
func _too_close_for_explosive(fire: WeaponFire, dist: float) -> bool:
	var info := _get_proj_info(fire)
	if not bool(info.get("is_explosive", false)):
		return false
	# A healing blast (Heal Grenade Launcher) is safe — and useful — point-blank.
	if float(info.get("self_damage", -1.0)) >= 0.0:
		return false
	if _accept_self_damage(info):
		return false
	return dist < float(info.get("splash_radius", 0.0)) + EXPLOSIVE_SAFE_MARGIN


## First non-heal weapon that would not splash this bot at [param dist].  Used
## at point-blank to swap away from a self-damaging explosive instead of
## freezing in place while the target closes.
func _first_safe_weapon_index(wc: WeaponController, dist: float) -> int:
	for i in wc._weapons.size():
		if i == wc.current_weapon_index:
			continue
		var weapon: Weapon = wc._weapons[i]
		if weapon == null or _weapon_heals_allies(weapon):
			continue
		if not wc.weapon_has_infinite_ammo(weapon) and weapon.mag_current <= 0:
			continue
		if not _weapon_can_engage(weapon, dist):
			continue
		var dangerous := false
		for index in _shoot_indices_for(weapon):
			var fire: WeaponFire = weapon.weapon_fires[index]
			if fire != null and _too_close_for_explosive(fire, dist):
				dangerous = true
				break
		if not dangerous:
			return i
	return -1


# Special firing mechanisms
#
# This is the in-file "AI fire profile" for a Weapon.  Everything is derived
# from data — the SIGNAL fire's presence and the projectile's actual signal
# handler — so a new weapon with an ordinary exploding or redirecting
# projectile needs no bot changes.
#
# Extension points:
#   * charged weapons: `Weapon.charged` (draw/release handled by Trigger).
#   * explode-on-signal: a SIGNAL fire + a SHOOT projectile using
#     `simple_projectile.gd` (the base `_on_weapon_signal()` explodes).
#   * redirect-on-signal: a SIGNAL fire + a projectile that declares
#     `_initial_speed` (arrow.gd / redirectable_rocket.gd).
#   * anything else: OTHER, so the bot leaves the SIGNAL alone rather than
#     doing something wrong (e.g. gravity_rocket.gd flips gravity).
func _refresh_weapon_specialty(weapon: Weapon) -> void:
	_signal_mode = SignalMode.NONE
	_signal_index = -1
	_signal_projectile_path = ""
	_signal_blast_radius = 0.0
	if weapon == null:
		return

	for i in weapon.weapon_fires.size():
		var fire: WeaponFire = weapon.weapon_fires[i]
		if fire != null and fire.action_type == WeaponFire.ActionType.SIGNAL:
			_signal_index = i
			break
	if _signal_index < 0:
		return

	# The handler lives on the projectile, so classify the SHOOT projectile.
	# The SIGNAL fire's own projectile_scene/multishot fields are not used by
	# WeaponController and are not authoritative.
	for i in _shoot_indices_for(weapon):
		var shoot: WeaponFire = weapon.weapon_fires[i]
		if shoot == null or shoot.projectile_scene == null:
			continue
		var info := _get_proj_info(shoot)
		_signal_projectile_path = shoot.projectile_scene.resource_path
		_signal_blast_radius = float(info.get("splash_radius", 0.0))
		if bool(info.get("has_redirect_marker", false)):
			_signal_mode = SignalMode.REDIRECT
		elif str(info.get("script_path", "")).ends_with("simple_projectile.gd"):
			_signal_mode = SignalMode.EXPLODE
		else:
			_signal_mode = SignalMode.OTHER
		return
	_signal_mode = SignalMode.OTHER


## Live projectiles this bot fired from [param scene_path] ("" matches any).
## Exploded projectiles linger for a few seconds before being freed, so the
## ExplosionComponent flag skips them.
func _own_projectiles(scene_path: String) -> Array[SimpleProjectile]:
	var result: Array[SimpleProjectile] = []
	var parent := GameManager.projectile_parent
	if parent == null or not is_instance_valid(parent):
		return result
	for child in parent.get_children():
		if not child is SimpleProjectile:
			continue
		var proj := child as SimpleProjectile
		if not is_instance_valid(proj) or proj.is_queued_for_deletion():
			continue
		if proj.shooter_name != player.name:
			continue
		if not scene_path.is_empty() and proj.scene_file_path != scene_path:
			continue
		if proj._explosion_component != null and proj._explosion_component.exploded:
			continue
		result.append(proj)
	return result


func _has_live_own_projectile() -> bool:
	return not _own_projectiles(_signal_projectile_path).is_empty()


## True when a live signal projectile of this bot is close enough to the current
## target for its blast to matter.
func _own_projectile_near_target(blast_radius: float) -> bool:
	if _current_target == null or not is_instance_valid(_current_target):
		return false
	var target_pos := _target_position_for_ai()
	if target_pos == Vector3.INF:
		return false
	for proj in _own_projectiles(_signal_projectile_path):
		if proj.global_position.distance_to(target_pos) <= blast_radius + SIGNAL_BLAST_MARGIN:
			return true
	return false

func _pick_wander_target() -> void:
	# Prefer a genuinely reachable graph node (it may be on another floor);
	# fall back to the old local ray-checked random offset while the graph bakes.
	if _traversal != null:
		var graph_point := _traversal.pick_wander_point(8.0, 20.0)
		if graph_point != Vector3.INF:
			_wander_target = graph_point
			return

	var origin := player.global_position + Vector3(0, STEER_RAY_HEIGHT, 0)
	for _attempt in 8:
		var offset := Vector3(
			randf_range(-WANDER_RANGE, WANDER_RANGE),
			0.0,
			randf_range(-WANDER_RANGE, WANDER_RANGE),
		)
		_wander_target = player.global_position + offset
		var to_w := Vector2(offset.x, offset.z)
		if to_w.length() < 2.0:
			continue
		var score := _score_direction(origin, to_w.normalized())
		if score > STEER_DISTANCE * 0.4:
			return

## Decide what to do when the current weapon runs dry. A real player reloads
## in place when it's safe, only swaps weapons when reloading would leave them
## defenseless against a target that's already close, and only ever resorts
## to melee when every gun is empty/reloading AND the target is already in
## melee range — never as an eager first choice.
func _bot_find_ammo_or_reload(wc: WeaponController) -> void:
	_trigger.release_all()
	var cur: Weapon = wc._weapons[wc.current_weapon_index]
	var dist := INF
	if _current_target != null and is_instance_valid(_current_target):
		var target_pos := _target_position_for_ai()
		if target_pos != Vector3.INF:
			dist = player.global_position.distance_to(target_pos)
	var cur_profile := _get_weapon_profile(cur)
	var can_reload_current := not cur.has_infinite_ammo and cur.mag_current < cur.mag_size

	# A reload already in flight should finish unless the fight is on top of us.
	if wc._is_reloading and dist > MELEE_CONSIDER_RANGE * 2.0:
		return

	# Reload in place when it is safe (or the target is far/out of LOS).
	if can_reload_current and _is_weapon_safe_to_reload(cur):
		_buttons.request_reload()
		return

	# Under pressure: pick the best ready weapon by range fit, not "anything
	# ranged".  Melee is a last resort and only inside its real reach.
	var best := _best_ready_weapon_index(wc, dist)
	if best >= 0 and best != wc.current_weapon_index:
		var best_weapon: Weapon = wc._weapons[best]
		if _weapon_can_engage(best_weapon, dist) or dist > float(cur_profile.get("range_effective", 8.0)):
			_switch_weapon(wc, best)
			return
	for i in wc._weapons.size():
		if i == wc.current_weapon_index:
			continue
		var melee: Weapon = wc._weapons[i]
		if melee == null or not _is_melee_weapon(melee):
			continue
		if melee.mag_current <= 0 and not melee.has_infinite_ammo:
			continue
		var melee_profile := _get_weapon_profile(melee)
		if dist <= float(melee_profile["range_effective"]) + WEAPON_MELEE_ONLY_MARGIN:
			_switch_weapon(wc, i)
			return

	if can_reload_current and not wc._is_reloading:
		_buttons.request_reload()

## Reset bot-local state on a false -> true `player.spawned` edge.  `rpc_reset`
## resets the Player and its weapons but knows nothing about this controller, so
## a stale target/trigger from the previous life would otherwise survive.
func _reset_for_spawn() -> void:
	_trigger.release_all()
	_keyboard.release_all()
	_mouse.cancel()
	_buttons.cancel()
	_maneuvers.abort()
	_traversal.reset()
	_decision.reset()
	_arc_validation_timer = 0.0
	_arc_validation_blocked = false
	_arc_validation_high = false
	_est_target_name = ""
	_est_velocity = Vector3.ZERO
	_seen_since.clear()
	_last_damage_source_name = ""
	_last_damage_time = -999.0
	_last_damage_position = Vector3.INF
	_last_damage_direction = Vector3.ZERO
	_recent_damage = 0.0
	_nearby_enemy_count = 0
	_visible_enemy_count = 0
	_last_seen_time = -999.0
	_heard_position = Vector3.INF
	_heard_distance = INF
	_heard_timer = 0.0
	_heard_kind = &""
	_last_seen_velocity = Vector3.ZERO
	_target_visible = false
	_memory_target = null
	_memory_target_name = ""
	_memory_last_position = Vector3.INF
	_memory_last_velocity = Vector3.ZERO
	_memory_last_seen_ms = 0
	_memory_expires_ms = 0
	_memory_seen_time = 0.0
	_memory_grace_until_ms = 0
	_memory_chasing = false
	_memory_search_started = false
	_target_lock_until_ms = 0
	_target_lost_timer = 0.0
	_search_timer = 0.0
	_search_active = false
	_search_persistent = false
	_persistent_heard_position = Vector3.INF
	_persistent_heard_velocity = Vector3.ZERO
	_persistent_heard_direction = Vector3.ZERO
	_persistent_heard_name = ""
	_search_origin = Vector3.INF
	_search_deadline_ms = 0
	_search_direction = Vector3.ZERO
	_clear_hunt()
	_glance_timer = 0.0
	_strafe_force_change = false
	_strafe_reason = ""
	_shots_since_strafe = 0
	_last_mag_for_strafe = -1
	_combat_jump_timer = 0.0
	_combat_crouch_timer = 0.0
	_combat_range_state = CombatRangeState.HOLD
	_combat_pattern = CombatPattern.WIDE
	_combat_settle_timer = 0.0
	_combat_probe_timer = 0.0
	_combat_block_left = false
	_combat_block_right = false
	_combat_block_forward = false
	_combat_block_backward = false
	_combat_stall_timer = 0.0
	_combat_stall_position = Vector3.ZERO
	_combat_chasing = false
	_combat_chase_stall = 0.0
	_cover_position = Vector3.INF
	_cover_threat_pos = Vector3.INF
	_cover_phase = 0
	_cover_timer = 0.0
	_cover_total_timer = 0.0
	_cover_cooldown = 0.0
	_cover_rounds = 0
	_flee_position = Vector3.INF
	_flee_threat_pos = Vector3.INF
	_flee_timer = 0.0
	_flee_cooldown = 0.0
	_flee_repath_timer = 0.0
	# A fresh body, the same personality: the stable seed keeps this bot's
	# variance while still drawing a fresh style for the current skill.
	_style.draw(skill, _style_seed)
	_apply_trait_overrides()
	_strafe_bias = randf_range(-0.25, 0.25)
	_choice_history.clear()
	_strafe_dir = 0.0
	_strafe_timer = 0.0
	_current_target = null
	_heal_target = null
	_last_seen_position = Vector3.INF
	_intent = Intent.NONE
	_intent_text = "—"
	_objective_position = Vector3.INF
	_objective_hold_radius = OBJECTIVE_HOLD_RADIUS
	_objective_leash_radius = OBJECTIVE_LEASH_RADIUS
	_objective_name = ""
	_objective_active = false
	_objective_owned = false
	_objective_contested = false
	_objective_kind = ""
	_objective_attacking = false
	_retarget_timer = 0.0
	_weapon_switch_guard = 0.0
	_chosen_fire_index = -1
	_fire_mode_dirty = true
	_fire_mode_target_name = ""
	_fire_mode_weapon_key = ""
	_fire_mode_mag = -1
	_fire_mode_dist = -1.0
	_weapon_choice_timer = 0.0
	_weapon_choice_target_name = ""
	_weapon_choice_band = -999
	_weapon_choice_reason = ""
	_heal_candidate_name = ""
	_heal_candidate_time = 0.0
	_heal_absent_time = 0.0
	_explosion_jump_phase = 0
	_explosion_jump_timer = 0.0
	_explosion_jump_fire_wait = 0.0
	_explosion_jump_fire_index = -1
	_explosion_jump_weapon_index = -1
	_reaction_timer = 0.0
	_last_health = -1.0
	_explosion_jump_cooldown_timer = 0.0
	_safe_top_off_timer = 0.0
	_enemy_nearby = false
	_has_desired_aim = false
	aim_error_deg = -1.0
	_refresh_los_excludes()
	# Seed a local wander point now; MAIN_MENU/DEATHMATCH have no objective, and
	# leaving the target at Vector3.ZERO sent every bot toward the world origin.
	_pick_wander_target()


## Weighted choice with a repeat penalty and optional bias, for the entropy the
## stage asks for.  `_choice_history` stores the last index chosen per key; a
## repeat is down-weighted rather than forbidden, so even a predictable bot
## occasionally changes its mind.
func _weighted_choice(weights: Array[float], key: String) -> int:
	if weights.is_empty():
		return -1
	var adjusted: Array[float] = []
	var total := 0.0
	var previous := int(_choice_history.get(key, -1))
	for i in weights.size():
		var weight := maxf(weights[i], 0.0)
		if i == previous:
			weight *= 0.35
		adjusted.append(weight)
		total += weight
	if total <= 0.0:
		return randi() % weights.size()
	var roll := randf() * total
	for i in adjusted.size():
		roll -= adjusted[i]
		if roll <= 0.0:
			_choice_history[key] = i
			return i
	_choice_history[key] = adjusted.size() - 1
	return adjusted.size() - 1


## ============================================================================
## STAGE 2 VERB LAYER
## ----------------------------------------------------------------------------
## These inner classes are the only writers of the player's input and facing.
## Decision code (_act_*) states intent; it never touches PlayerInput, body
## rotation, head rotation or the fire flags directly.
## ============================================================================

## ============================================================================
## STAGE 4 — DECISION STATE MACHINE
## ============================================================================

## Committed high-level intent.  Each state has a minimum duration; only a new
## visible enemy, a fresh hit, or a state-specific interrupt can cut it short.
## States call the existing act/aim/locomotion APIs and never write inputs.
class Decision extends RefCounted:
	enum State {
		TRAVEL, SEARCH, COMBAT, HEAL, RELOAD_SAFE, RETREAT_COVER, STUCK_RECOVER,
		FLEE,
	}

	var bot: BotController
	var state: State = State.TRAVEL
	var _min_timer: float = 0.0
	var _consider_timer: float = 0.0
	var _stuck_hold: float = 0.0
	var _reason: String = "spawn"

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot

	func reset() -> void:
		state = State.TRAVEL
		_min_timer = 0.0
		_consider_timer = 0.0
		_stuck_hold = 0.0
		_reason = "spawn"

	func interrupt(next: State) -> void:
		if next != state:
			_enter(next)

	func update(delta: float) -> void:
		_min_timer = maxf(_min_timer - delta, 0.0)
		_stuck_hold = maxf(_stuck_hold - delta, 0.0)
		_consider_timer -= delta
		if _consider_timer > 0.0:
			return
		_consider_timer = DECISION_INTERVAL
		_consider()

	func _consider() -> void:
		var desired := _desired_state()
		if desired == state:
			return
		if _min_timer > 0.0:
			return
		_enter(desired)

	func _desired_state() -> State:
		if not bot.player.spawned:
			return State.TRAVEL
		# One threat assessment per consideration, shared by every branch below.
		var need: int = bot._assess_retreat()
		# Stuck recovery is a locomotion state, not a reason to stop shooting.
		# It must not abandon a committed escape.
		if need != RetreatNeed.FLEE and bot._traversal.is_recovering() \
				and bot._current_target == null and bot._heal_target == null:
			return State.STUCK_RECOVER
		if state == State.STUCK_RECOVER and _stuck_hold > 0.0 \
				and need != RetreatNeed.FLEE:
			return State.STUCK_RECOVER
		# Already behind valid cover while critical: hunker.  The cover's total
		# timer (or the FLEE fallback when it expires) bounds this, so the bot
		# shelters before it sprints back into the open.
		if need == RetreatNeed.FLEE and state == State.RETREAT_COVER \
				and bot._cover_position != Vector3.INF:
			return State.RETREAT_COVER
		# Critical: break contact even if the bot could self-heal.  The flee
		# cooldown then hands control back to HEAL once some space is made.
		if need == RetreatNeed.FLEE and bot._flee_cooldown <= 0.0:
			return State.FLEE
		var wc: WeaponController = bot.player.weapon_controller
		if wc != null and wc._is_ready():
			# Self-heal outranks cover: a medic's own heal is the fastest exit.
			if bot._health_ratio() < MEDIC_SELF_HEAL_THRESHOLD \
					and bot._find_self_heal_weapon_index(wc) >= 0:
				return State.HEAL
		# While a critical bot's flee cooldown is running, cover is the holding
		# pattern: hunker rather than stand in the open between escape bursts.
		if ENABLE_COVER and bot._cover_cooldown <= 0.0 \
				and (need == RetreatNeed.COVER or need == RetreatNeed.FLEE):
			return State.RETREAT_COVER
		if wc != null and wc._is_ready():
			var weapon: Weapon = wc._weapons[wc.current_weapon_index]
			if bot._heal_target != null and is_instance_valid(bot._heal_target) \
					and bot._weapon_heals_allies(weapon) \
					and bot._heal_is_safe():
				return State.HEAL
			if bot._current_target != null and is_instance_valid(bot._current_target) \
					and _should_reload_safe(wc, weapon):
				return State.RELOAD_SAFE
		if bot._current_target != null and is_instance_valid(bot._current_target):
			return State.COMBAT
		if bot._search_active and bot._last_seen_position != Vector3.INF:
			return State.SEARCH
		return State.TRAVEL

	func _should_reload_safe(wc: WeaponController, weapon: Weapon) -> bool:
		if weapon == null or weapon.has_infinite_ammo or wc._is_reloading:
			return false
		if bot._current_target == null or not is_instance_valid(bot._current_target):
			return false
		var cost := 1
		if bot._chosen_fire_index >= 0:
			cost = wc._get_fire_ammo_cost(weapon, bot._chosen_fire_index)
		if weapon.mag_current >= cost:
			return false
		var target_pos := bot._target_position_for_ai()
		if target_pos == Vector3.INF:
			return false
		var dist := bot.player.global_position.distance_to(target_pos)
		return dist > MELEE_CONSIDER_RANGE * 2.0

	func _enter(next: State) -> void:
		state = next
		_reason = "enter"
		match next:
			State.TRAVEL:
				_min_timer = 0.35
			State.SEARCH:
				_min_timer = 1.2
			State.COMBAT:
				_min_timer = 0.5
			State.HEAL:
				_min_timer = 0.4
			State.RELOAD_SAFE:
				_min_timer = 0.55
			State.RETREAT_COVER:
				_min_timer = 0.9
			State.STUCK_RECOVER:
				_min_timer = 0.3
				_stuck_hold = 0.8
			State.FLEE:
				_min_timer = 0.9
		bot._on_decision_enter(int(next))

	func act() -> void:
		match state:
			State.TRAVEL:
				bot._act_seek_objective_or_wander()
			State.SEARCH:
				bot._act_search()
			State.COMBAT:
				if bot._current_target != null and is_instance_valid(bot._current_target):
					bot._act_combat()
				else:
					bot._act_context()
			State.HEAL:
				_act_heal_state()
			State.RELOAD_SAFE:
				bot._act_reload_safe()
			State.RETREAT_COVER:
				bot._act_retreat_cover()
			State.STUCK_RECOVER:
				bot._act_context()
			State.FLEE:
				bot._act_flee()
			_:
				bot._act_context()

	func _act_heal_state() -> void:
		var wc: WeaponController = bot.player.weapon_controller
		if wc == null or not wc._is_ready():
			return
		if bot._health_ratio() < MEDIC_SELF_HEAL_THRESHOLD:
			var self_index := bot._find_self_heal_weapon_index(wc)
			if self_index >= 0:
				if wc.current_weapon_index == self_index:
					bot._act_self_heal(wc, wc._weapons[self_index])
					return
				if bot._switch_weapon(wc, self_index):
					bot._trigger.release_all()
					return
		var weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if bot._heal_target != null and bot._weapon_heals_allies(weapon) \
				and bot._heal_is_safe():
			bot._act_heal()
		else:
			bot._act_context()

	func get_state_text() -> String:
		var names: Array[String] = [
			"travel", "search", "combat", "heal", "reload", "cover", "stuck", "flee"
		]
		return "%s %.2f %s" % [names[int(state)], _min_timer, _reason]

	func reason(text: String) -> void:
		_reason = text


## ============================================================================
## STAGE 3 — TRAVERSAL
## ============================================================================

## Shared, time-sliced waypoint graph.  Baked once per map, reused by every bot
## on the server.  AStar3D stores topology; edge types are kept beside it because
## AStar3D has no per-edge metadata or weight.
class TravelGraph extends RefCounted:
	enum EdgeType { WALK, JUMP, CROUCH, DROP, STAIRS }
	enum BakeState { BOUNDS, COLUMNS, EDGES, READY, FAILED }

	static var _shared: TravelGraph = null
	static var _last_bake_frame: int = -1

	var _map_id: int = 0
	var _map_origin: Vector3 = Vector3.ZERO
	var _world: World3D = null
	var _astar: AStar3D = null
	var _state: BakeState = BakeState.BOUNDS

	var _node_positions: Array[Vector3] = []
	var _node_crouch: Array[bool] = []
	var _node_cells: Array[Vector2i] = []
	## cell -> Array[int] of point ids.  Untyped inner arrays on purpose:
	## Dictionary values come back as Variant (see CLAUDE.md).
	var _cells: Dictionary = {}
	## "a:b" -> EdgeType for the direction a -> b.
	var _edge_types: Dictionary = {}

	var _bounds: AABB = AABB()
	var _bounds_valid: bool = false
	var _spawn_points: Array[Vector3] = []
	var _scan_stack: Array[Node] = []
	var _exclude_rids: Array[RID] = []

	var _ray: PhysicsRayQueryParameters3D = null
	var _shape_query: PhysicsShapeQueryParameters3D = null
	var _stand_shape: CapsuleShape3D = null
	var _crouch_shape: CapsuleShape3D = null

	var _col_start: Vector2 = Vector2.ZERO
	var _col_step: float = TRAVEL_GRID
	var _col_x: int = 0
	var _col_z: int = 0
	var _col_index: int = 0
	var _edge_index: int = 0
	var _columns_done: int = 0
	var _columns_total: int = 0
	var _bake_queries: int = 0

	static func shared_for(world_player: Player) -> TravelGraph:
		var map := _find_map()
		if map == null or world_player == null or not is_instance_valid(world_player):
			return _shared
		var map_id := int(map.get_instance_id())
		if _shared == null or _shared._map_id != map_id:
			_shared = TravelGraph.new()
			_shared._begin(map, world_player)
			_last_bake_frame = -1
		return _shared

	static func _find_map() -> Node3D:
		if not is_instance_valid(GameManager.spawn_parent):
			return null
		for child in GameManager.spawn_parent.get_children():
			if child is Map:
				return child as Node3D
		return null

	func _begin(map: Node3D, world_player: Player) -> void:
		_map_id = int(map.get_instance_id())
		_map_origin = map.global_position
		_world = world_player.get_world_3d()
		_astar = AStar3D.new()
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collision_mask = 1 << 0
		_ray.collide_with_bodies = true
		_ray.collide_with_areas = false
		_shape_query = PhysicsShapeQueryParameters3D.new()
		_shape_query.collision_mask = 1 << 0
		_shape_query.collide_with_bodies = true
		_shape_query.collide_with_areas = false
		_stand_shape = CapsuleShape3D.new()
		_stand_shape.radius = CAPSULE_RADIUS
		_stand_shape.height = STAND_HEIGHT
		_crouch_shape = CapsuleShape3D.new()
		_crouch_shape.radius = CAPSULE_RADIUS
		_crouch_shape.height = CROUCH_HEIGHT

		# Dynamic colliders live on the same layer as the world, so they must be
		# named explicitly.  (Payload, movers, rotating brushes, physics props.)
		_exclude_rids.clear()
		_exclude_rids.append(world_player.get_rid())
		for node in world_player.get_tree().get_nodes_in_group("players"):
			if node is Player:
				_exclude_rids.append((node as Player).get_rid())
		var projectile_parent: Node3D = GameManager.projectile_parent
		if projectile_parent != null and is_instance_valid(projectile_parent):
			for child in projectile_parent.get_children():
				if child is CollisionObject3D:
					_exclude_rids.append((child as CollisionObject3D).get_rid())

		_scan_stack.clear()
		_scan_stack.append(map)
		_state = BakeState.BOUNDS

	func get_excludes() -> Array[RID]:
		return _exclude_rids

	func is_ready() -> bool:
		return _state == BakeState.READY

	func has_failed() -> bool:
		return _state == BakeState.FAILED

	func get_progress() -> float:
		if _state == BakeState.READY:
			return 1.0
		if _state == BakeState.FAILED or _state == BakeState.BOUNDS:
			return 0.0
		if _state == BakeState.COLUMNS:
			return 0.6 * float(_columns_done) / maxf(1.0, float(_columns_total))
		return 0.6 + 0.4 * float(_edge_index) / maxf(1.0, float(_node_positions.size()))

	func get_status_text() -> String:
		var names: Array[String] = ["bounds", "columns", "edges", "ready", "failed"]
		return "%s %.0f%% n=%d e=%d q=%d" % [
			names[int(_state)], get_progress() * 100.0,
			_node_positions.size(), _edge_types.size(), _bake_queries
		]

	func tick_bake() -> void:
		if _state == BakeState.READY or _state == BakeState.FAILED:
			return
		var frame := Engine.get_physics_frames()
		if frame == _last_bake_frame:
			return
		_last_bake_frame = frame

		var start := Time.get_ticks_usec()
		var guard := 0
		while Time.get_ticks_usec() - start < BAKE_BUDGET_USEC and guard < 20000:
			guard += 1
			match _state:
				BakeState.BOUNDS:
					if not _scan_step():
						_finish_bounds()
				BakeState.COLUMNS:
					if _col_index >= _columns_total:
						_state = BakeState.EDGES
					else:
						_bake_column(_col_index)
						_col_index += 1
						_columns_done += 1
				BakeState.EDGES:
					if _edge_index >= _node_positions.size():
						_state = BakeState.READY
					else:
						_bake_edges_for(_edge_index)
						_edge_index += 1
				_:
					return

	func _space() -> PhysicsDirectSpaceState3D:
		if _world == null:
			return null
		return _world.direct_space_state

	func _scan_step() -> bool:
		if _scan_stack.is_empty():
			return false
		var node: Node = _scan_stack.pop_back()
		if node == null or not is_instance_valid(node):
			return true
		if node is AnimatableBody3D or node is RigidBody3D:
			_exclude_rids.append((node as CollisionObject3D).get_rid())
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			_add_bounds(mi.global_transform * mi.get_aabb())
		if node is CSGShape3D and node.has_method("get_aabb"):
			var result: Variant = node.call("get_aabb")
			if result is AABB:
				_add_bounds((node as Node3D).global_transform * (result as AABB))
		if node is CollisionShape3D:
			var cs := node as CollisionShape3D
			if cs.shape != null:
				var debug_mesh := cs.shape.get_debug_mesh()
				if debug_mesh != null:
					_add_bounds(cs.global_transform * debug_mesh.get_aabb())
		if node is Marker3D:
			var marker := node as Marker3D
			_spawn_points.append(marker.global_position)
			_add_bounds(AABB(marker.global_position - Vector3.ONE, Vector3.ONE * 2.0))
		for child in node.get_children():
			_scan_stack.append(child)
		return true

	func _add_bounds(box: AABB) -> void:
		if box.size.length_squared() < 0.000001:
			return
		if not _bounds_valid:
			_bounds = box
			_bounds_valid = true
		else:
			_bounds = _bounds.merge(box)

	func _finish_bounds() -> void:
		if not _bounds_valid:
			var center := _map_origin
			if not _spawn_points.is_empty():
				center = Vector3.ZERO
				for p in _spawn_points:
					center += p
				center /= float(_spawn_points.size())
			_bounds = AABB(center - Vector3(60, 30, 60), Vector3(120, 60, 120))
			_bounds_valid = true
		_bounds = _bounds.grow(TRAVEL_BOUNDS_MARGIN)
		var center := _bounds.get_center()
		var size := _bounds.size
		size.x = minf(size.x, 400.0)
		size.z = minf(size.z, 400.0)
		size.y = minf(size.y, 300.0)
		_bounds = AABB(center - size * 0.5, size)
		_bounds = _bounds.grow(TRAVEL_BOUNDS_MARGIN)

		var area := _bounds.size.x * _bounds.size.z
		_col_step = maxf(TRAVEL_GRID, sqrt(area / float(TRAVEL_MAX_COLUMNS)))
		_col_x = maxi(1, int(_bounds.size.x / _col_step))
		_col_z = maxi(1, int(_bounds.size.z / _col_step))
		_columns_total = _col_x * _col_z
		_col_start = Vector2(
			_bounds.position.x + _col_step * 0.5,
			_bounds.position.z + _col_step * 0.5
		)
		_state = BakeState.COLUMNS

	func _bake_column(index: int) -> void:
		var space := _space()
		if space == null:
			_state = BakeState.FAILED
			return
		var ix := index % _col_x
		var iz := index / _col_x
		var x := _col_start.x + float(ix) * _col_step
		var z := _col_start.y + float(iz) * _col_step
		var from := Vector3(x, _bounds.end.y + 2.0, z)
		var to := Vector3(x, _bounds.position.y - 1.0, z)

		for _floor in TRAVEL_MAX_FLOORS_PER_COLUMN:
			_ray.from = from
			_ray.to = to
			_ray.exclude = _exclude_rids
			var hit := space.intersect_ray(_ray)
			_bake_queries += 1
			if hit.is_empty():
				break
			var pos: Vector3 = hit.position
			var normal: Vector3 = hit.normal
			if normal.angle_to(Vector3.UP) <= deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				var head := _headroom(space, pos)
				if head > 0:
					_add_node(pos, head == 1)
			from = Vector3(x, pos.y - 0.05, z)
			if from.y <= to.y:
				break

	func _headroom(space: PhysicsDirectSpaceState3D, feet: Vector3) -> int:
		if _shape_is_clear(space, _stand_shape, feet, STAND_HEIGHT):
			return 2
		if _shape_is_clear(space, _crouch_shape, feet, CROUCH_HEIGHT):
			return 1
		return 0

	func _shape_is_clear(space: PhysicsDirectSpaceState3D, shape: CapsuleShape3D,
			feet: Vector3, height: float) -> bool:
		_shape_query.shape = shape
		_shape_query.transform = Transform3D(
			Basis.IDENTITY, feet + Vector3.UP * (height * 0.5 + 0.05)
		)
		_shape_query.exclude = _exclude_rids
		var hits := space.intersect_shape(_shape_query, 1)
		_bake_queries += 1
		return hits.is_empty()

	func _add_node(pos: Vector3, crouch_only: bool) -> void:
		var cell := _cell_of(pos)
		if _cells.has(cell):
			for value in _cells[cell]:
				var other := int(value)
				if other >= 0 and other < _node_positions.size() \
						and _node_positions[other].distance_squared_to(pos) < 0.1225:
					return
		var id := _node_positions.size()
		_node_positions.append(pos)
		_node_crouch.append(crouch_only)
		_node_cells.append(cell)
		_astar.add_point(id, pos, 1.0)
		var bucket: Array = []
		if _cells.has(cell):
			bucket = _cells[cell]
		bucket.append(id)
		_cells[cell] = bucket

	func _cell_of(pos: Vector3) -> Vector2i:
		return Vector2i(
			int(round((pos.x - _col_start.x) / _col_step)),
			int(round((pos.z - _col_start.y) / _col_step))
		)

	func _bake_edges_for(id: int) -> void:
		var cell := _node_cells[id]
		var cardinal: Array[Vector2i] = [
			Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
		]
		var cardinal_ok: Dictionary = {}
		for dir in cardinal:
			cardinal_ok[dir] = _try_edge(id, cell + dir)
		var diagonals: Array[Vector2i] = [
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
		]
		for dir in diagonals:
			var horizontal := Vector2i(int(sign(dir.x)), 0)
			var vertical := Vector2i(0, int(sign(dir.y)))
			if bool(cardinal_ok.get(horizontal, false)) \
					and bool(cardinal_ok.get(vertical, false)):
				_try_edge(id, cell + dir)

	## Connect to EVERY plausible node in the neighbouring cell, not just the
	## vertically closest one.  A cell can hold a ground node and the stair/upper
	## floor above it; picking only the closest silently disconnected stacked
	## floors.
	func _try_edge(id: int, neighbor_cell: Vector2i) -> bool:
		if not _cells.has(neighbor_cell):
			return false
		var a := _node_positions[id]
		var any := false
		for value in _cells[neighbor_cell]:
			var other := int(value)
			if other == id:
				continue
			var b := _node_positions[other]
			var dy := b.y - a.y
			# A ramp can climb more than the jump height over one grid step; the
			# exact type is decided later by sampling the surface between nodes.
			if dy > TRAVEL_GRID * 1.6 or dy < -DROP_MAX:
				continue
			var horiz := Vector2(b.x - a.x, b.z - a.z).length()
			if horiz > TRAVEL_GRID * 1.8:
				continue
			if _connect_pair(id, other):
				any = true
		return any

	func _connect_pair(a: int, b: int) -> bool:
		if a == b:
			return false
		var pa := _node_positions[a]
		var pb := _node_positions[b]
		var dy := pb.y - pa.y
		var crouch := _node_crouch[a] or _node_crouch[b]
		var ramp := _is_ramp(pa, pb)
		var type := EdgeType.WALK
		if crouch:
			type = EdgeType.CROUCH
		elif ramp:
			# A ramp is walkable even though its rise per grid cell is large.
			type = EdgeType.WALK
		elif absf(dy) <= 0.12:
			type = EdgeType.WALK
		elif dy > 0.12 and dy <= JUMP_STEP_MAX:
			type = EdgeType.JUMP
		elif dy > JUMP_STEP_MAX and dy <= TRAVEL_GRID * 1.6 \
				and _is_stairs(pa, pb):
			# A staircase sampled at a coarse grid can rise more than one jump
			# over a cell.  The follower walks into it; local perception jumps
			# each step as it appears.
			type = EdgeType.STAIRS
		elif dy < -0.12 and dy >= -DROP_MAX:
			type = EdgeType.DROP
		else:
			return false

		var space := _space()
		if space == null:
			return false
		if type == EdgeType.JUMP or type == EdgeType.STAIRS:
			if not _jump_clear(space, pa, pb):
				return false
		elif not _edge_clear(space, pa, pb, crouch):
			return false

		if type == EdgeType.DROP:
			_astar.connect_points(a, b, false)
			_set_edge_type(a, b, type)
			return true
		_astar.connect_points(a, b, true)
		_set_edge_type(a, b, type)
		_set_edge_type(b, a, type)
		return true

	## True when the surface between two nodes follows the straight line between
	## them — a ramp/slope, not a stair step or a drop.  Two samples are enough at
	## a 2.5 m grid; a real step's midpoint sits at one level, not halfway.
	func _is_ramp(a: Vector3, b: Vector3) -> bool:
		var dy := b.y - a.y
		if absf(dy) < 0.12:
			return true
		var space := _space()
		if space == null:
			return false
		for i in 2:
			var t := 0.33 + 0.33 * float(i)
			var p := a.lerp(b, t)
			var from := Vector3(p.x, maxf(a.y, b.y) + 2.0, p.z)
			var to := Vector3(p.x, minf(a.y, b.y) - 1.0, p.z)
			_ray.from = from
			_ray.to = to
			_ray.exclude = _exclude_rids
			var hit := space.intersect_ray(_ray)
			_bake_queries += 1
			if hit.is_empty():
				return false
			if absf((hit.position as Vector3).y - p.y) > 0.12:
				return false
			if (hit.normal as Vector3).angle_to(Vector3.UP) > deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				return false
		return true

	## True when the space between two nodes contains intermediate horizontal
	## surfaces — a staircase.  A coarse grid cannot sample every step, so this
	## recognises the pattern and lets the follower climb it with repeated jumps.
	func _is_stairs(a: Vector3, b: Vector3) -> bool:
		var space := _space()
		if space == null:
			return false
		var min_y := minf(a.y, b.y)
		var max_y := maxf(a.y, b.y)
		var last_y := a.y
		var intermediates := 0
		for i in 4:
			var t := 0.2 + 0.2 * float(i)
			var p := a.lerp(b, t)
			var from := Vector3(p.x, max_y + 2.0, p.z)
			var to := Vector3(p.x, min_y - 1.0, p.z)
			_ray.from = from
			_ray.to = to
			_ray.exclude = _exclude_rids
			var hit := space.intersect_ray(_ray)
			_bake_queries += 1
			if hit.is_empty():
				return false
			var hy: float = (hit.position as Vector3).y
			if hy < min_y - 0.3 or hy > max_y + 0.3:
				return false
			if (hit.normal as Vector3).angle_to(Vector3.UP) > deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				return false
			if hy < last_y - 0.1:
				return false
			last_y = hy
			if absf(hy - a.y) > 0.1 and absf(hy - b.y) > 0.1:
				intermediates += 1
		return intermediates >= 2

	## Jump edge clearance: check the air at the HIGHER endpoint's chest height.
	## A capsule sweep along the floor would collide with the very stair/ledge the
	## bot is supposed to jump onto, so it would disconnect every staircase.
	func _jump_clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
		var higher := maxf(a.y, b.y)
		var a_height := higher - a.y + PROBE_CHEST_HEIGHT
		var b_height := higher - b.y + PROBE_CHEST_HEIGHT
		_ray.from = a + Vector3.UP * a_height
		_ray.to = b + Vector3.UP * b_height
		_ray.exclude = _exclude_rids
		_bake_queries += 1
		return space.intersect_ray(_ray).is_empty()

	func _edge_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3,
			crouch: bool) -> bool:
		# Cheap chest ray first; only a hit justifies the capsule sweep.
		_ray.from = from + Vector3.UP * PROBE_CHEST_HEIGHT
		_ray.to = to + Vector3.UP * PROBE_CHEST_HEIGHT
		_ray.exclude = _exclude_rids
		var hit := space.intersect_ray(_ray)
		_bake_queries += 1
		if hit.is_empty():
			return true

		var shape: CapsuleShape3D = _crouch_shape if crouch else _stand_shape
		var height := CROUCH_HEIGHT if crouch else STAND_HEIGHT
		_shape_query.shape = shape
		_shape_query.transform = Transform3D(
			Basis.IDENTITY, from + Vector3.UP * (height * 0.5 + 0.05)
		)
		_shape_query.motion = to - from
		_shape_query.exclude = _exclude_rids
		var result := space.cast_motion(_shape_query)
		_bake_queries += 1
		return result.size() >= 2 and result[0] >= 0.999

	func _edge_key(a: int, b: int) -> String:
		return "%d:%d" % [a, b]

	func _set_edge_type(a: int, b: int, type: int) -> void:
		_edge_types[_edge_key(a, b)] = type

	func _get_edge_type(a: int, b: int) -> int:
		return int(_edge_types.get(_edge_key(a, b), EdgeType.WALK))

	## Find a node near a position by vertical proximity first.  Plain
	## `get_closest_point` can return the floor above/below, which is exactly the
	## stacked-floor bug this graph exists to avoid.
	func find_node(pos: Vector3, vertical: float = NODE_LOOKUP_RADIUS) -> int:
		var cell := _cell_of(pos)
		var best := -1
		var best_score := INF
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var key := cell + Vector2i(dx, dz)
				if not _cells.has(key):
					continue
				for value in _cells[key]:
					var id := int(value)
					var p := _node_positions[id]
					if absf(p.y - pos.y) > vertical:
						continue
					var horiz := Vector2(p.x - pos.x, p.z - pos.z).length()
					if horiz > TRAVEL_GRID * 1.6:
						continue
					var score := horiz + absf(p.y - pos.y) * 0.5
					if score < best_score:
						best_score = score
						best = id
		return best

	func find_goal_node(pos: Vector3, bias: float) -> int:
		var cell := _cell_of(pos)
		var candidates: Array[int] = []
		var scores: Array[float] = []
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				var key := cell + Vector2i(dx, dz)
				if not _cells.has(key):
					continue
				for value in _cells[key]:
					var id := int(value)
					var p := _node_positions[id]
					if absf(p.y - pos.y) > 2.5:
						continue
					var horiz := Vector2(p.x - pos.x, p.z - pos.z).length()
					if horiz > TRAVEL_GRID * 2.2:
						continue
					# Insertion sort by distance; the list is tiny.
					var score := horiz + absf(p.y - pos.y) * 0.5
					var insert_at := candidates.size()
					while insert_at > 0 and scores[insert_at - 1] > score:
						insert_at -= 1
					candidates.insert(insert_at, id)
					scores.insert(insert_at, score)
		if candidates.is_empty():
			return -1
		var index := clampi(
			int(round((bias + 1.0) * 0.5 * float(candidates.size() - 1))),
			0, candidates.size() - 1
		)
		return candidates[index]

	func query(start_pos: Vector3, goal_pos: Vector3, recent_ids: Array[int],
			avoid_points: Array[Vector3], bias: float) -> Dictionary:
		if _state != BakeState.READY:
			return {}
		var start := find_node(start_pos)
		var goal := find_goal_node(goal_pos, bias)
		if start < 0 or goal < 0:
			return {}

		var penalties: Dictionary = {}
		# Penalise the route this bot just used: two equal-cost routes should not
		# produce identical copy-paste paths for every bot.
		for id in recent_ids:
			_penalize(penalties, id, 1.6)
		# Avoid nodes near recently stuck positions / the blocked edge.
		for point in avoid_points:
			var avoid_id := find_node(point, 2.0)
			if avoid_id >= 0:
				_penalize(penalties, avoid_id, 2.2)
		for id in penalties.keys():
			_astar.set_point_weight_scale(int(id), float(penalties[id]))

		var path := _astar.get_id_path(start, goal)
		# Soft vertical preference: if the first path climbs a lot, re-query with
		# its steep nodes penalised and keep the flatter of the two.
		if path.size() > 2:
			var vertical := _path_vertical_cost(path)
			if vertical > 2.0:
				var steep: Array[int] = []
				for i in range(1, path.size()):
					var a_id := int(path[i - 1])
					var b_id := int(path[i])
					if absf(_node_positions[a_id].y - _node_positions[b_id].y) > 0.5:
						steep.append(b_id)
				if not steep.is_empty():
					for id in steep:
						_astar.set_point_weight_scale(id, 1.35)
					var alt := _astar.get_id_path(start, goal)
					if not alt.is_empty() \
							and _path_vertical_cost(alt) < vertical * 0.85 \
							and alt.size() <= path.size() + 8:
						path = alt
					for id in steep:
						_astar.set_point_weight_scale(id, float(penalties.get(id, 1.0)))

		for id in penalties.keys():
			_astar.set_point_weight_scale(int(id), 1.0)

		if path.is_empty():
			return {}
		var points: Array[Vector3] = []
		var types: Array[int] = []
		var ids: Array[int] = []
		for value in path:
			var id := int(value)
			ids.append(id)
			points.append(_node_positions[id])
			if ids.size() == 1:
				types.append(EdgeType.WALK)
			else:
				types.append(_get_edge_type(ids[ids.size() - 2], id))
		return {"points": points, "types": types, "ids": ids}

	func _penalize(penalties: Dictionary, id: int, weight: float) -> void:
		if id < 0 or id >= _node_positions.size():
			return
		penalties[id] = maxf(float(penalties.get(id, 1.0)), weight)

	func _path_vertical_cost(path: PackedInt64Array) -> float:
		var total := 0.0
		for i in range(1, path.size()):
			var a := int(path[i - 1])
			var b := int(path[i])
			total += absf(_node_positions[a].y - _node_positions[b].y)
		return total

	func pick_wander_point(start_pos: Vector3, min_dist: float, max_dist: float) -> Vector3:
		if _state != BakeState.READY or _node_positions.is_empty():
			return Vector3.INF
		var start := find_node(start_pos)
		if start < 0:
			return Vector3.INF
		for _attempt in 8:
			var id := randi() % _node_positions.size()
			var p := _node_positions[id]
			var d := Vector2(p.x - start_pos.x, p.z - start_pos.z).length()
			if d < min_dist or d > max_dist:
				continue
			if _astar.get_id_path(start, id).is_empty():
				continue
			return p
		return Vector3.INF


## Per-map navmesh helpers, keyed by the runtime Map instance like TravelGraph.
## Server-only: queries only choose which Keyboard verbs Traversal uses; they
## never write position, velocity, or rollback state.
class NavRoutes extends RefCounted:
	enum State { PENDING, READY, NONE }

	static var _shared: NavRoutes = null

	var _map_id: int = 0
	var _map_rid: RID
	var _state: State = State.NONE
	var _ready_frame: int = 0

	static func shared_for(player: Player) -> NavRoutes:
		var map := TravelGraph._find_map()
		if map == null or player == null or not is_instance_valid(player):
			return _shared
		var map_id := int(map.get_instance_id())
		var nav_rid := player.get_world_3d().navigation_map
		if _shared == null or _shared._map_id != map_id or _shared._map_rid != nav_rid:
			_shared = NavRoutes.new()
			_shared._begin(map, nav_rid)
		return _shared

	func _begin(map: Node3D, nav_rid: RID) -> void:
		_map_id = int(map.get_instance_id())
		_map_rid = nav_rid
		_state = State.NONE
		for child in map.get_children():
			var region := child as NavigationRegion3D
			if region == null or not region.enabled:
				continue
			var mesh := region.navigation_mesh
			if mesh != null and mesh.get_polygon_count() > 0:
				# The region is in the tree, but NavigationServer3D syncs on a
				# worker.  Two frames covers the common case; a slower sync just
				# retries on the next repath (the two-strike rule prevents a
				# transient miss from starting the graph bake).
				_state = State.PENDING
				_ready_frame = Engine.get_physics_frames() + NAV_SYNC_FRAMES
				break

	func has_mesh() -> bool:
		return _state != State.NONE

	func is_usable() -> bool:
		if _state == State.READY:
			return true
		if _state != State.PENDING:
			return false
		if Engine.get_physics_frames() < _ready_frame:
			return false
		_state = State.READY
		return true

	func get_status_text() -> String:
		match _state:
			State.PENDING:
				return "pending"
			State.READY:
				return "ready"
			_:
				return "none"

	## Returns {} on a hard failure.  Otherwise "ok" is true for a full route;
	## a non-ok result with "partial" true is the closest reachable approach and
	## "gain" says whether following it actually closes distance.
	func query(from: Vector3, to: Vector3) -> Dictionary:
		if not is_usable():
			return {}
		var from_snap := NavigationServer3D.map_get_closest_point(_map_rid, from)
		var to_snap := NavigationServer3D.map_get_closest_point(_map_rid, to)
		var from_flat := Vector2(from.x - from_snap.x, from.z - from_snap.z).length()
		if from_flat > NAV_START_SNAP_MAX \
				or absf(from.y - from_snap.y) > NAV_START_SNAP_Y:
			return {}
		var to_flat := Vector2(to.x - to_snap.x, to.z - to_snap.z).length()
		if to_flat > NAV_GOAL_SNAP_MAX or absf(to.y - to_snap.y) > NAV_GOAL_SNAP_Y:
			return {}
		var points := NavigationServer3D.map_get_path(
			_map_rid, from_snap, to_snap, true, NAV_LAYERS
		)
		if points.is_empty():
			return {}
		var end := points[points.size() - 1]
		var end_flat := Vector2(end.x - to_snap.x, end.z - to_snap.z).length()
		var reached := end_flat <= NAV_ENDPOINT_TOL \
			and absf(end.y - to_snap.y) <= NAV_ENDPOINT_TOL
		var gain := Vector2(to.x - from.x, to.z - from.z).length() \
			- Vector2(to.x - end.x, to.z - end.z).length()
		return {
			"ok": reached,
			"partial": not reached,
			"gain": gain,
			"points": points,
			"types": _infer_types(points),
		}

	func _infer_types(points: PackedVector3Array) -> Array[int]:
		var types: Array[int] = [TravelGraph.EdgeType.WALK]
		for i in range(1, points.size()):
			var dy := points[i].y - points[i - 1].y
			var dx := points[i].x - points[i - 1].x
			var dz := points[i].z - points[i - 1].z
			var flat := sqrt(dx * dx + dz * dz)
			var edge := TravelGraph.EdgeType.WALK
			if dy < -NAV_WALK_STEP:
				edge = TravelGraph.EdgeType.DROP
			elif dy > NAV_WALK_STEP and dy > flat:
				# Steeper than 45 degrees: a step/ledge, not a walkable ramp.
				if dy <= WALK_STEP_MAX:
					edge = TravelGraph.EdgeType.STAIRS
				elif dy <= JUMP_STEP_MAX:
					edge = TravelGraph.EdgeType.JUMP
				else:
					# A corner spanning several steps: let the knee probe climb.
					edge = TravelGraph.EdgeType.STAIRS
			types.append(edge)
		return types

	func pick_wander_point(from: Vector3, min_dist: float, max_dist: float) -> Vector3:
		if not is_usable():
			return Vector3.INF
		for _attempt in NAV_WANDER_ATTEMPTS:
			var candidate := NavigationServer3D.map_get_random_point(
				_map_rid, NAV_LAYERS, true)
			var flat := Vector2(candidate.x - from.x, candidate.z - from.z).length()
			if flat < min_dist or flat > max_dist:
				continue
			if absf(candidate.y - from.y) > NAV_WANDER_MAX_Y:
				continue
			var result := query(from, candidate)
			if not bool(result.get("ok", false)):
				continue
			var points: PackedVector3Array = result.get("points", PackedVector3Array())
			if points.size() < 2:
				continue
			return points[points.size() - 1]
		return Vector3.INF


## Per-bot traversal state machine.  It turns a goal into W + a mouse look
## request, with short A/D taps and digital jump/crouch/back-up actions.  It
## never writes input directly; all verbs go through Keyboard/Mouse.
class Traversal extends RefCounted:
	enum Action { CONTINUE, TAP_LEFT, TAP_RIGHT, JUMP, CROUCH, STOP, BACK_UP, REROUTE }
	enum Recovery { NONE, JUMP, STRAFE, BACKUP, REROUTE, TURN }
	enum PathSource { DIRECT, GRAPH, NAV, NAV_PARTIAL }

	var bot: BotController
	var _graph: TravelGraph = null
	var _goal: Vector3 = Vector3.INF
	var _has_goal: bool = false
	var _urgency: float = 0.5
	var _arrival: float = 1.0
	var _caution: float = 0.0

	var _path_points: Array[Vector3] = []
	var _path_types: Array[int] = []
	var _path_ids: Array[int] = []
	var _path_index: int = 0
	var _path_origin: Vector3 = Vector3.ZERO
	var _repath_timer: float = 0.0
	var _query_goal: Vector3 = Vector3.INF
	var _force_repath: bool = false

	var _nav: NavRoutes = null
	var _graph_needed: bool = false
	var _nav_retry_after_ms: int = 0
	var _nav_fail_count: int = 0
	var _recent_graph_ids: Array[int] = []
	var _path_source: int = PathSource.DIRECT
	var _chase: bool = false

	var _progress_pos: Vector3 = Vector3.ZERO
	var _progress_timer: float = 0.0
	var _recovery: Recovery = Recovery.NONE
	var _recovery_timer: float = 0.0
	var _recovery_stage: int = 0
	var _recovery_applied: bool = false
	var _open_side: int = 0
	var _recent_stuck: Array[Dictionary] = []
	var _route_bias: float = 0.0
	var _state_text: String = "idle"

	var _ray: PhysicsRayQueryParameters3D = null
	var _shape_query: PhysicsShapeQueryParameters3D = null
	var _stand_shape: CapsuleShape3D = null
	var _crouch_shape: CapsuleShape3D = null
	var _own_exclude: Array[RID] = []
	var _ray_clock: float = 0.0
	var _rays_this_second: int = 0
	var _rays_per_second: int = 0
	var _tempo_timer: float = 0.0
	var _tempo_moving: bool = true

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collision_mask = 1 << 0
		_ray.collide_with_bodies = true
		_ray.collide_with_areas = false
		_shape_query = PhysicsShapeQueryParameters3D.new()
		_shape_query.collision_mask = 1 << 0
		_shape_query.collide_with_bodies = true
		_shape_query.collide_with_areas = false
		_stand_shape = CapsuleShape3D.new()
		_stand_shape.radius = CAPSULE_RADIUS
		_stand_shape.height = STAND_HEIGHT
		_crouch_shape = CapsuleShape3D.new()
		_crouch_shape.radius = CAPSULE_RADIUS
		_crouch_shape.height = CROUCH_HEIGHT
		_own_exclude.append(bot.player.get_rid())
		_route_bias = randf_range(-1.0, 1.0)

	func reset() -> void:
		_has_goal = false
		_goal = Vector3.INF
		_query_goal = Vector3.INF
		_path_points.clear()
		_path_types.clear()
		_path_ids.clear()
		_path_index = 0
		_path_origin = Vector3.ZERO
		_repath_timer = 0.0
		_force_repath = false
		_progress_timer = 0.0
		_recovery = Recovery.NONE
		_recovery_timer = 0.0
		_recovery_stage = 0
		_recovery_applied = false
		_recent_stuck.clear()
		_state_text = "idle"
		_graph = null
		_nav = null
		_graph_needed = false
		_nav_retry_after_ms = 0
		_nav_fail_count = 0
		_recent_graph_ids.clear()
		_path_source = PathSource.DIRECT
		_chase = false
		_route_bias = randf_range(-1.0, 1.0)
		_tempo_timer = 0.0
		_tempo_moving = true

	func is_recovering() -> bool:
		return _recovery != Recovery.NONE

	## A combat/heal/cover decision outranks locomotion recovery; stop the
	## recovery verbs before the new state sets its own movement.
	func cancel_recovery() -> void:
		_recovery = Recovery.NONE
		_recovery_timer = 0.0
		_recovery_applied = false
		_recovery_stage = 0
		_progress_timer = 0.0

	## Drop the current route without touching recovery.  Used when combat hands
	## locomotion back to its local strafe/movement block.
	func cancel_goal() -> void:
		_has_goal = false
		_goal = Vector3.INF
		_query_goal = Vector3.INF
		_clear_path()
		_chase = false

	## True when the current nav route could only reach the closest point and the
	## follower has stopped there.  Callers use this to give up a chase.
	func is_partial_approach() -> bool:
		return _path_source == PathSource.NAV_PARTIAL \
			and _path_index >= _path_points.size()

	## Remaining route for the debug overlay, in world space and lifted clear of
	## the floor.  Starts at the bot's body so the line visibly joins it.  A
	## partial approach that already exhausted its waypoints still draws its last
	## segment, because that is where the bot is parked.
	func get_debug_path() -> Array[Vector3]:
		var points: Array[Vector3] = []
		if _path_points.is_empty():
			return points
		var start := _path_index
		if start >= _path_points.size():
			if _path_source != PathSource.NAV_PARTIAL:
				return points
			start = _path_points.size() - 1
		var lift := Vector3.UP * DEBUG_PATH_LIFT
		points.append(bot.player.global_position + lift)
		for i in range(start, _path_points.size()):
			points.append(_path_points[i] + lift)
		return points

	func get_debug_path_source() -> int:
		return _path_source

	## The active goal, or Vector3.INF when there is none.
	func get_debug_goal() -> Vector3:
		return _goal if _has_goal else Vector3.INF

	func tick(delta: float) -> void:
		_ray_clock += delta
		if _ray_clock >= 1.0:
			_ray_clock -= 1.0
			_rays_per_second = _rays_this_second
			_rays_this_second = 0
		_repath_timer = maxf(_repath_timer - delta, 0.0)

		var graph := TravelGraph.shared_for(bot.player)
		if _nav == null or graph != _graph:
			_graph = graph
			_nav = NavRoutes.shared_for(bot.player)
			_clear_path()
			_query_goal = Vector3.INF
			_nav_retry_after_ms = 0
			_nav_fail_count = 0
			_graph_needed = false

		# A map with no baked region falls back to the graph immediately.  A map
		# with one must not start the bake during the two-frame nav sync window.
		if _nav == null or not _nav.has_mesh():
			_graph_needed = true
		if _graph != null and _graph_needed:
			_graph.tick_bake()

		if _caution > 0.4:
			_tempo_timer -= delta
			if _tempo_timer <= 0.0:
				_tempo_moving = not _tempo_moving
				_tempo_timer = randf_range(0.3, 0.6) if _tempo_moving \
					else randf_range(0.1, 0.2)
		else:
			_tempo_moving = true

		if _recovery != Recovery.NONE:
			_tick_recovery(delta)
			return
		if not _has_goal or not bot.player.spawned:
			return

		var pos := bot.player.global_position
		if pos.distance_to(_goal) <= _arrival:
			_progress_timer = 0.0
			return

		# Intentional stoppage is not "stuck": combat aim, reload/switch, or a
		# tempo pause.  Only a held movement key that produces no displacement
		# escalates recovery.
		var wc: WeaponController = bot.player.weapon_controller
		var intentional := (bot._current_target != null and not _chase) \
			or bot._reaction_timer > 0.0 \
			or (wc != null and (wc._is_reloading or wc.is_switching())) \
			or not bot._keyboard.is_moving()
		if intentional:
			_progress_timer = 0.0
			_progress_pos = pos
			return

		var moved := Vector2(pos.x - _progress_pos.x, pos.z - _progress_pos.z).length()
		if moved > STUCK_DISTANCE:
			_progress_pos = pos
			_progress_timer = 0.0
			_recovery_stage = 0
			return
		_progress_timer += delta
		if _progress_timer >= STUCK_TIME:
			_trigger_stuck()

	func move_to(goal: Vector3, urgency: float = 0.5,
			arrival_radius: float = TRAVEL_ARRIVE_DEFAULT,
			caution: float = 0.0, chase: bool = false) -> void:
		_chase = chase
		if goal == Vector3.INF or not bot.player.spawned:
			_has_goal = false
			bot._keyboard.set_move(0, 0)
			_state_text = "idle"
			return
		if not _has_goal or goal.distance_squared_to(_goal) > 9.0:
			_force_repath = true
		_has_goal = true
		_goal = goal
		_urgency = clampf(urgency, 0.0, 1.0)
		_arrival = maxf(0.2, arrival_radius)
		_caution = clampf(caution, 0.0, 1.0)
		if _recovery != Recovery.NONE:
			return

		var pos := bot.player.global_position
		var flat := Vector2(goal.x - pos.x, goal.z - pos.z)
		if flat.length() <= _arrival and absf(goal.y - pos.y) <= 1.5:
			bot._keyboard.set_move(0, 0)
			_state_text = "arrived"
			return

		# The graph may be deliberately unbaked on a navmesh map, so either
		# route source being usable is enough to enter path following.  A route
		# is preferred even when the straight line is clear: the navmesh is the
		# primary source (and what the route debug overlay draws), not merely an
		# obstacle workaround.  Short hops stay direct so combat micro-moves do
		# not pay for a query.
		var nav_ready := _nav != null and _nav.is_usable()
		var graph_ready := _graph != null and _graph.is_ready()
		if (nav_ready or graph_ready) and flat.length() > DIRECT_ROUTE_MIN:
			_follow_path(goal)
			return
		# Direct movement uses no route; drop a stale path source so an old
		# partial approach cannot be mistaken for the current state.
		_clear_path()
		_follow_direct(goal)

	func _follow_direct(goal: Vector3) -> void:
		var pos := bot.player.global_position
		var to_goal := Vector3(goal.x - pos.x, 0.0, goal.z - pos.z)
		var flat_dist := to_goal.length()
		if flat_dist < 0.001:
			bot._keyboard.set_move(0, 0)
			return
		var dir := to_goal / flat_dist
		var lookahead := _lookahead_distance()
		var look := pos + dir * minf(flat_dist, lookahead)
		if flat_dist <= lookahead:
			look = goal
		_request_look(look)
		_state_text = "direct"
		var action := _perceive(dir, lookahead)
		if _apply_action(action):
			return
		if not _tempo_ok():
			bot._keyboard.set_move(0, 0)
		elif _chase:
			# Combat owns the look; drive the goal in world space so W does not
			# follow the crosshair away from the objective.
			bot._keyboard.set_move_world(Vector2(dir.x, dir.z))
		else:
			bot._keyboard.set_move(1, 0)

	func _follow_path(goal: Vector3) -> void:
		var pos := bot.player.global_position
		# `_repath_timer` alone gates the empty-path case: `_query_path` sets it
		# every time, so a route discarded for direct steering is not re-queried
		# at 20 Hz.
		var need_query := _force_repath \
			or _repath_timer <= 0.0 \
			or _query_goal.distance_squared_to(goal) > 9.0
		if need_query:
			_query_path(goal)
		if _path_points.is_empty():
			_follow_direct(goal)
			return
		# A partial nav route must not override a clear straight line: it exists
		# for goals the mesh cannot reach, and following it would park the bot at
		# the gap while direct steering could walk the rest of the way.
		if _path_source == PathSource.NAV_PARTIAL and _direct_clear(goal):
			_clear_path()
			_follow_direct(goal)
			return

		# Drop waypoints already reached, and skip a later one when a straight
		# line to it is clear (route smoothing).
		while _path_index < _path_points.size():
			var p := _path_points[_path_index]
			if Vector2(p.x - pos.x, p.z - pos.z).length() < 0.75 \
					and absf(p.y - pos.y) < 1.5:
				_path_index += 1
				continue
			if _path_index + 1 < _path_points.size():
				var next := _path_points[_path_index + 1]
				if Vector2(next.x - pos.x, next.z - pos.z).length() < 5.0 \
						and absf(next.y - pos.y) < WALK_STEP_MAX \
						and _line_clear(pos, next):
					_path_index += 1
					continue
			break

		if _path_index >= _path_points.size():
			if _path_source == PathSource.NAV_PARTIAL:
				# Closest reachable point: stop rather than steer into a gap.
				bot._keyboard.set_move(0, 0)
				_state_text = "approach"
				return
			_follow_direct(goal)
			return

		var waypoint := _path_points[_path_index]
		var dir := Vector3(waypoint.x - pos.x, 0.0, waypoint.z - pos.z)
		var flat_dist := dir.length()
		if flat_dist < 0.001:
			dir = bot.player.horizontal_forward()
		else:
			dir = dir / flat_dist
		var edge := int(TravelGraph.EdgeType.WALK)
		if _path_index < _path_types.size():
			edge = _path_types[_path_index]

		# Graph DROP edges keep their old trusted behavior.  A nav path keeps the
		# forward ledge probe: a coarse nav corner must not authorize a walk-off
		# several metres past the descent.
		var allow_drop := edge == TravelGraph.EdgeType.DROP \
			and _path_source == PathSource.GRAPH

		var look := waypoint
		if flat_dist < 2.0 and _path_index + 1 < _path_points.size():
			look = _path_points[_path_index + 1]
		_request_look(look)

		if edge == TravelGraph.EdgeType.JUMP:
			if flat_dist <= JUMP_TAKEOFF and flat_dist > 0.35:
				bot._keyboard.jump_tap(false)
		elif edge == TravelGraph.EdgeType.CROUCH:
			bot._keyboard.crouch_hold(0.18)

		var lookahead := _lookahead_distance()
		var action := _perceive(dir, lookahead, allow_drop)
		if _apply_action(action):
			return

		var line_start := _path_origin
		if _path_index > 0:
			line_start = _path_points[_path_index - 1]
		_cross_track_tap(pos, line_start, waypoint)

		# A blind or sharp corner under caution gets a brief stop; otherwise W.
		var turn_angle := rad_to_deg(
			bot.player.horizontal_forward().angle_to(dir)
		)
		var cautious_stop := _caution > 0.35 and turn_angle > 65.0 \
			and flat_dist < CORNER_SLOW_RADIUS
		if cautious_stop or not _tempo_ok():
			bot._keyboard.set_move(0, 0)
		elif _chase:
			# Combat owns the look, so W points at the aim target rather than
			# along the route.  Drive the waypoint in world space instead.
			bot._keyboard.set_move_world(Vector2(dir.x, dir.z))
		else:
			bot._keyboard.set_move(1, 0)
		_state_text = "path"

	func _query_path(goal: Vector3) -> void:
		_force_repath = false
		_repath_timer = REPATH_INTERVAL
		_query_goal = goal
		var pos := bot.player.global_position
		var now_ms := Time.get_ticks_msec()
		var avoids := _active_stuck_points(now_ms)
		var nav_partial: Dictionary = {}

		# Navmesh first: a full route wins.  A closest-reachable approach is
		# held until the graph (or a later full route) can do better.
		if _nav != null and _nav.is_usable() and now_ms >= _nav_retry_after_ms:
			var nav_result := _nav.query(pos, goal)
			if bool(nav_result.get("ok", false)):
				_nav_fail_count = 0
				_nav_retry_after_ms = 0
				# The navmesh is carrying this bot; stop spending frame time on
				# the graph bake.  It resumes if a later route needs it.
				_graph_needed = false
				_set_path(nav_result.get("points", []),
					nav_result.get("types", []), [], PathSource.NAV)
				return
			if bool(nav_result.get("partial", false)) \
					and float(nav_result.get("gain", 0.0)) >= NAV_PARTIAL_MIN_GAIN:
				nav_partial = nav_result
				# The mesh cannot reach the goal; let the graph try a route.
				_graph_needed = true
			else:
				_nav_fail_count += 1
				if _nav_fail_count >= 2:
					_nav_retry_after_ms = now_ms + NAV_FAILURE_RETRY_MS
					# Two consecutive hard failures: not a map-load sync miss.
					_graph_needed = true

		if _graph != null and _graph.is_ready():
			var result := _graph.query(
				pos, goal, _recent_graph_ids, avoids, _route_bias
			)
			if not result.is_empty():
				_recent_graph_ids.clear()
				for value in result.get("ids", []):
					_recent_graph_ids.append(int(value))
				_set_path(result.get("points", []), result.get("types", []),
					result.get("ids", []), PathSource.GRAPH)
				return

		if not nav_partial.is_empty():
			_set_path(nav_partial.get("points", []),
				nav_partial.get("types", []), [], PathSource.NAV_PARTIAL)
			return

		_clear_path()

	func _set_path(points_variant: Variant, types_variant: Variant,
			ids_variant: Variant, source: int) -> void:
		_path_points.clear()
		_path_types.clear()
		_path_ids.clear()
		_path_origin = bot.player.global_position
		for value in points_variant:
			_path_points.append(value as Vector3)
		for value in types_variant:
			_path_types.append(int(value))
		for value in ids_variant:
			_path_ids.append(int(value))
		_path_index = 0
		_path_source = source

	func _clear_path() -> void:
		_path_points.clear()
		_path_types.clear()
		_path_ids.clear()
		_path_index = 0
		_path_source = PathSource.DIRECT

	func _active_stuck_points(now_ms: int) -> Array[Vector3]:
		var avoids: Array[Vector3] = []
		var now := float(now_ms) / 1000.0
		for i in range(_recent_stuck.size() - 1, -1, -1):
			var entry: Dictionary = _recent_stuck[i]
			if float(entry.get("until", 0.0)) < now:
				_recent_stuck.remove_at(i)
			else:
				avoids.append(entry.get("pos", Vector3.ZERO) as Vector3)
		return avoids

	func _request_look(point: Vector3) -> void:
		# Floor points become a look at body/eye height; a player looks ahead,
		# not at their feet.
		bot._mouse.request_look_at_point(
			point + Vector3.UP * TRAVEL_EYE_HEIGHT,
			LookPriority.TRAVEL_LOOKAHEAD,
			_urgency
		)

	func _lookahead_distance() -> float:
		return lerpf(LOOKAHEAD_MIN, LOOKAHEAD_MAX, _urgency) \
			* (1.0 - _caution * 0.35)

	func _tempo_ok() -> bool:
		return _tempo_moving

	func _cross_track_tap(pos: Vector3, line_start: Vector3, waypoint: Vector3) -> void:
		var segment := Vector3(waypoint.x - line_start.x, 0.0, waypoint.z - line_start.z)
		if segment.length_squared() < 0.01:
			return
		var seg_dir := segment.normalized()
		var right := Vector3.UP.cross(seg_dir).normalized()
		var lateral := Vector3(pos.x - line_start.x, 0.0, pos.z - line_start.z).dot(right)
		if absf(lateral) < CROSS_TRACK_TAP:
			return
		if lateral > 0.0:
			bot._keyboard.tap(&"left", randf_range(0.07, 0.12))
		else:
			bot._keyboard.tap(&"right", randf_range(0.07, 0.12))

	func _direct_clear(goal: Vector3) -> bool:
		var pos := bot.player.global_position
		if absf(goal.y - pos.y) > DIRECT_LINE_MAX_RISE:
			return false
		var flat := Vector2(goal.x - pos.x, goal.z - pos.z)
		if flat.length() < 0.6:
			return true
		var chest_from := pos + Vector3.UP * PROBE_CHEST_HEIGHT
		var chest_to := goal + Vector3.UP * PROBE_CHEST_HEIGHT
		if not _ray_clear(chest_from, chest_to):
			return false
		var knee_from := pos + Vector3.UP * PROBE_KNEE_HEIGHT
		var knee_to := goal + Vector3.UP * PROBE_KNEE_HEIGHT
		var hit := _ray_hit(knee_from, knee_to)
		if hit.is_empty():
			return true
		var normal: Vector3 = hit.normal
		return normal.angle_to(Vector3.UP) <= deg_to_rad(FLOOR_MAX_ANGLE_DEG)

	func _line_clear(from: Vector3, to: Vector3) -> bool:
		return _ray_clear(from + Vector3.UP * PROBE_CHEST_HEIGHT,
			to + Vector3.UP * PROBE_CHEST_HEIGHT)

	func _perceive(dir: Vector3, lookahead: float,
			allow_drop: bool = false) -> int:
		var pos := bot.player.global_position
		var flat := Vector3(dir.x, 0.0, dir.z)
		if flat.length_squared() < 0.0001:
			flat = bot.player.horizontal_forward()
		flat = flat.normalized()
		var dist := maxf(1.0, lookahead)

		var on_floor := bot.player.is_on_floor()
		var knee_hit := _ray_hit(pos + Vector3.UP * PROBE_KNEE_HEIGHT,
			pos + Vector3.UP * PROBE_KNEE_HEIGHT + flat * dist)
		var chest_hit := _ray_hit(pos + Vector3.UP * PROBE_CHEST_HEIGHT,
			pos + Vector3.UP * PROBE_CHEST_HEIGHT + flat * dist)
		var full_hit := _ray_hit(pos + Vector3.UP * PROBE_FULL_HEIGHT,
			pos + Vector3.UP * PROBE_FULL_HEIGHT + flat * dist)

		# Chest/full-height obstruction = wall or low ceiling, not a ramp.
		if not chest_hit.is_empty() or not full_hit.is_empty():
			if not full_hit.is_empty() and chest_hit.is_empty():
				if _headroom_clear(pos, false) and not _headroom_clear(pos, true):
					return Action.CROUCH
			var left := _side_clear(pos, flat, -1.0)
			var right := _side_clear(pos, flat, 1.0)
			if left and not right:
				_open_side = -1
				return Action.TAP_LEFT
			if right and not left:
				_open_side = 1
				return Action.TAP_RIGHT
			return Action.REROUTE

		# Knee hit with a walkable normal is a ramp, step or stair.  Without a
		# step-up helper even a small stair needs a jump, so only a near-flat ramp
		# is a continue.
		if not knee_hit.is_empty():
			var normal: Vector3 = knee_hit.normal
			if normal.angle_to(Vector3.UP) <= deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				var rise: float = (knee_hit.position as Vector3).y - pos.y
				if rise > 0.15:
					if _headroom_clear(pos, false):
						return Action.JUMP
					if _headroom_clear(pos, true):
						return Action.CROUCH
			# A vertical knee-height face is usually a wall, but the chest and
			# full rays above are clear, so its top is below chest height and it
			# may be a jumpable ledge.  Keep walking toward it and jump once it
			# is inside takeoff range; the character has no step-up, so every
			# riser is a jump.  The landing probe only runs that close.
			var face: Vector3 = knee_hit.position
			var face_flat := Vector2(face.x - pos.x, face.z - pos.z).length()
			if not on_floor:
				# Never reroute a face that a jump in progress is clearing.
				return Action.CONTINUE
			if face_flat > JUMP_TAKEOFF:
				# A low face is approached, not rerouted from lookahead range;
				# it is classified as jumpable or wall once it is that close.
				return Action.CONTINUE
			if _ledge_jump_state(pos, flat, face) == 1:
				return Action.JUMP
			# A knee-height vertical face is still a wall.
			var left := _side_clear(pos, flat, -1.0)
			var right := _side_clear(pos, flat, 1.0)
			if left and not right:
				_open_side = -1
				return Action.TAP_LEFT
			if right and not left:
				_open_side = 1
				return Action.TAP_RIGHT
			return Action.REROUTE

		# Safe drop check.  A route that intentionally drops is allowed to step
		# off; everything else stops before the ledge.
		if not allow_drop:
			var ledge_from := pos + flat * LEDGE_PROBE_AHEAD + Vector3.UP * 0.2
			var ledge_to := ledge_from + Vector3.DOWN * (LEDGE_DROP_DANGER + 0.5)
			var ledge_hit := _ray_hit(ledge_from, ledge_to)
			if ledge_hit.is_empty():
				return Action.BACK_UP

		# Capsule fits on the intended line?  This is the expensive check, run
		# only after the cheap rays found nothing.
		if not _forward_shape_clear(pos, flat, dist):
			var left := _side_clear(pos, flat, -1.0)
			var right := _side_clear(pos, flat, 1.0)
			if left and not right:
				_open_side = -1
				return Action.TAP_LEFT
			if right and not left:
				_open_side = 1
				return Action.TAP_RIGHT
			return Action.REROUTE
		return Action.CONTINUE

	## Classify a vertical knee-height face: 1 = jump now, 0 = a jumpable landing
	## exists but is farther than takeoff, -1 = wall or pit.  The caller only
	## invokes this inside takeoff range, so 0 is mostly a defensive result.  The
	## chest/full rays above were already clear, so the top is below chest height;
	## the landing probe is what rejects a low wall with a drop behind it.
	func _ledge_jump_state(pos: Vector3, flat: Vector3, face: Vector3) -> int:
		var face_flat := Vector2(face.x - pos.x, face.z - pos.z).length()
		var from_y := pos.y + PROBE_CHEST_HEIGHT + 0.4
		var to_y := pos.y - 0.5
		for ahead in [0.55, 0.95]:
			var ahead_f: float = ahead
			var column: Vector3 = pos + flat * (face_flat + ahead_f)
			var hit := _ray_hit(
				Vector3(column.x, from_y, column.z),
				Vector3(column.x, to_y, column.z)
			)
			if hit.is_empty():
				continue
			var normal: Vector3 = hit.normal
			if normal.angle_to(Vector3.UP) > deg_to_rad(FLOOR_MAX_ANGLE_DEG):
				continue
			var landing: Vector3 = hit.position
			var rise := landing.y - pos.y
			if rise < 0.15 or rise > JUMP_STEP_MAX:
				continue
			if not _headroom_clear(landing, false):
				continue
			return 1 if face_flat <= JUMP_TAKEOFF else 0
		return -1

	func _apply_action(action: int) -> bool:
		match action:
			Action.TAP_LEFT:
				bot._keyboard.tap(&"left", randf_range(0.08, 0.12))
				return true
			Action.TAP_RIGHT:
				bot._keyboard.tap(&"right", randf_range(0.08, 0.12))
				return true
			Action.JUMP:
				bot._keyboard.jump_tap(false)
				return false
			Action.CROUCH:
				bot._keyboard.crouch_hold(0.2)
				return false
			Action.STOP:
				bot._keyboard.set_move(0, 0)
				return true
			Action.BACK_UP:
				bot._keyboard.set_move(-1, 0)
				return true
			Action.REROUTE:
				_force_repath = true
				bot._keyboard.set_move(0, 0)
				_begin_recovery(Recovery.REROUTE, 0.3)
				return true
			_:
				return false

	func _ray_hit(from: Vector3, to: Vector3) -> Dictionary:
		_rays_this_second += 1
		var space := _space()
		if space == null:
			return {}
		_ray.from = from
		_ray.to = to
		_ray.exclude = _excludes()
		return space.intersect_ray(_ray)

	func _ray_clear(from: Vector3, to: Vector3) -> bool:
		return _ray_hit(from, to).is_empty()

	func _side_clear(pos: Vector3, forward: Vector3, sign_side: float) -> bool:
		var right := Vector3.UP.cross(forward).normalized()
		var dir := right * sign_side
		var from := pos + Vector3.UP * PROBE_CHEST_HEIGHT
		return _ray_clear(from, from + dir * SIDE_PROBE_DISTANCE)

	func _headroom_clear(pos: Vector3, crouch: bool) -> bool:
		var shape: CapsuleShape3D = _crouch_shape if crouch else _stand_shape
		var height := CROUCH_HEIGHT if crouch else STAND_HEIGHT
		var space := _space()
		if space == null:
			return true
		_rays_this_second += 1
		_shape_query.shape = shape
		_shape_query.transform = Transform3D(
			Basis.IDENTITY, pos + Vector3.UP * (height * 0.5 + 0.05)
		)
		_shape_query.exclude = _excludes()
		return space.intersect_shape(_shape_query, 1).is_empty()

	func _forward_shape_clear(pos: Vector3, dir: Vector3, dist: float) -> bool:
		var space := _space()
		if space == null:
			return true
		var crouch := bot.player.is_crouching
		var shape: CapsuleShape3D = _crouch_shape if crouch else _stand_shape
		var height := CROUCH_HEIGHT if crouch else STAND_HEIGHT
		_rays_this_second += 1
		_shape_query.shape = shape
		_shape_query.transform = Transform3D(
			Basis.IDENTITY, pos + Vector3.UP * (height * 0.5 + 0.05)
		)
		_shape_query.motion = dir * dist
		_shape_query.exclude = _excludes()
		var result := space.cast_motion(_shape_query)
		return result.size() >= 2 and result[0] >= 0.75

	func _excludes() -> Array[RID]:
		if _graph != null:
			return _graph.get_excludes()
		return _own_exclude

	func _space() -> PhysicsDirectSpaceState3D:
		return bot.player.get_world_3d().direct_space_state

	## Escalating recovery.  Never rotates the body; every stage is a Stage 2
	## verb, and progress clears the staircase so a single snag does not make the
	## bot permanently jumpy.
	func _trigger_stuck() -> void:
		if _recovery != Recovery.NONE:
			return
		_recovery_stage = mini(_recovery_stage + 1, 5)
		var pos := bot.player.global_position
		_recent_stuck.append({
			"pos": pos,
			"until": float(Time.get_ticks_msec()) / 1000.0 + STUCK_MEMORY,
		})
		_progress_timer = 0.0
		_progress_pos = pos
		match _recovery_stage:
			1:
				_begin_recovery(Recovery.JUMP, randf_range(0.35, 0.6))
			2:
				_begin_recovery(Recovery.STRAFE, randf_range(0.3, 0.5))
			3:
				_begin_recovery(Recovery.BACKUP, randf_range(0.35, 0.6))
			4:
				_nav_retry_after_ms = Time.get_ticks_msec() + NAV_STUCK_RETRY_MS
				_nav_fail_count = 0
				_graph_needed = true
				_force_repath = true
				_begin_recovery(Recovery.REROUTE, randf_range(0.3, 0.5))
			_:
				_begin_recovery(Recovery.TURN, randf_range(0.4, 0.7))

	func _begin_recovery(state: Recovery, duration: float) -> void:
		_recovery = state
		_recovery_timer = duration
		_recovery_applied = false

	func _tick_recovery(delta: float) -> void:
		var pos := bot.player.global_position
		if not _recovery_applied:
			_recovery_applied = true
			match _recovery:
				Recovery.JUMP:
					bot._keyboard.jump_tap(true)
				Recovery.STRAFE:
					if _open_side > 0:
						bot._keyboard.tap(&"right", 0.1)
					elif _open_side < 0:
						bot._keyboard.tap(&"left", 0.1)
					else:
						bot._keyboard.tap(
							&"right" if randf() > 0.5 else &"left", 0.1
						)
				Recovery.BACKUP:
					bot._keyboard.set_move(-1, 0)
					_request_look(_goal)
				Recovery.REROUTE:
					bot._keyboard.set_move(0, 0)
					_force_repath = true
				Recovery.TURN:
					var away := pos - _goal
					if away.length_squared() < 0.001:
						away = -bot.player.horizontal_forward()
					bot._mouse.request_look_direction(
						away, LookPriority.TRAVEL_LOOKAHEAD, 0.8
					)
					bot._keyboard.set_move(1, 0)
				_:
					pass

		match _recovery:
			Recovery.BACKUP:
				bot._keyboard.set_move(-1, 0)
				_request_look(_goal)
			Recovery.TURN:
				bot._keyboard.set_move(1, 0)
			Recovery.JUMP, Recovery.STRAFE:
				bot._keyboard.set_move(1, 0)
			_:
				bot._keyboard.set_move(0, 0)

		_recovery_timer -= delta
		if _recovery_timer <= 0.0:
			_recovery = Recovery.NONE
			_recovery_timer = 0.0
			_recovery_applied = false
			_progress_pos = pos
			_progress_timer = 0.0
			_state_text = "recovered%d" % _recovery_stage

	func pick_wander_point(min_dist: float, max_dist: float) -> Vector3:
		if _nav == null:
			_nav = NavRoutes.shared_for(bot.player)
		if _nav != null and _nav.has_mesh():
			if not _nav.is_usable():
				return Vector3.INF
			return _nav.pick_wander_point(
				bot.player.global_position, min_dist, max_dist)
		_graph_needed = true
		if _graph == null:
			_graph = TravelGraph.shared_for(bot.player)
		if _graph == null or not _graph.is_ready():
			return Vector3.INF
		return _graph.pick_wander_point(bot.player.global_position, min_dist, max_dist)

	func get_state_text() -> String:
		return _state_text

	func get_debug_text() -> String:
		var graph_text := "-"
		if _graph != null:
			graph_text = _graph.get_status_text()
		var nav_text := "-"
		if _nav != null:
			nav_text = _nav.get_status_text()
		var source_text: String = ["direct", "graph", "nav", "navpart"][_path_source]
		return "%s src=%s path=%d rays/s=%d nav=%s %s" % [
			_state_text, source_text, _path_points.size(), _rays_per_second,
			nav_text, graph_text
		]


## Per-bot movement/mouse personality, drawn once per spawn from `skill` plus
## variance.  Skill sets the average; these fields make two same-skill bots
## behave differently.
class Style extends RefCounted:
	var strafe_hold_median: float = 1.0
	var strafe_hold_spread: float = 0.25
	var pause_probability: float = 0.2
	var jump_rate: float = 0.08
	var crouch_rate: float = 0.02
	var peek_style_weights: Array[float] = [0.5, 0.3, 0.2, 0.0]
	var counter_strafe_skill: float = 0.5
	var reaction_time: float = 0.2
	var mouse_speed: float = 0.8
	var flick_accuracy: float = 0.8
	var tracking_lag: float = 0.12
	var bhop_ability: float = 0.5
	var allow_strafe: bool = true
	var allow_back: bool = true
	var allow_diagonal: bool = true
	var allow_jump: bool = true
	var allow_crouch: bool = true
	var fire_tap_min: float = BotController.FIRE_TAP_MIN
	var fire_tap_max: float = BotController.FIRE_TAP_MAX
	var fire_click_hz: float = BotController.FIRE_CLICK_HZ_MAX
	var key_min_hold: float = BotController.KEY_MIN_HOLD_MIN
	var key_flip_rate: float = BotController.KEY_FLIP_RATE_MAX
	## --- Stage 6 skill traits (see SKILL_TRAIT_TABLE) ---------------------
	var accuracy: float = 0.7
	var tracking_speed: float = 0.6
	var lead_quality: float = 0.5
	var movement_quality: float = 0.5
	var awareness: float = 0.6
	## 0 = cautious/flanking, 1 = direct/aggressive.  Used for target weighting,
	## a mild objective approach offset, and how long/where the bot hunts a
	## target that broke line of sight.
	var aggression: float = 0.5
	## 0 = fights to the death, 1 = breaks off as soon as the trade turns.
	## Drives the retreat thresholds, cover patience and flee duration.
	var survival: float = 0.5
	var flank_bias: float = 0.0

	func draw(skill_value: float, seed_value: int = 0) -> void:
		var s: float = clampf(skill_value, 0.0, 1.0)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value if seed_value != 0 else randi()
		var traits := _traits_at(s)
		accuracy = clampf(
			float(traits["accuracy"]) * rng.randf_range(0.94, 1.04), 0.05, 0.995
		)
		tracking_speed = clampf(
			float(traits["tracking_speed"]) * rng.randf_range(0.9, 1.08), 0.05, 1.0
		)
		lead_quality = clampf(
			float(traits["lead_quality"]) * rng.randf_range(0.85, 1.08), 0.0, 1.0
		)
		movement_quality = clampf(
			float(traits["movement_quality"]) * rng.randf_range(0.88, 1.08),
			0.05, 1.0
		)
		awareness = clampf(
			float(traits["awareness"]) * rng.randf_range(0.92, 1.06), 0.05, 1.0
		)
		aggression = clampf(
			float(traits["aggression"]) + rng.randf_range(-0.28, 0.28), 0.0, 1.0
		)
		reaction_time = clampf(
			float(traits["reaction"]) * rng.randf_range(0.82, 1.22),
			BotController.KEY_REACTION_MIN, BotController.KEY_REACTION_MAX
		)
		strafe_hold_median = lerpf(1.2, 0.4, movement_quality) * rng.randf_range(0.8, 1.25)
		strafe_hold_spread = lerpf(0.45, 0.15, movement_quality)
		pause_probability = lerpf(0.35, 0.06, movement_quality) * rng.randf_range(0.7, 1.3)
		jump_rate = lerpf(0.02, 0.16, movement_quality) * rng.randf_range(0.7, 1.3)
		crouch_rate = lerpf(0.0, 0.06, movement_quality)
		var low: Array[float] = [0.7, 0.2, 0.1, 0.0]
		var high: Array[float] = [0.3, 0.25, 0.3, 0.15]
		var weights: Array[float] = []
		for i in 4:
			weights.append(lerpf(low[i], high[i], movement_quality))
		peek_style_weights = weights
		counter_strafe_skill = movement_quality * rng.randf_range(0.75, 1.0)
		mouse_speed = lerpf(0.55, 1.0, accuracy) * rng.randf_range(0.9, 1.1)
		flick_accuracy = accuracy
		# Tracking lag is the inverse of the trait: a high tracking_speed settles
		# in ~0.03 s, a low one visibly trails at ~0.3 s.
		tracking_lag = lerpf(0.30, 0.03, tracking_speed) * rng.randf_range(0.85, 1.2)
		bhop_ability = movement_quality * rng.randf_range(0.5, 1.0)
		# Low skill unlocks only a small vocabulary; max skill unlocks everything.
		allow_strafe = movement_quality > 0.20
		allow_back = movement_quality > 0.38
		allow_diagonal = movement_quality > 0.52
		allow_jump = movement_quality > 0.28
		allow_crouch = movement_quality > 0.60
		fire_tap_min = lerpf(0.10, BotController.FIRE_TAP_MIN, accuracy) \
			* rng.randf_range(0.9, 1.1)
		fire_tap_max = lerpf(0.12, BotController.FIRE_TAP_MAX, accuracy) \
			* rng.randf_range(0.9, 1.1)
		fire_click_hz = lerpf(
			BotController.FIRE_CLICK_HZ_MIN, BotController.FIRE_CLICK_HZ_MAX, accuracy
		) * rng.randf_range(0.9, 1.1)
		key_min_hold = lerpf(
			BotController.KEY_MIN_HOLD_MAX, BotController.KEY_MIN_HOLD_MIN, movement_quality
		) * rng.randf_range(0.85, 1.15)
		key_flip_rate = lerpf(
			BotController.KEY_FLIP_RATE_MIN, BotController.KEY_FLIP_RATE_MAX, movement_quality
		) * rng.randf_range(0.9, 1.1)
		flank_bias = rng.randf_range(-1.0, 1.0)
		# Draw last so every pre-existing trait keeps the same value for a given
		# seed; adding a trait must not re-roll old personalities.
		survival = clampf(
			float(traits["survival"]) + rng.randf_range(-0.18, 0.18), 0.0, 1.0
		)

	## Apply one dev-menu trait override and keep every field derived from it in
	## sync.  The master Skill slider redraws the whole style first, then these
	## overrides are re-applied on top.
	func apply_trait(key: String, value: float) -> void:
		match key:
			"reaction_time":
				reaction_time = clampf(
					value, BotController.KEY_REACTION_MIN, BotController.KEY_REACTION_MAX
				)
			"tracking_speed":
				tracking_speed = clampf(value, 0.0, 1.0)
				tracking_lag = lerpf(0.30, 0.03, tracking_speed)
			"accuracy":
				accuracy = clampf(value, 0.0, 1.0)
				flick_accuracy = accuracy
				mouse_speed = lerpf(0.55, 1.0, accuracy)
				fire_tap_min = lerpf(0.10, BotController.FIRE_TAP_MIN, accuracy)
				fire_tap_max = lerpf(0.12, BotController.FIRE_TAP_MAX, accuracy)
				fire_click_hz = lerpf(
					BotController.FIRE_CLICK_HZ_MIN, BotController.FIRE_CLICK_HZ_MAX,
					accuracy
				)
			"aggression":
				aggression = clampf(value, 0.0, 1.0)
			"lead_quality":
				lead_quality = clampf(value, 0.0, 1.0)
			"movement_quality":
				movement_quality = clampf(value, 0.0, 1.0)
				strafe_hold_median = lerpf(1.2, 0.4, movement_quality)
				strafe_hold_spread = lerpf(0.45, 0.15, movement_quality)
				pause_probability = lerpf(0.35, 0.06, movement_quality)
				jump_rate = lerpf(0.02, 0.16, movement_quality)
				crouch_rate = lerpf(0.0, 0.06, movement_quality)
				counter_strafe_skill = movement_quality
				bhop_ability = movement_quality
				key_min_hold = lerpf(
					BotController.KEY_MIN_HOLD_MAX,
					BotController.KEY_MIN_HOLD_MIN,
					movement_quality
				)
				key_flip_rate = lerpf(
					BotController.KEY_FLIP_RATE_MIN,
					BotController.KEY_FLIP_RATE_MAX,
					movement_quality
				)
				allow_strafe = movement_quality > 0.20
				allow_back = movement_quality > 0.38
				allow_diagonal = movement_quality > 0.52
				allow_jump = movement_quality > 0.28
				allow_crouch = movement_quality > 0.60
			"awareness":
				awareness = clampf(value, 0.0, 1.0)
			"survival":
				survival = clampf(value, 0.0, 1.0)

	## Interpolate one row of SKILL_TRAIT_TABLE.  Kept here so every trait has a
	## single documented source and per-bot variance is applied by the caller.
	func _traits_at(s: float) -> Dictionary:
		var table: Array = BotController.SKILL_TRAIT_TABLE
		var lower: Dictionary = table[0]
		var upper: Dictionary = table[table.size() - 1]
		for i in table.size() - 1:
			var a: Dictionary = table[i]
			var b: Dictionary = table[i + 1]
			if s <= float(b["skill"]):
				lower = a
				upper = b
				break
		var span := maxf(float(upper["skill"]) - float(lower["skill"]), 0.0001)
		var t := clampf((s - float(lower["skill"])) / span, 0.0, 1.0)
		var result := {}
		for key in lower.keys():
			if key == "skill":
				continue
			result[key] = lerpf(float(lower[key]), float(upper[key]), t)
		return result


## The keyboard emulator.  Owns `input_dir`, `jump_input`, `crouch`, `dash_input`.
## Intent-level API:
##   set_move(forward, strafe)   +1/-1/0, human key terms (W positive)
##   set_move_world(dir)         rare adapter for navigation code
##   set_move_input_vector(v)    camera/body-local (x=strafe, y=backward)
##   tap(key, duration), hold(key), release(key), counter_strafe()
##   jump_tap(), crouch_hold(duration), dash_tap()
class Keyboard extends RefCounted:
	var bot: BotController

	## Desired and actually-held key signs.  Held state is what PlayerInput sees.
	var _desired_forward: int = 0
	var _desired_strafe: int = 0
	var _held_forward: int = 0
	var _held_strafe: int = 0

	## Minimum time a key stays down / cooldown before this axis may change sign.
	var _forward_hold: float = 0.0
	var _strafe_hold: float = 0.0
	var _forward_cooldown: float = 0.0
	var _strafe_cooldown: float = 0.0
	var _reaction_forward: float = 0.0
	var _reaction_strafe: float = 0.0

	## Short forced taps.  The axis returns to `_desired_*` when the tap expires.
	var _tap_forward_timer: float = 0.0
	var _tap_forward_sign: int = 0
	var _tap_strafe_timer: float = 0.0
	var _tap_strafe_sign: int = 0

	var _jump_timer: float = 0.0
	var _jump_cooldown: float = 0.0
	var _jump_held: bool = false
	var _crouch_timer: float = 0.0
	var _crouch_latched: bool = false
	var _dash_timer: float = 0.0
	var _dash_cooldown: float = 0.0

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot

	func set_move(forward: int, strafe: int) -> void:
		forward = clampi(forward, -1, 1)
		strafe = clampi(strafe, -1, 1)
		var style: BotController.Style = bot._style
		if style != null:
			if not style.allow_strafe:
				strafe = 0
			if not style.allow_back and forward < 0:
				forward = 0
			if not style.allow_diagonal and forward != 0 and strafe != 0:
				# Low skill: no simultaneous W+A/W+D.  Pick the dominant intent.
				if absi(forward) >= absi(strafe):
					strafe = 0
				else:
					forward = 0
		if _desired_forward == 0 and forward != 0:
			_reaction_forward = _reaction_delay()
		if _desired_strafe == 0 and strafe != 0:
			_reaction_strafe = _reaction_delay()
		_desired_forward = forward
		_desired_strafe = strafe

	func set_move_world(world_dir: Vector2) -> void:
		var keys := keys_for_world_dir(world_dir)
		set_move(keys.y, keys.x)

	func set_move_input_vector(local: Vector2) -> void:
		var forward := -local.y
		var keys := _quantise(local.x, forward)
		set_move(keys.y, keys.x)

	## Convert world direction to the nearest 8-way key pair.  Returns
	## (strafe, forward), both -1/0/1, in HUMAN key terms (+forward = W).
	## This is the rare adapter used by navigation and stuck recovery; normal
	## combat movement is built in the local frame and never round-trips here.
	func keys_for_world_dir(world_dir: Vector2) -> Vector2i:
		var local := world_to_input_local(world_dir)
		return _quantise(local.x, -local.y)

	## World direction -> input_dir convention (x = strafe, y = +1 backward).
	func world_to_input_local(world_dir: Vector2) -> Vector2:
		if world_dir.length_squared() < 0.000001:
			return Vector2.ZERO
		var forward := _movement_forward()
		var right := Vector3.UP.cross(forward).normalized()
		var world := Vector3(world_dir.x, 0.0, world_dir.y)
		return Vector2(world.dot(right), -world.dot(forward))

	func _movement_forward() -> Vector3:
		var fwd: Vector3 = bot.player.horizontal_forward()
		if fwd.length_squared() < 0.0001:
			var yaw: float = bot.player.body.rotation.y
			fwd = Vector3(-sin(yaw), 0.0, -cos(yaw))
		return fwd.normalized()

	func _quantise(strafe: float, forward: float) -> Vector2i:
		if absf(strafe) < 0.001 and absf(forward) < 0.001:
			return Vector2i.ZERO
		var angle := atan2(strafe, forward)
		var sector := posmod(int(round(angle / (PI / 4.0))), 8)
		match sector:
			0:
				return Vector2i(0, 1)
			1:
				return Vector2i(1, 1)
			2:
				return Vector2i(1, 0)
			3:
				return Vector2i(1, -1)
			4:
				return Vector2i(0, -1)
			5:
				return Vector2i(-1, -1)
			6:
				return Vector2i(-1, 0)
			_:
				return Vector2i(-1, 1)

	func tap(key: StringName, duration: float) -> void:
		var hold := maxf(duration, _min_hold())
		match key:
			&"jump":
				jump_tap(true)
			&"crouch":
				crouch_hold(hold)
			&"dash":
				dash_tap()
			&"forward":
				_tap_forward_timer = hold
				_tap_forward_sign = 1
			&"back":
				_tap_forward_timer = hold
				_tap_forward_sign = -1
			&"left":
				_tap_strafe_timer = hold
				_tap_strafe_sign = -1
			&"right":
				_tap_strafe_timer = hold
				_tap_strafe_sign = 1

	func hold(key: StringName) -> void:
		match key:
			&"jump":
				_jump_held = true
			&"crouch":
				_crouch_latched = true
			&"forward":
				set_move(1, _desired_strafe)
			&"back":
				set_move(-1, _desired_strafe)
			&"left":
				set_move(_desired_forward, -1)
			&"right":
				set_move(_desired_forward, 1)

	func release(key: StringName) -> void:
		match key:
			&"jump":
				_jump_held = false
			&"crouch":
				_crouch_latched = false
			&"forward":
				if _desired_forward > 0:
					set_move(0, _desired_strafe)
			&"back":
				if _desired_forward < 0:
					set_move(0, _desired_strafe)
			&"left":
				if _desired_strafe < 0:
					set_move(_desired_forward, 0)
			&"right":
				if _desired_strafe > 0:
					set_move(_desired_forward, 0)

	## Brief opposite-strafe tap.  The keyboard resolves one strafe sign at a
	## time, so this is a short opposite tap (not a simultaneous A+D press) that
	## bleeds lateral velocity before the next direction.
	func counter_strafe() -> void:
		var style: BotController.Style = bot._style
		if style != null and randf() > style.counter_strafe_skill:
			return
		if _held_strafe == 0 or _tap_strafe_timer > 0.0:
			return
		_tap_strafe_sign = -_held_strafe
		var movement_quality := style.movement_quality if style != null else bot.skill
		_tap_strafe_timer = maxf(_min_hold(), lerpf(0.09, 0.05, movement_quality))

	func jump_tap(allow_air: bool = false) -> void:
		var style: BotController.Style = bot._style
		if style != null and not style.allow_jump:
			return
		if _jump_timer > 0.0 or _jump_cooldown > 0.0:
			return
		if not allow_air and not bot.player.is_on_floor():
			return
		_jump_timer = maxf(BotController.KEY_MIN_HOLD_MIN, 0.06)
		_jump_cooldown = randf_range(0.18, 0.34)

	func crouch_hold(duration: float) -> void:
		var style: BotController.Style = bot._style
		if style != null and not style.allow_crouch:
			return
		_crouch_timer = maxf(
			_crouch_timer, maxf(duration, BotController.KEY_MIN_HOLD_MIN)
		)

	func dash_tap() -> void:
		if _dash_timer > 0.0 or _dash_cooldown > 0.0:
			return
		_dash_timer = maxf(BotController.KEY_MIN_HOLD_MIN, 0.06)
		_dash_cooldown = randf_range(0.4, 0.8)

	func tick(delta: float) -> void:
		_forward_hold = maxf(_forward_hold - delta, 0.0)
		_strafe_hold = maxf(_strafe_hold - delta, 0.0)
		_forward_cooldown = maxf(_forward_cooldown - delta, 0.0)
		_strafe_cooldown = maxf(_strafe_cooldown - delta, 0.0)
		_reaction_forward = maxf(_reaction_forward - delta, 0.0)
		_reaction_strafe = maxf(_reaction_strafe - delta, 0.0)
		_tap_forward_timer = maxf(_tap_forward_timer - delta, 0.0)
		_tap_strafe_timer = maxf(_tap_strafe_timer - delta, 0.0)
		_jump_timer = maxf(_jump_timer - delta, 0.0)
		_jump_cooldown = maxf(_jump_cooldown - delta, 0.0)
		_crouch_timer = maxf(_crouch_timer - delta, 0.0)
		_dash_timer = maxf(_dash_timer - delta, 0.0)
		_dash_cooldown = maxf(_dash_cooldown - delta, 0.0)

		var want_forward := _desired_forward
		if _tap_forward_timer > 0.0:
			want_forward = _tap_forward_sign
		if want_forward != _held_forward \
				and _forward_hold <= 0.0 \
				and _forward_cooldown <= 0.0 \
				and _reaction_forward <= 0.0:
			_held_forward = want_forward
			_forward_hold = _min_hold()
			_forward_cooldown = maxf(1.0 / _flip_rate(), _forward_hold)

		var want_strafe := _desired_strafe
		if _tap_strafe_timer > 0.0:
			want_strafe = _tap_strafe_sign
		if want_strafe != _held_strafe \
				and _strafe_hold <= 0.0 \
				and _strafe_cooldown <= 0.0 \
				and _reaction_strafe <= 0.0:
			_held_strafe = want_strafe
			_strafe_hold = _min_hold()
			_strafe_cooldown = maxf(1.0 / _flip_rate(), _strafe_hold)

		var input: PlayerInput = bot.player.player_input
		input.input_dir = Vector2(float(_held_strafe), -float(_held_forward))
		input.jump_input = _jump_timer > 0.0 or _jump_held
		input.crouch = _crouch_timer > 0.0 or _crouch_latched
		input.dash_input = _dash_timer > 0.0

	func release_all() -> void:
		_desired_forward = 0
		_desired_strafe = 0
		_held_forward = 0
		_held_strafe = 0
		_forward_hold = 0.0
		_strafe_hold = 0.0
		_forward_cooldown = 0.0
		_strafe_cooldown = 0.0
		_reaction_forward = 0.0
		_reaction_strafe = 0.0
		_tap_forward_timer = 0.0
		_tap_strafe_timer = 0.0
		_jump_timer = 0.0
		_jump_cooldown = 0.0
		_jump_held = false
		_crouch_timer = 0.0
		_crouch_latched = false
		_dash_timer = 0.0
		_dash_cooldown = 0.0
		if bot != null and is_instance_valid(bot.player) and bot.player.player_input != null:
			var input: PlayerInput = bot.player.player_input
			input.input_dir = Vector2.ZERO
			input.jump_input = false
			input.crouch = false
			input.dash_input = false

	func is_moving() -> bool:
		return _held_forward != 0 or _held_strafe != 0 \
			or _desired_forward != 0 or _desired_strafe != 0

	func _min_hold() -> float:
		var style: BotController.Style = bot._style
		if style == null:
			return BotController.KEY_MIN_HOLD_MIN
		return clampf(
			style.key_min_hold,
			BotController.KEY_MIN_HOLD_MIN,
			BotController.KEY_MIN_HOLD_MAX
		)

	func _flip_rate() -> float:
		var style: BotController.Style = bot._style
		if style == null:
			return BotController.KEY_FLIP_RATE_MIN
		return clampf(
			style.key_flip_rate,
			BotController.KEY_FLIP_RATE_MIN,
			BotController.KEY_FLIP_RATE_MAX
		)

	func _reaction_delay() -> float:
		var style: BotController.Style = bot._style
		if style == null:
			return BotController.KEY_REACTION_MIN
		return clampf(style.reaction_time, 0.0, BotController.KEY_REACTION_MAX) \
			* randf_range(0.6, 1.2)

	func get_state_text() -> String:
		var text := ""
		if _held_forward > 0:
			text += "W"
		if _held_forward < 0:
			text += "S"
		if _held_strafe < 0:
			text += "A"
		if _held_strafe > 0:
			text += "D"
		if text.is_empty():
			text = "-"
		if _jump_timer > 0.0 or _jump_held:
			text += "J"
		if _crouch_timer > 0.0 or _crouch_latched:
			text += "C"
		return text


## The mouse emulator.  Sole owner of body yaw and head pitch.  Other code
## places look REQUESTS with priorities; this class turns them into a ballistic
## flick, corrective submovements and pursuit tracking, then applies integer
## mouse counts through Body._apply_mouse_look (the real look path, including its
## pitch clamp).
class Mouse extends RefCounted:
	enum Mode { IDLE, TRAVEL, FLICK, TRACK, CORRECT }

	var bot: BotController
	var _event: InputEventMouseMotion = InputEventMouseMotion.new()

	var _has_request: bool = false
	var _priority: int = 0
	var _request_ttl: float = 0.0
	var _point: Vector3 = Vector3.ZERO
	var _direction: Vector3 = Vector3.ZERO
	var _use_direction: bool = false
	var _provider: Variant = null
	var _urgency: float = 0.5
	var _stimulus_key: String = ""

	var _reaction_timer: float = 0.0
	var _mode: Mode = Mode.IDLE
	var _flick_timer: float = 0.0
	var _flick_duration: float = 0.1
	var _flick_start_yaw: float = 0.0
	var _flick_start_pitch: float = 0.0
	var _flick_total_yaw: float = 0.0
	var _flick_total_pitch: float = 0.0
	var _flick_correction: bool = false
	var _corrections_left: int = 0
	var _correction_timer: float = 0.0

	var _track_vel_yaw: float = 0.0
	var _track_vel_pitch: float = 0.0
	var _target_vel_yaw: float = 0.0
	var _target_vel_pitch: float = 0.0
	var _prev_desired_yaw: float = 0.0
	var _prev_desired_pitch: float = 0.0
	var _has_prev: bool = false

	## Continuous drift: two slow sines plus one micro sine, never a random step.
	var _drift_time: float = 0.0
	var _drift_phase_a: float = 0.0
	var _drift_phase_b: float = 0.0
	var _drift_phase_c: float = 0.0
	var _drift_rate_a: float = 0.3
	var _drift_rate_b: float = 0.9
	var _drift_rate_c: float = 9.0
	var _jitter_yaw: float = 0.0
	var _jitter_pitch: float = 0.0
	var _idle_phase: float = 0.0
	var _residual_x: float = 0.0
	var _residual_y: float = 0.0
	var _last_dx: float = 0.0
	var _last_dy: float = 0.0

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot
		_drift_phase_a = randf() * TAU
		_drift_phase_b = randf() * TAU
		_drift_phase_c = randf() * TAU
		_drift_rate_a = randf_range(
			BotController.AIM_DRIFT_RATE_A_MIN, BotController.AIM_DRIFT_RATE_A_MAX
		)
		_drift_rate_b = randf_range(
			BotController.AIM_DRIFT_RATE_B_MIN, BotController.AIM_DRIFT_RATE_B_MAX
		)
		_drift_rate_c = randf_range(
			BotController.AIM_MICRO_RATE_MIN, BotController.AIM_MICRO_RATE_MAX
		)

	## Request the crosshair be placed on a world point.  `priority` is a
	## BotController.LookPriority; a lower-priority request is ignored while a
	## live higher-priority one exists.  `stimulus_key` identifies a NEW stimulus
	## (target instance id); the same key refreshed every think tick does not
	## restart the reaction delay.
	func request_look_at_point(point: Vector3, priority: int, urgency: float = 0.5,
			stimulus_key: String = "") -> void:
		if _has_request and priority < _priority and _request_ttl > 0.0:
			return
		var changed := not _has_request or priority > _priority \
			or (not stimulus_key.is_empty() and stimulus_key != _stimulus_key)
		_has_request = true
		_priority = priority
		_request_ttl = BotController.LOOK_REQUEST_TTL
		_point = point
		_use_direction = false
		_provider = null
		_urgency = urgency
		_stimulus_key = stimulus_key
		if changed:
			_begin_stimulus()

	func request_look_direction(direction: Vector3, priority: int,
			urgency: float = 0.3) -> void:
		if _has_request and priority < _priority and _request_ttl > 0.0:
			return
		var changed := not _has_request or priority > _priority \
			or not _use_direction
		if not changed and direction.length_squared() > 0.000001 \
				and _direction.length_squared() > 0.000001 \
				and direction.angle_to(_direction) > deg_to_rad(25.0):
			# A travel target changing by more than ~25 deg is a new stimulus:
			# a human does not snap the view to every path correction.
			changed = true
		_has_request = true
		_priority = priority
		_request_ttl = BotController.LOOK_REQUEST_TTL
		_direction = direction
		_use_direction = true
		_provider = null
		_urgency = urgency
		_stimulus_key = "dir"
		if changed:
			_begin_stimulus()

	## Hold the crosshair on a Node3D (for a Player this is the head bone) or on
	## a Callable that returns a world Vector3.  The provider is re-evaluated
	## every physics frame.
	func hold_crosshair_on(provider: Variant, priority: int,
			urgency: float = 0.5) -> void:
		if _has_request and priority < _priority and _request_ttl > 0.0:
			return
		var key := str(provider)
		var changed := not _has_request or priority > _priority or key != _stimulus_key
		_has_request = true
		_priority = priority
		_request_ttl = BotController.LOOK_REQUEST_TTL
		_provider = provider
		_use_direction = false
		_urgency = urgency
		_stimulus_key = key
		if changed:
			_begin_stimulus()

	func _begin_stimulus() -> void:
		_reaction_timer = _reaction_delay()
		_mode = Mode.IDLE
		_flick_timer = 0.0
		_correction_timer = 0.0
		_corrections_left = 0
		_track_vel_yaw = 0.0
		_track_vel_pitch = 0.0

	func _reaction_delay() -> float:
		var style: BotController.Style = bot._style
		var base := BotController.KEY_REACTION_MIN
		if style != null:
			base = maxf(style.reaction_time, BotController.KEY_REACTION_MIN)
		var urgency := clampf(_urgency, 0.0, 1.0)
		var scale := lerpf(1.6, 0.35, urgency)
		if _priority <= BotController.LookPriority.TRAVEL_LOOKAHEAD:
			scale *= 1.5
		return base * scale * randf_range(0.7, 1.3)

	## Low-frequency aim wander plus a tiny high-frequency tremor.  This is a
	## continuous function of time, so there is no visible stepping, and moving
	## targets widen it because tracking a strafer is harder than a stationary one.
	func _update_aim_drift() -> void:
		var style: BotController.Style = bot._style
		var accuracy := style.accuracy if style != null else 0.7
		var motion := 1.0
		var target := bot._current_target
		if target != null and is_instance_valid(target):
			var target_speed := bot._estimated_velocity_for(target).length()
			motion += clampf(target_speed / BotController.AIM_TARGET_SPEED_REF, 0.0, 1.0)
		var wander := BotController.AIM_DRIFT_BASE * (1.0 - accuracy) * motion
		var micro := lerpf(BotController.AIM_MICRO_MAX, 0.0008, accuracy) * motion
		_jitter_yaw = (
			sin(_drift_time * _drift_rate_a + _drift_phase_a) * 0.65
			+ sin(_drift_time * _drift_rate_b + _drift_phase_b) * 0.35
		) * wander + sin(_drift_time * _drift_rate_c + _drift_phase_c) * micro
		_jitter_pitch = (
			cos(_drift_time * _drift_rate_a * 0.83 + _drift_phase_b) * 0.65
			+ sin(_drift_time * _drift_rate_b * 1.11 + _drift_phase_c) * 0.35
		) * wander + cos(_drift_time * _drift_rate_c * 1.07 + _drift_phase_a) * micro

	func tick(delta: float) -> void:
		_idle_phase += delta
		_drift_time += delta
		_update_aim_drift()

		if _has_request:
			_request_ttl -= delta
			if _request_ttl <= 0.0:
				_has_request = false
				_provider = null

		if _provider != null and not _resolve_provider():
			_has_request = false
			_provider = null

		var desired := _desired_angles()
		var target_yaw: float = desired.x
		var target_pitch: float = desired.y

		# Recoil is part of the real camera ray but not of Body yaw / Head pitch.
		# Compensating it here (scaled by skill) keeps the old skill dial: a max
		# skill bot counters recoil perfectly, a low-skill bot does not.  Only
		# while there is an actual aim request — idle/travel must not fight
		# recoil with a crosshair nobody asked to place.
		var wc: WeaponController = bot.player.weapon_controller
		if _has_request and wc != null and is_instance_valid(wc) and wc.recoil != null:
			var recoil: Vector3 = wc.recoil.rotation
			# Shots add positive pitch/yaw, so counter-rotate by subtracting.
			# Accuracy (not raw skill) decides how much of the kick is corrected.
			var style: BotController.Style = bot._style
			var comp := style.accuracy if style != null else bot.skill
			target_yaw -= recoil.y * BotController.RECOIL_COMP_SIGN * comp
			target_pitch -= recoil.x * BotController.RECOIL_COMP_SIGN * comp

		target_yaw += _jitter_yaw
		target_pitch += _jitter_pitch
		target_pitch = clampf(
			target_pitch, -BotController.LOOK_PITCH_LIMIT, BotController.LOOK_PITCH_LIMIT
		)

		var body: Node3D = bot.player.body
		var current_yaw: float = body.rotation.y
		var current_pitch: float = bot._head_node.rotation.x
		var err_yaw := wrapf(target_yaw - current_yaw, -PI, PI)
		var err_pitch := wrapf(target_pitch - current_pitch, -PI, PI)
		var err_deg := rad_to_deg(sqrt(err_yaw * err_yaw + err_pitch * err_pitch))

		if _reaction_timer > 0.0:
			_reaction_timer = maxf(_reaction_timer - delta, 0.0)
			_remember_desired(target_yaw, target_pitch)
			return

		if _mode == Mode.FLICK or _mode == Mode.CORRECT:
			_tick_ballistic(delta, target_yaw, target_pitch)
			_remember_desired(target_yaw, target_pitch)
			return

		if _correction_timer > 0.0:
			_correction_timer = maxf(_correction_timer - delta, 0.0)
			if _correction_timer <= 0.0 and err_deg > BotController.LOOK_CORRECTION_DEG:
				_start_flick(target_yaw, target_pitch, true)
			_remember_desired(target_yaw, target_pitch)
			return

		if err_deg > BotController.LOOK_FLICK_START_DEG:
			_start_flick(target_yaw, target_pitch, false)
			_remember_desired(target_yaw, target_pitch)
			return

		_mode = Mode.TRAVEL if not _has_request else Mode.TRACK
		_tick_tracking(delta, target_yaw, target_pitch, err_yaw, err_pitch)
		_remember_desired(target_yaw, target_pitch)

	func _desired_angles() -> Vector2:
		if _has_request:
			if _use_direction:
				var dir := _direction
				if dir.length_squared() > 0.000001:
					var flat := Vector2(dir.x, dir.z).length()
					return Vector2(
						atan2(-dir.x, -dir.z),
						atan2(dir.y, maxf(flat, 0.001))
					)
			else:
				return _angles_for_point(_point)
		return _fallback_angles()

	func _angles_for_point(point: Vector3) -> Vector2:
		var head := bot._head_node.global_position
		var to := point - head
		if to.length_squared() < 0.000001:
			return Vector2(bot.player.body.rotation.y, bot._head_node.rotation.x)
		var flat := Vector2(to.x, to.z).length()
		return Vector2(
			atan2(-to.x, -to.z),
			atan2(to.y, maxf(flat, 0.001))
		)

	func _fallback_angles() -> Vector2:
		var velocity := bot.player.velocity
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		var look_dir := Vector3.ZERO
		if flat.length() > 0.5:
			look_dir = flat.normalized()
		else:
			var input := bot.player.player_input.input_dir
			if input.length() > 0.1:
				var forward := bot.player.horizontal_forward()
				var right := Vector3.UP.cross(forward).normalized()
				look_dir = (forward * -input.y + right * input.x).normalized()
		if look_dir.length_squared() > 0.000001:
			return Vector2(atan2(-look_dir.x, -look_dir.z), 0.0)
		# Idle: hold the yaw, settle the pitch to eye level with a tiny drift.
		return Vector2(
			bot.player.body.rotation.y,
			sin(_idle_phase * 0.7) * BotController.LOOK_IDLE_DRIFT
		)

	func _resolve_provider() -> bool:
		if _provider is Callable:
			var callback := _provider as Callable
			if not callback.is_valid():
				return false
			var result: Variant = callback.call()
			if result is Vector3:
				_point = result as Vector3
				return true
			return false
		if _provider is Player:
			var target := _provider as Player
			if not is_instance_valid(target) or not target.spawned:
				return false
			_point = bot._get_head_position(target)
			return true
		if _provider is Node3D:
			var node := _provider as Node3D
			if not is_instance_valid(node):
				return false
			_point = node.global_position + Vector3(0.0, BotController.AIM_CENTER_HEIGHT, 0.0)
			return true
		return false

	func _start_flick(target_yaw: float, target_pitch: float, correction: bool) -> void:
		var body: Node3D = bot.player.body
		var start_yaw: float = body.rotation.y
		var start_pitch: float = bot._head_node.rotation.x
		var total_yaw := wrapf(target_yaw - start_yaw, -PI, PI)
		var total_pitch := wrapf(target_pitch - start_pitch, -PI, PI)
		var style: BotController.Style = bot._style
		var accuracy := 0.7
		var mouse_speed := 0.8
		if style != null:
			accuracy = style.accuracy
			mouse_speed = style.mouse_speed
		var error := 1.0 - clampf(accuracy, 0.0, 1.0)
		# Landing error: undershoot/overshoot plus a little lateral error, both
		# proportional to the distance travelled.  High skill barely misses; low
		# skill visibly corrects afterwards.
		var scale := 1.0 + randf_range(-error * 0.6, error * 0.6)
		total_yaw *= scale
		total_pitch *= scale
		var magnitude := sqrt(total_yaw * total_yaw + total_pitch * total_pitch)
		var lateral := magnitude * error * 0.12
		total_yaw += randf_range(-1.0, 1.0) * lateral
		total_pitch += randf_range(-1.0, 1.0) * lateral * 0.8

		var deg := rad_to_deg(sqrt(total_yaw * total_yaw + total_pitch * total_pitch))
		var duration := clampf(
			BotController.LOOK_FLICK_BASE_TIME
				+ BotController.LOOK_FLICK_LOG_TIME * log(1.0 + deg / 3.0),
			BotController.LOOK_FLICK_MIN_TIME,
			BotController.LOOK_FLICK_MAX_TIME
		)
		# Low accuracy flicks are slower as well as less accurate: a beginner
		# moves the mouse late and short, then corrects; a good player snaps.
		duration *= lerpf(1.45, 0.82, accuracy) / maxf(mouse_speed, 0.4)
		if correction:
			duration *= 0.6
		# Vertical movement is slower and less accurate than horizontal.
		if absf(total_pitch) > absf(total_yaw):
			duration *= 1.2

		_flick_start_yaw = start_yaw
		_flick_start_pitch = start_pitch
		_flick_total_yaw = total_yaw
		_flick_total_pitch = total_pitch
		_flick_duration = duration
		_flick_timer = 0.0
		_flick_correction = correction
		_mode = Mode.CORRECT if correction else Mode.FLICK
		if correction:
			_corrections_left = maxi(_corrections_left - 1, 0)
		else:
			# Fewer, tighter corrections at high accuracy: 3 at the bottom, 1 at
			# the top.  This is the visible "settling" phase after the flick.
			_corrections_left = maxi(1, int(round(lerpf(3.0, 1.0, accuracy))))

	func _tick_ballistic(delta: float, _target_yaw: float, _target_pitch: float) -> void:
		_flick_timer += delta
		var t := clampf(_flick_timer / maxf(_flick_duration, 0.001), 0.0, 1.0)
		# Bell-shaped velocity: 1 - cos(2*pi*t), whose integral over [0,1] is 1.
		var progress := t - sin(TAU * t) / TAU
		var want_yaw := _flick_start_yaw + _flick_total_yaw * progress
		var want_pitch := _flick_start_pitch + _flick_total_pitch * progress
		var body: Node3D = bot.player.body
		_move_angles(
			wrapf(want_yaw - body.rotation.y, -PI, PI),
			want_pitch - bot._head_node.rotation.x
		)
		if t >= 1.0:
			_track_vel_yaw = 0.0
			_track_vel_pitch = 0.0
			_mode = Mode.TRACK
			if _corrections_left > 0:
				_correction_timer = randf_range(0.02, 0.08)

	func _tick_tracking(delta: float, target_yaw: float, target_pitch: float,
			err_yaw: float, err_pitch: float) -> void:
		var style: BotController.Style = bot._style
		var lag := 0.12
		var mouse_speed := 0.8
		var tracking_speed := 0.6
		if style != null:
			lag = maxf(style.tracking_lag, 0.02)
			mouse_speed = style.mouse_speed
			tracking_speed = style.tracking_speed
		if _has_prev and delta > 0.000001:
			var raw_yaw := wrapf(target_yaw - _prev_desired_yaw, -PI, PI) / delta
			var raw_pitch := wrapf(target_pitch - _prev_desired_pitch, -PI, PI) / delta
			var alpha := clampf(delta / lag, 0.0, 1.0)
			_target_vel_yaw = lerpf(_target_vel_yaw, raw_yaw, alpha)
			_target_vel_pitch = lerpf(_target_vel_pitch, raw_pitch, alpha)
		var max_speed := BotController.LOOK_TRACK_MAX_SPEED * maxf(mouse_speed, 0.3)
		# The pursuit gain is the tracking trait, not raw skill.  A low-tracking
		# bot answers a strafe late and only partially catches up before the
		# target reverses again.
		var gain := BotController.LOOK_TRACK_GAIN * lerpf(0.55, 1.0, tracking_speed)
		var want_yaw := _target_vel_yaw + clampf(err_yaw * gain, -max_speed, max_speed)
		var want_pitch := _target_vel_pitch \
			+ clampf(err_pitch * gain * 0.8, -max_speed * 0.8, max_speed * 0.8)
		var accel := BotController.LOOK_TRACK_ACCEL \
			* lerpf(0.35, 1.0, tracking_speed)
		_track_vel_yaw = move_toward(_track_vel_yaw, want_yaw, accel * delta)
		_track_vel_pitch = move_toward(_track_vel_pitch, want_pitch, accel * delta)
		_track_vel_yaw = clampf(_track_vel_yaw, -max_speed, max_speed)
		_track_vel_pitch = clampf(_track_vel_pitch, -max_speed * 0.8, max_speed * 0.8)
		_move_angles(_track_vel_yaw * delta, _track_vel_pitch * delta)

	func _remember_desired(target_yaw: float, target_pitch: float) -> void:
		_prev_desired_yaw = target_yaw
		_prev_desired_pitch = target_pitch
		_has_prev = true

	## Convert an angular delta to integer mouse counts, carry the remainder, and
	## apply it through Body._apply_mouse_look — the same path a human mouse uses,
	## including its pitch clamp.  Never writes body/head rotation directly.
	func _move_angles(delta_yaw: float, delta_pitch: float) -> void:
		var body: Node3D = bot.player.body
		var sens_x := 0.002
		var sens_y := 0.002
		var raw_x: Variant = body.get("mouse_sens_x")
		var raw_y: Variant = body.get("mouse_sens_y")
		if raw_x != null:
			sens_x = maxf(float(raw_x), 0.00001)
		if raw_y != null:
			sens_y = maxf(float(raw_y), 0.00001)
		_residual_x += -delta_yaw / sens_x
		_residual_y += -delta_pitch / sens_y
		var dx := roundf(_residual_x / BotController.MOUSE_COUNT_STEP) \
			* BotController.MOUSE_COUNT_STEP
		var dy := roundf(_residual_y / BotController.MOUSE_COUNT_STEP) \
			* BotController.MOUSE_COUNT_STEP
		if absf(dx) < 0.5 and absf(dy) < 0.5:
			return
		_residual_x -= dx
		_residual_y -= dy
		_last_dx = dx
		_last_dy = dy
		_event.relative = Vector2(dx, dy)
		body.call("_apply_mouse_look", _event)

	func current_aim_error_to(point: Vector3) -> float:
		var head := bot._head_node.global_position
		var to_aim := point - head
		if to_aim.length_squared() < 0.000001:
			return 0.0
		var forward := -bot._head_node.global_transform.basis.z
		return rad_to_deg(forward.angle_to(to_aim.normalized()))

	func cancel() -> void:
		_has_request = false
		_provider = null
		_priority = 0
		_request_ttl = 0.0
		_reaction_timer = 0.0
		_mode = Mode.IDLE
		_flick_timer = 0.0
		_correction_timer = 0.0
		_corrections_left = 0
		_track_vel_yaw = 0.0
		_track_vel_pitch = 0.0
		_target_vel_yaw = 0.0
		_target_vel_pitch = 0.0
		_has_prev = false
		_residual_x = 0.0
		_residual_y = 0.0
		_last_dx = 0.0
		_last_dy = 0.0

	func get_state_text() -> String:
		var names: Array[String] = ["idle", "travel", "flick", "track", "corr"]
		return names[int(_mode)]

	func get_delta_text() -> String:
		return "%.0f,%.0f" % [_last_dx, _last_dy]


## Reload / weapon-switch button emulator.  Both actions are preceded by a
## human reaction delay; the WeaponController's real state machine still owns
## reload time and equip time.
class Buttons extends RefCounted:
	var bot: BotController
	var _reload_timer: float = -1.0
	var _switch_timer: float = -1.0
	var _switch_index: int = -1

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot

	func request_reload() -> bool:
		if _reload_timer >= 0.0 or _switch_timer >= 0.0:
			return false
		var wc: WeaponController = bot.player.weapon_controller
		if wc == null or not is_instance_valid(wc) or wc._is_reloading or wc.is_switching():
			return false
		var weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if weapon == null or weapon.has_infinite_ammo:
			return false
		if weapon.mag_current >= weapon.mag_size:
			return false
		_reload_timer = _reaction_delay(
			BotController.RELOAD_REACTION_MIN, BotController.RELOAD_REACTION_MAX
		)
		return true

	func request_switch(index: int) -> bool:
		var wc: WeaponController = bot.player.weapon_controller
		if wc == null or not is_instance_valid(wc) or not wc._is_ready():
			return false
		if index < 0 or index >= wc._weapons.size():
			return false
		if index == wc.current_weapon_index or wc.is_switching():
			return false
		if _switch_timer >= 0.0:
			return false
		_switch_index = index
		_switch_timer = _reaction_delay(
			BotController.SWITCH_REACTION_MIN, BotController.SWITCH_REACTION_MAX
		)
		return true

	func tick(delta: float) -> void:
		var wc: WeaponController = bot.player.weapon_controller
		if wc == null or not is_instance_valid(wc):
			cancel()
			return
		if _switch_timer >= 0.0:
			_switch_timer -= delta
			if _switch_timer <= 0.0:
				var index := _switch_index
				_switch_index = -1
				_switch_timer = -1.0
				if wc._is_ready() and not wc.is_switching() \
						and index >= 0 and index < wc._weapons.size() \
						and index != wc.current_weapon_index:
					wc.current_weapon_index = index
		if _reload_timer >= 0.0:
			_reload_timer -= delta
			if _reload_timer <= 0.0:
				_reload_timer = -1.0
				var weapon: Weapon = wc._weapons[wc.current_weapon_index]
				if wc._is_ready() and not wc._is_reloading and not wc.is_switching() \
						and weapon != null and not weapon.has_infinite_ammo \
						and weapon.mag_current < weapon.mag_size:
					wc.start_reload()

	func is_switch_pending() -> bool:
		return _switch_timer >= 0.0

	func pending_index() -> int:
		return _switch_index

	func cancel() -> void:
		_reload_timer = -1.0
		_switch_timer = -1.0
		_switch_index = -1

	func _reaction_delay(minimum: float, maximum: float) -> float:
		var skill_trait := bot.skill
		if bot._style != null:
			skill_trait = bot._style.accuracy
		return lerpf(maximum, minimum, clampf(skill_trait, 0.0, 1.0)) \
			* randf_range(0.7, 1.3)


## One step of a maneuver: a scripted, interruptible timeline of key/mouse/fire
## verbs.  Stage 4 selects maneuvers; this only executes them.
class ManeuverStep extends RefCounted:
	enum Kind {
		MOVE_KEYS, MOVE_WORLD, KEY_TAP, KEY_HOLD,
		LOOK_POINT, LOOK_DIRECTION, WAIT, FIRE,
	}

	var kind: Kind = Kind.WAIT
	var duration_min: float = 0.1
	var duration_max: float = 0.2
	var forward: int = 0
	var strafe: int = 0
	var world_dir: Vector2 = Vector2.ZERO
	var key_name: StringName = &""
	var look_point: Vector3 = Vector3.ZERO
	var look_direction: Vector3 = Vector3.ZERO
	var look_priority: int = int(BotController.LookPriority.TRAVEL_LOOKAHEAD)
	var fire_index: int = -1
	var condition: Callable = Callable()

	func _init(kind_value: Kind) -> void:
		kind = kind_value


## Executes a maneuver step by step with randomized durations.  Aborts when a
## higher-priority maneuver or an external event (target, damage, stun) calls
## abort(); the next decision tick then chooses again.
class ManeuverRunner extends RefCounted:
	var bot: BotController
	var _steps: Array[BotController.ManeuverStep] = []
	var _index: int = -1
	var _timer: float = 0.0
	var _priority: int = 0
	var _running: bool = false
	var _was_fire: bool = false

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot

	func start(steps: Array[BotController.ManeuverStep], priority: int) -> bool:
		if _running and priority < _priority:
			return false
		if steps.is_empty():
			abort()
			return false
		_steps = steps
		_index = -1
		_priority = priority
		_running = true
		_advance()
		return true

	func abort() -> void:
		if _was_fire and bot._trigger != null:
			bot._trigger.release_all()
		_was_fire = false
		_running = false
		_steps.clear()
		_index = -1
		_timer = 0.0

	func is_running() -> bool:
		return _running

	func tick(delta: float) -> void:
		if not _running:
			return
		_timer -= delta
		if _timer > 0.0:
			return
		_advance()

	func _advance() -> void:
		if _was_fire and bot._trigger != null:
			bot._trigger.release_all()
		_was_fire = false
		_index += 1
		if _index >= _steps.size():
			_running = false
			_steps.clear()
			return
		var step: BotController.ManeuverStep = _steps[_index]
		if step.condition.is_valid() and not bool(step.condition.call()):
			abort()
			return
		_timer = maxf(0.02, randf_range(step.duration_min, step.duration_max))
		match step.kind:
			BotController.ManeuverStep.Kind.MOVE_KEYS:
				bot._keyboard.set_move(step.forward, step.strafe)
			BotController.ManeuverStep.Kind.MOVE_WORLD:
				bot._keyboard.set_move_world(step.world_dir)
			BotController.ManeuverStep.Kind.KEY_TAP:
				bot._keyboard.tap(step.key_name, _timer)
			BotController.ManeuverStep.Kind.KEY_HOLD:
				bot._keyboard.hold(step.key_name)
			BotController.ManeuverStep.Kind.LOOK_POINT:
				bot._mouse.request_look_at_point(
					step.look_point, step.look_priority, 0.8
				)
			BotController.ManeuverStep.Kind.LOOK_DIRECTION:
				bot._mouse.request_look_direction(
					step.look_direction, step.look_priority, 0.8
				)
			BotController.ManeuverStep.Kind.FIRE:
				bot._trigger.request_fire(step.fire_index, true)
				_was_fire = true
			BotController.ManeuverStep.Kind.WAIT:
				pass


## Sole owner of the three fire flags.  The rest of the controller only states
## intent via request_fire(); this class decides WHEN to press and release, at
## physics rate.
##
## Why a state machine: the old code cleared the flags on every 20 Hz think tick
## and relied on a 2 s pulse, so a semi-auto was released ~50 ms after pressing
## and could not fire again for ~2.15 s.  A single owner also guarantees no
## other system can clear a press mid-tap, and gives charged/semi/automatic
## weapons their own cadence instead of one shared pulse.
class Trigger extends RefCounted:
	enum State { IDLE, PRESSING, WAITING, CHARGING }

	var bot: BotController
	var _state: State = State.IDLE
	var _wants_fire: bool = false
	var _fire_index: int = -1
	## Explosion jump: bypass the aim gate (full aim->fire->jump sequencing is
	## Stage 5).  Still respects weapon readiness.
	var _force: bool = false
	var _press_frames: int = 0
	var _wait_timer: float = 0.0
	var _aim_delay_timer: float = 0.0
	var _gate_was_open: bool = false
	var _charge_threshold: float = 1.0
	var _charge_armed: bool = false
	var _charged_hold: float = 0.0

	## Special SIGNAL sequence (mine/remote detonation, or redirect).  Armed by
	## the shot, then fires the SIGNAL mode once the sequencer decides it is
	## sensible.  Kept separate from the main state machine so a signal press
	## cannot stomp a press/draw in progress.
	var _special_pending: bool = false
	var _special_elapsed: float = 0.0
	var _special_timer: float = 0.0
	var _special_scan_timer: float = 0.0
	var _signal_active: bool = false
	var _signal_press_frames: int = 0

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot

	func request_fire(index: int, wants_fire: bool, force: bool = false) -> void:
		if not wants_fire:
			release_all()
			return
		if index != _fire_index and _state == State.PRESSING:
			# A different mode mid-tap: end the tap cleanly before starting the
			# new one, rather than inheriting the old press's latch.
			release_all()
		_fire_index = index
		_wants_fire = true
		_force = force

	## Clear the flags and reset the machine.  A live charge draw is CANCELLED
	## (not released): dropping the flag is what fires a charged weapon, so a
	## target loss or stun must not loose the arrow.
	func release_all() -> void:
		var wc: WeaponController = bot.player.weapon_controller
		if wc != null and is_instance_valid(wc) and wc.is_charging_weapon():
			wc._cancel_charge_synced.rpc()
		_release_flags()
		_state = State.IDLE
		_wants_fire = false
		_fire_index = -1
		_force = false
		_press_frames = 0
		_wait_timer = 0.0
		_aim_delay_timer = 0.0
		_gate_was_open = false
		_charge_armed = false
		_charged_hold = 0.0
		_special_pending = false
		_special_elapsed = 0.0
		_special_timer = 0.0
		_special_scan_timer = 0.0
		_signal_active = false
		_signal_press_frames = 0

	func tick(delta: float) -> void:
		if not _wants_fire or _fire_index < 0:
			_release_flags()
			_state = State.IDLE
			_aim_delay_timer = 0.0
			_gate_was_open = false
			return

		var wc: WeaponController = bot.player.weapon_controller
		if wc == null or not is_instance_valid(wc) or not wc._is_ready():
			release_all()
			return
		var weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if weapon == null or _fire_index >= weapon.weapon_fires.size():
			release_all()
			return
		var fire: WeaponFire = weapon.weapon_fires[_fire_index]
		if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
			release_all()
			return
		if not wc.weapon_has_infinite_ammo(weapon) \
				and weapon.mag_current < wc._get_fire_ammo_cost(weapon, _fire_index):
			release_all()
			return

		# The intent can outlive a switch/reload/death.  Never hold a trigger the
		# weapon could not act on.
		if wc.is_switching() or wc._is_reloading or not bot.player.spawned \
				or wc._fire_is_blocked() or wc._ability_fire_interrupt:
			_release_flags()
			_state = State.IDLE
			return
		if bot.player.is_charging() or bot.player.is_bashing():
			_release_flags()
			_state = State.IDLE
			return
		if bot.player.ability_manager != null and bot.player.ability_manager.is_equipped():
			_release_flags()
			_state = State.IDLE
			return

		var aim_open := _aim_gate_open(weapon, fire)
		if aim_open and not _gate_was_open:
			var accuracy := bot._style.accuracy if bot._style != null else bot.skill
			_aim_delay_timer = lerpf(
				BotController.TRIGGER_DELAY_MAX,
				BotController.TRIGGER_DELAY_MIN,
				accuracy
			) * randf_range(0.7, 1.3)
		if not aim_open:
			_aim_delay_timer = 0.0
		_gate_was_open = aim_open
		if _aim_delay_timer > 0.0:
			_aim_delay_timer = maxf(_aim_delay_timer - delta, 0.0)

		# A signal-driven weapon fires one projectile per cycle, even when its
		# fire mode is marked automatic (mine layer, redirectable rockets): the
		# point is to place one and then decide when to signal it.
		var special_main := bot._signal_mode == BotController.SignalMode.EXPLODE \
			or bot._signal_mode == BotController.SignalMode.REDIRECT
		if weapon.charged:
			_tick_charged(delta, wc, weapon, fire, aim_open)
		elif fire.automatic and not special_main:
			_tick_automatic(wc, fire, aim_open)
		else:
			_tick_semi(delta, wc, fire, aim_open)
		_tick_signal(delta, aim_open)

	## Automatic weapons hold through their own cooldown and fire cycle: that is
	## the rate.  The gate still releases while the bot is not actually aimed.
	func _tick_automatic(wc: WeaponController, _fire: WeaponFire, aim_open: bool) -> void:
		if (not aim_open and not _force) or _aim_delay_timer > 0.0:
			_release_flags()
			_state = State.IDLE
			return
		_press(_fire_index)
		_state = State.PRESSING

	## Semi-auto: a guaranteed-length tap, then a gap of the weapon's real
	## cooldown plus a skill-scaled human pause.  The gap is what lets the
	## controller's `_fired_this_press` latch clear (it needs a false read).
	func _tick_semi(delta: float, wc: WeaponController, fire: WeaponFire, aim_open: bool) -> void:
		match _state:
			State.PRESSING:
				_press(_fire_index)
				_press_frames -= 1
				if _press_frames <= 0:
					_release_flags()
					_state = State.WAITING
					_begin_special()
					_wait_timer = maxf(wc._fire_cooldown, 0.0) + _skill_gap()
			State.WAITING:
				_wait_timer -= delta
				if _wait_timer <= 0.0:
					_state = State.IDLE
			_:
				if (not aim_open and not _force) or _aim_delay_timer > 0.0:
					return
				if not _ready_to_start(wc, fire):
					return
				_press(_fire_index)
				_state = State.PRESSING
				_press_frames = _tap_frames()
				if fire.hold_required_for_pre_shoot_delay:
					# Releasing before the pre-shoot delay elapses cancels the
					# shot (Derringer).  Keep the flag down long enough for it.
					_press_frames = maxi(
						_press_frames,
						int(ceil((fire.pre_shoot_delay + 2.0 / 90.0) * 90.0))
					)

	## Charged: hold to draw, then release one frame — the release IS the shot.
	func _tick_charged(delta: float, wc: WeaponController, weapon: Weapon,
			fire: WeaponFire, aim_open: bool) -> void:
		match _state:
			State.WAITING:
				_wait_timer -= delta
				if _wait_timer <= 0.0:
					_state = State.IDLE
			State.CHARGING:
				if not wc.is_charging_weapon():
					# The draw ended elsewhere (reload/switch); start over.
					_state = State.IDLE
					return
				_press(_fire_index)
				if not _charge_armed:
					var ratio := wc.get_charge_ratio_for(weapon)
					if ratio >= _charge_threshold:
						_charge_armed = true
						var accuracy := bot._style.accuracy if bot._style != null else bot.skill
						_charged_hold = lerpf(
							BotController.CHARGE_OVERHOLD_MAX, 0.0, accuracy
						) * randf_range(0.0, 1.0)
					return
				# At full draw: wait for the gate, then for the small overhold.
				if (not aim_open and not _force) or _aim_delay_timer > 0.0:
					return
				_charged_hold -= delta
				if _charged_hold > 0.0:
					return
				_release_flags()
				_state = State.WAITING
				_begin_special()
				_wait_timer = _semi_gap(wc)
			_:
				if not _ready_to_start(wc, fire):
					return
				if not aim_open and not _force:
					return
				_press(_fire_index)
				_state = State.CHARGING
				_charge_armed = false
				_charged_hold = 0.0
				# Never above 1.0: get_charge_ratio_for() clamps at 1.0, so a
				# threshold of 1.001 would leave the bot charging forever.
				var accuracy := bot._style.accuracy if bot._style != null else bot.skill
				_charge_threshold = minf(
					lerpf(BotController.CHARGE_RELEASE_MIN, 1.0, accuracy)
						+ randf_range(0.0, 0.02),
					1.0
				)

	## Arm the SIGNAL sequence after a shot that has one.  No-op for weapons
	## without a signal or with a handler we do not understand.
	func _begin_special() -> void:
		if bot._signal_mode != BotController.SignalMode.EXPLODE \
				and bot._signal_mode != BotController.SignalMode.REDIRECT:
			return
		_special_pending = true
		_special_elapsed = 0.0
		_special_scan_timer = 0.0
		if bot._signal_mode == BotController.SignalMode.EXPLODE:
			_special_timer = lerpf(
				BotController.SIGNAL_ARM_DELAY_MAX,
				BotController.SIGNAL_ARM_DELAY_MIN,
				bot.skill
			) * randf_range(0.85, 1.25)
		else:
			_special_timer = lerpf(
				BotController.REDIRECT_DELAY_MAX,
				BotController.REDIRECT_DELAY_MIN,
				bot.skill
			) * randf_range(0.8, 1.2)

	## Drive the SIGNAL press.  It never overlaps a main press/draw; by the time
	## a shot has armed the sequence the main state is WAITING or IDLE.
	func _tick_signal(delta: float, aim_open: bool) -> void:
		if not _special_pending and not _signal_active:
			return
		if bot._signal_index < 0:
			_special_pending = false
			_signal_active = false
			return

		if _signal_active:
			# The SIGNAL action is edge-triggered; hold long enough to be
			# sampled, then release so the next cycle can fire it again.
			_press(bot._signal_index)
			_signal_press_frames -= 1
			if _signal_press_frames <= 0:
				_release_flags()
				_signal_active = false
				_special_pending = false
			return

		if _state == State.PRESSING or _state == State.CHARGING:
			return

		_special_elapsed += delta
		if _special_elapsed < _special_timer:
			return

		# The projectile-parent scan is the expensive part; throttle it.
		_special_scan_timer -= delta
		if _special_scan_timer > 0.0:
			return
		_special_scan_timer = BotController.SPECIAL_SCAN_INTERVAL

		if bot._signal_mode == BotController.SignalMode.EXPLODE:
			if not bot._has_live_own_projectile():
				_special_pending = false
				return
			if not bot._own_projectile_near_target(bot._signal_blast_radius):
				# Keep it armed while the target is elsewhere, but detonate
				# after the hold limit so a missed placement is not left behind.
				if _special_elapsed < BotController.SIGNAL_MAX_HOLD:
					return
			_signal_active = true
			_signal_press_frames = maxi(
				BotController.SIGNAL_PRESS_FRAMES, _tap_frames()
			)
		elif bot._signal_mode == BotController.SignalMode.REDIRECT:
			if not bot._has_live_own_projectile():
				_special_pending = false
				return
			if not aim_open:
				return
			_signal_active = true
			_signal_press_frames = maxi(
				BotController.SIGNAL_PRESS_FRAMES, _tap_frames()
			)
		else:
			_special_pending = false

	func _ready_to_start(wc: WeaponController, fire: WeaponFire) -> bool:
		if _special_pending:
			# Don't place a second mine/rocket while the first is still waiting
			# to be detonated or redirected.  The SIGNAL press is a different
			# fire slot and is not blocked by this.
			return false
		if not bot.player.spawned or not wc._is_ready():
			return false
		if wc.is_switching() or wc._is_reloading or wc._pending_fire or wc._is_firing:
			return false
		if wc._fire_cooldown > 0.0 or wc._fire_is_blocked() or wc._ability_fire_interrupt:
			return false
		if bot.player.is_charging() or bot.player.is_bashing():
			return false
		if bot.player.ability_manager != null and bot.player.ability_manager.is_equipped():
			return false
		var weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if weapon == null:
			return false
		if not wc.weapon_has_infinite_ammo(weapon):
			if weapon.mag_current < wc._get_fire_ammo_cost(weapon, _fire_index):
				return false
		# A pre-shoot-delay shot with no hold requirement fires after the delay
		# even if released; no extra handling is needed here.
		return true

	func _aim_gate_open(weapon: Weapon, fire: WeaponFire) -> bool:
		if _force:
			return true
		if not bot._has_desired_aim or bot.aim_error_deg < 0.0:
			return false
		return bot.aim_error_deg <= bot.aim_tolerance_for(weapon, fire)

	func _skill_gap() -> float:
		var accuracy := bot._style.accuracy if bot._style != null else bot.skill
		return lerpf(
			BotController.SEMI_GAP_MAX, BotController.SEMI_GAP_MIN, accuracy
		) * randf_range(0.7, 1.4)

	## Human click length, in physics frames.  Always at least the 3-frame
	## guaranteed-sampled press; the style's 40-100 ms click is used when longer.
	func _tap_frames() -> int:
		var duration := BotController.FIRE_TAP_MIN
		var style: BotController.Style = bot._style
		if style != null:
			duration = randf_range(style.fire_tap_min, style.fire_tap_max)
		return maxi(BotController.SEMI_PRESS_FRAMES, int(ceil(duration * 90.0)))

	## Semi-auto gap: the weapon's real cooldown, a skill-scaled human pause, and
	## the bot's own click-rate cap (6-9 Hz).
	func _semi_gap(wc: WeaponController) -> float:
		var gap := maxf(wc._fire_cooldown, 0.0) + _skill_gap()
		var style: BotController.Style = bot._style
		if style != null:
			gap = maxf(gap, 1.0 / maxf(style.fire_click_hz, 0.1))
		return gap

	func _press(index: int) -> void:
		var input: PlayerInput = bot.player.player_input
		input.primary_fire_held = index == 0
		input.secondary_fire_held = index == 1
		input.tertiary_fire_held = index == 2

	func _release_flags() -> void:
		var input: PlayerInput = bot.player.player_input
		input.primary_fire_held = false
		input.secondary_fire_held = false
		input.tertiary_fire_held = false

	func get_state_text() -> String:
		var names: Array[String] = ["idle", "press", "wait", "charge"]
		var parts := PackedStringArray()
		parts.append(names[int(_state)])
		if _force:
			parts.append("force")
		if _fire_index >= 0:
			parts.append("idx=%d" % _fire_index)
		if _wait_timer > 0.0:
			parts.append("wait=%.2f" % _wait_timer)
		if _aim_delay_timer > 0.0:
			parts.append("aimdelay=%.2f" % _aim_delay_timer)
		if _signal_active:
			parts.append("SIGNAL")
		elif _special_pending:
			parts.append("armed=%.2f" % _special_elapsed)
		return " ".join(parts)
