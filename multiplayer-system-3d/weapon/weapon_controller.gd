class_name WeaponController extends Node

@export var current_weapon: Weapon
@export var weapon_model_parent: Node3D
@export var projectile_spawn_parent: Node3D
@export var player_input: PlayerInput

@onready var recoil = %CameraRecoil
@onready var camera = $"../CameraRecoil/Camera3D"
@onready var _parent_player: Player = $"../.."

var current_weapon_model: Node3D
var _fire_cooldown: float = 0.0
var _fired_this_press: bool = false

func _ready() -> void:
	if current_weapon:
		spawn_weapon_model()
	player_input.primary_fire.connect(_on_primary_fire_held)
	player_input.primary_fire_released.connect(_on_primary_fire_released)

func _physics_process(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

@rpc("authority", "call_local", "reliable")
func spawn_weapon_model() -> void:
	if current_weapon_model:
		current_weapon_model.queue_free()
	if current_weapon.weapon_model:
		current_weapon_model = current_weapon.weapon_model.instantiate()
		weapon_model_parent.add_child(current_weapon_model)
		current_weapon_model.position = current_weapon.weapon_offset
		current_weapon_model.rotation = current_weapon.weapon_rotation

func _on_primary_fire_held() -> void:
	if current_weapon.automatic:
		_try_fire()
	else:
		if not _fired_this_press:
			_try_fire()
			_fired_this_press = true

func _on_primary_fire_released() -> void:
	_fired_this_press = false

func _try_fire() -> void:
	if _fire_cooldown > 0.0:
		return
	_fire_cooldown = current_weapon.pre_shoot_delay + current_weapon.post_shoot_delay
	_spawn_projectile.rpc_id(1)
	recoil.recoilFire()

@rpc("any_peer", "call_local")
func _spawn_projectile() -> void:
	if is_multiplayer_authority():
		var projectile_scene = current_weapon.projectile_scene.instantiate() as Node3D
		projectile_scene.global_transform = _parent_player.global_transform
		projectile_scene.shooter_name = _parent_player.name
		var forward_dir: Vector3 = camera.global_transform.basis.z
		var SPEED := 100
		projectile_scene.velocity = -forward_dir * SPEED
		projectile_spawn_parent.add_child(projectile_scene, true)
