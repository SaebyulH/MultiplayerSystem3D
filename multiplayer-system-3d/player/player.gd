extends CharacterBody3D
class_name Player


const NORMAL_SPEED: float = 5
const ADS_SPEED: float = 3.0
const FALL_GRAVITY: float = 9.8
const FALL_DAMAGE_SOUND: AudioStream = preload("res://assets/sounds/universfield-fast-body-fall-impact-352725.mp3")

@export var acceleration: float = 25.0
@export var friction: float = 30.0
@export var air_acceleration: float = 25
#accell
@export var air_speed_cap: float = 1.5
@export var tick_interpolator: TickInterpolator

@export var respawn_time: float = 1.5
## Kill and respawn the player when they fall below this Y position (out of world).
@export var fall_kill_y: float = -200.0
## Fall damage: maximum damage dealt at/above [member fall_damage_max_distance].
@export var fall_damage_max: float = 99.0
## Fall damage: fall distance (metres) below which no fall damage is taken.
@export var fall_damage_min_distance: float = 15.0
## Fall damage: fall distance (metres) at/above which full [member fall_damage_max] is dealt.
@export var fall_damage_max_distance: float = 35.0
var respawn_timer: float = 0.0

var is_bot: bool = false  # set by SpawnManager before add_child

var entity_id: String :
	get:
		return name   # for players, entity_id == name == str(network_id)
	set(value):
		name = value  # bots set this explicitly before add_child


var ads: bool = false

## When true, gravity pulls the player upward instead of downward (gravity-flip effect).
var gravity_flipped := false

## Active shield instance — spawned when a SHIELD fire-mode is toggled on.
var shield_instance: PlayerShield = null
## The WeaponFire that spawned the current shield (null if no shield).
var _active_shield_fire: WeaponFire = null

enum Team {SPI, SCI, FFA} #If set to FFA, you can damage anyone
const FRIENDLY_FIRE_MULTIPLIER = 0.0

signal team_changed()


var skins: Array[MeshInstance3D] = []

## Original surface-0 material for each entry in [member skins], captured when
## the character model is built.  Team tinting duplicates these so the model's
## own textures survive instead of being flattened to a single solid colour.
var _skin_original_materials: Array[Material] = []

const TEAM_COLORS: Dictionary = {
	Team.SCI: Color.DODGER_BLUE,
	Team.SPI: Color.RED,
}

var team: Team = Team.SPI:
	set(value):
		team = value
		if is_inside_tree():
			_apply_team_color()
		team_changed.emit()

func get_gmc_team() -> Player.Team:
		match team:
			Team.SPI: return Player.Team.SPI
			Team.SCI: return Player.Team.SCI
			_: return Player.Team.FFA


var knockback_velocity := Vector3.ZERO

# -- Stamina & movement tech --
## Maximum number of stamina bars the player can hold.
const MAX_STAMINA: int = 40
## Seconds to recover a single stamina bar.
@export var stamina_recovery_time: float = 3.0
## Horizontal speed of a grounded dash (fixed; overrides prior momentum).
@export var dash_speed: float = 11.0
## Horizontal impulse added by an air dash (stacks with prior momentum).
@export var air_dash_impulse: float = 5.0
## Vertical impulse added by a down dash (air dash toward the ground).
@export var down_dash_impulse: float = 14.0
## Horizontal speed of a dash jump. Deadlock sets this to 611 u/s; this project
## walks at ~4 u/s and dashes at ~11 u/s, so the default is scaled accordingly.
@export var dash_jump_speed: float = 4.0
## Vertical launch speed of a dash jump.
@export var dash_jump_upward: float = 3.0
## How long a grounded dash lasts (seconds).
@export var dash_duration: float = 0.25
## Seconds into the dash when the dash-jump window opens.
@export var dash_jump_window_start: float = 0.01
## Seconds into the dash when the dash-jump window closes.
@export var dash_jump_window_end: float = 0.3
## Window (seconds) to press crouch again for a down dash.
const DOWN_DASH_WINDOW: float = 0.44

## Current stamina (fractional - the fractional part is a bar recovering).
var stamina: float = float(MAX_STAMINA)

# Input edge-detection memory (rolled back so presses replay deterministically).
var dash_held_prev: bool = false
var jump_held_prev: bool = false
var crouch_held_prev: bool = false

# Air action limits - one double jump and one air dash per airtime.
var air_jump_used: bool = false
var air_dash_used: bool = false

# Active grounded-dash state.
var dash_time: float = 0.0             # > 0 while a grounded dash is running
var active_dash_dir: Vector3 = Vector3.ZERO
var dash_grounded: bool = false        # dash began grounded (enables coyote dash jump)

# Dash-jump timing.
var dash_jump_locked: bool = false     # timing failed; locked out this dash

# Down-dash double-tap timer.
var crouch_tap_timer: float = 0.0

# Dash-jump timing feedback (cosmetic; read by the HUD each frame).
var _dash_jump_feedback: String = ""
var _dash_jump_feedback_timer: float = 0.0

## Speed modifiers set by status effects.  { effect_id: multiplier }
## The most severe slow (lowest multiplier) wins.
var _speed_modifiers: Dictionary = {}

var speed = 1.0
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
@onready var status_effect_manager: StatusEffectManager = $StatusEffectManager

var is_crouching: bool = false

# Character selection
var _character: Character = null

## The currently-active third-person model (what other players see): the
## built-in mannequin, or a spawned character model.
var model: Node3D = null

## The [PlayerModel] component attached to [member model] (null until a model
## that carries the script is active).
var model_script: PlayerModel = null

## The currently-active first-person viewmodel (what the local player sees):
## the built-in viewmodel mannequin, or a spawned character viewmodel.
var viewmodel: Node3D = null

## The [PlayerModel] component attached to [member viewmodel].
var viewmodel_script: PlayerModel = null

## The currently-active first-person legs model (what the local player sees
## when looking down): the built-in legs mannequin, or a spawned copy.
var legs: Node3D = null

## The [PlayerModel] component attached to [member legs].
var legs_script: PlayerModel = null

## The built-in mannequin (always present under Body) drives the world model's
## animation via the AnimationTree; a spawned character model copies its pose.
@onready var mannequin: Node3D = $Body/Mannequin
var mannequin_skeleton: Skeleton3D = null

## The built-in viewmodel mannequin under the camera/head drives the first-person
## viewmodel animation; a spawned character viewmodel copies its pose.
@onready var viewmodel_mannequin: Node3D = $Body/Recoil/Head/Mannequin_VIEWMODEL
var viewmodel_skeleton: Skeleton3D = null

## The built-in legs mannequin under Body drives the first-person legs; a
## spawned character legs model copies its pose.
@onready var legs_mannequin: Node3D = $Body/MannequinLEGS
var legs_skeleton: Skeleton3D = null

## Skeleton of a spawned character model that mirrors the mannequin's pose.
var _pose_target: Skeleton3D = null
## Destination bone index (into _pose_target) per mannequin bone index, -1 if missing.
var _pose_map: PackedInt32Array = PackedInt32Array()

## Skeleton of a spawned character viewmodel that mirrors the viewmodel's pose.
var _viewmodel_target: Skeleton3D = null
## Destination bone index (into _viewmodel_target) per viewmodel bone index.
var _viewmodel_map: PackedInt32Array = PackedInt32Array()

## Skeleton of a spawned character legs model that mirrors the legs mannequin's pose.
var _legs_target: Skeleton3D = null
## Destination bone index (into _legs_target) per legs mannequin bone index.
var _legs_map: PackedInt32Array = PackedInt32Array()

## When true, the first-person viewmodel (arms) renders in its own separate
## render layer, layered over the world by a dedicated viewmodel camera.  When
## false, the local player's full body model is shown instead (arms included),
## and the separate viewmodel arms and legs are hidden.
@export var use_viewmodel_layer: bool = true

## Debug: when a character model replaces the mannequin, show BOTH at once (the
## mannequin AND the spawned character skin) so their alignment can be compared,
## instead of hiding the mannequin.
@export var debug_show_both_models: bool = false

@onready var animation_tree: AnimationTree = $Body/AnimationTree
@onready var viewmodel_camera: Camera3D = %ViewModelCamera

@export var crouch_height: float = 1.0
@export var stand_height: float = 2.0
@export var crouch_transition_speed: float = 40.0

@export var crouch_speed_multiplier: float = 0.5

# Crouch acceleration is low regardless of speed — you can't gain much speed
# while crouched, you can only preserve what you already have.
@export var crouch_ground_acceleration: float = 1.0

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
var _max_fall_speed: float = 0.0
var _was_airborne: bool = false
## Seconds spent grounded; gates jumping until a minimum contact time is met.
var _ground_contact_time: float = 0.0


var spawn_manager: SpawnManager

var pitch := 0.0

# ── Footsteps ──────────────────────────────────────
## Time between footstep sounds while walking.
const FOOTSTEP_INTERVAL: float = 0.53335
## Random pitch variation applied to footstep sounds (matches WeaponController.PITCH_RANGE).
const FOOTSTEP_PITCH_RANGE: float = 0.05
## Footstep sound pool — one is picked at random per step.
var _footstep_sounds: Array[AudioStream] = [
	#preload("res://assets/sounds/footsteps/data_pion-st1-footstep-sfx-323053.mp3"),
	preload("res://assets/sounds/footsteps/data_pion-st2-footstep-sfx-323055.mp3"),
	preload("res://assets/sounds/footsteps/data_pion-st3-footstep-sfx-323056.mp3"),
]
## Primed to the interval so the first step fires as soon as walking starts.
var _footstep_timer: float = FOOTSTEP_INTERVAL

# ── Respawn state ─────────────────────────────────
# Persistent across rollback: _spawn_pending_position is NOT consumed inside
# _rollback_tick, so re-simulations of death/respawn ticks always see it.
# It is consumed only in _physics_process (real frames only).
var _spawn_pending_position: Vector3 = Vector3.ZERO
var spawned := false

# Stored so late-joining peers can be synced with the correct weapon models.
var _loadout_primary_path: String = ""
var _loadout_secondary_path: String = ""
var _loadout_melee_path: String = ""
var _loadout_character_path: String = ""
var _loadout_class_path: String = ""

# Randomize-on-death — when true, weapons are re-randomized from the class on each respawn.
var _randomize_on_death: bool = false

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
	# Run _process last (after Recoil / AnimationTree / TickInterpolator) so the
	# viewmodel camera sync and pose copying read this frame's final state.
	process_priority = 100

	skins = [
		#$Body/Recoil/Head/WeaponParent/RightArm,
		#$Body/Recoil/Head/WeaponParent/RightForearm,
		#$Body/Recoil/Head/WeaponParent/LeftForearm,
		#$Body/Recoil/Head/WeaponParent/LeftArm,
		#$Body/Recoil/Head/Helmet,
		#$Body/LeftLeg3, $Body/LeftLeg9, $Body/LeftLeg10, $Body/LeftLeg5, $Body/LeftLeg4, $Body/LeftLeg6, $Body/LeftLeg7, $Body/LeftLeg8,
		#
		#
		# Character skin meshes are collected dynamically in _rebuild_skins().
		
		#$Body/Torso,
		#$Body/LeftLeg,
		#$Body/RighLeg,
	]
	team = team

	# Resolve the built-in mannequins — they always drive the animations.
	mannequin_skeleton = mannequin.find_child("Skeleton3D", true, false) as Skeleton3D
	viewmodel_skeleton = viewmodel_mannequin.find_child("Skeleton3D", true, false) as Skeleton3D
	legs_skeleton = legs_mannequin.find_child("Skeleton3D", true, false) as Skeleton3D
	# SkeletonModifier3D (CCDIK/Aim/CopyTransform) results are rolled back after
	# the skeleton update, so copy the pose inside skeleton_updated — not in
	# _process, where get_bone_pose_* already returns the un-modified pose.
	if mannequin_skeleton:
		mannequin_skeleton.skeleton_updated.connect(_copy_mannequin_pose)
	if legs_skeleton:
		legs_skeleton.skeleton_updated.connect(_copy_legs_pose)
	animation_tree.active = true
	if _is_own_model():
		($Body/Recoil/Head/AnimationTreeViewmodel as AnimationTree).active = true
	else:
		# Bots and remote players never render the first-person viewmodel or legs.
		# Stop their skeletons and animation trees so they don't animate every frame
		# (two ~250-bone skeletons per player that were pure waste).
		($Body/Recoil/Head/AnimationTreeViewmodel as AnimationTree).active = false
		var legs_tree := $Body/AnimationTreeLegs as AnimationTree
		legs_tree.active = false
		legs_tree.set_process(false)
		viewmodel_mannequin.visible = false
		legs_mannequin.visible = false
	_setup_viewmodel_viewport()

	add_to_group("players")
	attribute_component.health_changed.connect(_health_changed)
	attribute_component.no_health.connect(no_health)
	rollback_sync.process_settings()

	# Give each player its own collider shape.  Shape3D resources are shared across
	# scene instances by default, so crouching one player would resize every other
	# player's collider (and they'd fight over the same height — the jitter).
	collider.shape = collider.shape.duplicate()

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
	_reset_movement_tech()
	_speed_modifiers.clear()

	# Reset health, weapons, and status effects on every peer.
	attribute_component.reset()
	weapon_controller.reset()
	if status_effect_manager:
		status_effect_manager.clear_all_effects()

	# Randomize weapons on death if the option is enabled.
	if multiplayer.is_server() and _randomize_on_death and not _loadout_class_path.is_empty():
		_randomize_weapons_from_class()

## Full-state sync for a late-joining peer.  Handles visibility and weapon
## loadout in one atomic RPC so the player does not flicker into view with
## wrong weapon models.
@rpc("authority", "call_remote", "reliable")
func rpc_sync_full_state(pos: Vector3, pp: String, sp: String, mp: String = "", cp: String = "") -> void:
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
				if not mp.is_empty():
					var melee: Weapon = load(mp) as Weapon
					if melee:
						nw.append(melee.duplicate(true) as Weapon)
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
	_reset_movement_tech()
	spawn()


func no_health() -> void:
	# Play the character's death sound at the death location, delayed 0.5s.
	if _character and _character.death_sound:
		var death_sound := _character.death_sound
		var death_pos := global_position
		var parent := get_parent()
		get_tree().create_timer(0.16).timeout.connect(func() -> void:
			if is_instance_valid(parent):
				AudioPool.play(parent, death_sound, Transform3D(Basis(), death_pos), 1.0, 10.0, 20.0)
		)

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
	if status_effect_manager:
		status_effect_manager.clear_all_effects()
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
			$BodyHurtbox/CollisionShape3D.hide()
		else:
			camera.current = false
			camera.visible = false
	else:
		camera.current = false
		camera.visible = false


func set_randomize_on_death(enabled: bool) -> void:
	_randomize_on_death = enabled


func _randomize_weapons_from_class() -> void:
	"""Pick random weapons from the stored class and apply them."""
	var cls: Class = load(_loadout_class_path) as Class
	if not cls:
		return
	if cls.primary_weapons.is_empty() or cls.secondary_weapons.is_empty() or cls.melee_weapons.is_empty():
		return
	var primary: Weapon = cls.primary_weapons.pick_random().duplicate(true) as Weapon
	var secondary: Weapon = cls.secondary_weapons.pick_random().duplicate(true) as Weapon
	var melee: Weapon = cls.melee_weapons.pick_random().duplicate(true) as Weapon
	var nw: Array[Weapon] = [primary, secondary, melee]
	weapon_controller.set_weapons(nw)
	weapon_controller.current_weapon_index = 0
	_loadout_primary_path = primary.resource_path
	_loadout_secondary_path = secondary.resource_path
	_loadout_melee_path = melee.resource_path
	_rpc_sync_randomized_loadout.rpc(name, _loadout_primary_path, _loadout_secondary_path, _loadout_melee_path)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_randomized_loadout(tpid: String, pp: String, sp: String, mp: String) -> void:
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if not primary or not secondary or not melee:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	weapon_controller.set_weapons(nw)
	weapon_controller.current_weapon_index = 0


## Mirror the mannequin's animated pose onto a spawned character model every
## frame so any skin rigged to the same humanoid skeleton follows along.
func _process(_delta: float) -> void:
	# First-person pose copy and camera sync are only needed for the local player.
	# For bots and remote players this is wasted work that runs every render frame.
	if not _is_own_model():
		return
	_copy_viewmodel_pose()
	_sync_viewmodel_camera()


func _copy_mannequin_pose() -> void:
	if _pose_target == null or mannequin_skeleton == null:
		return
	for src_idx in mannequin_skeleton.get_bone_count():
		var dst_idx := _pose_map[src_idx]
		if dst_idx < 0:
			continue
		_pose_target.set_bone_pose_position(dst_idx, mannequin_skeleton.get_bone_pose_position(src_idx))
		_pose_target.set_bone_pose_rotation(dst_idx, mannequin_skeleton.get_bone_pose_rotation(src_idx))
		_pose_target.set_bone_pose_scale(dst_idx, mannequin_skeleton.get_bone_pose_scale(src_idx))


func _copy_viewmodel_pose() -> void:
	if _viewmodel_target == null or viewmodel_skeleton == null:
		return
	for src_idx in viewmodel_skeleton.get_bone_count():
		var dst_idx := _viewmodel_map[src_idx]
		if dst_idx < 0:
			continue
		_viewmodel_target.set_bone_pose_position(dst_idx, viewmodel_skeleton.get_bone_pose_position(src_idx))
		_viewmodel_target.set_bone_pose_rotation(dst_idx, viewmodel_skeleton.get_bone_pose_rotation(src_idx))
		_viewmodel_target.set_bone_pose_scale(dst_idx, viewmodel_skeleton.get_bone_pose_scale(src_idx))


func _copy_legs_pose() -> void:
	if _legs_target == null or legs_skeleton == null:
		return
	for src_idx in legs_skeleton.get_bone_count():
		var dst_idx := _legs_map[src_idx]
		if dst_idx < 0:
			continue
		_legs_target.set_bone_pose_position(dst_idx, legs_skeleton.get_bone_pose_position(src_idx))
		_legs_target.set_bone_pose_rotation(dst_idx, legs_skeleton.get_bone_pose_rotation(src_idx))
		_legs_target.set_bone_pose_scale(dst_idx, legs_skeleton.get_bone_pose_scale(src_idx))


## Keep the viewmodel camera aligned with the main camera (position + rotation),
## leaving FOV alone so it can be tuned manually in the inspector.
func _sync_viewmodel_camera() -> void:
	if viewmodel_camera == null:
		return
	viewmodel_camera.global_transform = camera.global_transform


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
		_reset_movement_tech()
		spawn()

	# Fall out of the world - kill and respawn (server-authoritative), crediting
	# the last enemy who damaged the player.
	if multiplayer.is_server() and spawned and global_position.y < fall_kill_y:
		attribute_component.apply_environmental_damage(attribute_component.starting_health)

	_track_fall_damage()

	# Passive shield regen — runs even when retracted.
	_shield_regen(delta)

	if _dash_jump_feedback_timer > 0.0:
		_dash_jump_feedback_timer -= delta
		if _dash_jump_feedback_timer <= 0.0:
			_dash_jump_feedback = ""

	# Footsteps play on real frames only (never inside the rollback tick,
	# which re-simulates and would double-play sounds).
	_update_footsteps(delta)


## Track the player's maximum downward speed and apply fall damage on landing.
## Server-only and real-frames-only (never inside the rollback tick).
func _track_fall_damage() -> void:
	if not multiplayer.is_server():
		return
	if not spawned:
		_max_fall_speed = 0.0
		_was_airborne = false
		return
	if not is_on_floor():
		_was_airborne = true
		_max_fall_speed = maxf(_max_fall_speed, -velocity.y)
	else:
		if _was_airborne:
			_apply_fall_damage(_max_fall_speed)
		_was_airborne = false
		_max_fall_speed = 0.0


## Convert a downward impact speed into fall damage and apply it as
## environmental damage (crediting the last enemy attacker).
func _apply_fall_damage(fall_speed: float) -> void:
	var min_vel := sqrt(2.0 * FALL_GRAVITY * fall_damage_min_distance)
	var max_vel := sqrt(2.0 * FALL_GRAVITY * fall_damage_max_distance)
	if max_vel <= min_vel or fall_speed <= min_vel:
		return
	var t := clampf((fall_speed - min_vel) / (max_vel - min_vel), 0.0, 1.0)
	attribute_component.apply_environmental_damage(t * fall_damage_max)
	_play_fall_damage_sound.rpc(global_position)


## Plays the fall-impact sound on every peer.
@rpc("any_peer", "call_local", "reliable")
func _play_fall_damage_sound(pos: Vector3) -> void:
	AudioPool.play(get_parent(), FALL_DAMAGE_SOUND, Transform3D(Basis(), pos))


func _update_footsteps(delta: float) -> void:
	if not spawned:
		_footstep_timer = FOOTSTEP_INTERVAL
		return
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and h_speed > 0.1:
		_footstep_timer += delta
		if _footstep_timer >= FOOTSTEP_INTERVAL:
			_footstep_timer = 0.0
			_play_footstep()
	else:
		# Reset while stopped so the first step fires immediately on walking.
		_footstep_timer = FOOTSTEP_INTERVAL

func _play_footstep() -> void:
	if _footstep_sounds.is_empty():
		return
	# Pooled one-shot audio player (see AudioPool) instead of a fresh node per step.
	AudioPool.play(
		self,
		_footstep_sounds.pick_random(),
		Transform3D(Basis(), global_position),
		1.0 + randf_range(-FOOTSTEP_PITCH_RANGE, FOOTSTEP_PITCH_RANGE)
	)

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
	var mult: float = _character.knockback_multiplier if _character else 2.0
	knockback_velocity += force * mult

## Reset all stamina / dash / air-action state on respawn.
func _reset_movement_tech() -> void:
	stamina = float(MAX_STAMINA)
	dash_held_prev = false
	jump_held_prev = false
	crouch_held_prev = false
	air_jump_used = false
	air_dash_used = false
	dash_time = 0.0
	active_dash_dir = Vector3.ZERO
	dash_grounded = false
	dash_jump_locked = false
	crouch_tap_timer = 0.0
	_dash_jump_feedback = ""
	_dash_jump_feedback_timer = 0.0


## Perform a dash jump: a fixed velocity burst that disregards prior momentum.
func _do_dash_jump() -> void:
	stamina -= 2.0
	velocity.x = active_dash_dir.x * dash_jump_speed
	velocity.z = active_dash_dir.z * dash_jump_speed
	velocity.y = dash_jump_upward
	# Ends the dash and does not consume an air jump or air dash.
	dash_time = 0.0
	active_dash_dir = Vector3.ZERO
	dash_grounded = false
	dash_jump_locked = false
	_dash_jump_feedback = ""
	_dash_jump_feedback_timer = 0.0


## Jump from the ground, gated by the character's minimum ground-contact time.
func _grounded_jump() -> void:
	var min_contact: float = _character.min_ground_contact_time if _character else 0.1
	if _ground_contact_time >= min_contact:
		knockback_velocity = Vector3.ZERO
		velocity.y = _cmult(JUMP_VELOCITY, _character.jump_mult if _character else 1.0)


## Set the "too early" / "too late" feedback for the HUD.
func _set_dash_jump_feedback(text: String) -> void:
	_dash_jump_feedback = text
	_dash_jump_feedback_timer = 1.5


## Register a speed modifier from a status effect.
## [param effect_id] -- unique effect identifier (e.g. "slow").
## [param mult] -- speed multiplier (1.0 = normal, 0.5 = half speed).
func add_speed_modifier(effect_id: String, mult: float) -> void:
	_speed_modifiers[effect_id] = mult


## Remove a speed modifier when its status effect expires.
func remove_speed_modifier(effect_id: String) -> void:
	_speed_modifiers.erase(effect_id)


## Flip the gravity direction (used by the gravity-flip status effect).
func set_gravity_flipped(flipped: bool) -> void:
	gravity_flipped = flipped


## Returns the most severe speed multiplier from active status effects.
## 1.0 = normal speed, < 1.0 = slowed.
func get_status_speed_mult() -> float:
	if _speed_modifiers.is_empty():
		return 1.0
	var min_mult := 1.0
	for mult in _speed_modifiers.values():
		min_mult = minf(min_mult, mult)
	return min_mult



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

	# ── Crouch: snap the collider straight to the crouch/stand height ──
	# Smoothly interpolating the height every tick made the capsule float and
	# jitter (the integration fought netfox's rollback).  Crouch height is now a
	# pure function of the crouch input, so every peer derives the same shape.
	is_crouching = player_input.crouch
	var shape: CapsuleShape3D = collider.shape as CapsuleShape3D
	var crouch_factor: float = 0.0
	if shape and _stand_collider_height > 0.0:
		var target_height: float = crouch_height if is_crouching else _stand_collider_height
		shape.height = target_height
		# Keep the capsule bottom fixed so the body doesn't bob up/down.
		collider.position.y = _stand_collider_y - (_stand_collider_height - target_height) * 0.5
		#%Recoil.position.y = _stand_recoil_y - (_stand_collider_height - target_height) * 0.5
		crouch_factor = 1.0 if is_crouching else 0.0

	# Track grounded time so a minimum contact time can gate re-jumping.
	if on_floor:
		_ground_contact_time += delta
	else:
		_ground_contact_time = 0.0

	var input_dir := player_input.input_dir
	var cam_basis: Basis = camera.global_transform.basis
	# Derive forward from the camera's (always-horizontal) right vector so pitch
	# never inverts inputs when looking straight up or down.
	var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var forward := right.cross(Vector3.UP)
	var direction := (forward * input_dir.y + right * input_dir.x).normalized()

	# -- Input edges --
	# Rising-edge detection so presses replay deterministically under rollback.
	var jump_pressed: bool = player_input.jump_input and not jump_held_prev
	jump_held_prev = player_input.jump_input
	var dash_pressed: bool = player_input.dash_input and not dash_held_prev
	dash_held_prev = player_input.dash_input
	var crouch_pressed: bool = player_input.crouch and not crouch_held_prev
	crouch_held_prev = player_input.crouch

	# While grounded, air actions are available (reset each grounded tick).
	if on_floor:
		air_jump_used = false
		air_dash_used = false

	# Advance the grounded dash and end it once its duration elapses.
	if dash_time > 0.0:
		dash_time += delta
		if dash_time >= dash_duration:
			dash_time = 0.0
			active_dash_dir = Vector3.ZERO
			dash_grounded = false
			dash_jump_locked = false

	# Gravity (skipped while grounded).
	if not on_floor:
		velocity += get_gravity() * delta * (-1.0 if gravity_flipped else 1.0)

	# -- Down dash --
	# Airborne double-tap of crouch: press crouch twice within DOWN_DASH_WINDOW.
	if crouch_pressed:
		if not on_floor:
			if crouch_tap_timer > 0.0:
				crouch_tap_timer = 0.0
				if dash_time <= 0.0 and not air_dash_used and stamina >= 1.0:
					stamina -= 1.0
					air_dash_used = true
					velocity.y = -down_dash_impulse
			else:
				crouch_tap_timer = DOWN_DASH_WINDOW
	crouch_tap_timer = maxf(0.0, crouch_tap_timer - delta)

	# -- Jump / double jump / dash jump --
	if jump_pressed:
		if dash_time > 0.0 and dash_grounded and not dash_jump_locked:
			# Jumping during a grounded dash is a dash-jump attempt.
			if dash_time < dash_jump_window_start:
				dash_jump_locked = true
				_set_dash_jump_feedback("too early")
			elif dash_time > dash_jump_window_end:
				dash_jump_locked = true
				_set_dash_jump_feedback("too late")
			elif stamina >= 2.0:
				_do_dash_jump()
		elif on_floor:
			# Normal jump.
			_grounded_jump()
		elif not air_jump_used and stamina >= 1.0:
			# Double jump.
			stamina -= 1.0
			air_jump_used = true
			velocity.y = _cmult(JUMP_VELOCITY, _character.jump_mult if _character else 1.0)
	elif on_floor and player_input.jump_input and dash_time <= 0.0:
		# Auto bunny hop: holding jump re-jumps the moment the player lands.
		_grounded_jump()

	# -- Dash (grounded = fixed velocity, air = impulse) --
	if dash_pressed and dash_time <= 0.0:
		# Grounded dashes snap to the four cardinal directions; air dashes keep
		# the full eight-way input.
		var dd := input_dir
		if on_floor:
			if absf(dd.x) >= absf(dd.y):
				dd = Vector2(sign(dd.x), 0.0)
			else:
				dd = Vector2(0.0, sign(dd.y))
		var dash_dir := forward * dd.y + right * dd.x
		if dash_dir.length_squared() > 0.0001:
			dash_dir = dash_dir.normalized()
			if on_floor and stamina >= 1.0:
				# Grounded dash: fixed speed, opens the dash-jump window.
				stamina -= 1.0
				dash_time = delta
				active_dash_dir = dash_dir
				dash_grounded = true
				dash_jump_locked = false
			elif not on_floor and not air_dash_used and stamina >= 1.0:
				# Air dash: impulse stacked onto current velocity.
				stamina -= 1.0
				air_dash_used = true
				velocity.x += dash_dir.x * air_dash_impulse
				velocity.z += dash_dir.z * air_dash_impulse

	# -- Grounded dash: lock horizontal velocity to the dash speed --
	if dash_time > 0.0:
		velocity.x = active_dash_dir.x * dash_speed
		velocity.z = active_dash_dir.z * dash_speed

	# Recover a stamina bar once every stamina_recovery_time seconds.
	if stamina < MAX_STAMINA:
		stamina = minf(stamina + delta / stamina_recovery_time, float(MAX_STAMINA))

	# Apply ADS speed modifier before computing final speed.
	if ads:
		speed = ADS_SPEED
	else:
		speed = NORMAL_SPEED

	var calc_speed: float = _cmult(speed, _character.speed_mult if _character else 1.0)
	var weapons := weapon_controller.get_weapons()
	if not weapons.is_empty():
		calc_speed = calc_speed * weapons[weapon_controller.current_weapon_index].player_speed_multiplier
		calc_speed = calc_speed * weapon_controller.get_active_fire_speed_mult()
	# Blend speed penalty smoothly with the collider.
	var eff_crouch_mult: float = crouch_speed_multiplier * (_character.crouch_speed_mult if _character else 1.0)
	calc_speed *= lerp(1.0, eff_crouch_mult, crouch_factor)

	# Apply status-effect speed modifiers (e.g. slow/tag on hit).
	calc_speed *= get_status_speed_mult()

	if on_floor:
		var h_speed: float = Vector2(velocity.x, velocity.z).length()

		# Detect slope for acceleration boost and slide sustain.
		var floor_normal: Vector3 = get_floor_normal()
		var slope_angle: float = rad_to_deg(acos(Vector3.UP.dot(floor_normal)))
		var on_slope: bool = slope_angle > min_slope_angle

		# True slide (not just crouching while slow): requires either speed
		# or pushing downhill on a slope.
		var slide_active: bool = crouch_factor > 0.5 \
			and h_speed > min_slide_speed

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
			# When sliding, don't cap speed — let momentum carry.
			if slide_active:
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
	else:
		camera.fov = 90.0

	var fov_ratio: float = camera.fov / BASE_FOV
	body.mouse_sens_x = BASE_MOUSE_SENS * fov_ratio
	body.mouse_sens_y = BASE_MOUSE_SENS * fov_ratio

func change_health(health: float, changer: String, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false):
	# Invincible players take no damage and are immune to negative effects.
	if health < 0.0 and status_effect_manager and status_effect_manager.is_invincible():
		return
	if health < 0.0 and shield_instance and shield_instance.active:
		shield_instance.absorb_damage(-health)
		return
	attribute_component.apply_health_delta(health, changer, self.name, is_headshot, falloff_mult, is_backshot)


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

## The character resource currently applied to this player (null if none).
func get_character() -> Character:
	return _character

## Apply character stat offsets on top of base values.
func set_character(char: Character) -> void:
	_character = char
	if char:
		attribute_component.starting_health = 100.0 * char.health_mult
		attribute_component.reset_health()
	_spawn_character_model()


## Show the built-in mannequin or spawn the selected character's world model,
## and do the same for the first-person viewmodel under the head.  Each spawned
## model mirrors its mannequin's animated pose.
func _spawn_character_model() -> void:
	var own := _is_own_model()
	# Show the first-person viewmodel/legs only for the local player, and only
	# while the separate-viewmodel-layer feature is enabled.  When it is off the
	# local player sees their own body model (arms included) instead.
	var show_first_person := own and use_viewmodel_layer

	# Free any previously spawned character world model (the mannequin is permanent).
	if model != null and model != mannequin:
		model.queue_free()
	model = null
	_pose_target = null
	_pose_map = PackedInt32Array()

	# Free any previously spawned character viewmodel (the viewmodel mannequin is permanent).
	if viewmodel != null and viewmodel != viewmodel_mannequin:
		viewmodel.queue_free()
	viewmodel = null
	_viewmodel_target = null
	_viewmodel_map = PackedInt32Array()

	# Free any previously spawned character legs model (the legs mannequin is permanent).
	if legs != null and legs != legs_mannequin:
		legs.queue_free()
	legs = null
	_legs_target = null
	_legs_map = PackedInt32Array()

	var scene: PackedScene = _character.character_scene if _character and _character.character_scene else null
	var world_instance: Node3D = null
	var viewmodel_instance: Node3D = null
	var legs_instance: Node3D = null
	if scene != null:
		world_instance = scene.instantiate() as Node3D
		# First-person viewmodel + legs only exist for the local player.  Bots and
		# remote players never render them, so spawning them wastes memory and
		# per-frame pose-copy work — a cost that scales with player count.
		if own:
			viewmodel_instance = scene.instantiate() as Node3D
			legs_instance = scene.instantiate() as Node3D

	# --- Third-person world model (visible to other players) ---
	if world_instance == null:
		model = mannequin
	else:
		# Debug: keep the mannequin visible alongside the spawned character model
		# so their alignment can be compared directly.
		_set_mannequin_meshes_visible(debug_show_both_models)


		world_instance.transform = mannequin.transform
		world_instance.name = "Model"
		$Body.add_child(world_instance)
		model = world_instance
		_setup_pose_copy(world_instance)
	if model == mannequin:
		# Hide/show the built-in model's meshes rather than the whole node, so the
		# weapon (parented to the mannequin skeleton's hand bone) stays visible.
		_set_mannequin_meshes_visible(not show_first_person)
	else:
		model.visible = not show_first_person

	# --- First-person viewmodel (visible only to the local player) ---
	if viewmodel_instance == null:
		viewmodel = viewmodel_mannequin
	else:
		viewmodel_mannequin.visible = false
		viewmodel_instance.name = "ViewModel"
		viewmodel_instance.transform = viewmodel_mannequin.transform
		$Body/Recoil/Head.add_child(viewmodel_instance)
		viewmodel = viewmodel_instance
		_setup_viewmodel_pose_copy(viewmodel_instance)
		
	viewmodel.visible = show_first_person

	# --- First-person legs (visible only to the local player) ---
	if legs_instance == null:
		legs = legs_mannequin
	else:
		legs_mannequin.visible = false
		legs_instance.name = "Legs"
		legs_instance.transform = legs_mannequin.transform
		$Body.add_child(legs_instance)
		legs = legs_instance
		_setup_legs_pose_copy(legs_instance)
	legs.visible = show_first_person

	model_script = model as PlayerModel
	viewmodel_script = viewmodel as PlayerModel
	legs_script = legs as PlayerModel

	# Rebuild the team-colour skin list and re-apply the current team (world model only).
	_rebuild_skins()
	team = team

	# Our own first-person model: strip the world model's rim light, hide the
	# viewmodel's head, and make the viewmodel render over the world.
	if own:
		if model_script != null:
			model_script.disable_rim_layer()
			if not use_viewmodel_layer:
				# Feature disabled: the local player sees their own body model, so
				# hide its head so it doesn't clip the first-person camera.
				model_script.hide_head_meshes()
		if viewmodel_script != null:
			viewmodel_script.hide_head_meshes()
		if legs_script != null:
			legs_script.hide_head_meshes()
		if use_viewmodel_layer:
			PlayerModel.move_to_viewmodel_layer(viewmodel)
		#PlayerModel.move_to_viewmodel_layer(legs)


## Show or hide the mannequin's body/head meshes without hiding the node itself.
## The first-person weapon is parented to the mannequin skeleton's hand bone, so
## hiding the whole node would hide the weapon too — hide the meshes instead.
func _set_mannequin_meshes_visible(visible: bool) -> void:
	mannequin.visible = true
	if mannequin_skeleton == null:
		return
	for node in mannequin_skeleton.find_children("*", "MeshInstance3D", false, false):
		if node is MeshInstance3D:
			(node as MeshInstance3D).visible = visible


## Prepare the spawned model's skeleton to mirror the mannequin's pose.  Bones
## are matched by name; both rigs share the same humanoid "DEF-…" naming.
func _setup_pose_copy(model_node: Node3D) -> void:
	var skeleton_nodes := model_node.find_children("*", "Skeleton3D", true, false)
	_pose_target = skeleton_nodes[0] as Skeleton3D if not skeleton_nodes.is_empty() else null
	if _pose_target == null or mannequin_skeleton == null:
		_pose_target = null
		return
	_pose_map = PackedInt32Array()
	_pose_map.resize(mannequin_skeleton.get_bone_count())
	for src_idx in mannequin_skeleton.get_bone_count():
		_pose_map[src_idx] = _pose_target.find_bone(mannequin_skeleton.get_bone_name(src_idx))


## Prepare the spawned viewmodel's skeleton to mirror the viewmodel mannequin's
## pose.  Same bone-name matching as _setup_pose_copy.
func _setup_viewmodel_pose_copy(model_node: Node3D) -> void:
	var skeleton_nodes := model_node.find_children("*", "Skeleton3D", true, false)
	_viewmodel_target = skeleton_nodes[0] as Skeleton3D if not skeleton_nodes.is_empty() else null
	if _viewmodel_target == null or viewmodel_skeleton == null:
		_viewmodel_target = null
		return
	_viewmodel_map = PackedInt32Array()
	_viewmodel_map.resize(viewmodel_skeleton.get_bone_count())
	for src_idx in viewmodel_skeleton.get_bone_count():
		_viewmodel_map[src_idx] = _viewmodel_target.find_bone(viewmodel_skeleton.get_bone_name(src_idx))


## Prepare the spawned legs model's skeleton to mirror the legs mannequin's
## pose.  Same bone-name matching as _setup_pose_copy.
func _setup_legs_pose_copy(model_node: Node3D) -> void:
	var skeleton_nodes := model_node.find_children("*", "Skeleton3D", true, false)
	_legs_target = skeleton_nodes[0] as Skeleton3D if not skeleton_nodes.is_empty() else null
	if _legs_target == null or legs_skeleton == null:
		_legs_target = null
		return
	_legs_map = PackedInt32Array()
	_legs_map.resize(legs_skeleton.get_bone_count())
	for src_idx in legs_skeleton.get_bone_count():
		_legs_map[src_idx] = _legs_target.find_bone(legs_skeleton.get_bone_name(src_idx))


## Render the viewmodel in its own viewport, layered over the main view.  The
## viewmodel camera sees only the viewmodel layer, and the main camera sees
## everything else.  This gives the viewmodel its own depth buffer (no clipping,
## no see-through) while the viewmodel camera's FOV stays manually adjustable.
func _setup_viewmodel_viewport() -> void:
	if not _is_own_model():
		return
	if not use_viewmodel_layer:
		return

	# Main camera renders everything except the viewmodel layer.
	camera.cull_mask = camera.cull_mask & ~PlayerModel.VIEWMODEL_LAYER
	# Viewmodel camera renders only the viewmodel layer.
	viewmodel_camera.cull_mask = PlayerModel.VIEWMODEL_LAYER

	var canvas := CanvasLayer.new()
	canvas.name = "ViewmodelCanvas"
	canvas.layer = -1  # above the 3D world, below the root canvas (PlayerUI) and all CanvasLayer UI
	add_child(canvas)

	var container := SubViewportContainer.new()
	container.name = "ViewmodelOverlay"
	container.stretch = true
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE  # let clicks pass through to menus
	canvas.add_child(container)

	var vp := SubViewport.new()
	vp.name = "ViewmodelViewport"
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.world_3d = get_viewport().world_3d  # share main world so it sees the viewmodel meshes
	container.add_child(vp)

	# A camera renders to the viewport it lives in, so move it into the viewport.
	viewmodel_camera.reparent(vp, true)


## Re-tint every skin mesh to the current team colour while keeping its own
## texture.  FFA (no team) resolves to white — the identity tint — so the model
## renders with its authored materials instead of a flat colour.
func _apply_team_color() -> void:
	var color: Color = TEAM_COLORS.get(team, Color.WHITE)
	for i in skins.size():
		var skin: MeshInstance3D = skins[i]
		if skin == null:
			continue
		var original: Material = _skin_original_materials[i] if i < _skin_original_materials.size() else null
		if original == null:
			continue
		# Identity tint (FFA) or an untintable shader — show the authored material.
		if color.is_equal_approx(Color.WHITE) or not (original is BaseMaterial3D):
			skin.set_surface_override_material(0, null)
			continue
		var tinted: Material = original.duplicate() as Material
		(tinted as BaseMaterial3D).albedo_color = color
		skin.set_surface_override_material(0, tinted)


## Return the material a mesh uses for surface 0 before any team-tint override,
## falling back to a fresh material when the model ships none.
func _original_surface_material(mesh: MeshInstance3D) -> Material:
	if mesh.mesh != null:
		if mesh.mesh.get_surface_count() > 0:
			var mat := mesh.mesh.surface_get_material(0)
			if mat != null:
				return mat
		if mesh.mesh.material != null:
			return mesh.mesh.material
	if mesh.material_override != null:
		return mesh.material_override
	return StandardMaterial3D.new()


## True when this Player is the local peer's own first-person model.
func _is_own_model() -> bool:
	return body.is_multiplayer_authority() and not is_bot


## Collect the meshes that should receive team colouring (everything except
## the head meshes, which are marked on the model's PlayerModel).
func _rebuild_skins() -> void:
	skins.clear()
	_skin_original_materials.clear()
	if model_script == null:
		return
	for mesh in model_script.get_skin_meshes():
		skins.append(mesh)
		_skin_original_materials.append(_original_surface_material(mesh))


## Read a base stat with an optional character offset applied.
func _cmult(base: float, mult: float) -> float:
	return base * mult
