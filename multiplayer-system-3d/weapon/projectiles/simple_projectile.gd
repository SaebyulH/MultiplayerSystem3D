@tool
extends RigidBody3D
class_name SimpleProjectile

var _stuck_to: Node3D = null
var _local_offset: Transform3D

# AUX
var shooter_name: String
var shooter_team: Player.Team


var _time_alive := 0.0
var _distance_traveled := 0.0
var _prev_position: Vector3
@export var lifetime: float = 5.0
@export var explode_on_timeout: bool = false
# DAMAGE COMPONENTS
@export var _hitbox_component: HitboxComponent
@export var _explosion_component: ExplosionComponent

enum HurtboxHitMode {DISSAPEAR, PASSTHROUGH, EXPLODE, STICK}
@export var hurtbox_hit_mode: HurtboxHitMode

enum WorldHitMode {DISSAPEAR, NOTHING, EXPLODE, STICK}
@export var world_hit_mode: WorldHitMode

## If true, the projectile rotates to face its velocity direction while in flight.
## Disabled automatically when stuck to a surface.
@export var align_to_velocity: bool = false

# ── Distance-based damage falloff ────────────────────────────────────
## Configured per-projectile scene.  Uses _distance_traveled (metres) as the
## input to the falloff curve — e.g. a rocket that loses punch over distance.
@export var falloff_enabled: bool = true:
	set(value):
		falloff_enabled = value
		notify_property_list_changed()
@export var falloff_start: float = 10.0   ## metres until damage begins to drop
@export var falloff_end: float = 30.0    ## metres until damage reaches curve minimum
@export var falloff_curve: CurveTexture = preload("res://defaults/projectile_default_damage_falloff_curve.tres")

## Original damage values saved at _ready() so we can scale them each frame.
var _base_hitbox_damage: float = 0.0
var _base_explosion_damage: float = 0.0


func _validate_property(property: Dictionary) -> void:
	if property.name in ["falloff_start", "falloff_end", "falloff_curve"]:
		if not falloff_enabled:
			property.usage = PROPERTY_USAGE_NO_EDITOR


func _ready() -> void:
	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)

	# Snapshot base damages and start position so falloff can scale without drift.
	_prev_position = global_position
	_base_hitbox_damage = _hitbox_component.health_delta
	if _explosion_component:
		_base_explosion_damage = _explosion_component.splash_health_delta

	_connect_detonate_signal()


## Looks up the shooter's WeaponController and connects its signal_activated
## to this projectile's start_explode, so pressing the SIGNAL fire mode
## detonates all linked projectiles.
func _connect_detonate_signal() -> void:
	var shooter := GameManager.find_player(shooter_name)
	if shooter:
		shooter.weapon_controller.signal_activated.connect(
			#_on_weapon_signal, CONNECT_ONE_SHOT
			_on_weapon_signal
			
		)


func _on_weapon_signal(target: Vector3, player_transform: Vector3) -> void:
	# Only the server applies damage.  The signal fires on every peer, but
	# explode() applies splash damage — without this guard each peer would
	# deal the full explosion damage, multiplying it by the player count.
	if not is_multiplayer_authority():
		return
	await start_explode()


## Samples the falloff curve using _distance_traveled (metres) as the input.
## Returns 1.0 (full damage) when falloff is disabled or the curve is missing.
func _compute_falloff_multiplier() -> float:
	if not falloff_enabled or falloff_curve == null:
		return 1.0
	var t: float
	if falloff_end == falloff_start:
		t = 0.0
	else:
		t = (_distance_traveled - falloff_start) / (falloff_end - falloff_start)
	t = clamp(t, 0.0, 1.0)
	var curve: Curve = falloff_curve.curve
	if curve == null:
		return 1.0
	return curve.sample(t)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not is_multiplayer_authority():
		return

	if _stuck_to:
		global_transform = _stuck_to.global_transform * _local_offset
	elif align_to_velocity:
		var vel := linear_velocity
		if vel.length_squared() > 0.01:
			look_at(global_position + vel, Vector3.UP)

	if _time_alive >= lifetime:
		if explode_on_timeout:
			if _explosion_component:
				await start_explode()
		else:
			queue_free()
		return
	else:
		_time_alive += delta

	# Track distance travelled for falloff (metres).
	_distance_traveled += (global_position - _prev_position).length()
	_prev_position = global_position

	# Apply distance-based falloff to hitbox damage every frame so the
	# HitboxComponent always carries the correct falloff-adjusted value
	# when area_entered fires (before _on_hit_hurtbox is called).
	if falloff_enabled and _base_hitbox_damage != 0.0:
		var mult := _compute_falloff_multiplier()
		_hitbox_component.health_delta = _base_hitbox_damage * mult
		_hitbox_component.current_falloff_multiplier = mult


func _on_hit_hurtbox(hurtbox: HurtboxComponent) -> void:
	if not is_multiplayer_authority():
		return

	if hurtbox_hit_mode == HurtboxHitMode.DISSAPEAR:
		queue_free()

	elif hurtbox_hit_mode == HurtboxHitMode.PASSTHROUGH:
		pass
	elif hurtbox_hit_mode == HurtboxHitMode.EXPLODE:
		await start_explode()
	elif world_hit_mode == WorldHitMode.STICK:
		_attach_to(hurtbox)

@rpc("any_peer","call_local", "reliable")
func hide_model():
	for child in get_children():
		if child is MeshInstance3D:
			child.hide()


func _on_body_entered(body: Node3D) -> void:
	if not is_multiplayer_authority():
		return


	if world_hit_mode == WorldHitMode.DISSAPEAR:
		queue_free()
	elif world_hit_mode == WorldHitMode.NOTHING:
		pass
	elif world_hit_mode == WorldHitMode.EXPLODE:
		await start_explode()
	elif world_hit_mode == WorldHitMode.STICK:
		_attach_to(body)

func start_explode():
	hide_model.rpc()
	freeze = true
	# Multiply the explosion's base damage by the travel-time falloff so both
	# direct-hit and splash damage scale with projectile flight time.
	var falloff_mult := _compute_falloff_multiplier()
	if _explosion_component:
		_explosion_component.explode(falloff_mult)
	await get_tree().create_timer(10.0).timeout
	if is_instance_valid(self):
		queue_free()

func _attach_to(body: Node3D) -> void:
	freeze = true
	_stuck_to = body
	_local_offset = body.global_transform.affine_inverse() * global_transform
