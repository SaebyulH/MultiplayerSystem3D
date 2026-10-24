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
##   Follow-up tuning: `skill` now defaults to 1.0 and AIM_SMOOTH_MAX is 20/s
##   (max skill is meant to be aimbot-sharp).  Explosive self-damage is now read from
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
## - Stage 2+: not started.
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
## head (`%Head` = Body/Recoil/Head), NOT the physical head bone.  `_apply_smooth_aim`
## pitches `_head_node.rotation.x`, which must rotate the camera/weapon ray, not a
## ragdoll bone.  (The *target's* head bone is resolved separately in
## `_get_head_position()`.)
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
## Aim tracking speed at skill 0 / skill 1 — low skill trails the target
## noticeably instead of only missing via spread noise.
const AIM_SMOOTH_MIN: float      = 3.0
## 20/s at skill 1 is a ~50 ms time constant, i.e. genuinely "max skill":
## fast enough to snap onto a strafing target, while still leaving the weapon's
## own authored spread as the limiting factor.
const AIM_SMOOTH_MAX: float      = 20.0
## Path to the target's head bone — the `Physical Bone DEF-spine_006` hurtbox with
## `is_head = true` in player.tscn.  Bots aim at this bone's live world position
## rather than a fixed height, so headshots track the model's actual head.
const HEAD_BONE_PATH: String = "Body/Mannequin/mannequin/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-spine_006"
const NOISE_INTERVAL: float       = 0.4
## Max aim spread (radians) at skill 0; scaled to 0 at skill 1.
const AIM_NOISE_MAX: float        = 0.2
## Max projectile-lead time so prediction never overshoots on slow projectiles.
const LEAD_TIME_MAX: float        = 0.6

# Stuck detection
const STUCK_CHECK_INTERVAL: float    = 0.5
const STUCK_DISTANCE_THRESHOLD: float = 0.3
const STUCK_JUMP_ATTEMPTS: int        = 2

# Steering — a reduced fan (7 rays instead of 11) keeps wall-following smooth
# while cutting the steering raycast cost by ~40%.
const STEER_DISTANCE: float       = 8.0
const STEER_ANGLES: Array[float]  = [-55, -35, -20, 0, 20, 35, 55]
const STEER_RAY_HEIGHT: float     = 0.5
const WALL_FOLLOW_DISTANCE: float = 3.0

# Strafing
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

var _stuck_check_timer:  float = 0.0
var _last_position: Vector3    = Vector3.ZERO
var _stuck_jump_count: int     = 0
var _force_wander_timer: float = 0.0

var _strafe_dir: float   = 0.0
var _strafe_timer: float = 0.0

## Sole owner of the fire flags.  Assigned in _ready; ticked every physics
## frame, independently of the 20 Hz think loop.
var _trigger: Trigger = null

## The point `_act_combat`/`_act_heal` want the head ray to point at.  The aim
## gate measures the REAL head ray against this, not `_current_body_y/_x`.
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

var _aim_noise_y: float  = 0.0
var _aim_noise_x: float  = 0.0
var _noise_timer: float  = 0.0
var _current_body_y: float = 0.0
var _current_head_x: float = 0.0

## Counts down after acquiring a new target; firing is held off until it hits
## zero (see REACTION_TIME_MAX). Aiming/steering are never gated by this.
var _reaction_timer: float = 0.0

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
		# The weapon controller's fire flags are plain bools that survive death;
		# release them or the corpse keeps "holding" until respawn.
		_trigger.release_all()
		_has_desired_aim = false
		aim_error_deg = -1.0
		_was_spawned = false
		return
	if not _was_spawned:
		_was_spawned = true
		_reset_for_spawn()

	# Dev-menu "freeze all bots": park them exactly like a stun, clearing the
	# inputs BotController normally writes so nothing is left held down.
	if GameManager.dev_freeze_bots:
		player.player_input.input_dir = Vector2.ZERO
		player.player_input.jump_input = false
		player.player_input.crouch = false
		_trigger.release_all()
		_has_desired_aim = false
		if debug_draw:
			_debug_tick(delta)
		return

	# Stunned, pinned, or mid-channel bots cannot move, aim, or fire.
	if player.status_effect_manager and (player.status_effect_manager.is_stunned() or player.status_effect_manager.is_pinned() or player.status_effect_manager.is_action_blocked()):
		player.player_input.input_dir = Vector2.ZERO
		player.player_input.jump_input = false
		_trigger.release_all()
		_has_desired_aim = false
		if debug_draw:
			_debug_tick(delta)
		return

	# Physics-rate work: smooth the real head, measure the real aim error, and
	# run the trigger state machine.  None of this waits for the 20 Hz think.
	_apply_smooth_aim(delta)
	_update_aim_error()
	_trigger.tick(delta)
	if _reaction_timer > 0.0:
		_reaction_timer = maxf(_reaction_timer - delta, 0.0)
	if _explosion_jump_cooldown_timer > 0.0:
		_explosion_jump_cooldown_timer = maxf(_explosion_jump_cooldown_timer - delta, 0.0)

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

	# Stuck bots force-wander for a few seconds. Only re-steer at the normal tick
	# rate — steering every physics frame (~60 Hz) tripled the raycasts for a bot
	# that is merely walking away from an obstacle.
	if _force_wander_timer > 0.0:
		_trigger.release_all()
		_has_desired_aim = false
		_force_wander_timer -= PROCESS_INTERVAL
		var sd := _steer_toward(_wander_target)
		_apply_movement(sd)
		return

	_tick_stuck_detection()
	_tick_strafe()
	_tick_preferred_distance()

	_noise_timer += PROCESS_INTERVAL
	if _noise_timer >= NOISE_INTERVAL:
		_noise_timer = 0.0
		var spread := AIM_NOISE_MAX * (1.0 - skill)
		_aim_noise_y = randf_range(-spread, spread)
		_aim_noise_x = randf_range(-spread, spread)

	_think()
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

func _apply_movement(sd: Vector2) -> void:
	player.player_input.input_dir = sd

# Stuck detection

func _tick_stuck_detection() -> void:
	_stuck_check_timer += PROCESS_INTERVAL
	if _stuck_check_timer < STUCK_CHECK_INTERVAL:
		return
	_stuck_check_timer = 0.0

	var moved := player.global_position.distance_to(_last_position)
	_last_position = player.global_position

	var is_trying := player.player_input.input_dir.length() > 0.1
	if not is_trying:
		_stuck_jump_count = 0
		return

	if moved < STUCK_DISTANCE_THRESHOLD:
		_stuck_jump_count += 1
		if _stuck_jump_count <= STUCK_JUMP_ATTEMPTS:
			player.player_input.jump_input = true
		else:
			player.body.rotate_y(PI + randf_range(-0.5, 0.5))
			_stuck_jump_count = 0
			_force_wander_timer = 3.0
			player.player_input.jump_input = false
			_pick_wander_target()
			_wall_hug_side *= -1
	else:
		_stuck_jump_count = 0
		player.player_input.jump_input = false

# Aim smoothing

func _apply_smooth_aim(delta: float) -> void:
	# Higher skill tracks tighter and faster; low skill visibly trails the
	# target instead of only missing via random spread.
	var smooth := lerpf(AIM_SMOOTH_MIN, AIM_SMOOTH_MAX, skill)
	player.body.rotation.y = lerp_angle(
		player.body.rotation.y, _current_body_y, smooth * delta
	)
	var head_node: Node3D = _head_node
	head_node.rotation.x = lerp_angle(
		head_node.rotation.x, _current_head_x, smooth * delta
	)

# Strafing

func _tick_strafe() -> void:
	_strafe_timer -= PROCESS_INTERVAL
	if _strafe_timer <= 0.0:
		_strafe_timer = STRAFE_CHANGE_INTERVAL
		var roll := randi() % 3
		_strafe_dir = [-1.0, 0.0, 1.0][roll]

## Rerolls the per-bot preferred-fighting-distance wobble every couple of
## seconds so combat movement doesn't lock onto one exact, robotic distance.
func _tick_preferred_distance() -> void:
	_preferred_dist_timer -= PROCESS_INTERVAL
	if _preferred_dist_timer <= 0.0:
		_preferred_dist_timer = PREFERRED_DIST_REROLL_INTERVAL + randf_range(-0.5, 0.5)
		_preferred_dist_offset = randf_range(-PREFERRED_DIST_JITTER, PREFERRED_DIST_JITTER)

# Aim error

## Angle (degrees) between the head's REAL forward ray and the desired aim
## point.  Deliberately not derived from `_current_body_y/_current_head_x`:
## those are the smoothed-aim targets and can be well ahead of the actual head.
func _update_aim_error() -> void:
	aim_tolerance_deg = _current_aim_tolerance()
	if not _has_desired_aim:
		aim_error_deg = -1.0
		return
	var head_pos := _head_node.global_position
	var to_aim := _desired_aim_point - head_pos
	if to_aim.length_squared() < 0.000001:
		aim_error_deg = 0.0
		return
	var forward := -_head_node.global_transform.basis.z
	aim_error_deg = rad_to_deg(forward.angle_to(to_aim.normalized()))


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

func _think() -> void:
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
		return

	_retarget_timer = RETARGET_INTERVAL
	_full_scan_count += 1
	var prev_target := _current_target
	_current_target = null
	_heal_target = null

	var closest_dist_sq := SHOOT_RANGE * SHOOT_RANGE
	var heal_dist_sq := HEAL_RANGE * HEAL_RANGE
	var heal_best_ratio := 2.0
	_enemy_nearby = false

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
			if dist_sq < closest_dist_sq and _is_in_view_cone(p) and _has_line_of_sight_to_player(p):
				closest_dist_sq = dist_sq
				_current_target = p
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

	# Medic behaviour: put the heal gun away when nobody needs healing, and pull
	# it out when a teammate is critically hurt.  Exception: if the medic itself
	# is low and owns a self-heal weapon, keep it out — `_act` will heal itself.
	var needs_self_heal := _health_ratio() < MEDIC_SELF_HEAL_THRESHOLD
	var has_self_heal_weapon := _find_self_heal_weapon_index(wc) >= 0
	if holding_heal and _heal_target == null and heal_index >= 0 \
			and not (needs_self_heal and has_self_heal_weapon):
		_switch_weapon(wc, _first_damage_weapon_index(wc))
	elif not holding_heal and heal_index >= 0 and _heal_target != null:
		var ac := _heal_target.attribute_component
		if ac != null and ac.health / ac.max_health < _medic_heal_threshold():
			if _switch_weapon(wc, heal_index):
				_current_target = null  # don't fight while healing

	if _current_target != null:
		# Only a genuinely new target starts the reaction-delay clock — losing
		# and re-verifying the same target every RETARGET_INTERVAL shouldn't
		# make a skill-0 bot re-hesitate on someone it's already shooting.
		if _current_target != prev_target:
			_reaction_timer = REACTION_TIME_MAX * (1.0 - skill)
		_last_seen_position = _current_target.global_position

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


## Perfect counter-aim at skill 1.0, none at skill 0.0. Replaces stopping fire
## until recoil settles — that gave even a max-skill bot the same shaky
## aim as a low-skill one, just delayed, which is backwards for a skill dial.
## Returns (pitch, yaw) angle offsets to subtract from the intended aim.
## NOTE: this assumes wc.recoil.rotation adds visually on top of the aim the
## same way it does for a human camera. Flip the sign here if compensation
## pushes the aim the wrong way on your rig.
func _get_recoil_compensation(wc: WeaponController) -> Vector2:
	var r: Vector3 = wc.recoil.rotation
	return Vector2(r.x, r.y) * skill


## Best-effort melee detection. Duck-typed rather than hard-referencing an
## exact WeaponFire.ActionType.MELEE enum member or field name, so it still
## compiles and runs even if your schema differs — verify against your actual
## WeaponFire class and adjust the property names below if this misfires.
func _is_melee_weapon(weapon: Weapon) -> bool:
	if weapon == null or weapon.weapon_fires.is_empty():
		return false
	var melee_enum: int = WeaponFire.ActionType.get("MELEE", -999)
	for fire in weapon.weapon_fires:
		if fire == null:
			continue
		if melee_enum != -999 and fire.action_type == melee_enum:
			return true
		var explicit_flag: Variant = _read_prop(fire, PROP_IS_MELEE, null, "WeaponFire.is_melee")
		if explicit_flag is bool and explicit_flag:
			return true
		var configured_range: Variant = _read_prop(fire, PROP_RANGE, null, "WeaponFire.range")
		if configured_range != null and float(configured_range) > 0.0 and float(configured_range) <= MELEE_CONSIDER_RANGE:
			return true
	# Last-resort name sniff — only matters if nothing above hit.
	return weapon.resource_name.to_lower().contains("knife") or weapon.resource_name.to_lower().contains("melee")


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
	if _is_melee_weapon(weapon):
		return {"range": MELEE_ENGAGE_RANGE, "source": "melee"}
	for fire in weapon.weapon_fires:
		if fire == null:
			continue
		var range_info := _read_prop_ex(fire, PROP_RANGE, null, "WeaponFire.range")
		var r: Variant = range_info["value"]
		if r != null and float(r) > 0.0:
			return {
				"range": clampf(float(r), MELEE_CONSIDER_RANGE, MAX_SENSIBLE_RANGE) * 0.5,
				"source": "WeaponFire." + str(range_info["source"]),
			}
	return {"range": DEFAULT_RANGED_ENGAGE_DIST, "source": "default (no range property)"}


func _switch_weapon(wc: WeaponController, index: int) -> bool:
	if index < 0 or index >= wc._weapons.size() or index == wc.current_weapon_index:
		return false
	if _weapon_switch_guard > 0.0:
		return false
	_weapon_switch_guard = 1.0
	_trigger.release_all()
	wc.current_weapon_index = index
	_chosen_fire_index = -1
	_fire_mode_dirty = true
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
	if _explosion_jump_cooldown_timer > 0.0 or travel_dist < EXPLOSION_JUMP_MIN_GAP:
		return false
	if not wc._is_ready() or wc._is_reloading:
		return false

	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		return false
	var fire_index := _select_explosive_fire_index(weapon)
	if fire_index < 0:
		return false
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire.bullet_type != WeaponFire.BulletType.PROJECTILE:
		return false
	if not bool(_get_proj_info(fire).get("is_explosive", false)):
		return false
	if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
		return false

	# A skill-0 bot almost never pulls this off cleanly; a skill-1 bot does it
	# readily whenever there's a good reason to.
	if randf() > lerpf(0.02, 0.35, skill):
		return false

	_current_head_x = -1.4  # nearly straight down at our own feet
	_desired_aim_point = player.global_position
	_has_desired_aim = true
	# `force` skips the aim gate: the shot leaves while the head is still
	# pitching down.  Full aim -> fire -> jump sequencing is Stage 5.
	_trigger.request_fire(fire_index, true, true)
	player.player_input.jump_input = true
	_explosion_jump_cooldown_timer = EXPLOSION_JUMP_COOLDOWN
	return true

# Act

func _act() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return
	var weapon := wc._weapons[wc.current_weapon_index]

	# Self-preservation comes first.  If we are low and have a weapon that can
	# heal its own shooter, use it before healing anyone else or fighting.
	if _health_ratio() < MEDIC_SELF_HEAL_THRESHOLD:
		var self_heal_index := _find_self_heal_weapon_index(wc)
		if self_heal_index >= 0:
			if wc.current_weapon_index == self_heal_index:
				_act_self_heal(wc, wc._weapons[self_heal_index])
				return
			if _switch_weapon(wc, self_heal_index):
				_trigger.release_all()
				return

	if _heal_target != null and _weapon_heals_allies(weapon):
		_act_heal()
	elif _current_target != null:
		_act_combat()
	elif _last_seen_position != Vector3.INF:
		_act_pursue_last_seen()
	else:
		_act_seek_objective_or_wander()

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

	_trigger.release_all()
	_has_desired_aim = false
	_current_body_y = atan2(-(obj.x - player.global_position.x), -(obj.z - player.global_position.z))
	_current_head_x = 0.0
	var sd := _steer_toward(obj)
	_apply_movement(sd)

	if wc._is_ready() and not wc._is_reloading:
		var cw: Weapon = wc._weapons[wc.current_weapon_index]
		if cw.mag_current < cw.mag_size and not cw.has_infinite_ammo:
			wc.start_reload()

func _act_combat() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_trigger.release_all()
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		_trigger.release_all()
		return

	var to_target := _current_target.global_position - player.global_position
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
	# The aim gate measures the real head ray against THIS point, so lead and
	# recoil compensation flow into it automatically.
	_desired_aim_point = aim_pos
	_has_desired_aim = true

	var to_aim := aim_pos - _head_node.global_position
	var flat_to_aim := Vector3(to_aim.x, 0, to_aim.z).length()
	var target_body_y := atan2(-to_aim.x, -to_aim.z)
	var target_head_x := atan2(to_aim.y, maxf(flat_to_aim, 0.001))

	# Recoil compensation: perfect counter-aim at skill 1.0, none at 0.0 —
	# see _get_recoil_compensation for why this replaces waiting out recoil.
	var comp := _get_recoil_compensation(wc)
	_current_body_y = target_body_y + _aim_noise_y - comp.y
	_current_head_x = target_head_x + _aim_noise_x - comp.x

	# Weapon-aware engagement distance (melee closes all the way in; ranged
	# weapons fight at roughly half their configured range) plus a slowly
	# re-rolled per-bot jitter, blended continuously with steering instead of
	# hard distance bands — removes the "always exactly N units away" feel.
	var desired_dist := maxf(_get_engagement_range(weapon) + _preferred_dist_offset, MELEE_ENGAGE_RANGE * 0.5)
	var sd := _steer_toward(_current_target.global_position)
	var radial := clampf((dist - desired_dist) / 4.0, -1.0, 1.0)
	sd = sd * 0.6 + Vector2(_strafe_dir, -radial) * 0.6
	sd = sd.normalized() if sd.length() > 0.001 else Vector2(_strafe_dir, 0.0)
	_apply_movement(sd)

	# Firing: the Trigger owns the flags and applies the aim gate.  `wants` only
	# expresses intent (reaction delay, and not blowing ourselves up point-blank).
	var wants := _reaction_timer <= 0.0 and not _too_close_for_explosive(fire, dist)
	if not wants and _reaction_timer <= 0.0:
		# Point-blank with a self-damaging explosive: draw a sidearm instead of
		# standing there aiming at the ground while backing away.
		var safe_index := _first_safe_weapon_index(wc, dist)
		if safe_index >= 0 and _switch_weapon(wc, safe_index):
			_trigger.release_all()
			return
	_trigger.request_fire(fire_index, wants)

func _act_heal() -> void:
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

	_current_body_y = atan2(-flat.x, -flat.z) + _aim_noise_y
	var aim_pos := _predict_target_pos(_heal_target, fire, dist)
	_desired_aim_point = aim_pos
	_has_desired_aim = true
	var to_aim := aim_pos - _head_node.global_position
	var flat_to_aim := Vector3(to_aim.x, 0, to_aim.z).length()
	_current_head_x = atan2(to_aim.y, maxf(flat_to_aim, 0.001)) + _aim_noise_x

	# Move to a comfortable heal distance; back off if hugging the target.
	var flat2 := Vector2(flat.x, flat.z)
	var sd: Vector2
	if dist > HEAL_RANGE * 0.7:
		sd = _steer_toward(_heal_target.global_position)
	elif dist < 3.0:
		var back_off := -flat2.normalized() if flat2.length() > 0.001 else Vector2.ZERO
		sd = _steer_toward(_heal_target.global_position) * 0.3 + back_off * 0.7
		if sd.length() > 0.001:
			sd = sd.normalized()
	else:
		sd = Vector2(_strafe_dir * 0.6, 0.0).normalized()
	_apply_movement(sd)

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
	var to_feet := feet - _head_node.global_position
	var flat_to_feet := Vector2(to_feet.x, to_feet.z).length()
	_current_head_x = atan2(to_feet.y, maxf(flat_to_feet, 0.001))
	# A self-heal is a standstill action; the head pitch does the aiming.
	_apply_movement(Vector2.ZERO)
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
	_current_body_y = atan2(-flat.x, -flat.z)
	_current_head_x = 0.0

	var sd := _steer_toward(_last_seen_position)
	_apply_movement(sd)
	player.player_input.jump_input = _last_seen_position.y > player.global_position.y + 1.5

func _act_wander() -> void:
	_trigger.release_all()
	_has_desired_aim = false

	var wc: WeaponController = player.weapon_controller
	if wc._is_ready() and not wc._is_reloading:
		var current_weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if current_weapon.mag_current < current_weapon.mag_size and not current_weapon.has_infinite_ammo:
			wc.start_reload()

	var to_wander := _wander_target - player.global_position
	var flat := Vector2(to_wander.x, to_wander.z)

	if flat.length() < 1.0:
		player.player_input.input_dir = Vector2.ZERO
		_pick_wander_target()
		return

	_current_body_y = atan2(-flat.x, -flat.y)
	_current_head_x = 0.0

	var sd := _steer_toward(_wander_target)
	_apply_movement(sd)


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
	lines.append("weapon: %s" % _debug_weapon_text())
	lines.append("scans: %d" % _full_scan_count)
	_debug_label.text = "\n".join(lines)


func _debug_state_text() -> String:
	if GameManager.dev_freeze_bots:
		return "frozen"
	if _force_wander_timer > 0.0:
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
	var effective := _mode_effective_range(fire)
	var score := 100.0
	# Prefer fighting around 75% of the mode's reach; heavily punish a mode
	# whose shots cannot reach the target at all.
	score -= 20.0 * absf(dist - effective * 0.75) / maxf(effective, 1.0)
	if dist > effective:
		score -= 200.0

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
	if fire.bullet_type == WeaponFire.BulletType.HITSCAN:
		if fire.hitscan_range >= 1.0e8:
			return SHOOT_RANGE
		return maxf(fire.hitscan_range, MELEE_CONSIDER_RANGE * 0.5)
	var info := _get_proj_info(fire)
	var speed := float(info.get("speed", 0.0))
	var lifetime := float(info.get("lifetime", 20.0))
	return clampf(speed * lifetime, 5.0, SHOOT_RANGE)


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
	if _current_target != null:
		dist = player.global_position.distance_to(_current_target.global_position)

	var can_reload_current := not cur.has_infinite_ammo and cur.mag_current < cur.mag_size

	# No immediate pressure — just reload in place instead of juggling weapons.
	if can_reload_current and not wc._is_reloading and dist > MELEE_CONSIDER_RANGE * 2.0:
		wc.start_reload()
		return

	# Under pressure: look for another weapon with ammo ready right now,
	# preferring anything ranged over melee.
	var fallback_melee := -1
	for i in wc._weapons.size():
		if i == wc.current_weapon_index:
			continue
		var w: Weapon = wc._weapons[i]
		if w.mag_current <= 0 and not w.has_infinite_ammo:
			continue
		if _is_melee_weapon(w):
			fallback_melee = i
			continue
		_switch_weapon(wc, i)
		return

	# Nothing but melee is ready. Only take it if we're already close (or
	# close enough that closing the rest of the gap is trivial) — otherwise
	# just reload and try to fight at range instead.
	if fallback_melee >= 0 and dist <= MELEE_CONSIDER_RANGE:
		_switch_weapon(wc, fallback_melee)
		return

	if can_reload_current and not wc._is_reloading:
		wc.start_reload()

## Reset bot-local state on a false -> true `player.spawned` edge.  `rpc_reset`
## resets the Player and its weapons but knows nothing about this controller, so
## a stale target/trigger from the previous life would otherwise survive.
func _reset_for_spawn() -> void:
	_trigger.release_all()
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
	_reaction_timer = 0.0
	_explosion_jump_cooldown_timer = 0.0
	_safe_top_off_timer = 0.0
	_enemy_nearby = false
	_last_position = player.global_position
	_stuck_check_timer = 0.0
	_stuck_jump_count = 0
	_force_wander_timer = 0.0
	_aim_noise_x = 0.0
	_aim_noise_y = 0.0
	_noise_timer = 0.0
	_has_desired_aim = false
	aim_error_deg = -1.0
	_refresh_los_excludes()


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
				_press_frames = BotController.SEMI_PRESS_FRAMES
				if fire.hold_required_for_pre_shoot_delay:
					# Releasing before the pre-shoot delay elapses cancels the
					# shot (Derringer).  Keep the flag down long enough for it.
					_press_frames = maxi(
						BotController.SEMI_PRESS_FRAMES,
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
				_wait_timer = maxf(wc._fire_cooldown, 0.0) + _skill_gap()
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
			_signal_press_frames = BotController.SIGNAL_PRESS_FRAMES
		elif bot._signal_mode == BotController.SignalMode.REDIRECT:
			if not bot._has_live_own_projectile():
				_special_pending = false
				return
			if not aim_open:
				return
			_signal_active = true
			_signal_press_frames = BotController.SIGNAL_PRESS_FRAMES
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
