class_name WeaponController extends Node

#@export var current_weapon: Weapon

var _is_reloading: bool = false
var _reload_timer: float = 0.0
var _pending_fire: bool = false
var _pre_fire_timer: float = 0.0


@export var weapons: Array[Weapon] 
@export var current_weapon_index: int = 0:
	set(value):
		if value == current_weapon_index:
			return
		current_weapon_index = clamp(value, 0, weapons.size() - 1)
		_on_weapon_index_changed()

@export var weapon_model_parent: Node3D
@export var projectile_spawn_parent: Node3D
@export var player_input: PlayerInput

#@onready var recoil = %CameraRecoil
@onready var camera = %Camera3D
@onready var _parent_player: Player = $"../.."
#@onready var audio_player: AudioStreamPlayer3D = $AudioStreamPlayer3D


var current_weapon_model: Node3D
var _fire_cooldown: float = 0.0
var _fired_this_press: bool = false

func _ready() -> void:
	if weapons[current_weapon_index]:
		spawn_weapon_model()
	player_input.primary_fire.connect(_on_primary_fire_held)
	player_input.primary_fire_released.connect(_on_primary_fire_released)
	player_input.previous_weapon.connect(previous_weapon)
	player_input.next_weapon.connect(next_weapon)
	player_input.reload.connect(start_reload)
	
	#recoil.recoil = current_weapon.recoil_data.recoil
	#recoil.aim_recoil = current_weapon.recoil_data.aim_recoil
	#recoil.snappiness = current_weapon.recoil_data.snappiness
	#recoil.return_speed = current_weapon.recoil_data.return_speed
func _play_sound(stream: AudioStream) -> void:
	if stream == null:
		return
	
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	
	# place sound at weapon/player location
	player.global_transform = weapon_model_parent.global_transform
	
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


func _on_weapon_index_changed() -> void:
	_is_reloading = false
	_reload_timer = 0.0
	_pending_fire = false
	
	if not weapons.is_empty():
		spawn_weapon_model()


func _physics_process(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

	if _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()

	# handle delayed shot
	if _pending_fire:
		_pre_fire_timer -= delta
		if _pre_fire_timer <= 0.0:
			_do_fire()

func spawn_weapon_model() -> void:
	if current_weapon_model:
		current_weapon_model.queue_free()
	if weapons[current_weapon_index].weapon_model:
		current_weapon_model = weapons[current_weapon_index].weapon_model.instantiate()
		weapon_model_parent.add_child(current_weapon_model)
		current_weapon_model.position = weapons[current_weapon_index].weapon_offset
		current_weapon_model.rotation = weapons[current_weapon_index].weapon_rotation
		current_weapon_model.scale = weapons[current_weapon_index].weapon_scale
		

func _on_primary_fire_held() -> void:
	if _is_reloading:
		return

	var weapon = weapons[current_weapon_index]

	# EMPTY MAG
	if weapon.mag_current <= 0:
		if not _fired_this_press:
			_play_empty.rpc()   # networked version
			_fired_this_press = true
		#start_reload() # IF WE WANT AUTO RELOAD
		return
	
	# NORMAL FIRE
	if weapon.automatic:
		_try_fire()
	else:
		if not _fired_this_press:
			_try_fire()
			_fired_this_press = true
			
@rpc("any_peer", "call_local")
func _play_empty():
	_play_sound(weapons[current_weapon_index].empty_sound)

func start_reload() -> void:
	if _is_reloading:
		return
	
	_pending_fire = false
	
	var weapon = weapons[current_weapon_index]
	if weapon.mag_current == weapon.mag_size:
		return

	_is_reloading = true
	_reload_timer = weapon.reload_time

	_play_sound(weapon.reload_sound)  # <-- ADD THIS

func _finish_reload() -> void:
	var weapon = weapons[current_weapon_index]
	weapon.mag_current = weapon.mag_size
	_is_reloading = false


func _reload():
	
	weapons[current_weapon_index].mag_current = weapons[current_weapon_index].mag_size


func _on_primary_fire_released() -> void:
	_fired_this_press = false

func _try_fire() -> void:
	if _fire_cooldown > 0.0 or _is_reloading or _pending_fire:
		return

	var weapon = weapons[current_weapon_index]

	_pending_fire = true
	_pre_fire_timer = weapon.pre_shoot_delay
	
func _do_fire() -> void:
	_pending_fire = false

	var weapon = weapons[current_weapon_index]

	_spawn_projectile.rpc_id(1)
	weapon.mag_current -= 1

	#_play_sound(weapon.shoot_sound)  # <-- ADD THIS

	_fire_cooldown = weapon.post_shoot_delay
	
	
	#recoil_on_server.rpc_id(1)
#
#@rpc("any_peer", "call_local")
#func recoil_on_server():
	#recoil.recoilFire()


@rpc("any_peer", "call_local")
func _spawn_projectile() -> void:
	var weapon = weapons[current_weapon_index]

	# --- Spawn only on authority ---
	if is_multiplayer_authority():
		var projectile_scene = weapon.projectile_scene.instantiate() as Node3D
		projectile_scene.global_transform = _parent_player.global_transform
		projectile_scene.shooter_name = _parent_player.name
		projectile_scene.set_damage(weapon.damage)

		var forward_dir: Vector3 = weapon_model_parent.global_transform.basis.z
		var SPEED := 100
		projectile_scene.velocity = -forward_dir * SPEED

		projectile_spawn_parent.add_child(projectile_scene, true)

	# --- Play sound on ALL clients ---
	_play_sound(weapon.shoot_sound)

func next_weapon():
	next_weapon_server.rpc_id(1)

func previous_weapon():
	previous_weapon_server.rpc_id(1)

@rpc("any_peer", "call_local")
func next_weapon_server():
	if is_multiplayer_authority():
		current_weapon_index += 1

@rpc("any_peer", "call_local")
func previous_weapon_server():
	if is_multiplayer_authority():
		current_weapon_index -= 1
	
