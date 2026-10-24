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
##   the feet.  Sticky signal mines aim at mid-body.  Point-blank with a
##   self-damaging explosive now switches to the first safe sidearm instead of
##   standing still aiming at the ground.
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
##   RETREAT_COVER / STUCK_RECOVER.  It considers at 4 Hz, every state has a
##   minimum duration, and new targets, damage, and traversal recovery use
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
##   waits, peeks/fires, ducks back, and times out/falls back after 6 s or when no
##   cover exists.
##   SEARCH goes to the last-seen point then along remembered velocity, with
##   glances at side corridors/last threat.  Damage awareness records the source,
##   estimated direction, forces a strafe change, turns with a skill-scaled
##   REACT_DAMAGE look, and can enter SEARCH or RETREAT_COVER.
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
## OPEN QUESTIONS / HAZARDS FOR LATER STAGES
## - `_get_proj_info().heals_allies` is accurate (positive `health_delta` +
##   `can_hit_other_teamates`): Syringe Gun and Medpack Launcher only.
## - Projectile lead currently uses `flat_dist / speed` with no gravity; arcs
##   (arrow, grenade, rocket with gravity_scale) need an iterative solve.
## - The `_get_engagement_range` probes are dead (no range property).  Real
##   numbers must come from `hitscan_range` (hitscan) or projectile speed x
##   lifetime / engagement preference (projectile).
## - Bots never cast abilities, and `AbilityManager.is_equipped()` is false for
##   them; only input-driven movement tech (dash/jump) is currently usable.
## ============================================================================

## Raycast-based bot AI.  No navmesh required — bots probe the world
## around them with raycasts and steer toward the clearest path.
## Also seeks objectives (control points, payload) when no enemy is visible.
## Works on any map geometry automatically.
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

## Draws a live state label above this bot (action, target, fire mode, trigger
## flags, aim error, weapon/ammo) plus the steering rays it just cast.  Server
## side only, like the rest of the AI.  While false this creates no nodes and
## does no per-frame work: every debug entry point is gated on this flag.
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

## Cache of projectile-scene introspection: resource_path -> {
##   "speed": float, "speed_source": String, "heals_allies": bool,
##   "is_explosive": bool }.  `speed_source` names the property the value came
##   from, for the one-shot introspection log.
## Avoids instantiating a projectile every think just to read its HitboxComponent.
var _proj_cache: Dictionary = {}


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

	_fov_dot_threshold = cos(deg_to_rad(FOV_DEGREES * 0.5))

	_style = Style.new()
	_style.draw(skill)
	_keyboard = Keyboard.new(self)
	_mouse = Mouse.new(self)
	_buttons = Buttons.new(self)
	_maneuvers = ManeuverRunner.new(self)
	_traversal = Traversal.new(self)
	_decision = Decision.new(self)
	_trigger = Trigger.new(self)
	_los_exclude_rids.clear()
	_los_exclude_rids.append(player.get_rid())
	_los_query.exclude = _los_exclude_rids

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
## Bots only detect enemies within this horizontal field-of-view cone (degrees),
## centred on their facing direction.  Matches a human's ~120° peripheral vision.
const FOV_DEGREES: float = 120.0
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
const KEY_REACTION_MAX: float = 0.25
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
## Path to the target's head bone — the `Physical Bone DEF-spine_006` hurtbox with
## `is_head = true` in player.tscn.  Bots aim at this bone's live world position
## rather than a fixed height, so headshots track the model's actual head.
const HEAD_BONE_PATH: String = "Body/Mannequin/mannequin/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-spine_006"
const NOISE_INTERVAL: float       = 0.4
## Max aim spread (radians) at skill 0; scaled to 0 at skill 1.
const AIM_NOISE_MAX: float        = 0.2
## Max projectile-lead time so prediction never overshoots on slow projectiles.
const LEAD_TIME_MAX: float        = 0.6

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
const SEARCH_DURATION: float = 5.0
const TARGET_LOST_GRACE: float = 0.35
const RECOGNITION_TIME_MIN: float = 0.08
const RECOGNITION_TIME_MAX: float = 0.55
const TARGET_SWITCH_MARGIN: float = 0.35
const TARGET_STICKINESS: float = 0.85
const COVER_HEALTH_THRESHOLD: float = 0.42
const COMBAT_STRAFE_SHOT_MIN: int = 3
const COMBAT_STRAFE_SHOT_MAX: int = 6
const COMBAT_JUMP_MIN_INTERVAL: float = 1.8
const COMBAT_CROUCH_MIN_INTERVAL: float = 3.0

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

# Reaction time
## Worst-case delay (skill 0) before a bot pulls the trigger on a target it
## *just* acquired. Aiming/steering start immediately; only firing is gated,
## so it reads as "noticing and raising the gun" rather than "went blind".
const REACTION_TIME_MAX: float = 0.4

# Explosion jumping
const EXPLOSION_JUMP_COOLDOWN: float  = 4.0
## Only worth rocket-jumping if there's actually meaningful ground to cover.
const EXPLOSION_JUMP_MIN_GAP: float   = 6.0

# Debug overlay.  All of this is inert unless `debug_draw` is true.
## How often the label text and steering-ray mesh are rebuilt.  The AI thinks at
## 20 Hz; redrawing at that rate would just churn strings for nothing.
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

# Duck-typed property name lists.  These are the candidate names the original
# ad-hoc `.get("...")` chains probed.  Kept identical so this stage does not
# change behaviour; Stage 1 replaces the guesses with the verified fields.
const PROP_FIRE_LAUNCH_SPEED: Array[String] = ["projectile_speed", "speed"]
const PROP_PROJECTILE_LAUNCH_SPEED: Array[String] = ["speed", "projectile_speed"]
const PROP_LINEAR_VELOCITY: Array[String] = ["linear_velocity"]
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
var _last_seen_velocity: Vector3 = Vector3.ZERO
var _target_lost_timer: float = 0.0
var _search_timer: float = 0.0
var _search_active: bool = false
var _search_origin: Vector3 = Vector3.INF
var _glance_timer: float = 0.0

## Combat movement is event-driven, not a 1.5 s dice roll.
var _strafe_force_change: bool = false
var _strafe_reason: String = ""
var _shots_since_strafe: int = 0
var _last_mag_for_strafe: int = -1
var _combat_jump_timer: float = 0.0
var _combat_crouch_timer: float = 0.0

## Cover/peek state shared by Decision and _act_retreat_cover.
var _cover_position: Vector3 = Vector3.INF
var _cover_threat_pos: Vector3 = Vector3.INF
var _cover_phase: int = 0
var _cover_timer: float = 0.0
var _cover_total_timer: float = 0.0
var _cover_cooldown: float = 0.0
var _cover_peek_side: float = 1.0
var _cover_rounds: int = 0

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

## Seconds since an enemy was last visible or within SAFE_TOP_OFF_RADIUS.
## Drives the out-of-combat "heal to full" threshold only.
var _safe_top_off_timer: float = 0.0
## Set by the target rescan when a living enemy is within that radius.
var _enemy_nearby: bool = false

var _retarget_timer: float        = 0.0
var _weapon_switch_guard: float   = 0.0
var _fov_dot_threshold: float     = 0.5  # cos(FOV_DEGREES / 2), set in _ready

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

	# Dev-menu "freeze all bots": park them exactly like a stun.  Going through
	# the emulators keeps them the only writers of input/facing state.
	if GameManager.dev_freeze_bots:
		_keyboard.release_all()
		_trigger.release_all()
		_mouse.cancel()
		_maneuvers.abort()
		_abort_explosion_jump()
		_has_desired_aim = false
		if debug_draw:
			_debug_tick(delta)
		return

	# Stunned, pinned, or mid-channel bots cannot move, aim, or fire.
	if player.status_effect_manager and (player.status_effect_manager.is_stunned() or player.status_effect_manager.is_pinned() or player.status_effect_manager.is_action_blocked()):
		_keyboard.release_all()
		_trigger.release_all()
		_mouse.cancel()
		_maneuvers.abort()
		_abort_explosion_jump()
		_has_desired_aim = false
		if debug_draw:
			_debug_tick(delta)
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
		_react_to_damage(ac)
	_last_health = health_now

	if _reaction_timer > 0.0:
		_reaction_timer = maxf(_reaction_timer - delta, 0.0)
	if _explosion_jump_cooldown_timer > 0.0:
		_explosion_jump_cooldown_timer = maxf(_explosion_jump_cooldown_timer - delta, 0.0)
	if _cover_cooldown > 0.0:
		_cover_cooldown = maxf(_cover_cooldown - delta, 0.0)

	# Safe-top-off clock: reset as long as an enemy is visible or nearby.
	if _current_target != null or _enemy_nearby:
		_safe_top_off_timer = 0.0
	else:
		_safe_top_off_timer = minf(_safe_top_off_timer + delta, SAFE_TOP_OFF_DELAY)

	if debug_draw:
		_debug_tick(delta)

	if _weapon_switch_guard > 0.0:
		_weapon_switch_guard -= delta

	_timer += delta
	if _timer < PROCESS_INTERVAL:
		return
	_timer = 0.0

	_tick_strafe()
	_tick_preferred_distance()

	_think()
	_decision.update(PROCESS_INTERVAL)
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
		if _wall_hug_timer <= 0.0:
			_wall_hug_side = 1 if randf() > 0.5 else -1
			_wall_hug_timer = 3.0
		_wall_hug_timer -= PROCESS_INTERVAL
		var hug_dir := flat_desired.rotated(deg_to_rad(70.0 * _wall_hug_side))
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

# Strafing

func _tick_strafe() -> void:
	_strafe_timer -= PROCESS_INTERVAL
	var forced := _strafe_force_change
	if _strafe_timer > 0.0 and not forced:
		return
	_strafe_force_change = false

	var style: Style = _style
	if style == null:
		_strafe_timer = STRAFE_CHANGE_INTERVAL
		_strafe_dir = float([-1, 0, 1][randi() % 3])
		return

	var spread := clampf(style.strafe_hold_spread, 0.0, 0.9)
	_strafe_timer = maxf(
		0.16, style.strafe_hold_median * randf_range(1.0 - spread, 1.0 + spread)
	)
	if forced:
		# A hit or a burst of shots asks for a new direction now; humans do not
		# wait out the old strafe timer after being shot.
		_strafe_timer = randf_range(0.25, 0.55)
	var old_dir := _strafe_dir
	var in_combat := _current_target != null

	# Standing still is rare and short in a fight.  Out of combat the old
	# occasional pause is harmless.
	var pause_chance := style.pause_probability * (0.25 if in_combat else 1.0)
	if not style.allow_strafe or randf() < pause_chance:
		if old_dir != 0.0:
			_keyboard.counter_strafe()
		_strafe_dir = 0.0
		_strafe_timer = randf_range(0.12, 0.28) if in_combat else _strafe_timer
		return

	# Weighted left/right with a repeat penalty and a per-bot bias.  The bias
	# makes one bot prefer right peeks and another prefer left, so same-skill
	# bots do not look like copies.
	var weights: Array[float] = [
		maxf(0.05, 1.0 - _strafe_bias),
		maxf(0.05, 1.0 + _strafe_bias),
	]
	var pick := _weighted_choice(weights, "strafe")
	var new_dir := -1.0 if pick == 0 else 1.0
	if old_dir != 0.0 and not is_equal_approx(old_dir, new_dir):
		# Change direction the way a human would: a short opposite tap stops the
		# current lateral velocity before the new key takes over.
		_keyboard.counter_strafe()
	_strafe_dir = new_dir
	_strafe_reason = "event" if forced else "timer"

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

	var attacker_name := str(ac.last_enemy_attacker)
	if attacker_name.is_empty() or attacker_name == "NONE":
		attacker_name = str(ac.last_attacker)
	if not attacker_name.is_empty() and attacker_name != "NONE":
		var attacker := GameManager.find_player(attacker_name)
		if attacker != null and is_instance_valid(attacker) and attacker.spawned \
				and attacker != player and _is_enemy_of(attacker):
			_last_damage_source_name = attacker_name
			_last_damage_position = attacker.global_position
			if _current_target == null:
				_last_seen_position = attacker.global_position
				_last_seen_velocity = attacker.velocity
				_search_active = true
				_search_timer = SEARCH_DURATION
				_search_origin = attacker.global_position
				_decision.interrupt(Decision.State.SEARCH)
			_mouse.request_look_at_point(
				_get_head_position(attacker),
				LookPriority.REACT_DAMAGE,
				1.0,
				"damage:" + attacker_name
			)
			_maybe_cover_after_damage()
			return

	var direction: Vector3 = ac.last_hit_direction
	if direction.length_squared() > 0.001:
		# last_hit_direction points attacker -> victim, so flip it to look back.
		var source_dir := -direction.normalized()
		_last_damage_position = player.global_position + source_dir * 8.0
		_mouse.request_look_direction(source_dir, LookPriority.REACT_DAMAGE, 1.0)
		if _current_target == null:
			_last_seen_position = _last_damage_position
			_last_seen_velocity = Vector3.ZERO
			_search_active = true
			_search_timer = SEARCH_DURATION
			_search_origin = _last_damage_position
			_decision.interrupt(Decision.State.SEARCH)
	_maybe_cover_after_damage()


func _maybe_cover_after_damage() -> void:
	if not ENABLE_COVER:
		return
	if _health_ratio() < COVER_HEALTH_THRESHOLD and _has_threat():
		_decision.interrupt(Decision.State.RETREAT_COVER)
	elif _current_target != null:
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
		dist = player.global_position.distance_to(_current_target.global_position)
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
	var skill_mult := lerpf(AIM_SKILL_MULT_MAX, AIM_SKILL_MULT_MIN, skill)
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
	var base := lerpf(RECOGNITION_TIME_MAX, RECOGNITION_TIME_MIN, skill)
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
	score += 0.8 * clampf(seen_time / 2.0, 0.0, 1.0)
	if str(target.name) == _last_damage_source_name and now - _last_damage_time < 5.0:
		score += 1.0
	if _style != null:
		score += _style.aggression * 0.12
	var ac := target.attribute_component
	if ac != null and ac.max_health > 0.0 and ac.health / ac.max_health < 0.4:
		score += 0.15
	return score


## Idle/travel glance.  It uses GLANCE so it briefly beats the travel look but
## never a damage reaction or combat aim.
func _tick_glance(delta: float) -> void:
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


func _think() -> void:
	_tick_glance(PROCESS_INTERVAL)
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_current_target = null
		_heal_target = null
		_refresh_los_excludes()
		_trigger.release_all()
		_has_desired_aim = false
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if debug_draw or debug_log_weapons:
		_log_weapon_once(weapon)
	var holding_heal := _weapon_heals_allies(weapon)
	var heal_index := _find_heal_weapon_index(wc)  # -1 if none in loadout

	# Target lock: between full re-scans, only re-verify the current target (one
	# LOS raycast) instead of the O(N) scan.  A human doesn't re-evaluate every
	# enemy 20x/sec, and this cuts the raycast load dramatically in big fights.
	var need_rescan := _retarget_timer <= 0.0
	if not need_rescan and not _targets_valid():
		need_rescan = true

	if not need_rescan:
		_retarget_timer -= PROCESS_INTERVAL
		if _current_target != null:
			_last_seen_position = _current_target.global_position
			_last_seen_velocity = _current_target.velocity
		return

	_retarget_timer = RETARGET_INTERVAL
	_full_scan_count += 1
	var prev_target := _current_target
	_current_target = null
	_heal_target = null

	var heal_dist_sq := HEAL_RANGE * HEAL_RANGE
	var heal_best_ratio := 2.0
	_enemy_nearby = false
	var now := float(Time.get_ticks_msec()) / 1000.0
	var visible_names: Dictionary = {}
	var best_target: Player = null
	var best_score := -INF
	var best_visible_time := 0.0

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

		if is_enemy:
			# A heal weapon can't damage enemies — skip the wasted LOS raycast.
			if holding_heal:
				continue
			# Invisible players are untargetable.
			if p.status_effect_manager and p.status_effect_manager.has_effect("invisible"):
				continue
			var name_key := str(p.name)
			var in_fov := _is_in_view_cone(p)
			# Already-acquired targets stay trackable outside the cone, but NEW
			# detections still require the FOV.
			var trackable := in_fov or p == prev_target
			var visible := trackable and _has_line_of_sight_to_player(p)
			if not visible:
				_seen_since.erase(name_key)
				continue
			if not _seen_since.has(name_key):
				# Re-acquiring the current target must not drop it for one scan.
				_seen_since[name_key] = now - (2.0 if p == prev_target else 0.0)
			var seen_time := now - float(_seen_since[name_key])
			visible_names[name_key] = true
			var dist := sqrt(dist_sq)
			var recognition := _recognition_time(p, dist, in_fov)
			if seen_time < recognition:
				continue
			var score := _score_target(p, dist, seen_time, now)
			if p == prev_target:
				score += TARGET_STICKINESS
			if score > best_score:
				best_score = score
				best_target = p
				best_visible_time = seen_time
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

	# Drop recognition clocks for anyone no longer visible.
	for key in _seen_since.keys():
		if not visible_names.has(key):
			_seen_since.erase(key)

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
			and _heal_candidate_time >= MEDIC_HEAL_PERSIST:
		var ac := _heal_target.attribute_component
		if ac != null and ac.health / ac.max_health < _medic_heal_threshold():
			if _switch_weapon(wc, heal_index):
				best_target = null  # don't fight while healing

	if _heal_target != null:
		var healing_weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if _weapon_heals_allies(healing_weapon):
			best_target = null

	# Switch cost: keep the current target unless the new one is clearly better.
	if best_target != null and prev_target != null and best_target != prev_target \
			and is_instance_valid(prev_target) and prev_target.spawned:
		var prev_score := _score_target(
			prev_target,
			player.global_position.distance_to(prev_target.global_position),
			maxf(best_visible_time, 0.5),
			now
		) + TARGET_STICKINESS
		if best_score < prev_score + TARGET_SWITCH_MARGIN:
			best_target = prev_target
			best_score = prev_score

	_current_target = best_target
	if _current_target != null:
		_search_timer = 0.0
		_search_active = false
		_target_lost_timer = 0.0
		_last_seen_position = _current_target.global_position
		_last_seen_velocity = _current_target.velocity
		if _current_target != prev_target:
			# A newly acquired/switched target outranks any scripted maneuver and
			# pays a small re-aim cost on top of the normal reaction time.
			_maneuvers.abort()
			var reaction := REACTION_TIME_MAX * (1.0 - skill)
			if _style != null:
				reaction = _style.reaction_time
			var switch_cost := 0.0 if prev_target == null else reaction * randf_range(0.6, 1.2)
			_reaction_timer = maxf(_reaction_timer, reaction * randf_range(0.8, 1.2) + switch_cost)
			_decision.interrupt(Decision.State.COMBAT)
	else:
		if not _search_active and _last_seen_position != Vector3.INF:
			_search_active = true
			_search_timer = SEARCH_DURATION
			_search_origin = _last_seen_position
			_target_lost_timer = TARGET_LOST_GRACE
		elif _search_active and _target_lost_timer > 0.0:
			_target_lost_timer = maxf(_target_lost_timer - PROCESS_INTERVAL, 0.0)
			if _target_lost_timer <= 0.0:
				_decision.interrupt(Decision.State.SEARCH)

	_refresh_los_excludes()

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

	var chest_pos := target.global_position + Vector3(0, 0.5, 0)
	_los_query.from = origin
	_los_query.to = chest_pos
	return space.intersect_ray(_los_query).is_empty()


## True while the current combat/heal targets are still worth tracking.
##
## Returns TRUE when there is nothing to validate.  The old `return false` at the
## end made the 20 Hz `_think` treat "no targets" as "targets just became
## invalid", forcing a full O(N) scan with LOS rays every think tick (Issue I).
## A rescan should happen on the RETARGET_INTERVAL timer, not because idling is
## considered invalid.
func _targets_valid() -> bool:
	var combat_ok := true
	var heal_ok := true

	if _current_target != null:
		combat_ok = is_instance_valid(_current_target) \
			and _current_target.spawned \
			and not _current_target.dev_hidden_from_bots \
			and _is_enemy_of(_current_target) \
			and not (_current_target.status_effect_manager \
				and _current_target.status_effect_manager.has_effect("invisible")) \
			and _has_line_of_sight_to_player(_current_target)

	if _heal_target != null:
		heal_ok = is_instance_valid(_heal_target) \
			and _heal_target.spawned \
			and not _heal_target.dev_hidden_from_bots
		if heal_ok:
			var ac: AttributeComponent = _heal_target.attribute_component
			heal_ok = ac != null and ac.max_health > 0.0 \
				and ac.health < ac.max_health * _medic_heal_threshold() \
				and _has_line_of_sight_to_player(_heal_target)

	return combat_ok and heal_ok


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
## call, `speed > 1.0` in _predict_target_pos was always false, and no lead
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
		"lifetime": 20.0,
		"splash_radius": 0.0,
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

		var hb := proj.get_node_or_null("HitboxComponent") as HitboxComponent
		if hb != null:
			info["heals_allies"] = hb.health_delta > 0.0 and hb.can_hit_other_teamates
			info["heals_shooter"] = hb.health_delta > 0.0 and hb.can_hit_shooter

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
			info["explodes_on_timeout"] = on_timeout
			info["is_explosive"] = on_hurtbox or on_world or on_timeout

		proj.free()
	_proj_cache[path] = info
	return info


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
	info["dps"] = fire.hitscan_damage * float(shots) \
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


## Score a weapon for the current target distance.  Higher is better.  Melee is
## only ever viable inside its real hitscan reach; falloff makes a huge
## `hitscan_range` irrelevant past `falloff_end`.
func _weapon_situation_score(weapon: Weapon, dist: float, has_target: bool) -> float:
	var profile := _get_weapon_profile(weapon)
	if profile.is_empty():
		return -INF
	var score := 40.0
	if bool(profile["melee"]):
		var reach := float(profile["range_effective"]) + WEAPON_MELEE_ONLY_MARGIN
		if not has_target:
			score -= 80.0
		elif dist > reach:
			score -= 500.0 + (dist - reach) * 10.0
		else:
			score += 35.0
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
				if dist < ideal * 0.45 and bool(profile["explosive"]):
					score -= 45.0
	if not bool(profile["infinite_ammo"]) and weapon.mag_current <= 0:
		score -= 400.0
	if bool(profile["heals_allies"]):
		# A heal-only weapon is a poor combat pick when a damage weapon exists.
		score -= 70.0
	score += clampf(float(profile["dps"]) * 0.08, 0.0, 30.0)
	score -= float(profile["switch_time"]) * 6.0
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
		if _heal_target != null and is_instance_valid(_heal_target):
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

	var current_score := _weapon_situation_score(current_weapon, dist, has_target)
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
		var candidate_score := _weapon_situation_score(candidate, dist, has_target)
		if candidate_score > best_score:
			best_score = candidate_score
			best_index = i
			best_reason = "range" if not _weapon_can_engage(current_weapon, dist) else "value"
	if best_index != current and best_score >= current_score + WEAPON_SWITCH_MARGIN:
		if _switch_weapon(wc, best_index):
			_weapon_choice_reason = best_reason
			_weapon_choice_timer = 1.0


func _weapon_reload_threshold(weapon: Weapon) -> float:
	if weapon == null or weapon.mag_size <= 0:
		return 0.0
	return lerpf(WEAPON_RELOAD_RATIO_MIN, WEAPON_RELOAD_RATIO_MAX, skill)


func _is_weapon_safe_to_reload(weapon: Weapon) -> bool:
	if _current_target == null or not is_instance_valid(_current_target):
		return true
	if _decision != null and _decision.state == Decision.State.RETREAT_COVER:
		return true
	var dist := player.global_position.distance_to(_current_target.global_position)
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
		var score := _weapon_situation_score(weapon, dist, true)
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


## Aim at a predicted position: lead the target's velocity so the bot actually
## hits a strafing player (projectiles only — hitscan is instantaneous).
##
## The aim point matters per projectile: a rocket that explodes on world contact
## is best aimed at the feet (splash), whereas a grenade that passes through
## world geometry only detonates on a hurtbox and must be aimed at the body.
func _predict_target_pos(target: Player, fire: WeaponFire, flat_dist: float,
		aim_point: AimPoint = AimPoint.HEAD) -> Vector3:
	var pos: Vector3
	match aim_point:
		AimPoint.FEET:
			pos = target.global_position
		AimPoint.CENTER:
			pos = target.global_position + Vector3(0.0, AIM_CENTER_HEIGHT, 0.0)
		_:
			pos = _get_head_position(target)
	if fire != null and fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		var speed: float = _get_proj_info(fire).get("speed", 0.0)
		if speed > 1.0:
			var t := clampf(flat_dist / speed, 0.0, LEAD_TIME_MAX)
			pos += target.velocity * t * skill
	return pos


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
	return true

# Objective seeking

func _get_objective_target() -> Vector3:
	if not GameManager.game_mode_component:
		return Vector3.INF
	var gmc := GameManager.game_mode_component

	match gmc.game_mode:
		GameModeComponent.GameMode.KOTH, GameModeComponent.GameMode.CONTROL:
			if gmc.koth_mode and not gmc.koth_mode._control_points.is_empty():
				return gmc.koth_mode._control_points[0].global_position

		GameModeComponent.GameMode.DOMINATION:
			if gmc.domination_mode:
				var best: Vector3 = Vector3.INF
				var best_dist := INF
				for cp in gmc.domination_mode._control_points:
					var d := player.global_position.distance_squared_to(cp.global_position)
					var prio := 0.0
					if cp.owning_team != player.team or cp.is_contested:
						prio = 0.5
					var w := d * (1.0 - prio)
					if w < best_dist:
						best_dist = w
						best = cp.global_position
				return best

		GameModeComponent.GameMode.ESCORT:
			var payload := _get_payload_node(gmc)
			if payload:
				return payload.global_position

		GameModeComponent.GameMode.HYBRID:
			if gmc.hybrid_mode and gmc.hybrid_mode.point_is_captured:
				var payload := _get_payload_node(gmc)
				if payload:
					return payload.global_position
			elif gmc.hybrid_mode and not gmc.hybrid_mode._control_points.is_empty():
				return gmc.hybrid_mode._control_points[0].global_position

	return Vector3.INF

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
## — scaled by skill — far more often at higher skill. Returns true if it
## fired this tick (caller should skip normal movement for that tick).
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
	if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
		return false
	# Low health + a self-damaging blast is not a good trade.
	if float(info.get("self_damage", 0.0)) < 0.0 and _health_ratio() < 0.6:
		return false

	# A skill-0 bot almost never pulls this off cleanly; a skill-1 bot does it
	# readily whenever there's a good reason to.
	if randf() > lerpf(0.02, 0.35, skill):
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
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return
	# The explosion-jump sub-sequence owns aim/fire/jump until it finishes.
	if _explosion_jump_phase != 0:
		return
	_decision.act()

func _act_seek_objective_or_wander() -> void:
	var obj := _get_objective_target()
	if obj == Vector3.INF:
		_act_wander()
		return

	var dist := player.global_position.distance_to(obj)
	if dist < 1.5:
		_act_wander()
		return

	var wc: WeaponController = player.weapon_controller
	if _try_explosion_jump(wc, dist):
		return
	_update_weapon_choice(wc, 15.0, false)
	if _buttons.is_switch_pending() or wc.is_switching():
		_trigger.release_all()
		return

	_trigger.release_all()
	_has_desired_aim = false
	var goal := obj
	if _style != null:
		# Cautious bots approach from a slight flank; aggressive bots beeline.
		var to_obj := obj - player.global_position
		var perp := Vector3(-to_obj.z, 0.0, to_obj.x)
		if perp.length_squared() > 0.01:
			goal += perp.normalized() * _style.flank_bias \
				* (1.0 - _style.aggression) * 6.0
	_traversal.move_to(goal, 0.6, 1.5, 0.15)

	_maybe_tactical_reload(wc)

func _act_combat() -> void:
	if _current_target == null or not is_instance_valid(_current_target) \
			or not _current_target.spawned:
		_trigger.release_all()
		return
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_trigger.release_all()
		return
	if wc.is_switching() or _buttons.is_switch_pending():
		_trigger.release_all()
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		_trigger.release_all()
		return

	var to_target := _current_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_update_weapon_choice(wc, dist, true)
	if _buttons.is_switch_pending() or wc.is_switching():
		_trigger.release_all()
		return
	weapon = wc._weapons[wc.current_weapon_index]
	_update_fire_mode(weapon, dist)
	var fire_index := _chosen_fire_index
	if fire_index < 0:
		_trigger.release_all()
		_has_desired_aim = false
		_bot_find_ammo_or_reload(wc)
		return
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
		_trigger.release_all()
		return

	# Aim at the target's head bone — or its feet for splash weapons, where a
	# near-miss on the ground still counts and the target area is far bigger
	# — leading moving targets for projectiles, aiming the bone directly for
	# hitscan (headshots register a crit when the weapon has one).
	var proj_info := _get_proj_info(fire)
	var is_explosive: bool = bool(proj_info.get("is_explosive", false))
	var aim_point := AimPoint.HEAD
	if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		if _signal_mode == SignalMode.EXPLODE:
			# Sticky signal charges attach where they hit; aim at the body.
			aim_point = AimPoint.CENTER
		elif is_explosive:
			# Rockets explode on world contact -> feet for splash.  Grenades,
			# molotovs and poison jars pass through world geometry and only
			# detonate on a hurtbox -> mid-body for a direct hit.
			aim_point = AimPoint.FEET if bool(proj_info.get("explodes_on_world", false)) else AimPoint.CENTER
	var aim_pos: Vector3 = _get_head_position(_current_target)
	if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		aim_pos = _predict_target_pos(_current_target, fire, dist, aim_point)
	# Request, do not write.  The Mouse owns recoil compensation, the flick and
	# the tracking lag; the aim gate still measures the real head ray against
	# this point, so lead and recoil flow through automatically.
	_desired_aim_point = aim_pos
	_has_desired_aim = true
	_mouse.request_look_at_point(
		aim_pos, LookPriority.COMBAT, 1.0, str(_current_target.get_instance_id())
	)

	# Weapon-aware engagement distance with a wide soft band, a slight approach
	# angle, and close-range circling.  Movement is expressed in the keyboard's
	# LOCAL frame (strafe, backward); only the obstacle-steer ray goes through the
	# facing helper.  The world-space steer is safety, not the primary motion.
	var desired_dist := maxf(
		_get_engagement_range(weapon) + _preferred_dist_offset,
		MELEE_ENGAGE_RANGE * 0.5
	)
	var band := maxf(3.0, desired_dist * 0.35)
	var radial := clampf((dist - desired_dist) / band, -1.0, 1.0)
	var steer_world := _steer_toward(_current_target.global_position)
	var steer_local := _keyboard.world_to_input_local(steer_world)
	if dist < MELEE_CONSIDER_RANGE or dist < 4.0:
		# Close range: circle rather than line up.
		radial *= 0.3
		if _strafe_dir == 0.0:
			_strafe_dir = 1.0 if _strafe_bias >= 0.0 else -1.0
	var approach_lateral := _strafe_bias * 0.45
	var local := steer_local * 0.5 \
		+ Vector2(_strafe_dir * 0.85 + approach_lateral * (1.0 - absf(radial)), -radial) * 0.7
	if local.length() > 0.001:
		local = local.normalized()
	else:
		local = Vector2(_strafe_dir, 0.0)
	local = _combat_strafe_safe(local)
	_move_local(local)

	# Event-driven strafe trigger: shots fired, not a fixed 1.5 s dice roll.
	var mag := weapon.mag_current
	if _last_mag_for_strafe >= 0 and mag < _last_mag_for_strafe:
		_shots_since_strafe += _last_mag_for_strafe - mag
	_last_mag_for_strafe = mag
	if _shots_since_strafe >= COMBAT_STRAFE_SHOT_MIN + 2:
		_strafe_force_change = true
		_strafe_reason = "shots"
		_shots_since_strafe = 0

	# Occasional human movement, suppressed while the shot is tight/precise.
	_combat_jump_timer = maxf(_combat_jump_timer - PROCESS_INTERVAL, 0.0)
	_combat_crouch_timer = maxf(_combat_crouch_timer - PROCESS_INTERVAL, 0.0)
	var tight_aim := aim_error_deg >= 0.0 and aim_error_deg < 2.0
	if not tight_aim and not _is_precision_weapon(weapon) and dist > 3.0:
		if _combat_jump_timer <= 0.0 and _style != null \
				and randf() < _style.jump_rate * 0.12:
			_keyboard.jump_tap(false)
			_combat_jump_timer = COMBAT_JUMP_MIN_INTERVAL * randf_range(0.8, 1.5)
		if _combat_crouch_timer <= 0.0 and _style != null \
				and randf() < _style.crouch_rate * 0.12:
			_keyboard.crouch_hold(randf_range(0.2, 0.45))
			_combat_crouch_timer = COMBAT_CROUCH_MIN_INTERVAL * randf_range(0.8, 1.5)

	# Firing: the Trigger owns the flags and applies the aim gate.  `wants` only
	# expresses intent (reaction delay, not blowing ourselves up point-blank,
	# never swinging a knife at a target outside its real reach, and never
	# firing a heal-only weapon at an enemy while waiting out medic hysteresis).
	var heal_idle := _weapon_heals_allies(weapon) and _heal_target == null
	var wants := _reaction_timer <= 0.0 \
		and not heal_idle \
		and _can_fire_mode(fire, dist) \
		and not _too_close_for_explosive(fire, dist)
	if not wants and _reaction_timer <= 0.0:
		# Point-blank with a self-damaging explosive: draw a sidearm instead of
		# standing there aiming at the ground while backing away.
		var safe_index := _first_safe_weapon_index(wc, dist)
		if safe_index >= 0 and _switch_weapon(wc, safe_index):
			_trigger.release_all()
			return
	_trigger.request_fire(fire_index, wants)

func _act_heal() -> void:
	if _heal_target == null or not is_instance_valid(_heal_target) \
			or not _heal_target.spawned:
		_trigger.release_all()
		return
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_trigger.release_all()
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		_trigger.release_all()
		return

	var to_target := _heal_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_update_fire_mode(weapon, dist)
	var fire_index := _chosen_fire_index
	if fire_index < 0:
		_trigger.release_all()
		_has_desired_aim = false
		_bot_find_ammo_or_reload(wc)
		return
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire == null or fire.action_type != WeaponFire.ActionType.SHOOT:
		_trigger.release_all()
		return

	var aim_pos := _predict_target_pos(_heal_target, fire, dist)
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
			return
		_maybe_tactical_reload(wc)

	var to_wander := _wander_target - player.global_position
	var flat := Vector2(to_wander.x, to_wander.z)

	if flat.length() < 1.5:
		_keyboard.set_move(0, 0)
		_pick_wander_target()
		return
	if _try_explosion_jump(wc, flat.length()):
		return

	_traversal.move_to(_wander_target, 0.25, 1.2, 0.35)


## SEARCH: go to the last-seen point, then continue along the target's remembered
## velocity for a few seconds.  Glances are issued by `_tick_glance`.
func _act_search() -> void:
	_trigger.release_all()
	_has_desired_aim = false
	if _search_timer > 0.0:
		_search_timer = maxf(_search_timer - PROCESS_INTERVAL, 0.0)
	if _search_timer <= 0.0 or _last_seen_position == Vector3.INF:
		_search_active = false
		_last_seen_position = Vector3.INF
		_act_seek_objective_or_wander()
		return

	var pos := player.global_position
	var dest := _last_seen_position
	var flat_to := Vector2(dest.x - pos.x, dest.z - pos.z)
	if flat_to.length() < 2.0:
		var vel := Vector3(_last_seen_velocity.x, 0.0, _last_seen_velocity.z)
		if vel.length() > 0.5:
			dest += vel.normalized() * 6.0
		else:
			dest += player.horizontal_forward() * 5.0
	_traversal.move_to(dest, 0.9, 1.2, 0.15)
	var wc: WeaponController = player.weapon_controller
	if wc != null and wc._is_ready():
		_update_weapon_choice(wc, 15.0, false)
		if _buttons.is_switch_pending() or wc.is_switching():
			return
		_maybe_tactical_reload(wc)


## RELOAD_SAFE: keep eyes on the threat, break line of sight if cover is near,
## and reload.  Falls back to backing up when no cover is found.
func _act_reload_safe() -> void:
	_trigger.release_all()
	_has_desired_aim = false
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon != null and not weapon.has_infinite_ammo \
			and weapon.mag_current < weapon.mag_size and not wc._is_reloading:
		_buttons.request_reload()

	if _current_target == null or not is_instance_valid(_current_target):
		_act_seek_objective_or_wander()
		return

	var threat := _current_target.global_position
	if ENABLE_COVER:
		if _cover_position == Vector3.INF:
			_cover_position = _find_cover_position(threat)
		if _cover_position != Vector3.INF:
			_traversal.move_to(_cover_position, 1.0, 0.8, 0.0)
		else:
			_move_local(Vector2(_strafe_dir, 1.0))
	else:
		_move_local(Vector2(_strafe_dir, 1.0))
	_mouse.request_look_at_point(
		_get_head_position(_current_target), LookPriority.COMBAT, 0.8,
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
		return

	if _current_target != null and is_instance_valid(_current_target):
		_cover_threat_pos = _current_target.global_position
	if _cover_position == Vector3.INF:
		_cover_position = _find_cover_position(_cover_threat_pos)
		if _cover_position == Vector3.INF:
			_cover_cooldown = 6.0
			_decision.interrupt(
				Decision.State.COMBAT if _current_target != null else Decision.State.TRAVEL
			)
			_act_context()
			return

	_cover_total_timer = maxf(_cover_total_timer - PROCESS_INTERVAL, 0.0)
	if _cover_total_timer <= 0.0:
		_cover_cooldown = 3.0
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
				_cover_timer = randf_range(0.6, 1.4)
				_keyboard.set_move(0, 0)
		1:
			# Catch breath behind cover; keep the threat watched.
			_keyboard.set_move(0, 0)
			if _style != null and randf() < _style.crouch_rate * 0.5:
				_keyboard.crouch_hold(0.25)
			if _cover_threat_pos != Vector3.INF:
				_mouse.request_look_at_point(
					_cover_threat_pos + Vector3.UP * AIM_CENTER_HEIGHT,
					LookPriority.COMBAT, 0.6, "cover_wait"
				)
			if _cover_timer <= 0.0:
				_cover_phase = 2
				_cover_timer = randf_range(0.35, 0.55)
				_cover_peek_side = 1.0 if _strafe_bias >= 0.0 else -1.0
		2:
			# Step out and take the shot(s).
			if _current_target != null and is_instance_valid(_current_target):
				_act_combat()
			_has_desired_aim = _current_target != null
			if _current_target != null:
				_mouse.request_look_at_point(
					_get_head_position(_current_target), LookPriority.COMBAT, 0.9,
					str(_current_target.get_instance_id())
				)
			_move_local(Vector2(_cover_peek_side, -1.0))
			if _cover_timer <= 0.0:
				_cover_phase = 3
				_cover_timer = randf_range(0.3, 0.45)
		3:
			# Duck back to cover.
			_trigger.release_all()
			_has_desired_aim = false
			_traversal.move_to(_cover_position, 1.0, 0.7, 0.0)
			if _cover_timer <= 0.0:
				_cover_rounds += 1
				if _cover_rounds >= 3 and (
						_health_ratio() > COVER_HEALTH_THRESHOLD + 0.1
						or _current_target == null):
					_decision.interrupt(
						Decision.State.COMBAT if _current_target != null else Decision.State.SEARCH
					)
				else:
					_cover_phase = 1
					_cover_timer = randf_range(0.5, 1.2)


## Shared fallback used by STUCK_RECOVER and by cover/reload exits.
func _act_context() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
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
			and _weapon_heals_allies(weapon):
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


func _has_threat() -> bool:
	var now := float(Time.get_ticks_msec()) / 1000.0
	if _current_target != null:
		return true
	if _last_damage_position != Vector3.INF and now - _last_damage_time < 6.0:
		return true
	return _search_active and _last_seen_position != Vector3.INF


## Called by Decision on state entry for state-specific setup.
func _on_decision_enter(state: int) -> void:
	match state:
		Decision.State.COMBAT:
			_traversal.cancel_recovery()
			_strafe_force_change = true
			_shots_since_strafe = 0
			_cover_position = Vector3.INF
			_cover_phase = 0
			_cover_rounds = 0
		Decision.State.SEARCH:
			_search_active = true
			if _search_timer <= 0.0:
				_search_timer = SEARCH_DURATION
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
			_cover_total_timer = 6.0
			if _current_target != null:
				_cover_threat_pos = _current_target.global_position
			elif _last_damage_position != Vector3.INF:
				_cover_threat_pos = _last_damage_position
			else:
				_cover_threat_pos = _last_seen_position
		Decision.State.HEAL:
			_traversal.cancel_recovery()
			_trigger.release_all()
		_:
			pass


## Find a nearby spot that breaks line of sight from [param threat].  Conservative:
## requires a floor, a reasonably clear path, and a blocked threat->candidate ray.
func _find_cover_position(threat: Vector3) -> Vector3:
	if not ENABLE_COVER:
		return Vector3.INF
	var origin := player.global_position
	var threat_pos := threat
	if threat_pos == Vector3.INF:
		if _last_damage_position != Vector3.INF:
			threat_pos = _last_damage_position
		elif _last_seen_position != Vector3.INF:
			threat_pos = _last_seen_position
		else:
			return Vector3.INF
	var space := player.get_world_3d().direct_space_state
	var best := Vector3.INF
	var best_score := -INF
	for i in 8:
		var angle := TAU * float(i) / 8.0 + randf_range(-0.15, 0.15)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var distances: Array[float] = [3.0, 5.0, 7.0]
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
func _combat_strafe_safe(local: Vector2) -> Vector2:
	if absf(local.x) < 0.1:
		return local
	var forward := player.horizontal_forward()
	var right := Vector3.UP.cross(forward).normalized()
	var side_sign := signf(local.x)
	var side := right * side_sign
	var origin := player.global_position + Vector3.UP * STEER_RAY_HEIGHT
	var flat := Vector2(side.x, side.z)
	var score := _score_direction(origin, flat)
	if score >= 1.5 and _has_floor_side(side):
		return local
	var other_score := _score_direction(origin, -flat)
	if other_score > score and _has_floor_side(-side):
		local.x = -local.x
		return local
	local.x = 0.0
	return local


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

func _debug_tick(delta: float) -> void:
	if not debug_draw:
		return
	_ensure_debug_nodes()
	if _debug_label != null:
		_debug_label.visible = true
	if _debug_ray_instance != null:
		_debug_ray_instance.visible = true

	_debug_refresh_timer += delta
	if _debug_refresh_timer < DEBUG_REFRESH_INTERVAL:
		return
	_debug_refresh_timer = 0.0
	_update_debug_label()
	_render_debug_rays()


func _ensure_debug_nodes() -> void:
	# The Player owns these nodes, so a freed Player takes them with it.  Clear
	# the cached references rather than touching a freed instance.
	if _debug_label != null and not is_instance_valid(_debug_label):
		_debug_label = null
	if _debug_ray_instance != null and not is_instance_valid(_debug_ray_instance):
		_debug_ray_instance = null
		_debug_ray_mesh = null
		_debug_ray_material = null

	if _debug_label == null:
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
		var line_material := StandardMaterial3D.new()
		line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_material.vertex_color_use_as_albedo = true
		line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var ray_instance := MeshInstance3D.new()
		ray_instance.name = "BotDebugRays"
		ray_instance.top_level = true
		ray_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ray_instance.mesh = line_mesh
		ray_instance.material_override = line_material
		player.add_child(ray_instance)
		_debug_ray_mesh = line_mesh
		_debug_ray_material = line_material
		_debug_ray_instance = ray_instance


func _update_debug_label() -> void:
	if _debug_label == null or not is_instance_valid(player):
		return
	_debug_label.global_position = player.global_position + Vector3.UP * DEBUG_LABEL_HEIGHT

	var hp: float = 0.0
	if player.attribute_component != null:
		hp = player.attribute_component.health

	var target_name := _debug_target_name()
	var lines := PackedStringArray()
	lines.append("%s  hp=%.0f" % [_debug_state_text(), hp])
	lines.append("target: %s" % target_name)
	lines.append("fire: %d  trig: %s" % [_chosen_fire_index, _debug_trigger_text()])
	lines.append("aim err: %s deg" % _debug_aim_error(target_name != "-"))
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


func _render_debug_rays() -> void:
	if _debug_ray_mesh == null:
		return
	_debug_ray_mesh.clear_surfaces()
	if _debug_ray_lines.size() >= 2:
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
		# Only a blast that actually hurts the shooter is penalised.  The Heal
		# Grenade Launcher's self multiplier is -1 x -45, i.e. a self-heal.
		if float(info.get("self_damage", -1.0)) < 0.0 and dist < splash + EXPLOSIVE_SAFE_MARGIN:
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


## True when firing [param fire] would splash the bot itself.  Explosive modes
## aim at the feet, so this is a self-damage guard, not a "don't shoot" rule:
## movement backs the bot off while the trigger is held.
func _too_close_for_explosive(fire: WeaponFire, dist: float) -> bool:
	var info := _get_proj_info(fire)
	if not bool(info.get("is_explosive", false)):
		return false
	# A healing blast (Heal Grenade Launcher) is safe — and useful — point-blank.
	if float(info.get("self_damage", -1.0)) >= 0.0:
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
	var target_pos := _current_target.global_position
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
		dist = player.global_position.distance_to(_current_target.global_position)
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
	_seen_since.clear()
	_last_damage_source_name = ""
	_last_damage_time = -999.0
	_last_damage_position = Vector3.INF
	_last_damage_direction = Vector3.ZERO
	_last_seen_velocity = Vector3.ZERO
	_target_lost_timer = 0.0
	_search_timer = 0.0
	_search_active = false
	_search_origin = Vector3.INF
	_glance_timer = 0.0
	_strafe_force_change = false
	_strafe_reason = ""
	_shots_since_strafe = 0
	_last_mag_for_strafe = -1
	_combat_jump_timer = 0.0
	_combat_crouch_timer = 0.0
	_cover_position = Vector3.INF
	_cover_threat_pos = Vector3.INF
	_cover_phase = 0
	_cover_timer = 0.0
	_cover_total_timer = 0.0
	_cover_cooldown = 0.0
	_cover_rounds = 0
	# A fresh body, a fresh style: the per-bot mouse/keyboard personality is
	# drawn once per life, so two bots at the same skill still differ.
	_style.draw(skill)
	_strafe_bias = randf_range(-0.25, 0.25)
	_choice_history.clear()
	_strafe_dir = 0.0
	_strafe_timer = 0.0
	_current_target = null
	_heal_target = null
	_last_seen_position = Vector3.INF
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
	enum State { TRAVEL, SEARCH, COMBAT, HEAL, RELOAD_SAFE, RETREAT_COVER, STUCK_RECOVER }

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
		# Stuck recovery is a locomotion state, not a reason to stop shooting.
		if bot._traversal.is_recovering() and bot._current_target == null \
				and bot._heal_target == null:
			return State.STUCK_RECOVER
		if state == State.STUCK_RECOVER and _stuck_hold > 0.0:
			return State.STUCK_RECOVER
		var wc: WeaponController = bot.player.weapon_controller
		if wc != null and wc._is_ready():
			# Self-heal outranks cover: a medic's own heal is the fastest exit.
			if bot._health_ratio() < MEDIC_SELF_HEAL_THRESHOLD \
					and bot._find_self_heal_weapon_index(wc) >= 0:
				return State.HEAL
		if ENABLE_COVER and bot._cover_cooldown <= 0.0 \
				and bot._health_ratio() < COVER_HEALTH_THRESHOLD \
				and bot._has_threat():
			return State.RETREAT_COVER
		if wc != null and wc._is_ready():
			var weapon: Weapon = wc._weapons[wc.current_weapon_index]
			if bot._heal_target != null and is_instance_valid(bot._heal_target) \
					and bot._weapon_heals_allies(weapon):
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
		var dist := bot.player.global_position.distance_to(
			bot._current_target.global_position
		)
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
		if bot._heal_target != null and bot._weapon_heals_allies(weapon):
			bot._act_heal()
		else:
			bot._act_context()

	func get_state_text() -> String:
		var names: Array[String] = [
			"travel", "search", "combat", "heal", "reload", "cover", "stuck"
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


## Per-bot traversal state machine.  It turns a goal into W + a mouse look
## request, with short A/D taps and digital jump/crouch/back-up actions.  It
## never writes input directly; all verbs go through Keyboard/Mouse.
class Traversal extends RefCounted:
	enum Action { CONTINUE, TAP_LEFT, TAP_RIGHT, JUMP, CROUCH, STOP, BACK_UP, REROUTE }
	enum Recovery { NONE, JUMP, STRAFE, BACKUP, REROUTE, TURN }

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

	func tick(delta: float) -> void:
		_ray_clock += delta
		if _ray_clock >= 1.0:
			_ray_clock -= 1.0
			_rays_per_second = _rays_this_second
			_rays_this_second = 0
		_repath_timer = maxf(_repath_timer - delta, 0.0)

		var graph := TravelGraph.shared_for(bot.player)
		if graph != null and graph != _graph:
			_graph = graph
			_path_points.clear()
			_path_types.clear()
			_path_ids.clear()
			_path_index = 0
		if _graph != null:
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
		var intentional := bot._current_target != null \
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
			caution: float = 0.0) -> void:
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

		if _graph != null and _graph.is_ready() and not _direct_clear(goal):
			_follow_path(goal)
			return
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
		var action := _perceive(dir, lookahead, TravelGraph.EdgeType.WALK)
		if _apply_action(action):
			return
		if _tempo_ok():
			bot._keyboard.set_move(1, 0)
		else:
			bot._keyboard.set_move(0, 0)

	func _follow_path(goal: Vector3) -> void:
		var pos := bot.player.global_position
		var need_query := _path_points.is_empty() or _force_repath \
			or _repath_timer <= 0.0 \
			or _query_goal.distance_squared_to(goal) > 9.0
		if need_query:
			_query_graph(goal)
		if _path_points.is_empty():
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

		var look := waypoint
		if flat_dist < 2.0 and _path_index + 1 < _path_points.size():
			look = _path_points[_path_index + 1]
		_request_look(look)

		if edge == TravelGraph.EdgeType.JUMP:
			var takeoff := WALK_SPEED * (2.0 * JUMP_VELOCITY / GRAVITY) * 0.55
			if flat_dist <= takeoff and flat_dist > 0.35:
				bot._keyboard.jump_tap(false)
		elif edge == TravelGraph.EdgeType.CROUCH:
			bot._keyboard.crouch_hold(0.18)

		var lookahead := _lookahead_distance()
		var action := _perceive(dir, lookahead, edge)
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
		else:
			bot._keyboard.set_move(1, 0)
		_state_text = "path"

	func _query_graph(goal: Vector3) -> void:
		if _graph == null:
			return
		var avoids: Array[Vector3] = []
		var now := float(Time.get_ticks_msec()) / 1000.0
		for i in range(_recent_stuck.size() - 1, -1, -1):
			var entry: Dictionary = _recent_stuck[i]
			if float(entry.get("until", 0.0)) < now:
				_recent_stuck.remove_at(i)
			else:
				avoids.append(entry.get("pos", Vector3.ZERO) as Vector3)
		var result := _graph.query(
			bot.player.global_position, goal, _path_ids, avoids, _route_bias
		)
		_force_repath = false
		_repath_timer = REPATH_INTERVAL
		_query_goal = goal
		if result.is_empty():
			_path_points.clear()
			_path_types.clear()
			_path_ids.clear()
			_path_index = 0
			return
		var points_variant: Variant = result.get("points", [])
		var types_variant: Variant = result.get("types", [])
		var ids_variant: Variant = result.get("ids", [])
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

	func _perceive(dir: Vector3, lookahead: float, edge: int) -> int:
		var pos := bot.player.global_position
		var flat := Vector3(dir.x, 0.0, dir.z)
		if flat.length_squared() < 0.0001:
			flat = bot.player.horizontal_forward()
		flat = flat.normalized()
		var dist := maxf(1.0, lookahead)

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
		if edge != TravelGraph.EdgeType.DROP:
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
		return "%s path=%d rays/s=%d %s" % [
			_state_text, _path_points.size(), _rays_per_second, graph_text
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
	var aim_jitter: float = 0.0
	## 0 = cautious/flanking, 1 = direct/aggressive.  Used for target weighting
	## and a mild objective approach offset, not for a different ruleset.
	var aggression: float = 0.5
	var flank_bias: float = 0.0

	func draw(skill_value: float) -> void:
		var s: float = clampf(skill_value, 0.0, 1.0)
		reaction_time = lerpf(
			BotController.KEY_REACTION_MAX, BotController.KEY_REACTION_MIN, s
		) * randf_range(0.8, 1.2)
		strafe_hold_median = lerpf(1.2, 0.4, s) * randf_range(0.8, 1.25)
		strafe_hold_spread = lerpf(0.45, 0.15, s)
		pause_probability = lerpf(0.35, 0.06, s) * randf_range(0.7, 1.3)
		jump_rate = lerpf(0.02, 0.16, s) * randf_range(0.7, 1.3)
		crouch_rate = lerpf(0.0, 0.06, s)
		var low: Array[float] = [0.7, 0.2, 0.1, 0.0]
		var high: Array[float] = [0.3, 0.25, 0.3, 0.15]
		var weights: Array[float] = []
		for i in 4:
			weights.append(lerpf(low[i], high[i], s))
		peek_style_weights = weights
		counter_strafe_skill = s * randf_range(0.75, 1.0)
		mouse_speed = lerpf(0.55, 1.0, s) * randf_range(0.9, 1.1)
		flick_accuracy = clampf(
			lerpf(0.55, 0.97, s) * randf_range(0.95, 1.03), 0.1, 0.995
		)
		tracking_lag = lerpf(0.28, 0.04, s) * randf_range(0.85, 1.2)
		bhop_ability = s * randf_range(0.5, 1.0)
		# Low skill unlocks only a small vocabulary; max skill unlocks everything.
		allow_strafe = s > 0.12
		allow_back = s > 0.35
		allow_diagonal = s > 0.5
		allow_jump = s > 0.25
		allow_crouch = s > 0.6
		fire_tap_min = lerpf(0.10, BotController.FIRE_TAP_MIN, s) * randf_range(0.9, 1.1)
		fire_tap_max = lerpf(0.12, BotController.FIRE_TAP_MAX, s) * randf_range(0.9, 1.1)
		fire_click_hz = lerpf(
			BotController.FIRE_CLICK_HZ_MIN, BotController.FIRE_CLICK_HZ_MAX, s
		) * randf_range(0.9, 1.1)
		key_min_hold = lerpf(
			BotController.KEY_MIN_HOLD_MAX, BotController.KEY_MIN_HOLD_MIN, s
		) * randf_range(0.85, 1.15)
		key_flip_rate = lerpf(
			BotController.KEY_FLIP_RATE_MIN, BotController.KEY_FLIP_RATE_MAX, s
		) * randf_range(0.9, 1.1)
		aim_jitter = BotController.AIM_NOISE_MAX * (1.0 - s) * 0.5
		aggression = clampf(0.5 + randf_range(-0.35, 0.35) + (s - 0.5) * 0.2, 0.0, 1.0)
		flank_bias = randf_range(-1.0, 1.0)


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
		_tap_strafe_timer = maxf(_min_hold(), lerpf(0.09, 0.05, bot.skill))

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

	var _jitter_timer: float = 0.0
	var _jitter_yaw: float = 0.0
	var _jitter_pitch: float = 0.0
	var _idle_phase: float = 0.0
	var _residual_x: float = 0.0
	var _residual_y: float = 0.0
	var _last_dx: float = 0.0
	var _last_dy: float = 0.0

	func _init(owner_bot: BotController) -> void:
		bot = owner_bot

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

	func tick(delta: float) -> void:
		_idle_phase += delta
		_jitter_timer -= delta
		if _jitter_timer <= 0.0:
			_jitter_timer = BotController.NOISE_INTERVAL
			var style: BotController.Style = bot._style
			var amount := 0.0
			if style != null:
				amount = style.aim_jitter
			_jitter_yaw = randf_range(-amount, amount)
			_jitter_pitch = randf_range(-amount, amount)

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
			target_yaw -= recoil.y * bot.skill
			target_pitch -= recoil.x * bot.skill

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
		var accuracy := 0.8
		var mouse_speed := 0.8
		if style != null:
			accuracy = style.flick_accuracy
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
		duration *= lerpf(1.35, 0.85, bot.skill) / maxf(mouse_speed, 0.4)
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
			# Fewer, tighter corrections at high skill: 3 at skill 0, 1 at skill 1.
			_corrections_left = maxi(1, int(round(lerpf(3.0, 1.0, bot.skill))))

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
		if style != null:
			lag = maxf(style.tracking_lag, 0.02)
			mouse_speed = style.mouse_speed
		if _has_prev and delta > 0.000001:
			var raw_yaw := wrapf(target_yaw - _prev_desired_yaw, -PI, PI) / delta
			var raw_pitch := wrapf(target_pitch - _prev_desired_pitch, -PI, PI) / delta
			var alpha := clampf(delta / lag, 0.0, 1.0)
			_target_vel_yaw = lerpf(_target_vel_yaw, raw_yaw, alpha)
			_target_vel_pitch = lerpf(_target_vel_pitch, raw_pitch, alpha)
		var max_speed := BotController.LOOK_TRACK_MAX_SPEED * maxf(mouse_speed, 0.3)
		var gain := BotController.LOOK_TRACK_GAIN
		var want_yaw := _target_vel_yaw + clampf(err_yaw * gain, -max_speed, max_speed)
		var want_pitch := _target_vel_pitch \
			+ clampf(err_pitch * gain * 0.8, -max_speed * 0.8, max_speed * 0.8)
		var accel := BotController.LOOK_TRACK_ACCEL * lerpf(0.5, 1.0, bot.skill)
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
		return lerpf(maximum, minimum, clampf(bot.skill, 0.0, 1.0)) \
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
			_aim_delay_timer = lerpf(
				BotController.TRIGGER_DELAY_MAX,
				BotController.TRIGGER_DELAY_MIN,
				bot.skill
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
						_charged_hold = lerpf(
							BotController.CHARGE_OVERHOLD_MAX, 0.0, bot.skill
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
				_charge_threshold = minf(
					lerpf(BotController.CHARGE_RELEASE_MIN, 1.0, bot.skill)
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
		return lerpf(
			BotController.SEMI_GAP_MAX, BotController.SEMI_GAP_MIN, bot.skill
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
