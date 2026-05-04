class_name WeaponController extends Node
var _bullet_hole_scene: PackedScene = preload("res://effects/bullet_hole.tscn")
var _tracer_scene: PackedScene = preload("res://weapon/tracer.tscn")
var _hit_sound: AudioStream = preload("res://assets/sounds/Hitsound.wav")
var _hit_heal_sound: AudioStream = preload("res://assets/sounds/medkit_sound.mp3")


#enum FireType {PRIMARY, SECONDARY}
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
var _pending_fire_index: int = 0


var _pre_fire_timer: float  = 0.0
var _fire_cooldown: float   = 0.0
var _fired_this_press: bool = false

signal mag_changed(current: int, mag_max: int)
signal weapon_changed(index: int, weapon: Weapon)

# Use @export only for editor-assigned defaults. All runtime mutation goes
# through set_weapons() so the setter invariant is always enforced.
@export var _weapons: Array[Weapon]:
	set(value):
		if value == _weapons:
			return
		_weapons = value
		#even though index might be same
		_on_weapon_index_changed()
		_emit_weapon_changed()

@export var current_weapon_index: int = 0:
	set(value):
		if value == current_weapon_index:
			return
		current_weapon_index = clamp(value, 0, _weapons.size() - 1)
		_on_weapon_index_changed()
		
		#_on_weapon_index_changed()
		_emit_weapon_changed()

@export var weapon_model_parent: Node3D
@export var projectile_spawn_parent: Node3D
@export var player_input: PlayerInput
@export var recoil: Recoil
@export var _parent_player: Player
@export var _raycast: RayCast3D

var current_weapon_model: Node3D = null

#region Readiness
# Central invariant check. Every RPC and fire path that touches _weapons or
# current_weapon_model calls this first. One place to fix, one place to read.
func _is_ready() -> bool:
	return not _weapons.is_empty() \
		and current_weapon_index < _weapons.size() \
		and current_weapon_model != null \
		and is_instance_valid(current_weapon_model)
#endregion

#region Lifecycle
func _ready() -> void:
	# Deep-copy every Weapon resource so this WeaponController instance owns
	# its own mutable state. Without this, both the client-side and server-side
	# WeaponController nodes share the same Weapon objects in memory, causing
	# mag_current mutations from one peer to silently affect the other.
	var deep_weapons: Array[Weapon] = []
	for w: Weapon in _weapons:
		deep_weapons.append(w.duplicate(true) as Weapon)
	_weapons = deep_weapons

	if not _weapons.is_empty() and _weapons[current_weapon_index] != null:
		spawn_weapon_model()

	player_input.previous_weapon.connect(previous_weapon)
	player_input.next_weapon.connect(next_weapon)
	player_input.reload.connect(start_reload)

	#_apply_recoil_data()

func _physics_process(delta: float) -> void:
	_align_weapon_to_raycast()
	_tick_timers(delta)

	var my_id: int    = multiplayer.get_unique_id()
	var owner_id: int = _parent_player.name.to_int()
	if my_id == owner_id:
		_process_fire()

	if player_input.primary_fire_just_released:
		_fired_this_press           = false
		player_input.primary_fire_just_released = false
	
	if player_input.secondary_fire_just_released:
		_fired_this_press           = false
		player_input.secondary_fire_just_released = false
	

#func _tick_timers(delta: float) -> void:
	#if _fire_cooldown > 0.0:
		#_fire_cooldown -= delta
#
	#if is_multiplayer_authority() and _is_reloading:
		#_reload_timer -= delta
		#if _reload_timer <= 0.0:
			#_finish_reload()
#
	#if _pending_fire:
		#if player_input.fire_held:
			#_pre_fire_timer -= delta
		#else:
			#_pending_fire = false
#
		#if _pre_fire_timer <= 0.0:
			#_pending_fire = false
			#if multiplayer.is_server():
				#fire_intent(current_weapon_index)
			#else:
				#_do_fire_client()

func _tick_timers(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

	# Reload timer should tick on the server, since reload is server-authoritative.
	# is_multiplayer_authority() returns true for the OWNING CLIENT, not the server,
	# which means _finish_reload() was never being called server-side.
	if multiplayer.is_server() and _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()

	if _pending_fire:
		if player_input.fire_held:
			_pre_fire_timer -= delta
		else:
			_pending_fire = false

		if _pre_fire_timer <= 0.0:
			_pending_fire = false
			if multiplayer.is_server():
				fire_intent(current_weapon_index, _pending_fire_index)
					
			else:
				_do_fire_client()

func reset() -> void:
	current_weapon_index = 0
	for weapon in _weapons:
		weapon.reset()
	if not _weapons.is_empty():
		_emit_weapon_changed()


func _set_mag(value: int) -> void:
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon.mag_current = clamp(value, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)


func _emit_weapon_changed() -> void:
	if _weapons.is_empty():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon_changed.emit(current_weapon_index, weapon)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)
#endregion


#region Loadout
# The only correct way to assign weapons at runtime. Enforces all invariants:
# deep-copies resources, resets timers, spawns the model, emits signals.
# Nothing should ever write to _weapons directly outside of _ready().
func set_weapons(new_weapons: Array[Weapon]) -> void:
	var deep_weapons: Array[Weapon] = []
	for w: Weapon in new_weapons:
		deep_weapons.append(w.duplicate(true) as Weapon)
	_weapons = deep_weapons

	# Reset all firing state so stale cooldowns/reload flags from the previous
	# loadout cannot bleed into the new one.
	_is_reloading   = false
	_reload_timer   = 0.0
	_pending_fire   = false
	_fire_cooldown  = 0.0

	spawn_weapon_model()
	_emit_weapon_changed()


func get_weapons() -> Array[Weapon]:
	return _weapons
#endregion


#region Helpers
#func _apply_recoil_data() -> void:
	#if _weapons.is_empty():
		#return
	#var data: RecoilData = _weapons[current_weapon_index].recoil_data
	#recoil.recoil       = data.recoil
	#recoil.aim_recoil   = data.aim_recoil
	#recoil.snappiness   = data.snappiness
	#recoil.return_speed = data.return_speed


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
	if _weapons.is_empty():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if weapon.weapon_model == null:
		return
	current_weapon_model          = weapon.weapon_model.instantiate() as Node3D
	current_weapon_model.position = weapon.weapon_offset
	current_weapon_model.rotation = weapon.weapon_rotation
	current_weapon_model.scale    = weapon.weapon_scale
	weapon_model_parent.add_child(current_weapon_model)
#endregion


#region Weapon switching
func _on_weapon_index_changed() -> void:
	_is_reloading  = false
	_reload_timer  = 0.0
	_pending_fire  = false
	_fire_cooldown = 0.0
	if not _weapons.is_empty():
		spawn_weapon_model()
		#_apply_recoil_data()
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
#endregion


#region Reload
# Reload is fully server-authoritative.
# The client calls request_reload.rpc_id(1) — the server validates, runs the
# timer, and when done calls _confirm_reload_done.rpc() on all peers.
# The client sets _is_reloading = true immediately for local gate purposes
# (so it doesn't spam fire RPCs during reload), but the flag is only cleared
# by _confirm_reload_done arriving from the server. This means the client
# gate and server gate are always in sync — no timer drift divergence.

func start_reload() -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if _is_reloading or weapon.has_infinite_ammo:
		return
	if weapon.mag_current == weapon.mag_size:
		return
	if multiplayer.is_server():
		_begin_reload_server()
	else:
		_is_reloading = true
		request_reload.rpc_id(1)

#
#@rpc("any_peer")
#func request_reload() -> void:
	#if not is_multiplayer_authority():
		#return
	#var sender_id: int = multiplayer.get_remote_sender_id()
	#var owner_id: int  = _parent_player.name.to_int()
	#if sender_id != 0 and sender_id != owner_id:
		#return
	#_begin_reload_server()

@rpc("any_peer")
func request_reload() -> void:
	# Only the server should process reload requests
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	var owner_id: int  = _parent_player.name.to_int()
	if sender_id != 0 and sender_id != owner_id:
		return
	_begin_reload_server()

func _begin_reload_server() -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if _is_reloading or weapon.has_infinite_ammo:
		return
	if weapon.mag_current == weapon.mag_size:
		return
	_is_reloading = true
	_reload_timer = weapon.reload_time
	_notify_reload_started.rpc()


@rpc("call_local")
func _notify_reload_started() -> void:
	if not _is_ready():
		return
	_is_reloading = true
	_play_sound(_weapons[current_weapon_index].reload_sound)
	mag_changed.emit(
		_weapons[current_weapon_index].mag_current,
		_weapons[current_weapon_index].mag_size
	)


func _finish_reload() -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if weapon.reload_individually:
		_set_mag(weapon.mag_current + 1)
		_is_reloading = false
		if weapon.mag_current < weapon.mag_size:
			if player_input.primary_fire_held or player_input.secondary_fire_held:
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
	if _weapons.is_empty() or current_weapon_index >= _weapons.size():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon.mag_current = clamp(new_mag, 0, weapon.mag_size)
	_is_reloading      = false
	mag_changed.emit(weapon.mag_current, weapon.mag_size)
#endregion

#TODO: FIX ALL SHITTY CODE about primary and secondary fire shit later THIS IS SUPER SPAGHETTI!!!!!!!!!!!!!!!!!!!!!!!!!!
#region Firing — input processing (owning peer only)
func _process_fire() -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	
	
	#Fire empty sound if there is no ammo. Do not play if there is no attack 
	if (player_input.primary_fire_held) and not _fired_this_press:
		#early exit
		if weapon.weapon_fires.size() >= 1 and weapon.mag_current < (_weapons[current_weapon_index].weapon_fires[0].ammo_cost ) and not weapon.has_infinite_ammo:
			_play_empty.rpc(0)
			_fired_this_press = true
			return
	
	#Fire empty sound if there is no ammo. Do not play if there is no attack 
	if (player_input.secondary_fire_held) and not _fired_this_press:
		#early exit
		if weapon.weapon_fires.size() >= 2 and weapon.mag_current < (_weapons[current_weapon_index].weapon_fires[1].ammo_cost ) and not weapon.has_infinite_ammo:
			_play_empty.rpc(1)
			_fired_this_press = true
			return
	
	
	
	if weapon.automatic:
		if player_input.primary_fire_held:
			if weapon.weapon_fires.size() >= 1:
				_try_fire(0)
		if player_input.secondary_fire_held:
			if weapon.weapon_fires.size() >= 2:
				_try_fire(1)
	else:
		if player_input.primary_fire_held and not _fired_this_press:
			if weapon.weapon_fires.size() >= 1:
				_try_fire(0)
				_fired_this_press = true
		if player_input.secondary_fire_held and not _fired_this_press:
			if weapon.weapon_fires.size() >= 2:
				_try_fire(1)
				_fired_this_press = true	
		


func _try_fire(weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	if _fire_cooldown > 0.0 or _is_reloading or _pending_fire:
		return

	var weapon: Weapon   = _weapons[current_weapon_index]
	#var pre_delay: float = weapon.weapon_fires[0].pre_shoot_delay if fire_type == FireType.PRIMARY else weapon.weapon_fires[1].pre_shoot_delay
	var pre_delay: float = weapon.weapon_fires[weapon_fire_index].pre_shoot_delay
	

	if weapon.mag_current < (_weapons[current_weapon_index].weapon_fires[0].ammo_cost if player_input.primary_fire_held else _weapons[current_weapon_index].weapon_fires[1].ammo_cost) and not weapon.has_infinite_ammo:
		return




	#var data: RecoilData = _weapons[current_weapon_index].weapon_fires[0].recoil_data if fire_type == FireType.PRIMARY else _weapons[current_weapon_index].weapon_fires[1].recoil_data
	var data: RecoilData = _weapons[current_weapon_index].weapon_fires[weapon_fire_index].recoil_data
	
	recoil.recoil       = data.recoil
	recoil.aim_recoil   = data.aim_recoil
	recoil.snappiness   = data.snappiness
	recoil.return_speed = data.return_speed
	
	
	var r: Vector3      = recoil.recoil
	var rolled: Vector3 = Vector3(
		r.x,
		randf_range(-r.y, r.y),
		randf_range(-r.z, r.z)
	)
	
	
	
	_apply_recoil_rpc.rpc(rolled)
	
	
	if pre_delay > 0.0:
		_pending_fire   = true
		_pending_fire_index = weapon_fire_index
		_pre_fire_timer = pre_delay
	else:
		if multiplayer.is_server():
			fire_intent(current_weapon_index, weapon_fire_index)
		else:
			fire_intent(current_weapon_index, weapon_fire_index)


func _do_fire_client() -> void:
	if not _is_ready():
		return
	_fire_cooldown = _weapons[current_weapon_index].post_shoot_delay
	fire_intent.rpc_id(1, current_weapon_index)
#endregion


#region RPCs
@rpc("any_peer", "call_local")
func _play_empty(weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	_play_sound(_weapons[current_weapon_index].weapon_fires[weapon_fire_index].empty_sound)
		

@rpc("any_peer")
func fire_intent(weapon_index: int, weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[weapon_index]

	if not weapon.has_infinite_ammo:
		_set_mag(weapon.mag_current - (_weapons[weapon_index].weapon_fires[weapon_fire_index].ammo_cost))
	_fire_cooldown = weapon.weapon_fires[0].post_shoot_delay#

	_sync_mag.rpc(_weapons[current_weapon_index].mag_current)
	_execute_fire(weapon, weapon_fire_index)
	_play_shoot_sound.rpc(weapon_fire_index)


@rpc("any_peer", "call_local")
func _sync_mag(authoritative_mag: int) -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon.mag_current = clamp(authoritative_mag, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)


func _execute_fire(weapon: Weapon, weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	
	# Handle knockback recoil
	var weapon_fire: WeaponFire= weapon.weapon_fires[weapon_fire_index]
	
	
	
	var basis: Basis = weapon_model_parent.global_transform.basis
	var recoil: Vector3 = basis * weapon_fire.recoil_knockback

	_knockback_player_on_server.rpc_id(1, recoil)
		
		
	if weapon_fire.bullet_type == WeaponFire.BulletType.HITSCAN:
		var muzzle_node: Node3D = current_weapon_model.get_node("Muzzle") as Node3D
		var muzzle_pos: Vector3 = muzzle_node.global_position
		_flash_muzzle_flash.rpc(muzzle_pos)

		for shot_dir in weapon_fire.multishot_data:
			var shot_dir_v3: Vector3 = shot_dir as Vector3
			var world_dir: Vector3   = \
				weapon_model_parent.global_transform.basis * shot_dir_v3.normalized()

			var space_state: PhysicsDirectSpaceState3D = \
				_parent_player.get_world_3d().direct_space_state
			var origin: Vector3              = weapon_model_parent.global_position
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				origin,
				origin + world_dir * weapon_fire.hitscan_range
			)
			query.exclude          = [_parent_player.get_rid(), $"../HeadHurtbox".get_rid(), $"../BodyHurtbox".get_rid()]
			query.collide_with_areas = true
			query.collision_mask   = (1 << 0) | (1 << 2)

			var result: Dictionary = space_state.intersect_ray(query)
			if not result.is_empty():
				_on_hitscan_hit.rpc(result.position, result.normal, muzzle_pos)
				var collider: Node3D = result.collider
				if collider is HurtboxComponent:
					var distance := origin.distance_to(result.position)
					var mult     := _compute_falloff_multiplier(weapon, distance)
					var damage   := weapon_fire.hitscan_damage * mult
					if collider.is_head:
						damage *= weapon_fire.headshot_multiplier
					var player_name = collider.get_parent().name
					
					if collider.get_parent().team == get_parent().team:
						damage *= Player.FRIENDLY_FIRE_MULTIPLIER
						
					_change_health_on_server.rpc_id(1, player_name, -damage, _parent_player.name)
			else:
				if weapon_fire.hitscan_range >= 1000000000.0 / 10.0:
					var far_pos: Vector3    = origin + world_dir * 10000.0
					var fake_normal: Vector3 = -world_dir
					_on_hitscan_hit.rpc(far_pos, fake_normal, muzzle_pos)

	elif weapon_fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		for shot_dir in weapon_fire.multishot_data:
			_spawn_projectile_on_server.rpc_id(
				1, weapon_fire_index, shot_dir, weapon_model_parent.global_transform.basis, _parent_player.name, _parent_player.team
			)

@rpc("any_peer", "call_local", "reliable")
func _knockback_player_on_server(vector: Vector3):
	get_parent().apply_knockback(vector)



@rpc("any_peer", "call_local", "reliable")
func _spawn_projectile_on_server(weapon_fire_index, shot_dir, basis, parent_player_name, team):
	if not _is_ready():
		return
	var weapon: Weapon    = _weapons[current_weapon_index]
	var shot_dir_v3: Vector3 = shot_dir as Vector3
	var world_dir: Vector3   = basis * shot_dir_v3.normalized()

	var projectile_scene: Node3D  = weapon.weapon_fires[weapon_fire_index].projectile_scene.instantiate() as Node3D
	projectile_scene.global_transform = weapon_model_parent.global_transform
	projectile_scene.shooter_name     = parent_player_name

	var speed: float = projectile_scene.linear_velocity.length()
	projectile_scene.linear_velocity = world_dir * speed
	projectile_scene.shooter_team = team
	projectile_spawn_parent.add_child(projectile_scene, true)


@rpc("any_peer", "call_local", "reliable")
func _change_health_on_server(collider_name: String, delta, parent_player_name):
	if not is_multiplayer_authority():
		return
	for child in get_parent().get_parent().get_children():
		if child.name == collider_name and child is Player:
			child.change_health(delta, parent_player_name)


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


@rpc("any_peer", "call_local")
func _flash_muzzle_flash(start_position: Vector3) -> void:
	if not _is_ready():
		return
	var muzzle_flash = $MuzzleFlash
	muzzle_flash.global_rotation = current_weapon_model.global_rotation
	muzzle_flash.global_position = start_position
	muzzle_flash.fire()

#
#@rpc("any_peer", "call_local")
#func _on_hitscan_hit(
	#hit_position: Vector3,
	#hit_normal: Vector3,
	#start_position: Vector3
#) -> void:
	#var bullet_hole_scene: PackedScene = load("res://effects/bullet_hole.tscn") as PackedScene
	#var bullet_hole: Node3D            = bullet_hole_scene.instantiate() as Node3D
	#projectile_spawn_parent.add_child(bullet_hole)
	#bullet_hole.global_position        = hit_position
	#bullet_hole.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal))
#
	## --- Tracer setup ---
	#var tracer_mat: StandardMaterial3D  = StandardMaterial3D.new()
	#tracer_mat.albedo_color  = Color(1.0, 0.588, 0.294, 1.0)
	#tracer_mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	#tracer_mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
#
	#var cylinder: CylinderMesh = CylinderMesh.new()
	#cylinder.top_radius    = 0.01
	#cylinder.bottom_radius = 0.01
	#cylinder.radial_segments = 3
	#cylinder.rings         = 1
	#cylinder.material      = tracer_mat
#
	#var tracer_instance: MeshInstance3D = MeshInstance3D.new()
	#tracer_instance.mesh         = cylinder
	#tracer_instance.cast_shadow  = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	#projectile_spawn_parent.add_child(tracer_instance)
#
	#var distance: float = start_position.distance_to(hit_position)
#
	## --- Tween animation ---
	#var tween: Tween = get_tree().create_tween()
#
	#var tracer_fn := func(t: float) -> void:
		#if not is_instance_valid(tracer_instance):
			#return
		#var current_start: Vector3 = start_position.lerp(hit_position, t)
		#var mid: Vector3           = current_start.lerp(hit_position, 0.5)
		#var dir: Vector3           = hit_position - current_start
		#var tracer_len: float      = dir.length()
		#tracer_instance.global_position = mid
		#cylinder.height = tracer_len
		#if tracer_len > 0.001:
			#tracer_instance.global_transform.basis = Basis(
				#Quaternion(Vector3.UP, dir.normalized())
			#)
#
	#tween.tween_method(tracer_fn, 0.0, 1.0, distance * 0.02)
#
	## --- Lifetime control (race: tween vs 4s timer) ---
	#var alive := true
#
	#get_tree().create_timer(4.0).timeout.connect(func():
		#if alive and is_instance_valid(tracer_instance):
			#alive = false
			#if is_instance_valid(tween):
				#tween.kill()
			#tracer_instance.queue_free()
	#)
#
	## --- Bullet hole cleanup ---
	#get_tree().create_timer(7.0).timeout.connect(func():
		#if is_instance_valid(bullet_hole):
			#bullet_hole.queue_free()
	#)
	
@rpc("any_peer", "call_local")
func _on_hitscan_hit(hit_position: Vector3, hit_normal: Vector3, start_position: Vector3) -> void:
	# Bullet hole
	var bullet_hole: Node3D = _bullet_hole_scene.instantiate() as Node3D
	projectile_spawn_parent.add_child(bullet_hole)
	bullet_hole.global_position        = hit_position
	bullet_hole.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal))
	get_tree().create_timer(7.0).timeout.connect(func():
		if is_instance_valid(bullet_hole):
			bullet_hole.queue_free()
	)

	# Tracer — fully self-contained, no captures
	var tracer: Tracer = _tracer_scene.instantiate() as Tracer
	projectile_spawn_parent.add_child(tracer)
	tracer.fire(start_position, hit_position)


@rpc("any_peer", "call_local")
func _apply_recoil_rpc(rolled: Vector3) -> void:
	if _weapons.is_empty():
		return

	
	
	
	recoil.target_rotation += rolled
	


@rpc("any_peer", "call_local")
func _play_shoot_sound(weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	_play_sound(_weapons[current_weapon_index].weapon_fires[weapon_fire_index].shoot_sound)

## Played when you hit someone, called by attribute component
@rpc("any_peer", "call_local")
func play_hit_sound() -> void:
	if not _is_ready():
		return
	_play_sound(_hit_sound)

##Played when you heal someone, called by attribute component
@rpc("any_peer", "call_local")
func play_hit_heal_sound() -> void:
	if not _is_ready():
		return
	_play_sound(_hit_heal_sound)

func _align_weapon_to_raycast() -> void:
	if current_weapon_model == null or not _raycast.is_colliding():
		return
	var from: Vector3 = current_weapon_model.global_transform.origin
	var to: Vector3   = _raycast.get_collision_point()
	var dir: Vector3  = (to - from).normalized()
	if dir.length_squared() > 0.0:
		current_weapon_model.global_transform.basis = Basis.looking_at(dir, Vector3.UP)
#endregion
