class_name WeaponController extends Node

var _is_reloading: bool = false
var _reload_timer: float = 0.0
var _pending_fire: bool = false
var _pre_fire_timer: float = 0.0

signal mag_changed(current: int, max: int)
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
@export var _raycast :RayCast3D

var current_weapon_model: Node3D
var _fire_cooldown: float = 0.0
var _fired_this_press: bool = false
var reset_weapons: Array[Weapon]
func reset():
	current_weapon_index = 0
	weapons = reset_weapons

func _set_mag(value: int) -> void:
	var weapon = weapons[current_weapon_index]
	weapon.mag_current = clamp(value, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)
	
	
func _emit_weapon_changed() -> void:
	var weapon = weapons[current_weapon_index]
	weapon_changed.emit(current_weapon_index, weapon)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	reset_weapons = weapons
	
	if not weapons.is_empty() and weapons[current_weapon_index]:
		spawn_weapon_model()

	player_input.primary_fire.connect(_on_primary_fire_held)
	player_input.primary_fire_released.connect(_on_primary_fire_released)
	player_input.previous_weapon.connect(previous_weapon)
	player_input.next_weapon.connect(next_weapon)
	player_input.reload.connect(start_reload)

	_apply_recoil_data()


func _physics_process(delta: float) -> void:
	_align_weapon_to_raycast()
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

	if _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()

	if _pending_fire:
		_pre_fire_timer -= delta
		if _pre_fire_timer <= 0.0:
			_do_fire()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _apply_recoil_data() -> void:
	var data = weapons[current_weapon_index].recoil_data
	recoil.recoil       = data.recoil
	recoil.aim_recoil   = data.aim_recoil
	recoil.snappiness   = data.snappiness
	recoil.return_speed = data.return_speed


func _play_sound(stream: AudioStream) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.global_transform = weapon_model_parent.global_transform
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


func spawn_weapon_model() -> void:
	if current_weapon_model:
		current_weapon_model.queue_free()
	var weapon = weapons[current_weapon_index]
	if weapon.weapon_model:
		current_weapon_model = weapon.weapon_model.instantiate()
		weapon_model_parent.add_child(current_weapon_model)
		current_weapon_model.position = weapon.weapon_offset
		current_weapon_model.rotation = weapon.weapon_rotation
		current_weapon_model.scale    = weapon.weapon_scale

# ---------------------------------------------------------------------------
# Weapon switching
# ---------------------------------------------------------------------------

func _on_weapon_index_changed() -> void:
	_is_reloading = false
	_reload_timer = 0.0
	_pending_fire = false
	if not weapons.is_empty():
		spawn_weapon_model()
		_apply_recoil_data()


func next_weapon() -> void:
	next_weapon_server.rpc_id(1)

func previous_weapon() -> void:
	previous_weapon_server.rpc_id(1)

@rpc("any_peer", "call_local")
func next_weapon_server() -> void:
	if is_multiplayer_authority():
		current_weapon_index += 1

@rpc("any_peer", "call_local")
func previous_weapon_server() -> void:
	if is_multiplayer_authority():
		current_weapon_index -= 1

# ---------------------------------------------------------------------------
# Reload
# ---------------------------------------------------------------------------

func start_reload() -> void:
	if _is_reloading or weapons[current_weapon_index].has_infinite_ammo:
		return

	var weapon = weapons[current_weapon_index]
	if weapon.mag_current == weapon.mag_size:
		return

	_is_reloading = true
	_reload_timer = weapon.reload_time
	_play_sound(weapon.reload_sound)

	# Optional:
	mag_changed.emit(weapon.mag_current, weapon.mag_size)


func _finish_reload() -> void:
	var weapon = weapons[current_weapon_index]
	if weapon.reload_individually:
		_set_mag(weapon.mag_current + 1)
		_is_reloading = false
		start_reload()
	else:
		_set_mag(weapon.mag_size)
		_is_reloading = false

# ---------------------------------------------------------------------------
# Firing — input side (owning client only, driven by PlayerInput RPC)
# ---------------------------------------------------------------------------

func _on_primary_fire_held() -> void:
	if _is_reloading:
		return
	var weapon = weapons[current_weapon_index]
	if weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
		if not _fired_this_press:
			_play_empty.rpc()
			_fired_this_press = true
		return
	if weapon.automatic:
		_try_fire()
	else:
		if not _fired_this_press:
			_try_fire()
			_fired_this_press = true


func _on_primary_fire_released() -> void:
	_fired_this_press = false


func _try_fire() -> void:
	if _fire_cooldown > 0.0 or _is_reloading or _pending_fire:
		return
	_pending_fire   = true
	_pre_fire_timer = weapons[current_weapon_index].pre_shoot_delay


func _do_fire() -> void:
	_pending_fire = false
	if not weapons[current_weapon_index].has_infinite_ammo:
		weapons[current_weapon_index].mag_current -= 1
		mag_changed.emit(weapons[current_weapon_index].mag_current, weapons[current_weapon_index].mag_size)
	_fire_cooldown = weapons[current_weapon_index].post_shoot_delay

	# rpc_id(1) is silently dropped when you ARE peer 1 (host-as-player).
	# Call directly if we're the server, otherwise send the RPC.
	if multiplayer.is_server():
		_request_fire()
	else:
		_request_fire.rpc_id(1)

# ---------------------------------------------------------------------------
# RPCs
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_local")
func _play_empty() -> void:
	_play_sound(weapons[current_weapon_index].empty_sound)


# Client → server. No call_local — server handles everything inside.
@rpc("any_peer")
func _request_fire() -> void:
	if not is_multiplayer_authority():
		return
	var weapon = weapons[current_weapon_index]

	if weapon.bullet_type == Weapon.BulletType.HITSCAN:
		for shot_dir in weapon.multishot_data:
			# Transform the local shot direction into world space.
			var world_dir: Vector3 = weapon_model_parent.global_transform.basis * shot_dir.normalized()
			
			var space_state = _parent_player.get_world_3d().direct_space_state
			var origin: Vector3 = weapon_model_parent.global_position
			var query = PhysicsRayQueryParameters3D.create(
				origin,
				origin + world_dir * weapon.hitscan_range
			)
			query.exclude = [_parent_player]
			
			var result = space_state.intersect_ray(query)
			if result:
				# Tell all peers to show the hit effect at this position.
				_on_hitscan_hit.rpc(result.position, result.normal)
				
				# Apply damage only on the server.
				if result.collider.has_method("change_health"):
					result.collider.change_health(-weapon.hitscan_damage)

	elif weapon.bullet_type == Weapon.BulletType.PROJECTILE:
		for shot_dir in weapon.multishot_data:
			var world_dir: Vector3 = weapon_model_parent.global_transform.basis * shot_dir.normalized()
			
			var projectile_scene = weapon.projectile_scene.instantiate() as Node3D
			projectile_scene.global_transform = weapon_model_parent.global_transform
			projectile_scene.shooter_name = _parent_player.name
			
			var speed = projectile_scene.linear_velocity.length()
			projectile_scene.linear_velocity = world_dir * speed
			
			projectile_spawn_parent.add_child(projectile_scene, true)
			
			
	# Roll recoil once on the server — single source of truth, no randf divergence.
	var r: Vector3 = recoil.recoil
	var rolled := Vector3(
		r.x,
		randf_range(-r.y, r.y),
		randf_range(-r.z, r.z)
	)
	# Broadcast exact values to all peers so everyone applies identical recoil.
	_apply_recoil_rpc.rpc(rolled)
	# Play shoot sound on all peers.
	_play_shoot_sound.rpc()
	

@rpc("call_local")
func _on_hitscan_hit(hit_position: Vector3, hit_normal: Vector3) -> void:
	var mesh_instance := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.05
	sphere_mesh.height = 0.1
	mesh_instance.mesh = sphere_mesh

	# Create black material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0, 0, 0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_instance.material_override = mat

	projectile_spawn_parent.add_child(mesh_instance)
	mesh_instance.global_position = hit_position
	
	await get_tree().create_timer(7.0).timeout
	mesh_instance.queue_free()


# Server → all peers. Exact values so randf never diverges between peers.
@rpc("any_peer", "call_local")
func _apply_recoil_rpc(rolled: Vector3) -> void:
	recoil.target_rotation += rolled


@rpc("any_peer", "call_local")
func _play_shoot_sound() -> void:
	_play_sound(weapons[current_weapon_index].shoot_sound)

func _align_weapon_to_raycast() -> void:
	if not _raycast.is_colliding():
		return

	var from: Vector3 = current_weapon_model.global_transform.origin
	var to: Vector3 = _raycast.get_collision_point()

	var dir: Vector3 = (to - from).normalized()

	var basis := Basis().looking_at(dir, Vector3.UP)
	current_weapon_model.global_transform.basis = basis
