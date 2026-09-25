extends Node
class_name BotController

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
@export_range(0.0, 1.0) var skill: float = 0.9

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
##   "speed": float, "heals_allies": bool }.
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

# Tuning constants

const SHOOT_RANGE: float          = 100.0
const HEAL_RANGE: float           = 60.0
const WANDER_RANGE: float         = 15.0
const CLOSE_ENOUGH: float         = 5.0
const PROCESS_INTERVAL: float     = 0.05
## How often the bot does a full re-scan for a new target.  Between scans it only
## re-verifies its current target's line-of-sight (1 raycast instead of N).
const RETARGET_INTERVAL: float    = 0.25
## A teammate below this HP fraction makes the bot switch to a heal weapon.
const MEDIC_HEAL_THRESHOLD: float = 0.5
## Bots only detect enemies within this horizontal field-of-view cone (degrees),
## centred on their facing direction.  Matches a human's ~120° peripheral vision.
const FOV_DEGREES: float = 120.0
## Aim tracking speed at skill 0 / skill 1 — low skill trails the target
## noticeably instead of only missing via spread noise.
const AIM_SMOOTH_MIN: float      = 3.0
const AIM_SMOOTH_MAX: float      = 8.0
## Path to the target's head bone — the `Physical Bone DEF-spine_006` hurtbox with
## `is_head = true` in player.tscn.  Bots aim at this bone's live world position
## rather than a fixed height, so headshots track the model's actual head.
const HEAD_BONE_PATH: String = "Body/Mannequin/mannequin/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-spine_006"
const NOISE_INTERVAL: float       = 0.4
## Max aim spread (radians) at skill 0; scaled to 0 at skill 1.
const AIM_NOISE_MAX: float        = 0.2
const FIRE_CHOICE_INTERVAL: float = 2.0
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

# Fire pulse (non-auto weapons)
const FIRE_PULSE_HOLD: float = 2.0
const FIRE_PULSE_GAP: float  = 0.15

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

# Runtime state

var _stuck_check_timer:  float = 0.0
var _last_position: Vector3    = Vector3.ZERO
var _stuck_jump_count: int     = 0
var _force_wander_timer: float = 0.0

var _strafe_dir: float   = 0.0
var _strafe_timer: float = 0.0

var _fire_pulse_timer: float = 0.0
var _fire_pulse_held:  bool  = false

var _timer: float              = 0.0
var _wander_target: Vector3    = Vector3.ZERO
var _current_target: Player    = null
var _heal_target: Player       = null
var _last_seen_position: Vector3 = Vector3.INF

var _retarget_timer: float        = 0.0
var _weapon_switch_guard: float   = 0.0
var _fov_dot_threshold: float     = 0.5  # cos(FOV_DEGREES / 2), set in _ready

var _aim_noise_y: float  = 0.0
var _aim_noise_x: float  = 0.0
var _noise_timer: float  = 0.0
var _current_body_y: float = 0.0
var _current_head_x: float = 0.0

var _chosen_fire_index: int   = 0
var _fire_choice_timer: float = 0.0

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

# Main loop

func _physics_process(delta: float) -> void:
	if not player.is_bot:
		return
	if not multiplayer.is_server():
		return
	if not player.spawned:
		return

	# Stunned, pinned, or mid-channel bots cannot move, aim, or fire.
	if player.status_effect_manager and (player.status_effect_manager.is_stunned() or player.status_effect_manager.is_pinned() or player.status_effect_manager.is_action_blocked()):
		player.player_input.input_dir = Vector2.ZERO
		player.player_input.jump_input = false
		_clear_fire_inputs()
		return

	_apply_smooth_aim(delta)
	_tick_fire_pulse(delta)

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
		_force_wander_timer -= PROCESS_INTERVAL
		var sd := _steer_toward(_wander_target)
		_apply_movement(sd)
		return

	_tick_stuck_detection()
	_tick_strafe()
	_tick_preferred_distance()

	if _reaction_timer > 0.0:
		_reaction_timer -= PROCESS_INTERVAL
	if _explosion_jump_cooldown_timer > 0.0:
		_explosion_jump_cooldown_timer -= PROCESS_INTERVAL

	_noise_timer += PROCESS_INTERVAL
	if _noise_timer >= NOISE_INTERVAL:
		_noise_timer = 0.0
		var spread := AIM_NOISE_MAX * (1.0 - skill)
		_aim_noise_y = randf_range(-spread, spread)
		_aim_noise_x = randf_range(-spread, spread)

	_fire_choice_timer += PROCESS_INTERVAL
	if _fire_choice_timer >= FIRE_CHOICE_INTERVAL:
		_fire_choice_timer = 0.0
		_choose_fire_mode()

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

# Fire pulse

func _tick_fire_pulse(delta: float) -> void:
	if _fire_pulse_timer <= 0.0:
		return
	_fire_pulse_timer -= delta
	if _fire_pulse_timer <= 0.0:
		if _fire_pulse_held:
			_fire_pulse_held = false
			_fire_pulse_timer = FIRE_PULSE_GAP
			_clear_fire_inputs()

func _start_fire_pulse() -> void:
	if _fire_pulse_timer > 0.0:
		return
	_fire_pulse_held = true
	_fire_pulse_timer = FIRE_PULSE_HOLD
	match _chosen_fire_index:
		0: player.player_input.primary_fire_held = true
		1: player.player_input.secondary_fire_held = true
		2: player.player_input.tertiary_fire_held = true

# Think

func _think() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		_current_target = null
		_heal_target = null
		return

	var weapon := wc._weapons[wc.current_weapon_index]
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
	var prev_target := _current_target
	_current_target = null
	_heal_target = null

	var closest_dist_sq := SHOOT_RANGE * SHOOT_RANGE
	var heal_dist_sq := HEAL_RANGE * HEAL_RANGE
	var heal_best_ratio := 2.0

	for node in get_tree().get_nodes_in_group("players"):
		var p := node as Player
		if p == null or p == player or not p.spawned:
			continue
		var is_enemy := player.team == Player.Team.FFA or p.team != player.team
		var dist_sq := player.global_position.distance_squared_to(p.global_position)

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
			# Friendly heal candidate — only teammates who actually need HP.
			var ac := p.attribute_component
			if ac == null or ac.health >= ac.starting_health:
				continue
			var ratio := ac.health / ac.starting_health
			if dist_sq < heal_dist_sq and ratio < heal_best_ratio and _has_line_of_sight_to_player(p):
				heal_best_ratio = ratio
				_heal_target = p

	# Medic behaviour: put the heal gun away when nobody needs healing, and pull
	# it out when a teammate is critically hurt.
	if holding_heal and _heal_target == null and heal_index >= 0:
		_switch_weapon(wc, _first_damage_weapon_index(wc))
	elif not holding_heal and heal_index >= 0 and _heal_target != null:
		var ac := _heal_target.attribute_component
		if ac != null and ac.health / ac.starting_health < MEDIC_HEAL_THRESHOLD:
			if _switch_weapon(wc, heal_index):
				_current_target = null  # don't fight while healing

	if _current_target != null:
		# Only a genuinely new target starts the reaction-delay clock — losing
		# and re-verifying the same target every RETARGET_INTERVAL shouldn't
		# make a skill-0 bot re-hesitate on someone it's already shooting.
		if _current_target != prev_target:
			_reaction_timer = REACTION_TIME_MAX * (1.0 - skill)
		_last_seen_position = _current_target.global_position

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
func _targets_valid() -> bool:
	if _current_target != null:
		if not is_instance_valid(_current_target) or not _current_target.spawned:
			return false
		if not _is_enemy_of(_current_target):
			return false
		if _current_target.status_effect_manager and _current_target.status_effect_manager.has_effect("invisible"):
			return false
		return _has_line_of_sight_to_player(_current_target)
	if _heal_target != null:
		if not is_instance_valid(_heal_target) or not _heal_target.spawned:
			return false
		var ac := _heal_target.attribute_component
		if ac == null or ac.health >= ac.starting_health:
			return false
		return _has_line_of_sight_to_player(_heal_target)
	return false


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
	return bool(_get_proj_info(fire).get("heals_allies", false))


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

	var info := {"speed": 0.0, "heals_allies": false, "is_explosive": false}

	# Prefer speed declared on the fire config itself — it's the value the
	# weapon actually fires with and needs no scene instantiation at all.
	var fire_speed = fire.get("projectile_speed")
	if fire_speed == null:
		fire_speed = fire.get("speed")

	var proj := fire.projectile_scene.instantiate() as Node3D
	if proj != null:
		if fire_speed != null:
			info["speed"] = float(fire_speed)
		else:
			var exported_speed = proj.get("speed")
			if exported_speed == null:
				exported_speed = proj.get("projectile_speed")
			if exported_speed != null:
				info["speed"] = float(exported_speed)
			else:
				# Last-resort fallback — kept only so this doesn't regress to
				# a hard 0 if nothing above matched; this is the old,
				# unreliable read and will likely still report 0.
				var lv = proj.get("linear_velocity")
				if lv is Vector3:
					info["speed"] = (lv as Vector3).length()

		var hb := proj.get_node_or_null("HitboxComponent") as HitboxComponent
		if hb != null:
			info["heals_allies"] = hb.health_delta > 0.0 and hb.can_hit_other_teamates

		# Explosive/splash detection is likewise duck-typed since the exact
		# component name/property isn't known here — adjust to match your
		# actual explosion component if this misses.
		var explosion_node := proj.get_node_or_null("ExplosionComponent")
		if explosion_node == null:
			explosion_node = proj.get_node_or_null("SplashComponent")
		var splash_radius = proj.get("splash_radius")
		info["is_explosive"] = explosion_node != null or (splash_radius != null and float(splash_radius) > 0.0)

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
## Explosive/splash weapons aim at the target's feet (`global_position`)
## instead of the head — splash means a near-miss on the ground still hits,
## and it's a much bigger, more reliable target than a headshot bone.
func _predict_target_pos(target: Player, fire: WeaponFire, flat_dist: float, aim_at_feet: bool = false) -> Vector3:
	var pos := target.global_position if aim_at_feet else _get_head_position(target)
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
		var explicit_flag = fire.get("is_melee")
		if explicit_flag is bool and explicit_flag:
			return true
		var configured_range = fire.get("max_range")
		if configured_range == null:
			configured_range = fire.get("range")
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
	if _is_melee_weapon(weapon):
		return MELEE_ENGAGE_RANGE
	for fire in weapon.weapon_fires:
		if fire == null:
			continue
		var r = fire.get("max_range")
		if r == null:
			r = fire.get("range")
		if r != null and float(r) > 0.0:
			return clampf(float(r), MELEE_CONSIDER_RANGE, MAX_SENSIBLE_RANGE) * 0.5
	return DEFAULT_RANGED_ENGAGE_DIST


func _switch_weapon(wc: WeaponController, index: int) -> bool:
	if index < 0 or index >= wc._weapons.size() or index == wc.current_weapon_index:
		return false
	if _weapon_switch_guard > 0.0:
		return false
	_weapon_switch_guard = 1.0
	wc.current_weapon_index = index
	_chosen_fire_index = 0
	_fire_choice_timer = 0.0
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
	var fire_index := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
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
	_try_fire_current_weapon(wc)
	player.player_input.jump_input = true
	_explosion_jump_cooldown_timer = EXPLOSION_JUMP_COOLDOWN
	return true

# Act

func _act() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return
	var weapon := wc._weapons[wc.current_weapon_index]

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

	_clear_fire_inputs()
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
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		return
	var fire_index := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
	var fire: WeaponFire = weapon.weapon_fires[fire_index]

	var to_target := _current_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	# Aim at the target's head bone — or its feet for splash weapons, where a
	# near-miss on the ground still counts and the target area is far bigger
	# — leading moving targets for projectiles, aiming the bone directly for
	# hitscan (headshots register a crit when the weapon has one).
	var is_explosive: bool = bool(_get_proj_info(fire).get("is_explosive", false))
	var aim_pos: Vector3 = _get_head_position(_current_target)
	if fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		aim_pos = _predict_target_pos(_current_target, fire, dist, is_explosive)
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

	if _reaction_timer <= 0.0:
		_try_fire_current_weapon(wc)
	else:
		_clear_fire_inputs()

func _act_heal() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return

	var weapon := wc._weapons[wc.current_weapon_index]
	if weapon.weapon_fires.is_empty():
		return
	var fire_index := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
	var fire: WeaponFire = weapon.weapon_fires[fire_index]

	var to_target := _heal_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_current_body_y = atan2(-flat.x, -flat.z) + _aim_noise_y
	var aim_pos := _predict_target_pos(_heal_target, fire, dist)
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

	_try_fire_current_weapon(wc)

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

	_clear_fire_inputs()
	_current_body_y = atan2(-flat.x, -flat.z)
	_current_head_x = 0.0

	var sd := _steer_toward(_last_seen_position)
	_apply_movement(sd)
	player.player_input.jump_input = _last_seen_position.y > player.global_position.y + 1.5

func _act_wander() -> void:
	_clear_fire_inputs()

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


## Fire the current weapon at the current aim, with reload gating. Recoil is
## handled by compensating the aim (see _get_recoil_compensation) rather than
## pausing fire, so it scales with skill instead of stalling every bot alike.
## Shared by combat and heal paths.
func _try_fire_current_weapon(wc: WeaponController) -> void:
	var weapon := wc._weapons[wc.current_weapon_index]

	if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
		_clear_fire_inputs()
		_bot_find_ammo_or_reload(wc)
		return

	var is_auto := false
	if _chosen_fire_index < weapon.weapon_fires.size():
		is_auto = weapon.weapon_fires[_chosen_fire_index].automatic

	if is_auto:
		_clear_fire_inputs()
		match _chosen_fire_index:
			0: player.player_input.primary_fire_held = true
			1: player.player_input.secondary_fire_held = true
			2: player.player_input.tertiary_fire_held = true
	else:
		_clear_fire_inputs()
		_start_fire_pulse()

# Helpers

func _choose_fire_mode() -> void:
	if not player.weapon_controller._is_ready():
		return
	var wc := player.weapon_controller
	var weapon: Weapon = wc._weapons[wc.current_weapon_index]
	var available: Array[int] = []
	for i in weapon.weapon_fires.size():
		var wf: WeaponFire = weapon.weapon_fires[i]
		if wf.action_type != WeaponFire.ActionType.SHOOT:
			continue
		if not weapon.has_infinite_ammo and weapon.mag_current < wf.ammo_cost:
			continue
		available.append(i)
	_chosen_fire_index = available[randi() % available.size()] if not available.is_empty() else 0

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

func _clear_fire_inputs() -> void:
	player.player_input.primary_fire_held = false
	player.player_input.secondary_fire_held = false
	player.player_input.tertiary_fire_held = false
