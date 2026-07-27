extends CharacterBody3D
class_name Player


@export var acceleration: float = 100.0
@export var friction: float = 30.0
@export var air_acceleration: float = 25
#accell
@export var air_speed_cap: float = 1.5
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

## Active shield instance — spawned when a SHIELD fire-mode is toggled on.
var shield_instance: PlayerShield = null
## The WeaponFire that spawned the current shield (null if no shield).
var _active_shield_fire: WeaponFire = null

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
@onready var damage_number_manager: DamageNumberManager = $DamageNumberManager

var is_crouching: bool = false

# Character selection
var _character: Character = null

@export var crouch_height: float = 1.0
@export var stand_height: float = 2.0
@export var crouch_transition_speed: float = 40.0

@export var crouch_speed_multiplier: float = 0.5

# Crouch acceleration is low regardless of speed — you can't gain much speed
# while crouched, you can only preserve what you already have.
@export var crouch_ground_acceleration: float = 15.0

# Crouch / slide friction scales with current speed.
# Slow/stopped → normal friction (regular crouch).
# Fast       → near-zero friction (slide, preserves momentum).
@export var crouch_slide_friction: float = 0.2    # min friction when sliding
@export var crouch_slide_threshold: float = 3.0   # speed where slide fully kicks in

# Slide entry / exit.
@export var slide_entry_boost: float = 2.0        # speed burst when entering a slide
@export var min_slide_speed: float = 3.0          # below this, slide friction won't hold

# Slope acceleration — lets gravity build real speed downhill.
@export var slope_accel_multiplier: float = 4.0   # accel multiplier on slopes
@export var slope_gravity: float = 20.0            # downhill force on slopes (units/s²)
@export var min_slope_angle: float = 5.0           # degrees, min slope for accel boost

# Standing friction ramps UP at high speeds to kill momentum.
@export var stand_speed_friction: float = 25.0
@export var stand_speed_friction_threshold: float = 5.0

# One-time slowdown when landing fast without crouching.
@export var ground_impact_speed_threshold: float = 8.0
@export var ground_impact_deceleration: float = 40.0

# Stored at _ready() — the original values from the scene file.
var _stand_collider_height: float = 0.0
var _stand_collider_y: float = 0.0
var _stand_recoil_y: float = 0.0
var _was_on_floor: bool = false
var _was_sliding: bool = false


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
var _loadout_character_path: String = ""

# Used to be _pending_spawn_position / _has_pending_spawn — removed.


func _enter_tree() -> void:
	if is_bot:
		player_input.set_multiplayer_authority(1)
		body.set_multiplayer_authority(1)
		$DamageNumberManager.set_multiplayer_authority(1)
	else:
		var id := str(name).to_int()
		set_multiplayer_authority(1)
		player_input.set_multiplayer_authority(id)
		body.set_multiplayer_authority(id)
		$DamageNumberManager.set_multiplayer_authority(id)


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

	# Store reference values for crouch transitions.
	var shape: CapsuleShape3D = collider.shape as CapsuleShape3D
	if shape:
		_stand_collider_height = shape.height
	_stand_collider_y = collider.position.y
	_stand_recoil_y = %Recoil.position.y

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
	if pos == Vector3.ZERO:
		pos = Vector3(0, 12, 0)
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
func rpc_sync_full_state(pos: Vector3, pp: String, sp: String, cp: String = "") -> void:
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

	# -- Character --
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			set_character(char_res)
			_loadout_character_path = cp

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
	# Reset shield on death so the next life starts fresh.
	if shield_instance:
		shield_instance.reset_hp()
	if _active_shield_fire:
		_active_shield_fire.shield_current_hp = _active_shield_fire.shield_hp
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

	# Passive shield regen — runs even when retracted.
	_shield_regen(delta)

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



## Source-style air acceleration.
## [param wish_dir] – normalized input direction.
## [param wish_speed] – desired speed along that direction (capped by [member air_speed_cap]).
## [param delta] – frame delta.
func _air_accelerate(wish_dir: Vector3, wish_speed: float, delta: float) -> void:
	var vel: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var eff_air_cap: float = _cmult(air_speed_cap, _character.air_speed_cap_mult if _character else 1.0)
	var capped_wish_speed: float = min(wish_speed, eff_air_cap)
	var current_speed: float = vel.dot(wish_dir)
	var add_speed: float = capped_wish_speed - current_speed
	if add_speed <= 0.0:
		return
	var eff_air_accel: float = _cmult(air_acceleration, _character.air_accel_mult if _character else 1.0)
	var accel_speed: float = eff_air_accel * capped_wish_speed * delta
	accel_speed = min(accel_speed, add_speed)
	vel += wish_dir * accel_speed
	velocity.x = vel.x
	velocity.z = vel.z

func _apply_movement_from_input(delta):
	_force_update_is_on_floor()
	var on_floor := is_on_floor()

	# ── Crouch: smooth collider, camera, and physics blend ──
	# All crouch effects share one continuous factor (0 = stand, 1 = crouch)
	# so nothing snaps instantly while the collider is still animating.
	is_crouching = player_input.crouch
	var target_height: float = crouch_height if player_input.crouch else _stand_collider_height
	var shape: CapsuleShape3D = collider.shape as CapsuleShape3D
	var crouch_factor: float = 0.0
	if shape and _stand_collider_height > 0.0:
		shape.height = move_toward(shape.height, target_height, crouch_transition_speed * delta)
		# Keep the capsule bottom fixed so the body doesn't bob up/down.
		var half_diff: float = (_stand_collider_height - shape.height) * 0.5
		collider.position.y = _stand_collider_y - half_diff
		%Recoil.position.y = _stand_recoil_y - half_diff
		# Continuous blend factor derived from actual collider height.
		var denom: float = _stand_collider_height - crouch_height
		if denom > 0.0:
			crouch_factor = clamp((_stand_collider_height - shape.height) / denom, 0.0, 1.0)

	if not on_floor:
		velocity += get_gravity() * delta
	elif player_input.jump_input:
		knockback_velocity = Vector3.ZERO
		velocity.y = _cmult(JUMP_VELOCITY, _character.jump_mult if _character else 1.0)

	var input_dir := player_input.input_dir
	var cam_basis: Basis = camera.global_transform.basis
	var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var direction := (forward * input_dir.y + right * input_dir.x).normalized()

	var calc_speed: float = _cmult(speed, _character.speed_mult if _character else 1.0)
	var weapons := weapon_controller.get_weapons()
	if not weapons.is_empty():
		calc_speed = calc_speed * weapons[weapon_controller.current_weapon_index].player_speed_multiplier
	# Blend speed penalty smoothly with the collider.
	var eff_crouch_mult: float = crouch_speed_multiplier + (_character.crouch_speed_mult if _character else 1.0)
	calc_speed *= lerp(1.0, eff_crouch_mult, crouch_factor)

	if on_floor:
		var h_speed: float = Vector2(velocity.x, velocity.z).length()

		# Detect slope for acceleration boost and slide sustain.
		var floor_normal: Vector3 = get_floor_normal()
		var slope_angle: float = rad_to_deg(acos(Vector3.UP.dot(floor_normal)))
		var on_slope: bool = slope_angle > min_slope_angle

		# True slide (not just crouching while slow): requires either speed
		# or pushing downhill on a slope.
		var slide_active: bool = crouch_factor > 0.5 \
			and (h_speed > min_slide_speed or (on_slope and direction.length() > 0.0))

		# Entry boost — one burst when you first hit a real slide.
		if slide_active and not _was_sliding:
			var boost_dir: Vector2 = Vector2(velocity.x, velocity.z)
			var boost_len: float = boost_dir.length()
			if boost_len > 0.0:
				boost_dir /= boost_len
				var eff_boost: float = _cmult(slide_entry_boost, _character.slide_entry_boost_mult if _character else 1.0)
				velocity.x += boost_dir.x * eff_boost
				velocity.z += boost_dir.y * eff_boost
				h_speed = Vector2(velocity.x, velocity.z).length()
		_was_sliding = slide_active

		# Acceleration: low while crouching, boosted on slopes.
		var base_accel: float = _cmult(acceleration, _character.acceleration_mult if _character else 1.0)
		var accel: float = lerp(base_accel, crouch_ground_acceleration, crouch_factor)
		if crouch_factor > 0.0 and on_slope:
			accel *= slope_accel_multiplier

		# Friction: speed-dependent based on crouch state.
		var fric: float = _cmult(friction, _character.friction_mult if _character else 1.0)
		if crouch_factor > 0.0:
			var slide_t: float
			if not slide_active:
				# Too slow for a slide → normal crouch friction.
				slide_t = 0.0
			elif direction.length() > 0.0:
				slide_t = clamp(h_speed / crouch_slide_threshold, 0.3, 1.0)
			else:
				slide_t = clamp(h_speed / crouch_slide_threshold, 0.0, 1.0)
			var eff_slide_fric: float = _cmult(crouch_slide_friction, _character.slide_friction_mult if _character else 1.0)
			var crouch_fric: float = lerp(friction, eff_slide_fric, slide_t)
			fric = lerp(friction, crouch_fric, crouch_factor)
		elif h_speed > stand_speed_friction_threshold:
			# Standing: extra friction at high speeds to kill momentum.
			var excess: float = (h_speed - stand_speed_friction_threshold) / stand_speed_friction_threshold
			fric += stand_speed_friction * excess

		if direction:
			var target_x := direction.x * calc_speed
			var target_z := direction.z * calc_speed
			# When sliding, don't cap downhill speed — let slope gravity build it.
			if crouch_factor > 0.0:
				var vel_dot_dir: float = velocity.x * direction.x + velocity.z * direction.z
				if vel_dot_dir > calc_speed:
					target_x = direction.x * vel_dot_dir
					target_z = direction.z * vel_dot_dir
			velocity.x = move_toward(velocity.x, target_x, accel * delta)
			velocity.z = move_toward(velocity.z, target_z, accel * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, fric * delta)
			velocity.z = move_toward(velocity.z, 0.0, fric * delta)

		# Slope gravity: pull downhill when crouching, regardless of input.
		if crouch_factor > 0.0 and on_slope:
			var gravity_dir: Vector3 = Vector3.DOWN
			var downhill: Vector3 = (gravity_dir - floor_normal * gravity_dir.dot(floor_normal)).normalized()
			var eff_slope_grav: float = _cmult(slope_gravity, _character.slope_gravity_mult if _character else 1.0)
			velocity.x += downhill.x * eff_slope_grav * delta
			velocity.z += downhill.z * eff_slope_grav * delta

		# One-time slowdown on landing fast without crouching.
		if not _was_on_floor and crouch_factor < 0.5:
			if h_speed > ground_impact_speed_threshold:
				velocity.x = move_toward(velocity.x, 0.0, ground_impact_deceleration * delta)
				velocity.z = move_toward(velocity.z, 0.0, ground_impact_deceleration * delta)
	else:
		# Source-style air acceleration — crouch has no effect in the air.
		if direction.length() > 0.0:
			var wish_speed: float = calc_speed * input_dir.length()
			_air_accelerate(direction, wish_speed, delta)

	_was_on_floor = on_floor

	velocity *= NetworkTime.physics_factor
	velocity += knockback_velocity
	move_and_slide()
	velocity /= NetworkTime.physics_factor

	var knockback_decay: float = velocity.length() ** 2 * 10
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)

	const BASE_MOUSE_SENS: float = 0.002
	const BASE_FOV: float = 90.0

	if ads:
		camera.fov = weapon_controller.get_ads_zoom_fov()
		speed = 2.5
	else:
		camera.fov = 90.0
		speed = 5.0

	var fov_ratio: float = camera.fov / BASE_FOV
	body.mouse_sens_x = BASE_MOUSE_SENS * fov_ratio
	body.mouse_sens_y = BASE_MOUSE_SENS * fov_ratio

func change_health(health: float, changer: String, is_headshot: bool = false, falloff_mult: float = 1.0):
	if health < 0.0 and shield_instance and shield_instance.active:
		shield_instance.absorb_damage(-health)
		return
	attribute_component.apply_health_delta(health, changer, self.name, is_headshot, falloff_mult)


## Deploy a shield from a SHIELD-type WeaponFire.  Called by WeaponController.
## Parents the shield to the camera so it stays locked to the player's view.
func deploy_shield(fire: WeaponFire) -> void:
	if not fire or not fire.shield_scene:
		return
	if is_shield_active():
		return
	retract_shield()

	var instance := fire.shield_scene.instantiate()
	$Body/Recoil/Head/WeaponParent.add_child(instance)
	instance.position = Vector3.ZERO
	print("[deploy_shield] instance=", instance, " is_PlayerShield=", instance is PlayerShield)

	if instance is PlayerShield:
		instance.player = self
		instance.setup(fire)
		instance.deploy()
		shield_instance = instance
	else:
		# Scene doesn't have the PlayerShield script — apply basic visibility
		# so users can see their shield even before wiring up the script.
		_force_shield_visible(instance)
	_active_shield_fire = fire


## Fallback: walks a shield scene that has no PlayerShield script and makes
## every MeshInstance3D visible with a solid cyan colour.
func _force_shield_visible(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override == null or not mi.material_override is StandardMaterial3D:
			var smat := StandardMaterial3D.new()
			smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mi.material_override = smat
		var smat := mi.material_override as StandardMaterial3D
		smat.albedo_color = Color(0.3, 0.85, 0.95, 0.65)
	for child in node.get_children():
		_force_shield_visible(child)


## Retract (remove) the current shield.  Called on toggle-off or weapon switch.
func retract_shield() -> void:
	if shield_instance:
		shield_instance._sync_hp_to_fire()
		shield_instance.retract()
		shield_instance.queue_free()
		shield_instance = null
	# Keep _active_shield_fire so regen and HUD continue while retracted.
	# Only cleared on weapon switch or death.


## Returns true if a shield is currently deployed and not broken.
func is_shield_active() -> bool:
	return shield_instance != null and shield_instance.active and not shield_instance.broken


## Returns true if the active shield prevents shooting.
func shield_blocks_shooting() -> bool:
	if not is_shield_active():
		return false
	if not _active_shield_fire:
		return false
	return not _active_shield_fire.can_shoot_while_shielded


## Passive HP regen for the shield, even while retracted.
func _shield_regen(delta: float) -> void:
	if not _active_shield_fire:
		return
	var f := _active_shield_fire
	if f.shield_current_hp < f.shield_hp:
		f.shield_current_hp = minf(f.shield_current_hp + f.shield_regen_per_sec * delta, f.shield_hp)

## Apply character stat offsets on top of base values.
func set_character(char: Character) -> void:
	_character = char
	if char:
		attribute_component.starting_health = 100.0 * char.health_mult
		attribute_component.reset_health()

## Read a base stat with an optional character offset applied.
func _cmult(base: float, mult: float) -> float:
	return base * mult
