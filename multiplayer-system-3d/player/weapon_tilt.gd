class_name WeaponTilt
extends Node3D

## Procedural weapon sway and fire shake.
##
## This node's transform is copied onto the mannequin's gun bone (via a
## CopyTransformModifier3D in player.tscn), so rotating it moves the weapon
## independently of the rest of the body.  It combines two effects:
##
##   1. Sway  — the weapon lags a bounded amount behind the camera as it turns
##              and rolls into the turn, like most FPS games.
##   2. Shake — a sharp, random recoil jitter that runs only while firing and
##              grows with spread and recoil.
##
## Only the local player's own weapon sways (body is only authoritative on the
## peer that controls it), so remote players keep their IK-driven pose.

@export_group("Sway (camera turn)")
## Weapon lag per unit of turn velocity (radians of offset per rad/s of turn).
@export var sway_amount: float = 0.02
## Roll into the turn (radians of roll per rad/s of yaw velocity).
@export var sway_tilt: float = 0.015
## How quickly the sway tracks the turn velocity (higher = tighter / less lag).
@export var sway_follow: float = 25.0
## Maximum angular offset between the weapon and the aim direction (radians).
@export var sway_max: float = 0.08

@export_group("Shake (while firing)")
## Per-frame random impulse that drives the shake (radians).
@export var shake_impulse: float = 0.006
## Extra impulse added as spread reaches max (radians).
@export var spread_shake: float = 0.02
## Extra impulse added for high-recoil weapons (radians).
@export var recoil_shake: float = 0.015
## Extra impulse from an active recoil kick (radians).
@export var kick_shake: float = 0.06
## Recoil strength (radians) considered "high" for [member recoil_shake].
@export var recoil_reference: float = 1.0
## Maximum shake offset (radians).
@export var shake_max: float = 0.04
## How fast the applied shake snaps to its target (higher = sharper).
@export var shake_snap: float = 25.0

@onready var _body: Node3D = get_parent() as Node3D
@onready var _recoil: Recoil = _body.get_node("Recoil") as Recoil
@onready var _weapon_controller: WeaponController = _body.get_parent().get_node("WeaponController") as WeaponController

## The authored basis from the scene, captured once so we can layer sway/shake
## on top of it without drifting.
var _base_basis: Basis
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0
var _sway: Vector3 = Vector3.ZERO
var _shake_target: Vector3 = Vector3.ZERO
var _shake: Vector3 = Vector3.ZERO


func _ready() -> void:
	_base_basis = basis
	if _body != null:
		_last_yaw = _body.rotation.y
	if _recoil != null:
		_last_pitch = _recoil.global_rotation.x


func _process(delta: float) -> void:
	if _body == null or _recoil == null or not _body.is_multiplayer_authority():
		return

	# -- Sway: weapon trails the camera turn, bounded to sway_max -------------
	# Camera turn velocity comes from the frame-to-frame change in the body yaw
	# and the recoil node's global pitch (the real head direction).  Mouse look
	# runs in body.gd's _input, before _process, so the deltas reflect this frame.
	var yaw := _body.rotation.y
	var pitch := _recoil.global_rotation.x
	var yaw_vel := wrapf(yaw - _last_yaw, -PI, PI) / maxf(delta, 0.0001)
	var pitch_vel := (pitch - _last_pitch) / maxf(delta, 0.0001)
	_last_yaw = yaw
	_last_pitch = pitch

	# Sign conventions are tuned by eye; flip them if the motion feels inverted.
	var sway_target := Vector3(
		-pitch_vel * sway_amount,  # pitch lag
		-yaw_vel * sway_amount,    # yaw lag
		-yaw_vel * sway_tilt       # roll into the turn
	).limit_length(sway_max)
	_sway = _sway.lerp(sway_target, 1.0 - exp(-sway_follow * delta))

	# -- Shake: random recoil jitter, only while firing -----------------------
	if _is_firing():
		_shake_target += Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		) * _shake_impulse()
		_shake_target = _shake_target.limit_length(shake_max)
		_shake = _shake.lerp(_shake_target, 1.0 - exp(-shake_snap * delta))
	else:
		# Stop the instant firing ends — no lingering settle.
		_shake_target = Vector3.ZERO
		_shake = Vector3.ZERO

	# Layer sway + shake onto the authored basis in local space.
	basis = _base_basis * Basis.from_euler(_sway + _shake)


## True while the weapon controller reports an active fire cycle — the same
## flag it uses for the shoot speed multiplier.
func _is_firing() -> bool:
	return _weapon_controller != null and _weapon_controller.is_firing()


## Shake impulse magnitude this frame, scaled by spread, recoil strength, and
## the active recoil kick.
func _shake_impulse() -> float:
	var amp := shake_impulse
	amp += _spread_factor() * spread_shake
	amp += _recoil_strength_factor() * recoil_shake
	amp += _recoil_kick() * kick_shake
	return amp


## Accumulated spread as a 0..1 fraction of the current weapon's max spread.
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
	return clampf(_weapon_controller.get_current_spread() / maxf(weapon.max_spread, 0.01), 0.0, 1.0)


## The weapon's recoil strength as a 0..1 fraction of [member recoil_reference].
func _recoil_strength_factor() -> float:
	if _recoil == null:
		return 0.0
	var strength := _recoil.recoil.length() + _recoil.aim_recoil.length()
	return clampf(strength / maxf(recoil_reference, 0.01), 0.0, 1.0)


## Magnitude of the recoil currently kicking the camera (0..1 clamped).
func _recoil_kick() -> float:
	if _recoil == null:
		return 0.0
	return minf(_recoil.current_rotation.length(), 1.0)
