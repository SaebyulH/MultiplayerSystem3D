extends Node
class_name BotController

@export var player: Player
var _recoil_block_timer := 0.0
const RECOIL_BLOCK_TIME := 0.05
const AIM_NOISE: float = 0.08
const SHOOT_RANGE: float = 100.0
const WANDER_RANGE: float = 15.0
const RECOIL_THRESHOLD: float = 0.17
const PROCESS_INTERVAL: float = 0.05
const AIM_SMOOTH: float = 8.0
const CLOSE_ENOUGH: float = 5.0
const NOISE_INTERVAL: float = 0.4
const FIRE_CHOICE_INTERVAL: float = 2.0

# Stuck detection
const STUCK_CHECK_INTERVAL: float = 0.5
const STUCK_DISTANCE_THRESHOLD: float = 0.3
const STUCK_JUMP_ATTEMPTS: float = 2
var _stuck_check_timer: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _stuck_jump_count: int = 0
var _force_wander_timer: float = 0.0

# Strafing
var _strafe_dir: float = 0.0
var _strafe_timer: float = 0.0
const STRAFE_CHANGE_INTERVAL: float = 1.5

# Non-auto fire pulsing
var _fire_pulse_timer: float = 0.0
var _fire_pulse_held: bool = false
const FIRE_PULSE_HOLD: float = 2.0  # how long to hold the trigger
const FIRE_PULSE_GAP: float = 0.15    # how long to release before next shot

var _timer: float = 0.0
var _wander_target: Vector3 = Vector3.ZERO
var _current_target: Player = null
var _last_seen_position: Vector3 = Vector3.INF
var _aim_noise_y: float = 0.0
var _aim_noise_x: float = 0.0
var _noise_timer: float = 0.0
var _current_body_y: float = 0.0
var _current_head_x: float = 0.0
var _chosen_fire_index: int = 0
var _fire_choice_timer: float = 0.0

func _physics_process(delta: float) -> void:
	if not player.is_bot:
		return
	if not multiplayer.is_server():
		return
	if not player.spawned:
		return

	_apply_smooth_aim(delta)
	_tick_fire_pulse(delta)

	# Force wander timer overrides everything
	if _force_wander_timer > 0.0:
		_force_wander_timer -= delta
		_act_wander()
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

# -------------------------------------------------------------------------
# Stuck detection
# -------------------------------------------------------------------------
func _tick_stuck_detection() -> void:
	_stuck_check_timer += PROCESS_INTERVAL
	if _stuck_check_timer < STUCK_CHECK_INTERVAL:
		return
	_stuck_check_timer = 0.0

	var moved := player.global_position.distance_to(_last_position)
	_last_position = player.global_position

	# Only care about stuck when we're trying to move somewhere
	var is_trying_to_move := player.player_input.input_dir.length() > 0.1
	if not is_trying_to_move:
		_stuck_jump_count = 0
		return

	if moved < STUCK_DISTANCE_THRESHOLD:
		_stuck_jump_count += 1
		if _stuck_jump_count <= STUCK_JUMP_ATTEMPTS:
			# Try jumping over the obstacle
			player.player_input.jump_input = true
		else:
			# Still stuck after jumping — abandon and wander somewhere else
			player.body.rotate_y(2*PI)
			_stuck_jump_count = 0
			_force_wander_timer = 5.0
			player.player_input.jump_input = false
			_pick_wander_target()
			print("[%s] stuck! forcing wander" % player.name)
	else:
		_stuck_jump_count = 0
		player.player_input.jump_input = false

func _apply_smooth_aim(delta: float) -> void:
	player.body.rotation.y = lerp_angle(
		player.body.rotation.y, _current_body_y, AIM_SMOOTH * delta
	)
	player.get_node("%Head").rotation.x = lerp_angle(
		player.get_node("%Head").rotation.x, _current_head_x, AIM_SMOOTH * delta
	)

# -------------------------------------------------------------------------
# Strafing
# -------------------------------------------------------------------------
func _tick_strafe() -> void:
	_strafe_timer -= PROCESS_INTERVAL
	if _strafe_timer <= 0.0:
		_strafe_timer = STRAFE_CHANGE_INTERVAL
		# Randomly pick left, right, or no strafe
		var roll := randi() % 3
		_strafe_dir = [-1.0, 0.0, 1.0][roll]

# -------------------------------------------------------------------------
# Non-auto fire pulse
# -------------------------------------------------------------------------
func _tick_fire_pulse(delta: float) -> void:
	if _fire_pulse_timer <= 0.0:
		return
	_fire_pulse_timer -= delta
	if _fire_pulse_timer <= 0.0:
		if _fire_pulse_held:
			# End of hold — release and start gap
			_fire_pulse_held = false
			_fire_pulse_timer = FIRE_PULSE_GAP
			_clear_fire_inputs()
		# End of gap — do nothing, next shot triggered by _act_combat

func _start_fire_pulse() -> void:
	if _fire_pulse_timer > 0.0:
		return  # already mid-pulse
	_fire_pulse_held = true
	_fire_pulse_timer = FIRE_PULSE_HOLD
	match _chosen_fire_index:
		0: player.player_input.primary_fire_held = true
		1: player.player_input.secondary_fire_held = true
		2: player.player_input.tertiary_fire_held = true

# -------------------------------------------------------------------------
# Think
# -------------------------------------------------------------------------
func _think() -> void:
	_current_target = null
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return
	var weapon := wc._weapons[wc.current_weapon_index]
	var safe_fire_index := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
	var range_limit := SHOOT_RANGE
	if safe_fire_index < weapon.weapon_fires.size():
		range_limit = minf(SHOOT_RANGE, weapon.weapon_fires[safe_fire_index].hitscan_range)
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

# -------------------------------------------------------------------------
# LOS / path checks
# -------------------------------------------------------------------------
func _has_line_of_sight_to_player(target: Player) -> bool:
	var head: Node3D = player.get_node("%Head")
	var space := player.get_world_3d().direct_space_state
	var origin := head.global_position
	var target_pos := target.global_position + Vector3(0, 0.5, 0)
	var query := PhysicsRayQueryParameters3D.create(origin, target_pos)
	query.exclude = [player.get_rid()]
	query.collision_mask = (1 << 0)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return space.intersect_ray(query).is_empty()

func _has_clear_path_to(world_pos: Vector3) -> bool:
	var space := player.get_world_3d().direct_space_state
	var origin := player.global_position + Vector3(0, 0.5, 0)
	var query := PhysicsRayQueryParameters3D.create(origin, world_pos)
	query.exclude = [player.get_rid()]
	query.collision_mask = (1 << 0)
	var result := space.intersect_ray(query)
	return result.is_empty()

# -------------------------------------------------------------------------
# Act
# -------------------------------------------------------------------------
func _act() -> void:
	if _current_target != null:
		_act_combat()
	elif _last_seen_position != Vector3.INF:
		_act_pursue_last_seen()
	else:
		_act_wander()

func _act_combat() -> void:
	var wc: WeaponController = player.weapon_controller
	if not wc._is_ready():
		return

	var to_target := _current_target.global_position - player.global_position
	var flat := Vector3(to_target.x, 0, to_target.z)
	var dist := flat.length()

	_current_body_y = atan2(-flat.x, -flat.z) + _aim_noise_y

	var head_pos :Vector3= player.get_node("%Head").global_position
	var weapon := wc._weapons[wc.current_weapon_index]
	var safe_fire_index := clampi(_chosen_fire_index, 0, weapon.weapon_fires.size() - 1)
	var aims_for_head := weapon.weapon_fires[safe_fire_index].headshot_multiplier > 1.0
	var aim_offset := Vector3(0, 0.7, 0) if aims_for_head else Vector3(0, 0.2, 0)
	var target_pos := _current_target.global_position + aim_offset
	var to_aim := target_pos - head_pos
	_current_head_x = atan2(to_aim.y, flat.length()) + _aim_noise_x

	# Move: approach if far, strafe if close
	if dist > 8.0:
		player.player_input.input_dir = Vector2(_strafe_dir * 0.4, -1.0).normalized()
	elif dist > 3.0:
		player.player_input.input_dir = Vector2(_strafe_dir, 0.0)
	else:
		# Too close — back up
		player.player_input.input_dir = Vector2(_strafe_dir * 0.4, 1.0).normalized()

	# Weapon management
	var r := wc.recoil.rotation
	var recoil_magnitude :float = abs(r.x) * 1.5 + abs(r.y) + abs(r.z) * 0.5 #Math is that it should return all xyz added i think
	if recoil_magnitude > RECOIL_THRESHOLD:
		_recoil_block_timer = RECOIL_BLOCK_TIME
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

	# Check if weapon is automatic
	var is_auto := false
	if _chosen_fire_index < current_weapon.weapon_fires.size():
		is_auto = current_weapon.weapon_fires[_chosen_fire_index].automatic

	if is_auto:
		# Hold fire continuously
		_clear_fire_inputs()
		match _chosen_fire_index:
			0: player.player_input.primary_fire_held = true
			1: player.player_input.secondary_fire_held = true
			2: player.player_input.tertiary_fire_held = true
	else:
		# Pulse fire for non-auto weapons
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

	if _has_clear_path_to(_last_seen_position):
		player.player_input.input_dir = Vector2(0.0, -1.0)
		player.player_input.jump_input = _last_seen_position.y > player.global_position.y + 1.5
	else:
		_act_wander()

func _act_wander() -> void:
	_clear_fire_inputs()

	var wc: WeaponController = player.weapon_controller
	if wc._is_ready() and not wc._is_reloading:
		var current_weapon: Weapon = wc._weapons[wc.current_weapon_index]
		if current_weapon.mag_current < current_weapon.mag_size and not current_weapon.has_infinite_ammo:
			wc.start_reload()

	var to_wander := _wander_target - player.global_position
	var flat := Vector3(to_wander.x, 0, to_wander.z)

	if flat.length() < 1.0:
		player.player_input.input_dir = Vector2.ZERO
		_pick_wander_target()
		return

	_current_body_y = atan2(-flat.x, -flat.z)
	_current_head_x = 0.0
	player.player_input.input_dir = Vector2(0.0, -1.0)

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
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
	_wander_target = player.global_position + Vector3(
		randf_range(-WANDER_RANGE, WANDER_RANGE),
		0.0,
		randf_range(-WANDER_RANGE, WANDER_RANGE)
	)

func _bot_find_ammo_or_reload(wc: WeaponController) -> void:
	for i in wc._weapons.size():
		if i == wc.current_weapon_index:
			continue
		var w: Weapon = wc._weapons[i]
		if w.mag_current > 0 or w.has_infinite_ammo:
			wc.current_weapon_index = i
			_chosen_fire_index = 0  # ← reset when switching weapon
			_fire_choice_timer = 0.0  # ← force re-choose next tick
			return
	if not wc._is_reloading:
		for i in wc._weapons.size():
			var w: Weapon = wc._weapons[i]
			if w.mag_current < w.mag_size and not w.has_infinite_ammo:
				wc.current_weapon_index = i
				_chosen_fire_index = 0  # ← reset here too
				_fire_choice_timer = 0.0
				wc.start_reload()
				return

func _clear_fire_inputs() -> void:
	player.player_input.primary_fire_held = false
	player.player_input.secondary_fire_held = false
	player.player_input.tertiary_fire_held = false
