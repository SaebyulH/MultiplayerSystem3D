@tool
extends RigidBody3D
class_name SimpleProjectile

## The hurtbox/body this projectile is lodged in.  Held weakly: the target is a
## Player (or a child of it) and can be freed — a bot removed mid-match, or a
## disconnect — while the projectile is deliberately parented to the world and
## outlives it.  `_is_stuck` distinguishes "never attached" from "attached to
## something that has since died", which a null/falsy check cannot.
var _stuck_ref: WeakRef = null
## Replicated through this projectile's MultiplayerSynchronizer (spawn + change)
## so the trail, which is local on every peer, also stops at a surface on
## clients.  A stationary nozzle would otherwise keep emitting forever.
var _is_stuck := false:
	set(value):
		if value == _is_stuck:
			return
		_is_stuck = value
		if value:
			_stop_trail()
		else:
			_start_trail()
var _local_offset: Transform3D

# AUX
var shooter_name: String
var shooter_team: Player.Team

# ── Shootable ────────────────────────────────────────────────────────
## Physics layer of the dedicated shootable hurtbox (`_shot_hurtbox`, an
## `Area3D` created per projectile) so bullets can find it: a hitscan ray stops
## on it, and another projectile's swept ray in `_sweep_shot_hits()` tests it.
## The hurtbox is deliberately much larger than the body's own collision shape,
## which is never touched — shooting a projectile is meant to be easy.
## **No collision mask includes this layer** and the area's own mask is 0, so it
## generates no overlaps and no physical collision.  Bits 0-3 and 7 are already
## used (world `1`, player `2`, hurtbox `4`, hitbox `8`, ragdoll `128`); this
## takes bit 4.
const SHOT_HURTBOX_LAYER := 1 << 4
## Seconds a projectile must be in flight before another projectile can shoot
## it.  Covers volley / spread weapons whose projectiles spawn overlapping.
const PROJECTILE_SHOT_ARM_TIME := 0.2
## Detached `ShotHurtbox` areas are reused across projectiles instead of being
## created and freed per shot.
const SHOT_HURTBOX_POOL_LIMIT := 24
static var _shot_hurtbox_pool: Array = []

# ── Toon exhaust trail ───────────────────────────────────────────────
const TOON_TRAIL_SCENE := preload("res://effects/toon_trail/toon_trail.tscn")
const TOON_TRAIL_SCRIPT := preload("res://effects/toon_trail/toon_trail.gd")

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

## Water crossing latency.  Every projectile now has a trail swap, so the query
## runs at 10 Hz instead of once per rendered frame; 0.1 s is below the point a
## waterline crossing reads as late.  The detonation itself samples immediately.
const WATER_CHECK_INTERVAL := 0.1

var _trail: Node3D
var _trail_nozzle: Marker3D
## Water state the running trail was chosen for.  Recomputed only when
## [member underwater_trail_preset] is set, in `_process` (runs on every peer —
## `_physics_process` is authority-only).
var _trail_in_water := false
## Accumulates render delta until the next throttled water query.
var _water_check_accum := 0.0
## Cached map for the water query; re-resolved if a map swap frees it.
var _water_map: Map = null
## World-space contact latched at the frame `body_entered` fires.  The burst is
## played against the real surface normal and contact point, per
## `README-explosions.md`; `_contact_valid` distinguishes "never captured" from
## "captured at the origin".
var _contact_point := Vector3.ZERO
var _contact_normal := Vector3.ZERO
var _contact_valid := false

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

# ── Shootable (anyone may shoot a projectile) ────────────────────────
## Hit points.  Every shipped projectile authors 1, so any bullet takes the last
## point in one shot and triggers the behaviour below.
@export_range(1.0, 100.0, 1.0) var health: float = 1.0

## Radius in metres of the dedicated shootable `ShotHurtbox` sphere.  It is
## intentionally much larger than the model (1 m), so hitting a flying
## projectile is forgiving; it does not affect the projectile's own physical
## `CollisionShape3D`.
@export_range(0.1, 5.0, 0.05) var shot_hurtbox_radius: float = 1.0

enum ShotBehaviour {
	AUTO,     ## Derive from the authored hit modes (see `is_explosive()`).
	EXPLODE,  ## Force an air-burst detonation when shot (a sticky explosive).
	DEFLECT,  ## Force a redirect along the bullet's direction when shot.
}
## What happens when a bullet takes the last hit point: an explosive projectile
## detonates in the air, a non-explosive one is deflected along the shot.  AUTO
## is right for every scene whose contact mode already says which it is; MINE
## overrides to EXPLODE because its contact mode is STICK.
@export var shot_behaviour: ShotBehaviour = ShotBehaviour.AUTO

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

# ── Shootable ────────────────────────────────────────────────────────
## The dedicated, oversized shootable volume.  Authority-only and created in
## code (no scene has it), so scene `<projectile>.tscn` collision shapes stay
## exactly as authored.
var _shot_hurtbox: Area3D
## Authored value of [member health], restored after a deflection so the same
## projectile can be shot (and deflected) again.
var _max_health: float = 1.0
## Launch speed sampled at _ready(), used to restore speed after a deflection
## (an arrow shot out of a wall needs a speed its frozen body no longer has).
var _launch_speed: float = 0.0
## Set once a shot detonates this projectile, so the frozen 10 s despawn shell
## cannot be detonated a second time.
var _shot_dead := false


func _validate_property(property: Dictionary) -> void:
	if property.name in ["falloff_start", "falloff_end", "falloff_curve"]:
		if not falloff_enabled:
			property.usage = PROPERTY_USAGE_NO_EDITOR


func _ready() -> void:
	_hitbox_component.hit_hurtbox.connect(_on_hit_hurtbox)

	# Snapshot base damages and start position so falloff can scale without drift.
	_prev_position = global_position
	_max_health = health
	_launch_speed = linear_velocity.length()
	# Bullets find projectiles through the dedicated hurtbox area.  Built on
	# every peer (the nodes are replicated); only the authority runs the rays, so
	# a client's copy is simply never queried.
	if not Engine.is_editor_hint():
		_ensure_shot_hurtbox()
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
	if _is_stuck:
		return
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
	# Reuse a finished game trail from the shared pool; only instantiate when the
	# pool is empty.  Per-run state is reset by `start()`.
	var trail: Node3D = TOON_TRAIL_SCRIPT.acquire()
	if trail == null:
		trail = TOON_TRAIL_SCENE.instantiate() as Node3D
	if trail == null:
		return
	trail.set("auto_free", true)
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
func _process(delta: float) -> void:
	if Engine.is_editor_hint() or underwater_trail_preset.is_empty():
		return
	_water_check_accum += delta
	if _water_check_accum < WATER_CHECK_INTERVAL:
		return
	_water_check_accum = 0.0
	var in_water := _is_underwater()
	if in_water == _trail_in_water:
		return
	_trail_in_water = in_water
	_stop_trail()
	_start_trail()


## True while the projectile is inside a `WaterVolume`.  Same query the swimmer
## uses; cached map, so a rocket in flight costs one AABB test per frame.
func _is_underwater() -> bool:
	return _is_point_underwater(global_position)


## Water state at an arbitrary point, used to pick the underwater burst at
## detonation.  The map is static and identical on every peer, so the server's
## answer is deterministic.
func _is_point_underwater(point: Vector3) -> bool:
	if not is_instance_valid(_water_map):
		_water_map = null
		var spawn_parent := GameManager.spawn_parent
		if spawn_parent != null:
			_water_map = spawn_parent.get_node_or_null("Map") as Map
	if _water_map == null or not _water_map.has_water:
		return false
	return _water_map.is_point_in_water(point)


static var _cached_local_up := Vector3.ZERO
## Local gravity-up at the projectile.  Flat maps use world up; the setting is
## read once per process and cached.
func _local_up() -> Vector3:
	if _cached_local_up.is_zero_approx():
		var gravity: Vector3 = ProjectSettings.get_setting(
				"physics/3d/default_gravity_vector", Vector3.DOWN)
		_cached_local_up = (-gravity).normalized() if gravity.length_squared() > 0.0001 else Vector3.UP
	return _cached_local_up


## Keep the current collision contact latched every physics step.  This is the
## cheap surface test used at detonation: a grenade resting on a wall/floor has
## contacts, a grenade that stopped short of one has none.  Jolt reports contacts
## only while the body is awake, so a settled body keeps its last valid normal.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if state.get_contact_count() == 0:
		_contact_valid = false
		return
	var point := state.get_contact_local_position(0)
	var normal := state.get_contact_local_normal(0)
	if normal.length_squared() < 0.0001:
		# Fallback for a contact without a usable normal: for the sphere rocket
		# this centre-to-contact direction is exact; for other hulls it is close.
		normal = global_position - point
		if normal.length_squared() < 0.000001:
			return
	_contact_point = point
	_contact_normal = normal.normalized()
	_contact_valid = true


## Latch the solid-surface contact that just fired `body_entered`.  Used as the
## immediate sample before freeze; `_integrate_forces()` keeps it current each
## step for fuse detonations.  `get_contact_local_normal` was verified against a
## tilted slab (0.993 dot) to be the outward surface normal in world space; the
## centre-to-contact fallback covers a contact that reports no normal.
func _capture_contact() -> void:
	_contact_valid = false
	var state := PhysicsServer3D.body_get_direct_state(get_rid())
	if state == null or state.get_contact_count() == 0:
		return
	var point := state.get_contact_local_position(0)
	var normal := state.get_contact_local_normal(0)
	if normal.length_squared() < 0.0001:
		normal = global_position - point
		if normal.length_squared() < 0.000001:
			return
	_contact_point = point
	_contact_normal = normal.normalized()
	_contact_valid = true


## Surface normal when no contact was captured: the reversed travel direction
## is exact for a perpendicular hit and the best available guess otherwise.
func _fallback_normal() -> Vector3:
	var velocity := linear_velocity
	if velocity.length_squared() > 0.0001:
		return -velocity.normalized()
	return _local_up()


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
	_release_shot_hurtbox()


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


## Build the oversized shootable hurtbox: an `Area3D` on `SHOT_HURTBOX_LAYER`
## with a sphere of [member shot_hurtbox_radius].  It overlaps nothing (mask 0,
## monitoring off) — it exists only as a target for the hitscan ray and the
## projectile sweep.  Authority-only; the projectile's own `CollisionShape3D`
## is untouched.
func _ensure_shot_hurtbox() -> void:
	if is_instance_valid(_shot_hurtbox):
		return
	var area: Area3D = null
	while not _shot_hurtbox_pool.is_empty():
		area = _shot_hurtbox_pool.pop_back() as Area3D
		if not is_instance_valid(area):
			area = null
			continue
		if area.get_parent() != null:
			area.get_parent().remove_child(area)
		break
	if area == null:
		area = Area3D.new()
		area.name = "ShotHurtbox"
		area.collision_mask = 0
		area.monitoring = false
		area.monitorable = true
		var shape := CollisionShape3D.new()
		shape.name = "CollisionShape3D"
		var sphere := SphereShape3D.new()
		shape.shape = sphere
		area.add_child(shape)
	# Root re-parenting may have auto-renamed a duplicate while pooled;
	# `from_shot_collider()` identifies this area by name.
	area.name = "ShotHurtbox"
	area.collision_layer = SHOT_HURTBOX_LAYER
	area.position = Vector3.ZERO
	var shape_node := area.get_child(0) as CollisionShape3D
	if shape_node != null:
		var sphere := shape_node.shape as SphereShape3D
		if sphere != null:
			sphere.radius = shot_hurtbox_radius
	add_child(area)
	_shot_hurtbox = area


## Detach the shootable area and return it to the shared pool.  Safe to call on
## every peer and at any point in the projectile's life; the pooled area is
## re-armed by `_ensure_shot_hurtbox()` on the next projectile.
func _release_shot_hurtbox() -> void:
	var area := _shot_hurtbox
	_shot_hurtbox = null
	if not is_instance_valid(area):
		return
	if area.get_parent() == self:
		remove_child(area)
	area.position = Vector3.ZERO
	var tree := get_tree()
	if tree == null or _shot_hurtbox_pool.size() >= SHOT_HURTBOX_POOL_LIMIT:
		area.queue_free()
		return
	# Park it under the root so the RIDs are released with the tree instead of
	# leaking as detached objects; layer 0 keeps it inert while pooled.
	area.collision_layer = 0
	tree.root.add_child(area)
	_shot_hurtbox_pool.append(area)


## The projectile behind a hitscan / sweep collider: the `ShotHurtbox` Area3D
## (the normal case) or the RigidBody itself.  Null when the collider is not a
## projectile — callers use that to fall through to their other branches.
static func from_shot_collider(collider: Object) -> SimpleProjectile:
	var projectile := collider as SimpleProjectile
	if projectile != null:
		return projectile
	var area := collider as Area3D
	if area != null and area.name == "ShotHurtbox":
		return area.get_parent() as SimpleProjectile
	return null


## True when a bullet taking the last hit point detonates this projectile
## instead of deflecting it.  AUTO reads the authored hit modes: either EXPLODE
## mode, or a fuse that explodes on timeout, means explosive.  Everything else —
## the arrows, rocks, shurikens, balls and the calligraphy elements — deflects.
func is_explosive() -> bool:
	if shot_behaviour == ShotBehaviour.EXPLODE:
		return true
	if shot_behaviour == ShotBehaviour.DEFLECT:
		return false
	return world_hit_mode == WorldHitMode.EXPLODE \
			or hurtbox_hit_mode == HurtboxHitMode.EXPLODE \
			or explode_on_timeout


## One bullet's worth of damage on this projectile.  **Server-only** — both
## callers (`WeaponController._fire_single_shot`'s hitscan hit and
## `_sweep_shot_hits` below) are already inside an authority-gated path.
##
## The bullet that takes the last hit point either detonates an explosive
## projectile in the air or deflects a non-explosive one along
## [param shot_dir].  Anyone may do it: there is deliberately no team or
## ownership check here.
func take_bullet_hit(shot_dir: Vector3, attacker_name: String, attacker_team: Player.Team) -> void:
	# A projectile that already detonated (fuse, contact, SIGNAL) is a spent,
	# hidden shell; `start_explode()` has switched its hurtbox off already.
	if _shot_dead or (_explosion_component != null and _explosion_component.exploded):
		return
	health -= 1.0
	if health > 0.0:
		return
	if is_explosive():
		_shot_dead = true
		# Air burst: `start_explode(false)` still probes for a nearby surface, so
		# a mine shot while stuck to a wall gets the surface preset.
		start_explode(false)
		return
	_deflect(shot_dir, attacker_name, attacker_team)


## Redirect a non-explosive projectile along the shot and hand it to the
## deflector.  Re-owning it is load-bearing: the hitbox rejects a hit whose
## victim owns the projectile (`HitboxComponent` `hit_self`), so without the
## reassignment a reflected arrow could never hurt the player who fired it.
func _deflect(shot_dir: Vector3, attacker_name: String, attacker_team: Player.Team) -> void:
	if _is_stuck:
		_unstick()
	var dir := shot_dir.normalized()
	if dir.is_zero_approx():
		dir = -global_transform.basis.z
	# A deflected projectile keeps its speed; a projectile shot out of a wall
	# (frozen, velocity zero) uses the speed it launched with.
	linear_velocity = dir * maxf(linear_velocity.length(), _launch_speed)
	sleeping = false
	shooter_name = attacker_name
	shooter_team = attacker_team
	# Fresh flight: the deflected projectile gets its full lifetime back, and the
	# projectile-vs-projectile sweep re-arms.
	_time_alive = 0.0
	health = _max_health


## Let a bullet *projectile* shoot other projectiles.  Runs only on the
## authority, as a swept ray over the segment the body moved since the previous
## tick — collision shapes are deliberately not enabled between projectiles, so
## this ray is the only interaction, and sampling both endpoints stops a fast
## bullet tunnelling through a target between frames.
func _sweep_shot_hits() -> void:
	if _is_stuck or _prev_position.distance_squared_to(global_position) < 0.000001:
		return
	var query := PhysicsRayQueryParameters3D.create(
			_prev_position, global_position, SHOT_HURTBOX_LAYER)
	# Exclude the bullet's own body AND its own oversized hurtbox: the swept
	# segment always starts inside that sphere, so without this every ray would
	# hit self and report nothing.
	query.exclude = [get_rid()]
	if is_instance_valid(_shot_hurtbox):
		query.exclude.append(_shot_hurtbox.get_rid())
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var target := SimpleProjectile.from_shot_collider(hit.collider)
	if target == null or target == self:
		return
	target.take_bullet_hit(linear_velocity, shooter_name, shooter_team)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not is_multiplayer_authority():
		return
	# A shot-detonated projectile is frozen and waiting out the 10 s despawn;
	# nothing here applies to it any more.
	if _shot_dead:
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

	# Bullet projectiles shoot other projectiles.  Armed after a short delay so a
	# volley's own spawn overlap cannot detonate it.
	if _time_alive >= PROJECTILE_SHOT_ARM_TIME:
		_sweep_shot_hits()

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
		# Capture while the physics contact still exists, then freeze.
		_capture_contact()
		await start_explode(true)
	elif world_hit_mode == WorldHitMode.STICK:
		_attach_to(body)

## @param on_surface — true only for a solid-surface detonation.  Hurtbox hits,
##   timed airbursts and the SIGNAL path are air bursts and pass false.
func start_explode(on_surface := false):
	# Latch a contact while the body still exists physically: a grenade resting
	# on a floor/wall at fuse time reports the real surface here.  Stuck mines
	# latched theirs in `_attach_to()`.  No rays, no shape query.
	if not _contact_valid:
		_capture_contact()
	# The Davy Crockett's global alarm runs from arming through flight; this is
	# its normal end.  Server-authoritative RPC, so every peer stops together.
	_stop_shooter_equip_siren()
	# No trail left to re-preset while the projectile sits out its 10 s despawn.
	set_process(false)
	_stop_trail()
	_stop_siren()
	hide_model.rpc()
	# The shell lives on (invisibly) for 10 s; drop its hurtbox back into the pool
	# so nothing in flight can stop on, or shoot, a source nobody can see.
	_release_shot_hurtbox()
	freeze = true
	# Guide contract: a latched contact supplies the surface point and outward
	# normal; with no contact the burst is an air burst (zero normal, up axis).
	# Only the collision hull counts — a grenade that stopped 0.5 m short of a
	# wall is still an air burst.
	var up := _local_up()
	var point := global_position
	var normal := Vector3.ZERO
	if _contact_valid:
		point = _contact_point
		normal = _contact_normal
	elif on_surface:
		# Contact sample was unavailable (e.g. freed collider); travel direction
		# is the best guess.
		normal = _fallback_normal()
	var submerged := _is_point_underwater(point)
	# Multiply the explosion's base damage by the travel-time falloff so both
	# direct-hit and splash damage scale with projectile flight time.
	var falloff_mult := _compute_falloff_multiplier()
	if _explosion_component:
		_explosion_component.explode(falloff_mult, normal, point, submerged, up)
	await get_tree().create_timer(10.0).timeout
	if is_instance_valid(self):
		queue_free()

func _attach_to(body: Node3D) -> void:
	# Only world geometry (layer 1) gives a wall normal.  A mine stuck to a
	# player's hurtbox must stay an air burst, so that contact is not latched.
	if body is CollisionObject3D and ((body as CollisionObject3D).collision_layer & 1) != 0:
		_capture_contact()
	freeze = true
	_is_stuck = true
	_stuck_ref = weakref(body)
	_local_offset = body.global_transform.affine_inverse() * global_transform


## Release from whatever this projectile is lodged in, so it can fly again
## (used by redirectable projectiles on a weapon SIGNAL).
func _unstick() -> void:
	_is_stuck = false
	_stuck_ref = null
	_contact_valid = false
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
