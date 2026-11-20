@tool
extends RigidBody3D
class_name SimpleProjectile

## The hurtbox/body this projectile is lodged in.  Held weakly: the target is a
## Player (or a child of it) and can be freed — a bot removed mid-match, or a
## disconnect — while the projectile is deliberately parented to the world and
## outlives it.  `_is_stuck` distinguishes "never attached" from "attached to
## something that has since died", which a null/falsy check cannot.
var _stuck_ref: WeakRef = null
var _is_stuck := false
var _local_offset: Transform3D

# AUX
var shooter_name: String
var shooter_team: Player.Team

# ── Toon exhaust trail ───────────────────────────────────────────────
const TOON_TRAIL_SCENE := preload("res://effects/toon_trail/toon_trail.tscn")

## Preset id from `effects/toon_trail/trail_profiles.gd`.  Empty = no trail.
## Purely cosmetic and local: every peer spawns its own from this scene value,
## so no RPC and nothing rides the synchronizer.
@export var trail_preset: String = ""
## Preset used while the projectile is inside a water volume.  Empty = never
## switch; the projectile keeps [member trail_preset] everywhere.
##
## The swap is local on every peer, driven by the same replicated `WaterVolume`
## geometry the swimmer uses (`Map.is_point_in_water`), so no RPC is needed and
## every peer sees the same trail.  Mid-flight crossings restart the trail: the
## old emission stops and drains while the underwater one begins at the
## waterline, which is the intended read.
@export var underwater_trail_preset: String = ""
@export_range(0.05, 16.0, 0.01) var trail_scale: float = 1.0
## Local nozzle offset.  The trail treats the marker's -Z as its forward axis;
## `align_to_velocity` projectiles already point -Z along the flight path.
@export var trail_nozzle_offset: Vector3 = Vector3.ZERO

var _trail: Node3D
var _trail_nozzle: Marker3D
## Water state the running trail was chosen for.  Recomputed only when
## [member underwater_trail_preset] is set, in `_process` (runs on every peer —
## `_physics_process` is authority-only).
var _trail_in_water := false
## Cached map for the water query; re-resolved if a map swap frees it.
var _water_map: Map = null

# ── Falling alarm (nuke) ─────────────────────────────────────────────
## Optional looping siren while this projectile is in flight, used by the
## nuke.  Local per peer, like the trail: every peer starts its own copy.
@export var fall_siren: AudioStream
@export_range(-40.0, 12.0, 0.5) var fall_siren_volume_db := -14.0
## 3D attenuation size in metres; large so the alarm carries across the map.
@export_range(1.0, 120.0, 0.5) var fall_siren_unit_size := 50.0
## When true, detonating also stops the shooter's global equip siren (the Davy
## Crockett arming alarm).  The server broadcasts the stop to every peer; a
## scene flag rather than a class test so any projectile can opt in.
@export var stops_equip_siren_on_explosion: bool = false

var _siren: AudioStreamPlayer3D


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

	if not Engine.is_editor_hint():
		_trail_in_water = _is_underwater()
		_start_trail()
		_start_siren()
		# The water check runs on every peer, so it cannot live in
		# `_physics_process` (authority-only).  Do not process at all when the
		# scene has no underwater variant.
		set_process(not underwater_trail_preset.is_empty())


## Start the exhaust trail on this peer.  The trail node is parented to the
## world above the ProjectilesParent: that parent's MultiplayerSpawner
## replicates every direct child and only knows projectile scenes, and the
## trail must also outlive this projectile so its samples can drain.
func _start_trail() -> void:
	var preset := _active_trail_preset()
	if preset.is_empty() or not is_inside_tree():
		return
	var host := _effect_host()
	if host == null:
		return
	# Reuse the nozzle across a mid-flight water crossing, so the trail restarts
	# from the same point instead of snapping to a newly created marker.
	if not is_instance_valid(_trail_nozzle):
		_trail_nozzle = Marker3D.new()
		_trail_nozzle.position = trail_nozzle_offset
		add_child(_trail_nozzle)
	var trail: Node3D = TOON_TRAIL_SCENE.instantiate() as Node3D
	if trail == null:
		return
	trail.effect_scale = trail_scale
	host.add_child(trail)
	if not trail.start(preset, _trail_nozzle):
		trail.queue_free()
		return
	_trail = trail


## The preset for the current water state.
func _active_trail_preset() -> String:
	if not underwater_trail_preset.is_empty() and _trail_in_water:
		return underwater_trail_preset
	return trail_preset


## Swap the trail when a rocket crosses a water surface.
##
## `toon_trail.stop()` stops emitting and lets the existing fire/smoke drain, so
## the old trail ends at the waterline while the new one starts there.  Runs on
## every peer, from replicated map geometry only.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or underwater_trail_preset.is_empty():
		return
	var in_water := _is_underwater()
	if in_water == _trail_in_water:
		return
	_trail_in_water = in_water
	_stop_trail()
	_start_trail()


## True while the projectile is inside a `WaterVolume`.  Same query the swimmer
## uses; cached map, so a rocket in flight costs one AABB test per frame.
func _is_underwater() -> bool:
	if not is_instance_valid(_water_map):
		_water_map = null
		var spawn_parent := GameManager.spawn_parent
		if spawn_parent != null:
			_water_map = spawn_parent.get_node_or_null("Map") as Map
	if _water_map == null:
		return false
	return _water_map.is_point_in_water(global_position)


func _effect_host() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	var world := parent.get_parent()
	return world as Node3D if world is Node3D else parent as Node3D


func _stop_trail() -> void:
	if is_instance_valid(_trail):
		_trail.stop()
	_trail = null


## Loop [member fall_siren] from spawn until the projectile detonates.  The
## stream is duplicated so enabling `loop` never mutates the loaded resource.
func _start_siren() -> void:
	if fall_siren == null or not is_inside_tree():
		return
	var stream: AudioStream = fall_siren.duplicate()
	if stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	else:
		stream.set("loop", true)
	_siren = AudioStreamPlayer3D.new()
	_siren.stream = stream
	_siren.volume_db = fall_siren_volume_db
	_siren.unit_size = fall_siren_unit_size
	_siren.max_distance = 250.0
	add_child(_siren)
	_siren.play()


func _stop_siren() -> void:
	if is_instance_valid(_siren):
		_siren.stop()
		_siren.queue_free()
	_siren = null


## Stop the shooter's global arming siren at detonation.  Only the server has
## the authoritative `start_explode()` call; the RPC reaches every peer.
func _stop_shooter_equip_siren() -> void:
	if not stops_equip_siren_on_explosion or not multiplayer.is_server():
		return
	var shooter := GameManager.find_player(shooter_name)
	if shooter != null and shooter.ability_manager != null:
		shooter.ability_manager.stop_equip_siren_on_explosion.rpc()


func _exit_tree() -> void:
	_stop_trail()
	_stop_siren()


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

	if _is_stuck:
		var stuck := _stuck_target()
		if stuck == null:
			# Nothing left to ride — the player/hurtbox it stuck into is gone.
			queue_free()
			return
		global_transform = stuck.global_transform * _local_offset
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

@rpc("authority", "call_local", "reliable")
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
	# The Davy Crockett's global alarm runs from arming through flight; this is
	# its normal end.  Server-authoritative RPC, so every peer stops together.
	_stop_shooter_equip_siren()
	# No trail left to re-preset while the projectile sits out its 10 s despawn.
	set_process(false)
	_stop_trail()
	_stop_siren()
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
	_is_stuck = true
	_stuck_ref = weakref(body)
	_local_offset = body.global_transform.affine_inverse() * global_transform


## Release from whatever this projectile is lodged in, so it can fly again
## (used by redirectable projectiles on a weapon SIGNAL).
func _unstick() -> void:
	_is_stuck = false
	_stuck_ref = null
	freeze = false
	sleeping = false


## The object this projectile is lodged in, if it is still alive.
func _stuck_target() -> Node3D:
	if _stuck_ref == null:
		return null
	var ref: Variant = _stuck_ref.get_ref()
	if not is_instance_valid(ref):
		return null
	return ref as Node3D
