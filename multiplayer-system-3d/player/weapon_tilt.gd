class_name WeaponTilt
extends Node3D

## Procedural weapon sway and fire shake.

@export_group("Sway (camera movement)")
@export var sway_yaw: float = 1.5 ## Horizontal sway strength from camera yaw movement.
@export var sway_pitch: float = 1.5 ## Vertical sway strength from camera pitch movement.
@export var sway_roll: float = 1.0 ## Roll sway strength from horizontal camera movement.
@export var sway_max: float = 0.08 ## Maximum overall sway rotation.
@export var sway_speed: float = 12.0 ## Speed at which sway responds to camera movement.
@export var sway_return: float = 8.0 ## Speed at which sway returns to neutral when the camera stops moving.

@export_group("Head Follow")
@export var head_follow_speed: float = 15.0 ## Speed at which the weapon follows the head's vertical rotation.

@export_group("Shake (while firing)")
@export var shake_impulse: float = 0.006 ## Base random shake applied each frame while firing.
@export var spread_shake: float = 0.02 ## Additional shake based on the weapon's current spread.
@export var recoil_shake: float = 0.015 ## Additional shake based on the weapon's recoil strength.
@export var kick_shake: float = 0.06 ## Additional shake based on the current recoil kick.
@export var recoil_reference: float = 1.0 ## Recoil strength that corresponds to maximum recoil-based shake.
@export var shake_max: float = 0.04 ## Maximum overall firing shake.
@export var shake_snap: float = 25.0 ## Speed at which firing shake reaches its target.

@onready var _body: Node3D = get_parent() as Node3D
@onready var _recoil: Recoil = _body.get_node("Recoil") as Recoil
@onready var _weapon_controller: WeaponController = _body.get_parent().get_node("WeaponController") as WeaponController


var _base_rotation: Vector3

var _last_yaw: float = 0.0
var _last_pitch: float = 0.0

var _sway: Vector3 = Vector3.ZERO

var _shake_target: Vector3 = Vector3.ZERO
var _shake: Vector3 = Vector3.ZERO

var _head_rotation_x: float = 0.0


func _ready() -> void:
	_base_rotation = rotation

	if _body != null:
		_last_yaw = _body.rotation.y

	if %Head != null:
		_last_pitch = %Head.rotation.x
		_head_rotation_x = %Head.rotation.x


func _process(delta: float) -> void:
	if _body == null or _recoil == null or not _body.is_multiplayer_authority():
		return

	# -------------------------------------------------------------------------
	# SWAY
	# -------------------------------------------------------------------------

	var yaw := _body.rotation.y
	var pitch: float = %Head.rotation.x + _recoil.rotation.x + %Camera3D.rotation.x

	var yaw_delta := wrapf(yaw - _last_yaw, -PI, PI)
	var pitch_delta := wrapf(pitch - _last_pitch, -PI, PI)

	_last_yaw = yaw
	_last_pitch = pitch

	var sway_target := Vector3(
		pitch_delta * sway_pitch,
		-yaw_delta * sway_yaw,
		-yaw_delta * sway_roll
	)

	sway_target = sway_target.limit_length(sway_max)

	_sway = _sway.lerp(
		sway_target,
		1.0 - exp(-sway_speed * delta)
	)

	if absf(yaw_delta) < 0.0001 and absf(pitch_delta) < 0.0001:
		_sway = _sway.lerp(
			Vector3.ZERO,
			1.0 - exp(-sway_return * delta)
		)

	# -------------------------------------------------------------------------
	# SHAKE
	# -------------------------------------------------------------------------

	if _is_firing():
		_shake_target += Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		) * _shake_impulse()

		_shake_target = _shake_target.limit_length(shake_max)

		_shake = _shake.lerp(
			_shake_target,
			1.0 - exp(-shake_snap * delta)
		)
	else:
		_shake_target = Vector3.ZERO
		_shake = Vector3.ZERO

	# -------------------------------------------------------------------------
	# APPLY
	# -------------------------------------------------------------------------

	# Smoothly follow the head's X rotation independently.
	_head_rotation_x = lerpf(
		_head_rotation_x,
		-%Head.rotation.x,
		1.0 - exp(-head_follow_speed * delta)
	)

	rotation.x = _base_rotation.x +_head_rotation_x - 1.1 * _recoil.rotation.x + _sway.x + _shake.x
	rotation.y = _base_rotation.y + _sway.y + _shake.y
	rotation.z = _base_rotation.z + _sway.z + _shake.z


func _is_firing() -> bool:
	return _weapon_controller != null and _weapon_controller.is_firing()


func _shake_impulse() -> float:
	var amp := shake_impulse

	amp += _spread_factor() * spread_shake
	amp += _recoil_strength_factor() * recoil_shake
	amp += _recoil_kick() * kick_shake

	return amp


func _spread_factor() -> float:
	if _weapon_controller == null:
		return 0.0

	var weapons := _weapon_controller.get_weapons()

	if weapons.is_empty():
		return 0.0

	var index: int = _weapon_controller.current_weapon_index

	if index < 0 or index >= weapons.size():
		return 0.0

	var weapon: Weapon = weapons[index]

	return clampf(
		_weapon_controller.get_current_spread()
		/ maxf(weapon.max_spread, 0.01),
		0.0,
		1.0
	)


func _recoil_strength_factor() -> float:
	if _recoil == null:
		return 0.0

	var strength := (
		_recoil.recoil.length()
		+ _recoil.aim_recoil.length()
	)

	return clampf(
		strength / maxf(recoil_reference, 0.01),
		0.0,
		1.0
	)


func _recoil_kick() -> float:
	if _recoil == null:
		return 0.0

	return minf(
		_recoil.current_rotation.length(),
		1.0
	)
