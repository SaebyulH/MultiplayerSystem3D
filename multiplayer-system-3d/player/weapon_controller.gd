class_name WeaponController extends Node

# ---------------------------------------------------------------------------
# Architecture notes
# ---------------------------------------------------------------------------
# Fire authority model:
#   • PlayerInput.fire_held / fire_just_released are NOT in the rollback
#     synchronizer. Netfox would stomp them on re-simulation ticks.
#     WeaponController reads them raw in _physics_process every frame.
#   • The OWNING CLIENT runs _process_fire() every physics frame.
#     It maintains its own cooldown/pending state for responsiveness.
#     When the gate passes it sends fire_intent.rpc_id(1).
#   • The SERVER re-validates everything in fire_intent before acting.
#     Ammo is only deducted once — authoritatively on the server.
#     The client UI optimistically shows -1 mag; the server corrects via
#     mag_changed if it rejects the shot.
#   • Host-as-player skips the RPC and calls fire_intent() directly,
#     but uses a separate code path so it never pre-sets _fire_cooldown
#     before the server validation gate runs.
# ---------------------------------------------------------------------------

var _is_reloading: bool     = false
var _reload_timer: float    = 0.0
var _pending_fire: bool     = false
var _pre_fire_timer: float  = 0.0
var _fire_cooldown: float   = 0.0
var _fired_this_press: bool = false

signal mag_changed(current: int, mag_max: int)
signal weapon_changed(index: int, weapon: Weapon)

@export var weapons: Array[Weapon]

@export var current_weapon_index: int = 0:
	set(value):
		if value == current_weapon_index:
			return
		current_weapon_index = clamp(value, 0, weapons.size() - 1)
		_on_weapon_index_changed()
		_emit_weapon_changed()

@export var weapon_model_parent: Node3D
@export var projectile_spawn_parent: Node3D
@export var player_input: PlayerInput
@export var recoil: Recoil
@export var _parent_player: Player
@export var _raycast: RayCast3D

var current_weapon_model: Node3D = null
var _reset_weapons: Array[Weapon]


func reset() -> void:
	current_weapon_index = 0
	# Re-deep-copy from the originals so mag counts return to full
	var fresh: Array[Weapon] = []
	for w: Weapon in _reset_weapons:
		fresh.append(w.duplicate(true) as Weapon)
	weapons = fresh


func _set_mag(value: int) -> void:
	var weapon: Weapon = weapons[current_weapon_index]
	weapon.mag_current = clamp(value, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)


func _emit_weapon_changed() -> void:
	var weapon: Weapon = weapons[current_weapon_index]
	weapon_changed.emit(current_weapon_index, weapon)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Deep-copy every Weapon resource so this WeaponController instance owns
	# its own mutable state. Without this, both the client-side and server-side
	# WeaponController nodes share the same Weapon objects in memory, causing
	# mag_current mutations from one peer to silently affect the other.
	# Each WeaponController gets its own deep copy so client/server mutations
	# never share the same Resource object.
	var deep_weapons: Array[Weapon] = []
	var orig_weapons: Array[Weapon] = []
	for w: Weapon in weapons:
		var copy: Weapon = w.duplicate(true) as Weapon
		deep_weapons.append(copy)
		# Keep a second independent copy as the reset baseline BEFORE any mutation
		orig_weapons.append(w.duplicate(true) as Weapon)
	weapons        = deep_weapons
	_reset_weapons = orig_weapons

	if not weapons.is_empty() and weapons[current_weapon_index] != null:
		spawn_weapon_model()

	player_input.previous_weapon.connect(previous_weapon)
	player_input.next_weapon.connect(next_weapon)
	player_input.reload.connect(start_reload)

	_apply_recoil_data()


func _physics_process(delta: float) -> void:
	_align_weapon_to_raycast()
	_tick_timers(delta)

	# Only the owning peer drives fire input — not the server on behalf of others
	var my_id: int     = multiplayer.get_unique_id()
	var owner_id: int  = _parent_player.name.to_int()
	if my_id == owner_id:
		_process_fire()

	# Consume the one-frame release flag
	if player_input.fire_just_released:
		
		_fired_this_press          = false
		player_input.fire_just_released = false


func _tick_timers(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

	# Reload timer only ticks on the server — completion is broadcast via RPC
	if is_multiplayer_authority() and _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()

	if _pending_fire:
		if player_input.fire_held:
			_pre_fire_timer -= delta
		else:
			# optional: cancel if they released early
			_pending_fire = false

		if _pre_fire_timer <= 0.0:
			_pending_fire = false
			if multiplayer.is_server():
				fire_intent(current_weapon_index)
			else:
				_do_fire_client()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _apply_recoil_data() -> void:
	var data: RecoilData = weapons[current_weapon_index].recoil_data
	recoil.recoil       = data.recoil
	recoil.aim_recoil   = data.aim_recoil
	recoil.snappiness   = data.snappiness
	recoil.return_speed = data.return_speed


func _play_sound(stream: AudioStream) -> void:
	if stream == null:
		return
	var player: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	player.stream           = stream
	player.global_transform = weapon_model_parent.global_transform
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


func spawn_weapon_model() -> void:
	if current_weapon_model != null:
		current_weapon_model.queue_free()
		current_weapon_model = null
	var weapon: Weapon = weapons[current_weapon_index]
	if weapon.weapon_model == null:
		return
	current_weapon_model          = weapon.weapon_model.instantiate() as Node3D
	current_weapon_model.position = weapon.weapon_offset
	current_weapon_model.rotation = weapon.weapon_rotation
	current_weapon_model.scale    = weapon.weapon_scale
	weapon_model_parent.add_child(current_weapon_model)

# ---------------------------------------------------------------------------
# Weapon switching
# ---------------------------------------------------------------------------

func _on_weapon_index_changed() -> void:
	_is_reloading  = false
	_reload_timer  = 0.0
	_pending_fire  = false
	_fire_cooldown = 0.0
	if not weapons.is_empty():
		spawn_weapon_model()
		_apply_recoil_data()
	# If server switches weapon mid-reload, tell all clients reload is cancelled
	if is_multiplayer_authority():
		_cancel_reload.rpc()


@rpc("call_local")
func _cancel_reload() -> void:
	_is_reloading = false
	_reload_timer = 0.0


func next_weapon() -> void:
	if multiplayer.is_server():
		current_weapon_index += 1
	else:
		_next_weapon_server.rpc_id(1)

func previous_weapon() -> void:
	if multiplayer.is_server():
		current_weapon_index -= 1
	else:
		_previous_weapon_server.rpc_id(1)

@rpc("any_peer", "call_local")
func _next_weapon_server() -> void:
	if is_multiplayer_authority():
		current_weapon_index += 1

@rpc("any_peer", "call_local")
func _previous_weapon_server() -> void:
	if is_multiplayer_authority():
		current_weapon_index -= 1

# ---------------------------------------------------------------------------
# Reload
# ---------------------------------------------------------------------------
# Reload is fully server-authoritative.
# The client calls request_reload.rpc_id(1) — the server validates, runs the
# timer, and when done calls _confirm_reload_done.rpc() on all peers.
# The client sets _is_reloading = true immediately for local gate purposes
# (so it doesn't spam fire RPCs during reload), but the flag is only cleared
# by _confirm_reload_done arriving from the server. This means the client
# gate and server gate are always in sync — no timer drift divergence.

func start_reload() -> void:
	var weapon: Weapon = weapons[current_weapon_index]
	if _is_reloading or weapon.has_infinite_ammo:
		return
	if weapon.mag_current == weapon.mag_size:
		return

	if multiplayer.is_server():
		_begin_reload_server()
	else:
		# Optimistically block firing locally so the player doesn't
		# get ghost shots while the RPC round-trips
		_is_reloading = true
		request_reload.rpc_id(1)


@rpc("any_peer")
func request_reload() -> void:
	if not is_multiplayer_authority():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	var owner_id: int  = _parent_player.name.to_int()
	if sender_id != 0 and sender_id != owner_id:
		return
	_begin_reload_server()


func _begin_reload_server() -> void:
	var weapon: Weapon = weapons[current_weapon_index]
	if _is_reloading or weapon.has_infinite_ammo:
		return
	if weapon.mag_current == weapon.mag_size:
		return
	_is_reloading = true
	_reload_timer = weapon.reload_time
	# Tell all peers (including the owning client) that reload has started
	_notify_reload_started.rpc()


@rpc("call_local")
func _notify_reload_started() -> void:
	_is_reloading = true
	_play_sound(weapons[current_weapon_index].reload_sound)
	mag_changed.emit(
		weapons[current_weapon_index].mag_current,
		weapons[current_weapon_index].mag_size
	)


func _finish_reload() -> void:
	# Runs on server only — _tick_timers only runs the reload timer on authority
	var weapon: Weapon = weapons[current_weapon_index]
	if weapon.reload_individually:
		_set_mag(weapon.mag_current + 1)
		_is_reloading = false
		if weapon.mag_current < weapon.mag_size:
			if player_input.fire_held:
				# interrupt reload cleanly
				_is_reloading = false
				return
			else:
				_begin_reload_server()
			
		else:
			_confirm_reload_done.rpc(weapon.mag_current)
	else:
		_set_mag(weapon.mag_size)
		_is_reloading = false
		_confirm_reload_done.rpc(weapon.mag_size)


@rpc("call_local")
func _confirm_reload_done(new_mag: int) -> void:
	# Authoritative mag value from server — overwrite whatever the client had
	var weapon: Weapon = weapons[current_weapon_index]
	weapon.mag_current = clamp(new_mag, 0, weapon.mag_size)
	_is_reloading      = false
	mag_changed.emit(weapon.mag_current, weapon.mag_size)

# ---------------------------------------------------------------------------
# Firing — input processing (owning peer only)
# ---------------------------------------------------------------------------

func _process_fire() -> void:
	var weapon: Weapon = weapons[current_weapon_index]

	# Empty mag click — feedback only, no RPC needed
	if player_input.fire_held and not _fired_this_press:
		if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
			_play_empty.rpc()
			_fired_this_press = true
			return

	if weapon.automatic:
		if player_input.fire_held:
			_try_fire()
	else:
		if player_input.fire_held and not _fired_this_press:
			_try_fire()
			_fired_this_press = true


func _try_fire() -> void:
	if _fire_cooldown > 0.0 or _is_reloading or _pending_fire:
		return

	var pre_delay: float = weapons[current_weapon_index].pre_shoot_delay

	if pre_delay > 0.0:
		_pending_fire   = true
		_pre_fire_timer = pre_delay
	else:
		# No pre-delay — fire immediately
		if multiplayer.is_server():
			fire_intent(current_weapon_index)
		else:
			_do_fire_client()


func _do_fire_client() -> void:
	# Pure client only. Send the intent RPC and set local cooldown to prevent
	# spamming. Do NOT touch mag_current here — the server is the only source
	# of truth for ammo. It calls _set_mag after every accepted shot, which
	# emits mag_changed and updates this client's display via the RPC path.
	# Optimistic deduction causes drift because the server may silently reject
	# shots (cooldown, reload state) and there is no rollback of the deduction.
	_fire_cooldown = weapons[current_weapon_index].post_shoot_delay
	fire_intent.rpc_id(1, current_weapon_index)

# ---------------------------------------------------------------------------
# RPCs
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_local")
func _play_empty() -> void:
	_play_sound(weapons[current_weapon_index].empty_sound)


# Owning client → server (or direct call for host-as-player).
# This is the single authoritative fire point. Everything before here is
# prediction / UI only.
@rpc("any_peer")
func fire_intent(weapon_index: int) -> void:
	if not is_multiplayer_authority():
		return

	# Validate the sender is actually the player who owns this controller.
	# get_remote_sender_id() returns 0 on a direct call (host-as-player) — allow it.
	var sender_id: int = multiplayer.get_remote_sender_id()
	var owner_id: int  = _parent_player.name.to_int()
	if sender_id != 0 and sender_id != owner_id:
		return

	# Server-side gate — all must pass
	if _is_reloading:
		return
	if _fire_cooldown > 0.0:
		return
	if weapon_index != current_weapon_index:
		return

	var weapon: Weapon = weapons[current_weapon_index]
	if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
		return

	# Authoritative deduction and cooldown — only happens here
	if not weapon.has_infinite_ammo:
		_set_mag(weapon.mag_current - 1)
	_fire_cooldown = weapon.post_shoot_delay

	# Push authoritative mag to all peers so client display stays in sync.
	# Without this, a rejected shot (due to server-side cooldown or reload
	# state mismatch) leaves the client's display one count too low forever.
	_sync_mag.rpc(weapons[current_weapon_index].mag_current)

	_execute_fire(weapon)

	# Roll recoil once on server so all peers get identical values
	var r: Vector3     = recoil.recoil
	var rolled: Vector3 = Vector3(
		r.x,
		randf_range(-r.y, r.y),
		randf_range(-r.z, r.z)
	)
	_apply_recoil_rpc.rpc(rolled)
	_play_shoot_sound.rpc()


@rpc("call_local")
func _sync_mag(authoritative_mag: int) -> void:
	# Server → all peers. Overwrites the local mag display with the server's
	# count after every accepted shot. This is the reconciliation step that
	# prevents client display drift from silent server rejections.
	var weapon: Weapon = weapons[current_weapon_index]
	weapon.mag_current = clamp(authoritative_mag, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)


func _execute_fire(weapon: Weapon) -> void:
	if weapon.bullet_type == Weapon.BulletType.HITSCAN:
		var muzzle_node: Node3D = current_weapon_model.get_node("Muzzle") as Node3D
		var muzzle_pos: Vector3 = muzzle_node.global_position
		_flash_muzzle_flash.rpc(muzzle_pos)

		for shot_dir in weapon.multishot_data:
			var shot_dir_v3: Vector3 = shot_dir as Vector3
			var world_dir: Vector3 = \
				weapon_model_parent.global_transform.basis * shot_dir_v3.normalized()

			var space_state: PhysicsDirectSpaceState3D = \
				_parent_player.get_world_3d().direct_space_state
			var origin: Vector3 = weapon_model_parent.global_position
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				origin,
				origin + world_dir * weapon.hitscan_range
			)
			query.exclude = [_parent_player]

			var result: Dictionary = space_state.intersect_ray(query)
			if not result.is_empty():
				_on_hitscan_hit.rpc(result.position, result.normal, muzzle_pos)
				
				var collider: Object = result.collider
				
				if collider.has_method("change_health"):
					var distance := origin.distance_to(result.position)
					var mult := _compute_falloff_multiplier(weapon, distance)
					var damage := weapon.hitscan_damage * mult
					
					collider.change_health(-damage, _parent_player.name)

	elif weapon.bullet_type == Weapon.BulletType.PROJECTILE:
		for shot_dir in weapon.multishot_data:
			var shot_dir_v3: Vector3 = shot_dir as Vector3
			var world_dir: Vector3 = \
				weapon_model_parent.global_transform.basis * shot_dir_v3.normalized()

			var projectile_scene: Node3D = weapon.projectile_scene.instantiate() as Node3D
			projectile_scene.global_transform = weapon_model_parent.global_transform
			projectile_scene.shooter_name     = _parent_player.name

			var speed: float = projectile_scene.linear_velocity.length()
			projectile_scene.linear_velocity = world_dir * speed

			projectile_spawn_parent.add_child(projectile_scene, true)


func _compute_falloff_multiplier(weapon: Weapon, distance: float) -> float:
	if not weapon.has_damage_falloff or weapon.falloff_curve == null:
		return 1.0
	
	var t: float
	
	if weapon.falloff_end == weapon.falloff_start:
		t = 0.0
	else:
		t = (distance - weapon.falloff_start) / (weapon.falloff_end - weapon.falloff_start)
	
	t = clamp(t, 0.0, 1.0)
	
	var curve: Curve = weapon.falloff_curve.curve
	if curve == null:
		return 1.0
	
	return curve.sample(t)


@rpc("call_local")
func _flash_muzzle_flash(start_position: Vector3) -> void:
	#var muzzle_flash_scene: PackedScene = load("res://weapon/muzzle_flash.tscn") as PackedScene
	#var muzzle_flash: Node              = muzzle_flash_scene.instantiate()
	
	
	
	#projectile_spawn_parent.add_child(muzzle_flash)
	var muzzle_flash = $MuzzleFlash
	muzzle_flash.global_rotation = current_weapon_model.global_rotation
	muzzle_flash.global_position = start_position
	muzzle_flash.fire()

	#var duration: float = 0.1
	#if muzzle_flash.has_node("Sparks"):
		#var sparks: GPUParticles3D = muzzle_flash.get_node("Sparks") as GPUParticles3D
		#duration = sparks.lifetime

	#get_tree().create_timer(duration).timeout.connect(func() -> void:
		#if is_instance_valid(muzzle_flash):
			#muzzle_flash.hide()
	#)


@rpc("call_local")
func _on_hitscan_hit(
	hit_position: Vector3,
	hit_normal: Vector3,
	start_position: Vector3
) -> void:
	var bullet_hole_scene: PackedScene = load("res://effects/bullet_hole.tscn") as PackedScene
	var bullet_hole: Node3D            = bullet_hole_scene.instantiate() as Node3D
	projectile_spawn_parent.add_child(bullet_hole)
	bullet_hole.global_position        = hit_position
	bullet_hole.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal))

	var tracer_mat: StandardMaterial3D  = StandardMaterial3D.new()
	tracer_mat.albedo_color             = Color(1.0, 0.588, 0.294, 1.0)
	tracer_mat.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer_mat.cull_mode                = BaseMaterial3D.CULL_DISABLED

	var cylinder: CylinderMesh          = CylinderMesh.new()
	cylinder.top_radius                 = 0.01
	cylinder.bottom_radius              = 0.01
	cylinder.radial_segments            = 3
	cylinder.rings                      = 1
	cylinder.material                   = tracer_mat

	var tracer_instance: MeshInstance3D = MeshInstance3D.new()
	tracer_instance.mesh                = cylinder
	tracer_instance.cast_shadow         = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	projectile_spawn_parent.add_child(tracer_instance)

	var distance: float = start_position.distance_to(hit_position)

	var tween: Tween = get_tree().create_tween()
	tween.tween_method(
		func(t: float) -> void:
			var current_start: Vector3 = start_position.lerp(hit_position, t)
			var mid: Vector3           = current_start.lerp(hit_position, 0.5)
			var dir: Vector3           = hit_position - current_start
			var len: float             = dir.length()
			tracer_instance.global_position = mid
			cylinder.height = len
			if len > 0.001:
				tracer_instance.global_transform.basis = Basis(
					Quaternion(Vector3.UP, dir.normalized())
				),
		0.0, 1.0, distance * 0.05
	)
	tween.tween_callback(func() -> void: tracer_instance.queue_free())

	await get_tree().create_timer(7.0).timeout
	if is_instance_valid(bullet_hole):
		bullet_hole.queue_free()


@rpc("any_peer", "call_local")
func _apply_recoil_rpc(rolled: Vector3) -> void:
	recoil.target_rotation += rolled


@rpc("any_peer", "call_local")
func _play_shoot_sound() -> void:
	_play_sound(weapons[current_weapon_index].shoot_sound)


func _align_weapon_to_raycast() -> void:
	if current_weapon_model == null or not _raycast.is_colliding():
		return
	var from: Vector3 = current_weapon_model.global_transform.origin
	var to: Vector3   = _raycast.get_collision_point()
	var dir: Vector3  = (to - from).normalized()
	if dir.length_squared() > 0.0:
		current_weapon_model.global_transform.basis = Basis().looking_at(dir, Vector3.UP)
