extends Node
class_name BotController

## Raycast-based bot AI.  No navmesh required — bots probe the world
## around them with raycasts and steer toward the clearest path.
## Also seeks objectives (control points, payload) when no enemy is visible.
## Works on any map geometry automatically.

@export var player: Player

# Tuning constants

const SHOOT_RANGE: float          = 100.0
const WANDER_RANGE: float         = 15.0
const CLOSE_ENOUGH: float         = 5.0
const PROCESS_INTERVAL: float     = 0.05
const AIM_SMOOTH: float           = 8.0
const RECOIL_THRESHOLD: float     = 0.17
const NOISE_INTERVAL: float       = 0.4
const AIM_NOISE: float            = 0.08
const FIRE_CHOICE_INTERVAL: float = 2.0

# Stuck detection
const STUCK_CHECK_INTERVAL: float    = 0.5
const STUCK_DISTANCE_THRESHOLD: float = 0.3
const STUCK_JUMP_ATTEMPTS: int        = 2

# Steering
const STEER_DISTANCE: float       = 8.0
const STEER_ANGLES: Array[float]  = [-60, -30, -10, 0, 10, 30, 60]
const STEER_RAY_HEIGHT: float     = 0.5
const WALL_FOLLOW_DISTANCE: float = 3.0

# Strafing
const STRAFE_CHANGE_INTERVAL: float = 1.5

# Fire pulse (non-auto weapons)
const FIRE_PULSE_HOLD: float = 2.0
const FIRE_PULSE_GAP: float  = 0.15

# Runtime state

var _recoil_block_timer: float = 0.0
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
var _last_seen_position: Vector3 = Vector3.INF

var _aim_noise_y: float  = 0.0
var _aim_noise_x: float  = 0.0
var _noise_timer: float  = 0.0
var _current_body_y: float = 0.0
var _current_head_x: float = 0.0

var _chosen_fire_index: int   = 0
var _fire_choice_timer: float = 0.0

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

	_apply_smooth_aim(delta)
	_tick_fire_pulse(delta)

	if _force_wander_timer > 0.0:
		_force_wander_timer -= delta
		var sd := _steer_toward(_wander_target)
		_apply_movement(sd)
		return

	_timer += delta
	if _timer < PROCESS_INTERVAL:
		return
	_timer = 0.0

	_tick_stuck_detection()
	_tick_strafe()

	_noise_timer += PROCESS_INTERVAL
	if _noise_timer >= NOISE_INTERVAL:
		_noise_timer = 0.0
		_aim_noise_y = randf_range(-AIM_NOISE, AIM_NOISE)
		_aim_noise_x = randf_range(-AIM_NOISE, AIM_NOISE)

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

	var best_dir := flat_desired
	var best_score := -9999.0

	for angle in STEER_ANGLES:
		var rad := deg_to_rad(angle)
		var test_dir := flat_desired.rotated(rad)
		var score := _score_direction(origin, test_dir)
		score += (1.0 - abs(angle) / 90.0) * 2.0
		if score > best_score:
			best_score = score
			best_dir = test_dir

	_last_steer_dir = best_dir

	var center_score := _score_direction(origin, flat_desired)
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
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.exclude = [player.get_rid()]
	query.collision_mask = (1 << 0)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
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
	player.body.rotation.y = lerp_angle(
		player.body.rotation.y, _current_body_y, AIM_SMOOTH * delta
	)
	var head_node: Node3D = player.get_node("%Head") as Node3D
	head_node.rotation.x = lerp_angle(
		head_node.rotation.x, _current_head_x, AIM_SMOOTH * delta
	)

# Strafing

func _tick_strafe() -> void:
	_strafe_timer -= PROCESS_INTERVAL
	if _strafe_timer <= 0.0:
		_strafe_timer = STRAFE_CHANGE_INTERVAL
		var roll := randi() % 3
		_strafe_dir = [-1.0, 0.0, 1.0][roll]

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
	_current_target = null
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return
	var weapon := wc._weapons[wc.current_weapon_index]
	var safe_idx := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
	var range_limit := SHOOT_RANGE
	if safe_idx < weapon.weapon_fires.size():
		range_limit = minf(SHOOT_RANGE, weapon.weapon_fires[safe_idx].hitscan_range)
	var closest_dist := range_limit
	for p in get_tree().get_nodes_in_group("players"):
		if p == player or not p.spawned or p.team == player.team:
			continue
		var dist := player.global_position.distance_to(p.global_position)
		if dist < closest_dist and _has_line_of_sight_to_player(p):
			closest_dist = dist
			_current_target = p
	if _current_target != null:
		_last_seen_position = _current_target.global_position

# Line-of-sight

func _has_line_of_sight_to_player(target: Player) -> bool:
	var head: Node3D = player.get_node("%Head") as Node3D
	var space := player.get_world_3d().direct_space_state
	var origin := head.global_position
	var target_pos := target.global_position + Vector3(0, 0.5, 0)
	var query := PhysicsRayQueryParameters3D.create(origin, target_pos)
	query.exclude = [player.get_rid()]
	query.collision_mask = (1 << 0)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return space.intersect_ray(query).is_empty()

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

# Act

func _act() -> void:
	if _current_target != null:
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

	_clear_fire_inputs()
	_current_body_y = atan2(-(obj.x - player.global_position.x), -(obj.z - player.global_position.z))
	_current_head_x = 0.0
	var sd := _steer_toward(obj)
	_apply_movement(sd)

	var wc: WeaponController = player.weapon_controller
	if wc._is_ready() and not wc._is_reloading:
		var cw: Weapon = wc._weapons[wc.current_weapon_index]
		if cw.mag_current < cw.mag_size and not cw.has_infinite_ammo:
			wc.start_reload()

func _act_combat() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return

	var to_target := _current_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_current_body_y = atan2(-flat.x, -flat.z) + _aim_noise_y

	var head_pos: Vector3 = (player.get_node("%Head") as Node3D).global_position
	var weapon := wc._weapons[wc.current_weapon_index]
	var safe_idx := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
	var aims_for_head := weapon.weapon_fires[safe_idx].headshot_multiplier > 1.0
	var aim_offset := Vector3(0, 0.7, 0) if aims_for_head else Vector3(0, 0.2, 0)
	var target_pos := _current_target.global_position + aim_offset
	var to_aim := target_pos - head_pos
	_current_head_x = atan2(to_aim.y, flat.length()) + _aim_noise_x

	var sd := _steer_toward(_current_target.global_position)
	if dist > 8.0:
		sd = (sd + Vector2(_strafe_dir * 0.2, -1.0)).normalized()
	elif dist > 3.0:
		sd = (sd * 0.5 + Vector2(_strafe_dir, 0.0)).normalized()
	else:
		sd = Vector2(_strafe_dir * 0.4, 1.0).normalized()
	_apply_movement(sd)

	var r: Vector3 = wc.recoil.rotation
	var recoil_magnitude: float = abs(r.x) * 1.5 + abs(r.y) + abs(r.z) * 0.5
	if recoil_magnitude > RECOIL_THRESHOLD:
		_recoil_block_timer = 0.05
		_clear_fire_inputs()
		return

	if _recoil_block_timer > 0.0:
		_recoil_block_timer -= PROCESS_INTERVAL
		_clear_fire_inputs()
		return

	var current_weapon: Weapon = wc._weapons[wc.current_weapon_index]
	if current_weapon.mag_current <= 0 and not current_weapon.has_infinite_ammo:
		_clear_fire_inputs()
		_bot_find_ammo_or_reload(wc)
		return

	var is_auto := false
	if _chosen_fire_index < current_weapon.weapon_fires.size():
		is_auto = current_weapon.weapon_fires[_chosen_fire_index].automatic

	if is_auto:
		_clear_fire_inputs()
		match _chosen_fire_index:
			0: player.player_input.primary_fire_held = true
			1: player.player_input.secondary_fire_held = true
			2: player.player_input.tertiary_fire_held = true
	else:
		_clear_fire_inputs()
		_start_fire_pulse()

func _act_pursue_last_seen() -> void:
	_clear_fire_inputs()
	var to_last := _last_seen_position - player.global_position
	var flat := Vector3(to_last.x, 0, to_last.z)
	var dist := flat.length()

	if dist < CLOSE_ENOUGH:
		_last_seen_position = Vector3.INF
		_pick_wander_target()
		return

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

func _bot_find_ammo_or_reload(wc: WeaponController) -> void:
	for i in wc._weapons.size():
		if i == wc.current_weapon_index:
			continue
		var w: Weapon = wc._weapons[i]
		if w.mag_current > 0 or w.has_infinite_ammo:
			wc.current_weapon_index = i
			_chosen_fire_index = 0
			_fire_choice_timer = 0.0
			return
	if not wc._is_reloading:
		for i in wc._weapons.size():
			var w: Weapon = wc._weapons[i]
			if w.mag_current < w.mag_size and not w.has_infinite_ammo:
				wc.current_weapon_index = i
				_chosen_fire_index = 0
				_fire_choice_timer = 0.0
				wc.start_reload()
				return

func _clear_fire_inputs() -> void:
	player.player_input.primary_fire_held = false
	player.player_input.secondary_fire_held = false
	player.player_input.tertiary_fire_held = false
