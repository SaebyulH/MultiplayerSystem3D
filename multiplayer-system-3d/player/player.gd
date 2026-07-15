extends CharacterBody3D
class_name Player


@export var acceleration: float = 40.0
@export var friction: float = 18.0
@export var air_acceleration: float = 100.0
@export var air_friction: float = 4.0
@export var tick_interpolator: TickInterpolator

@export var respawn_time: float = 1.5
var respawn_timer: float = 0.0

var is_bot: bool = false  # set by SpawnManager before add_child

var entity_id: String :
	get:
		return name   # for players, entity_id == name == str(network_id)
	set(value):
		name = value  # bots set this explicitly before add_child


var ads: bool = false

enum Team {SPI, SCI, FFA} #If set to FFA, you can damage anyone
const FRIENDLY_FIRE_MULTIPLIER = 0.0

signal team_changed()


var skins: Array[MeshInstance3D] = []

const TEAM_COLORS: Dictionary = {
	Team.SCI: Color.WHITE,
	Team.SPI: Color.BLACK,
}

var team: Team = Team.SPI:
	set(value):
		team = value
		if is_inside_tree():
			var color: Color = TEAM_COLORS.get(value, Color.PURPLE)
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			for skin in skins:
				if skin == null:
					continue
				skin.set_surface_override_material(0, mat)
		team_changed.emit()

func get_gmc_team() -> Player.Team:
		match team:
			Team.SPI: return Player.Team.SPI
			Team.SCI: return Player.Team.SCI
			_: return Player.Team.FFA


var knockback_velocity := Vector3.ZERO

var speed = 5.0
const JUMP_VELOCITY = 5.0

var queue_velocity := Vector3(0.0, 0.0, 0.0)

@export var player_input: PlayerInput
@export var rollback_sync: RollbackSynchronizer
@export var attribute_component: AttributeComponent
@onready var camera := %Camera3D
@export var body :Node3D


@export var weapon_controller: WeaponController
@onready var collider: CollisionShape3D = $CollisionShape3D
@onready var mesh: MeshInstance3D = $MeshInstance3D

var is_crouching: bool = false

@export var crouch_height: float = 1.0
@export var stand_height: float = 2.0

@export var crouch_speed_multiplier: float = 0.5


var spawn_manager: SpawnManager

var pitch := 0.0

# ── Respawn state ─────────────────────────────────
# Persistent across rollback: _spawn_pending_position is NOT consumed inside
# _rollback_tick, so re-simulations of death/respawn ticks always see it.
# It is consumed only in _physics_process (real frames only).
var _spawn_pending_position: Vector3 = Vector3.ZERO
var spawned := false

# Stored so late-joining peers can be synced with the correct weapon models.
var _loadout_primary_path: String = ""
var _loadout_secondary_path: String = ""

# Used to be _pending_spawn_position / _has_pending_spawn — removed.


func _enter_tree() -> void:
	if is_bot:
		player_input.set_multiplayer_authority(1)
		body.set_multiplayer_authority(1)
	else:
		var id := str(name).to_int()
		set_multiplayer_authority(1)
		player_input.set_multiplayer_authority(id)
		body.set_multiplayer_authority(id)


func _ready() -> void:
	skins = [
		$Body/Recoil/Head/WeaponParent/RightArm,
		$Body/Recoil/Head/WeaponParent/RightForearm,
		$Body/Recoil/Head/WeaponParent/LeftForearm,
		$Body/Recoil/Head/WeaponParent/LeftArm,
		$Body/Recoil/Head/Helmet,
		$Body/Torso,
		$Body/LeftLeg,
		$Body/RighLeg,
	]
	team = team

	add_to_group("players")
	attribute_component.health_changed.connect(_health_changed)
	attribute_component.no_health.connect(no_health)
	rollback_sync.process_settings()
	despawn()

func _health_changed():
	pass

func _get_spawn_position() -> Vector3:
	for node in GameManager.spawn_parent.get_children():
		if node is Map:
			return node.get_random_spawn_location(team)
	return Vector3.ZERO

@rpc("any_peer", "call_local")
func rpc_reset(pos: Vector3) -> void:
	despawn()
	respawn_timer = respawn_time
	_spawn_pending_position = pos
	velocity = Vector3.ZERO
	knockback_velocity = Vector3.ZERO

	# Reset health and weapons on every peer so clients stay in sync.
	attribute_component.reset()
	weapon_controller.reset()

## Full-state sync for a late-joining peer.  Handles visibility and weapon
## loadout in one atomic RPC so the player does not flicker into view with
## wrong weapon models.
@rpc("authority", "call_remote", "reliable")
func rpc_sync_full_state(pos: Vector3, pp: String, sp: String) -> void:
	# -- Weapons first (before spawn, so correct model is visible) --
	if not pp.is_empty() and not sp.is_empty():
		var ctrl: WeaponController = $WeaponController
		if ctrl:
			var primary: Weapon = load(pp) as Weapon
			var secondary: Weapon = load(sp) as Weapon
			if primary and secondary:
				var nw: Array[Weapon] = [
					primary.duplicate(true) as Weapon,
					secondary.duplicate(true) as Weapon,
				]
				ctrl.set_weapons(nw)
				ctrl.current_weapon_index = 0

	# -- Visibility --
	if spawned:
		return
	global_position = pos
	velocity = Vector3.ZERO
	knockback_velocity = Vector3.ZERO
	spawn()


func no_health() -> void:
	if OS.is_debug_build():
		print(name + " KILLED BY " + attribute_component.last_attacker)

	# State reset is handled inside rpc_reset so it runs on every peer.
	if multiplayer.is_server():
		rpc_reset.rpc(_get_spawn_position())

@rpc("call_local")
func _sync_head():
	$HeadHurtbox.global_rotation = %Head.global_rotation
	$BodyHurtbox.global_rotation = $Body.global_rotation


## Hide the player: disable collision, stop camera, move off-grid.
## Projectiles (child of ProjectilesParent) are NOT touched.
func despawn():
	hide()
	spawned = false
	collider.disabled = true
	global_position = GameManager.get_despawn_position()
	$Body/PlayerUI.hide()
	camera.current = false
	camera.visible = false

## Show the player: enable collision, restore camera, position at the given
## location (already set before calling this).
func spawn():
	show()
	spawned = true
	collider.disabled = false
	$Body/PlayerUI.show()
	if not is_bot:
		var my_id := multiplayer.get_unique_id()
		var player_id := name.to_int()
		if my_id == player_id:
			camera.make_current()
			$BodyHurtbox/MeshInstance3D2.hide()
			$BodyHurtbox/CollisionShape3D.hide()
		else:
			camera.current = false
			camera.visible = false
	else:
		camera.current = false
		camera.visible = false


func _physics_process(delta: float) -> void:
	if respawn_timer > 0.0:
		respawn_timer -= delta
	# Only auto-spawn when a spawn position was explicitly queued (e.g. by
	# rpc_reset from class-select or death).  This prevents the player from
	# popping into the world before class select.
	elif not spawned and _spawn_pending_position != Vector3.ZERO:
		var pos := _spawn_pending_position
		_spawn_pending_position = Vector3.ZERO
		global_position = pos
		velocity = Vector3.ZERO
		knockback_velocity = Vector3.ZERO
		spawn()

func _rollback_tick(delta, tick, is_fresh):
	# ── Respawn / teleport handling ────────────────
	# _spawn_pending_position persists across re-simulation because it is
	# consumed only in _physics_process (real frames only).  Every rollback
	# tick, whether fresh or re-simulated, sees the same flag and teleports.
	if _spawn_pending_position != Vector3.ZERO:
		global_position = _spawn_pending_position
		velocity = Vector3.ZERO
		tick_interpolator.teleport()
		return

	# Don't simulate movement while dead (no respawn queued yet).
	if not spawned:
		return

	_apply_movement_from_input(delta)

func _force_update_is_on_floor():
	var old_velocity = velocity
	velocity = Vector3.ZERO
	move_and_slide()
	velocity = old_velocity


func apply_knockback(force: Vector3) -> void:
	if force.length() < 0.01:
		return
	knockback_velocity += force


func _apply_movement_from_input(delta):
	_force_update_is_on_floor()
	var on_floor := is_on_floor()

	if not on_floor:
		velocity += get_gravity() * delta
	elif player_input.jump_input:
		knockback_velocity = Vector3.ZERO
		velocity.y = JUMP_VELOCITY

	var input_dir := player_input.input_dir
	var cam_basis: Basis = camera.global_transform.basis
	var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var direction := (forward * input_dir.y + right * input_dir.x).normalized()

	var calc_speed: float = speed
	var weapons := weapon_controller.get_weapons()
	if not weapons.is_empty():
		calc_speed = speed * weapons[weapon_controller.current_weapon_index].player_speed_multiplier
	if is_crouching:
		calc_speed *= crouch_speed_multiplier

	if on_floor:
		# Ground movement
		if direction:
			var target_x := direction.x * calc_speed
			var target_z := direction.z * calc_speed
			velocity.x = move_toward(velocity.x, target_x, acceleration * delta)
			velocity.z = move_toward(velocity.z, target_z, acceleration * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, friction * delta)
			velocity.z = move_toward(velocity.z, 0.0, friction * delta)
	else:
		# Source-style air strafe
		var max_air_speed: float = calc_speed * 1.15
		var horiz_vel: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		var proj_vel: Vector3 = horiz_vel.dot(direction) * direction
		var is_away: bool = direction.dot(proj_vel) <= 0.0
		if direction.length() > 0.0 and (proj_vel.length() < max_air_speed or is_away):
			var vc: Vector3 = direction * air_acceleration * delta
			if not is_away:
				var max_add: float = max_air_speed - proj_vel.length()
				if max_add > 0.0:
					vc = vc.limit_length(max_add)
				else:
					vc = Vector3.ZERO
			else:
				vc = vc.limit_length(max_air_speed + proj_vel.length())
			velocity.x += vc.x
			velocity.z += vc.z
		# No friction in air -- horizontal velocity persists.

	velocity *= NetworkTime.physics_factor
	velocity += knockback_velocity
	move_and_slide()
	velocity /= NetworkTime.physics_factor

	var knockback_decay: float = velocity.length() ** 2 * 10
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)

	if ads:
		camera.fov = 20.0
		body.mouse_sens_x = 0.002 * 0.268
		body.mouse_sens_y = 0.002 * 0.268
		speed = 2.5
	else:
		camera.fov = 90.0
		body.mouse_sens_x = 0.002
		body.mouse_sens_y = 0.002
		speed = 5.0

func change_health(health: float, changer: String):
	attribute_component.apply_health_delta(health, changer, self.name)
