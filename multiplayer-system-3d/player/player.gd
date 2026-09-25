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

@export var respawn_time: float = 1.0
## Seconds a death ragdoll corpse stays in the world before being freed.
const RAGDOLL_LIFETIME: float = 25.0
## Impulse (N·s) applied to each ragdoll bone along the killing blow's direction.
const RAGDOLL_DEATH_IMPULSE: float = 4.0
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
signal character_changed()


var skins: Array[MeshInstance3D] = []

## Original surface-0 material for each entry in [member skins], captured when
## the character model is built.  Team tinting duplicates these so the model's
## own textures survive instead of being flattened to a single solid colour.
var _skin_original_materials: Array[Material] = []

const TEAM_COLORS: Dictionary = {
	Team.SCI: Color.BLUE,
	Team.SPI: Color.RED,
}

var team: Team = Team.FFA:
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
const MAX_STAMINA: int = 3
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

# Air action limits — consumed mid-air jumps/dashes, reset each grounded tick.
var air_jumps_used: int = 0
var air_dashes_used: int = 0

## The character's maximum stamina, or the default when no character is set.
func get_max_stamina() -> int:
	return _character.max_stamina if _character else MAX_STAMINA


## Mid-air jumps allowed per airtime (character override, default 1).
func get_max_air_jumps() -> int:
	return _character.air_jumps if _character else 1


## Mid-air dashes allowed per airtime (character override, default 1).
func get_max_air_dashes() -> int:
	return _character.air_dashes if _character else 1

# Active grounded-dash state.
var dash_time: float = 0.0             # > 0 while a grounded dash is running
var active_dash_dir: Vector3 = Vector3.ZERO
var dash_grounded: bool = false        # dash began grounded (enables coyote dash jump)

# Active shoulder-charge state (rolled back).
var charge_time: float = 0.0           # > 0 while a charge is running
var charge_dir: Vector3 = Vector3.ZERO # unit direction the charge travels along

# Active bashdown state (rolled back).
var bashdown_time: float = 0.0            # > 0 while the lunge window is open
var bashdown_dir: Vector3 = Vector3.ZERO  # frozen look direction at cast
var bashdown_slamming: bool = false       # true during the slam-down phase

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
@onready var third_person_camera := $ThirdPersonRoot/ThirdPersonPitch/SpringArm3D/ThirdPersonCamera3D as Camera3D
@onready var third_person_root := $ThirdPersonRoot as Node3D
@onready var third_person_pitch := $ThirdPersonRoot/ThirdPersonPitch as Node3D
@onready var third_person_raycast := $ThirdPersonRoot/ThirdPersonPitch/SpringArm3D/ThirdPersonCamera3D/RayCast3D as RayCast3D
@export var body :Node3D


@export var weapon_controller: WeaponController
@onready var collider: CollisionShape3D = $CollisionShape3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var damage_number_manager: DamageNumberManager = $DamageNumberManager
@onready var status_effect_manager: StatusEffectManager = $StatusEffectManager
@onready var ability_manager: AbilityManager = $AbilityManager

var is_crouching: bool = false

## True while the local player is in third-person view (toggled with F).
var third_person: bool = false

# Character selection
var _character: Character = null

## Cached ShoulderChargeAbility (read for its tunables inside the rollback tick).
var _charge_ability: ShoulderChargeAbility = null

## Server-side list of players currently pinned to this charger (by name).
var _pinned_players: Array[String] = []
## Server-side latch: set when the charge hits a wall, processed next frame.
var _wall_slam_pending: bool = false

## Cached BashDownAbility (read for its tunables inside the rollback tick).
var _bashdown_ability: BashDownAbility = null

## Cached TeleportAbility (read for its tunables inside the rollback tick).
var _teleport_ability: TeleportAbility = null

## Cached AimbotAbility (read for its max angle / active-state inside _process).
var _aimbot_ability: AimbotAbility = null
## Server-side list of players currently being carried by a bashdown slam.
var _bashdown_pinned: Array[String] = []
## victim name -> whether they were standing on the ground when grabbed.
var _bashdown_victim_grounded: Dictionary = {}
## Server-side latch: a bashdown bump was detected; pin the victim next frame.
var _bashdown_bump_pending: bool = false
## Server-side latch: a bashdown slam reached the ground; release victims next frame.
var _bashdown_land_pending: bool = false
## Victim name chosen by the deterministic bump scan (server only).
var _bashdown_bump_enemy: String = ""
## The victim's is_on_floor() at the moment of the bump (server only).
var _bashdown_bump_grounded: bool = false

## The currently-active third-person model (what other players see): the
## built-in mannequin, or a spawned character model.
var model: Node3D = null

## The [PlayerModel] component attached to [member model] (null until a model
## that carries the script is active).
var model_script: PlayerModel = null

## The built-in mannequin (always present under Body) drives the world model's
## animation via the AnimationTree; a spawned character model copies its pose.
@onready var mannequin: Node3D = $Body/Mannequin
var mannequin_skeleton: Skeleton3D = null

## Skeleton of a spawned character model that mirrors the mannequin's pose.
var _pose_target: Skeleton3D = null
## Destination bone index (into _pose_target) per mannequin bone index, -1 if missing.
var _pose_map: PackedInt32Array = PackedInt32Array()

## Debug: when a character model replaces the mannequin, show BOTH at once (the
## mannequin AND the spawned character skin) so their alignment can be compared,
## instead of hiding the mannequin.
@export var debug_show_both_models: bool = false

@onready var animation_tree: AnimationTree = $Body/AnimationTree

@export var crouch_height: float = 1.3333
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
@export var slope_gravity: float = 40.0            # downhill force on slopes (units/s²)
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

## Cached FOV applied to the camera; used to skip recomputing mouse sensitivity
## every rendered frame when the scope FOV is unchanged.
var _applied_fov: float = -1.0

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

# ── Pinned-by-charge state ────────────────────────
# Set via RPC by the charger and read inside _rollback_tick (like
# _spawn_pending_position, it persists across re-simulation).  While
# pinned_charger_name is set, the player follows that charger every tick.
var pinned_charger_name: String = ""
var pinned_offset: Vector3 = Vector3.ZERO
## True while pinned and being pushed against a wall (prevents noclip and ends
## the charger's charge).  Rollback state so the charger reads it deterministically.
var pinned_at_wall: bool = false

# ── Enlarge (Rampage) state ────────────────────────
# Persistent across rollback: set via RPC by EnlargeEffect and read inside
# _rollback_tick (like _spawn_pending_position, it persists across re-simulation).
# Scaling the root node directly would be overwritten by netfox's rollback state
# (global_transform), so the scale is re-derived from this multiplier every tick.
var _enlarge_scale: float = 1.0

# ── Wallhack reveal state (client-side rendering) ──
# Each client toggles the outline / health bar on its own copies of other
# players, based on the viewer's wallhack/health-sight effects and the target's
# reveal effects.  Purely visual — never rollback-simulated or networked.
const WALLHACK_OUTLINE_SHADER: Shader = preload("res://player/wallhack_outline.gdshader")
const ALLY_OUTLINE_COLOR := Color(0.35, 0.85, 1.0)
const ENEMY_OUTLINE_COLOR := Color(1.0, 0.4, 0.2)

var _outline_material: ShaderMaterial = null
var _outline_meshes: Array[MeshInstance3D] = []
var _wallhack_outline_enabled := false
var _wallhack_outline_color := ALLY_OUTLINE_COLOR

## Teammate wallhack outlines fade out after being occluded this long (to avoid
## constant visual noise), then fade over TEAM_WALLHACK_FADE_TIME seconds.
const TEAM_WALLHACK_FADE_DELAY := 3.0
const TEAM_WALLHACK_FADE_TIME := 1.0
## Player name -> seconds spent occluded (teammates only).
var _teammate_occluded_time: Dictionary = {}

## Set by the local viewer each frame: whether they can currently "see" this
## player — directly (not occluded) or revealed through a wallhack.  Read by
## damage numbers and the health bar.
var _seen_by_local := true

## Occlusion raycasts + the players-group query are the only per-frame cost in
## `_update_visibility`, and they cascade O(N²) across clients.  Throttle both to
## a fixed interval and reuse cached results in between (see #2 in
## docs/05-known-issues.md).
const OCCLUSION_REFRESH_INTERVAL := 0.1
var _occlusion_timer := 0.0
## Player list + last occlusion result, refreshed every OCCLUSION_REFRESH_INTERVAL.
var _visibility_players: Array[Player] = []
var _occlusion_cache: Dictionary = {}  # player name -> bool

# ── Ghost abilities (invisibility / noclip) ───────────────────────────────
## Materials applied as material_override to the model + weapon while a ghost
## effect is active.  Client-side rendering, driven by the synced effect mirror.
const INVISIBLE_GLASS: StandardMaterial3D = preload("res://assets/materials/invisible_glass.tres")
const NOCLIP_BLACK: StandardMaterial3D = preload("res://assets/materials/noclip_black.tres")

## Visual tiers for a ghost-effected player.  NONE = normal, GLASS = translucent
## glass (self/teammate invisible), BLACK = translucent black (noclip), HIDDEN =
## fully invisible (invisible to an enemy).
enum GhostTier { NONE, GLASS, BLACK, HIDDEN }

## The tier currently applied to this player's local copy of the model.
var _ghost_tier: int = GhostTier.NONE

## Server-only: seconds remaining of the post-noclip 999-damage overlap pulse.
var _noclip_exit_time: float = 0.0
## Server-only: player names already hit by the current exit pulse (once each).
var _noclip_exit_hit: Dictionary = {}

## Whether the player's hurtbox areas are currently enabled (disabled in noclip).
var _hurtboxes_active := true

## 2D health-bar reveal UI (projected above the head, like a damage number).
var _health_bar: Label = null

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

	player_input.toggle_camera.connect(_on_toggle_camera)

	# Resolve the built-in mannequin — it always drives the animation.
	mannequin_skeleton = mannequin.find_child("Skeleton3D", true, false) as Skeleton3D
	# SkeletonModifier3D (CCDIK/Aim/CopyTransform) results are rolled back after
	# the skeleton update, so copy the pose inside skeleton_updated — not in
	# _process, where get_bone_pose_* already returns the un-modified pose.
	if mannequin_skeleton:
		mannequin_skeleton.skeleton_updated.connect(_copy_mannequin_pose)
	# Give each player its own animation tree.  tree_root (and its nested nodes,
	# e.g. the ArmsAnim hold node) is a shared SubResource across scene instances,
	# so changing one player's weapon hold would change every player's.
	animation_tree.tree_root = animation_tree.tree_root.duplicate(true) as AnimationNodeBlendTree
	animation_tree.active = true

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

	# Wallhack outline material — one shared instance per player.
	_outline_material = ShaderMaterial.new()
	_outline_material.shader = WALLHACK_OUTLINE_SHADER

	# Health-bar reveal UI: a 2D Label on its own CanvasLayer, projected above
	# the head like a damage number (constant screen size regardless of distance).
	var layer := CanvasLayer.new()
	layer.layer = 3
	layer.name = "HealthBarLayer"
	add_child(layer)
	_health_bar = Label.new()
	_health_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_health_bar.add_theme_color_override("font_color", Color(0.35, 0.95, 0.35))
	_health_bar.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_health_bar.add_theme_constant_override("outline_size", 4)
	_health_bar.add_theme_font_size_override("font_size", 22)
	_health_bar.visible = false
	layer.add_child(_health_bar)

	# The old world-space label is superseded by the 2D bar above.
	$Body/HealthBarPublic.hide()

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

	# Clear pinned-by-charge state (this player is no longer being carried).
	pinned_charger_name = ""
	pinned_offset = Vector3.ZERO
	pinned_at_wall = false
	_wall_slam_pending = false
	_bashdown_bump_pending = false
	_bashdown_land_pending = false
	_bashdown_bump_enemy = ""

	# If this player was carrying enemies, release them (server only).
	if multiplayer.is_server():
		_release_all_pinned(false)
		_release_bashdown_pinned()

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


## Spawn a physical ragdoll corpse at this player's death location, on every peer.
## Each peer duplicates its own local copy of the dead player's visible model (the
## character skin when one is active, otherwise the built-in mannequin), freezes
## its animation, and lets the physical bones flop it to the ground for
## RAGDOLL_LIFETIME seconds.
@rpc("any_peer", "call_local", "reliable")
func _spawn_ragdoll(ragdoll_transform: Transform3D, death_impulse: Vector3) -> void:
	if mannequin == null:
		return

	# Ragdoll the player's current third-person model: the character skin when one
	# is active, otherwise the built-in mannequin.
	var source: Node3D = mannequin
	if model != null and model != mannequin and is_instance_valid(model):
		source = model

	var corpse: Node3D = source.duplicate()
	corpse.name = "Ragdoll_" + name
	get_parent().add_child(corpse)
	corpse.global_transform = ragdoll_transform
	corpse.visible = true
	corpse.add_to_group("ragdolls")

	# Reveal every mesh (the local player's own head is hidden in first person).
	for m in corpse.find_children("*", "MeshInstance3D", true, false):
		if m is MeshInstance3D:
			(m as MeshInstance3D).visible = true

	var skel := corpse.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		# `duplicate()` copies rest poses only, not the current animated pose —
		# copy the live skeleton pose so the corpse drops from the death pose.
		var src_skel := source.find_child("Skeleton3D", true, false) as Skeleton3D
		if src_skel:
			for i in src_skel.get_bone_count():
				skel.set_bone_pose_position(i, src_skel.get_bone_pose_position(i))
				skel.set_bone_pose_rotation(i, src_skel.get_bone_pose_rotation(i))
				skel.set_bone_pose_scale(i, src_skel.get_bone_pose_scale(i))
		# Freeze aim/copy modifiers (CCDIK, CopyTransformModifier) so they don't
		# fight the ragdoll physics. PhysicalBoneSimulator3D is itself a
		# SkeletonModifier3D, so exclude it explicitly.
		for child in skel.get_children():
			if child is SkeletonModifier3D and not child is PhysicalBoneSimulator3D:
				child.enabled = false

	# The mannequin carries the physical-bone setup; a character model does not.
	# Copy it onto the character model's skeleton — bone names match (both rigs
	# use the same humanoid "DEF-…" naming, see _setup_pose_copy).
	var sim := corpse.find_child("PhysicalBoneSimulator3D", true, false) as PhysicalBoneSimulator3D
	if sim == null and skel != null:
		var src_sim := mannequin.find_child("PhysicalBoneSimulator3D", true, false) as PhysicalBoneSimulator3D
		if src_sim:
			sim = src_sim.duplicate() as PhysicalBoneSimulator3D
			skel.add_child(sim)

	# Turn on the ragdoll physics so the corpse flops to the ground.  Move the
	# bones to the dedicated RAGDOLLS layer (1 << 7) that nothing scans, and keep
	# them colliding only with world geometry (1 << 0) so they don't shove players.
	if sim:
		for bone in sim.get_children():
			if bone is PhysicalBone3D:
				bone.collision_layer = 1 << 7
				bone.collision_mask = 1 << 0
				# The corpse's bones inherited the HurtboxComponent script from the
				# live mannequin; strip it so they aren't mistaken for living hurtboxes.
				bone.set_script(null)
		sim.physical_bones_start_simulation()

	# Apply the killing blow's impulse so the corpse flies away from the shot.
	if sim and death_impulse != Vector3.ZERO:
		for bone in sim.get_children():
			if bone is PhysicalBone3D:
				(bone as PhysicalBone3D).apply_central_impulse(death_impulse)

	# Despawn after RAGDOLL_LIFETIME seconds (timer parented to the corpse so it
	# is freed alongside it on map swap — same pattern as the hit-decal timer).
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = RAGDOLL_LIFETIME
	timer.timeout.connect(corpse.queue_free)
	corpse.add_child(timer)
	timer.start()


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
		# Cleanse status effects the moment of death so nothing leaks to the next
		# life.  (rpc_reset clears again below; this guards the death frame itself.)
		if status_effect_manager:
			status_effect_manager.clear_all_effects()
		var death_impulse := attribute_component.last_hit_direction * RAGDOLL_DEATH_IMPULSE
		_spawn_ragdoll.rpc(mannequin.global_transform, death_impulse)
		rpc_reset.rpc(_get_spawn_position())


## Respawn immediately, skipping the respawn timer.  Called by CheatDeathAbility.
## Server-only entry point; the RPC zeroes the timer on every peer so each peer
## respawns on its next _physics_process tick (spawn position already queued).
func cheat_death() -> void:
	if not multiplayer.is_server() or spawned:
		return
	rpc_cheat_death.rpc()


@rpc("any_peer", "call_local", "reliable")
func rpc_cheat_death() -> void:
	respawn_timer = 0.0


#@rpc("call_local")
#func _sync_head():
	#$HeadHurtbox.global_rotation = %Head.global_rotation
	#$BodyHurtbox.global_rotation = $Body.global_rotation


## Toggle between first- and third-person view (F key).
func _on_toggle_camera() -> void:
	third_person = not third_person
	_apply_camera_mode()


## Make the first- or third-person camera current for the local player.
func _apply_camera_mode() -> void:
	if not _is_own_model() or not spawned:
		return
	if third_person:
		_sync_third_person_rig()
		camera.current = false
		camera.visible = false
		third_person_camera.visible = true
		third_person_camera.make_current()
		_set_own_head_visible(true)
	else:
		third_person_camera.current = false
		third_person_camera.visible = false
		camera.visible = true
		camera.make_current()
		_set_own_head_visible(false)


## Show or hide the local player's own head meshes.  The head is hidden in first
## person so it doesn't clip the camera; third person shows it again.
func _set_own_head_visible(visible: bool) -> void:
	if model_script == null:
		return
	if visible:
		model_script.show_head_meshes()
	else:
		model_script.hide_head_meshes()


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
	set_wallhack_outline(false)
	set_public_health_visible(false)
	hide()
	spawned = false
	collider.disabled = true
	global_position = GameManager.get_despawn_position()
	$Body/PlayerUI.hide()
	camera.current = false
	camera.visible = false
	third_person_camera.current = false
	third_person_camera.visible = false

## Show the player: enable collision, restore camera, position at the given
## location (already set before calling this).
func spawn():
	show()
	spawned = true
	collider.disabled = false
	# The first-person HUD belongs only to the local peer's own model. Showing it
	# for bots/remote players is what briefly surfaced their HUD on your screen.
	if _is_own_model():
		$Body/PlayerUI.show()
	else:
		$Body/PlayerUI.hide()
	if not is_bot:
		var my_id := multiplayer.get_unique_id()
		var player_id := name.to_int()
		if my_id == player_id:
			_apply_camera_mode()
			#$BodyHurtbox/CollisionShape3D.hide()
		else:
			camera.current = false
			camera.visible = false
			third_person_camera.current = false
			third_person_camera.visible = false
	else:
		camera.current = false
		camera.visible = false
		third_person_camera.current = false
		third_person_camera.visible = false

	# Weapon is briefly unusable on every (re)spawn — plays the pull-out anim and
	# locks it for the weapon's pullout_time.
	weapon_controller.trigger_pullout()

	# Cleanse any status effect that leaked in during the despawn window (e.g. a
	# lingering projectile hit) so every life starts clean.
	if status_effect_manager:
		status_effect_manager.clear_all_effects()

	# Re-apply always-on passive status effects (wallhacked/health-visible to
	# team, and any character passives).  Server-only; clear_all_effects() wiped
	# them above.
	_apply_passive_effects()


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

	# Shoulder charge carry/stun (server-authoritative, real frames only).
	_update_shoulder_charge()

	# Bashdown bump/slam damage (server-authoritative, real frames only).
	_update_bashdown()

	# Noclip exit pulse: for ~1 s after leaving noclip, deal 999 damage to any
	# enemy overlapping this player's body (server-authoritative).
	if _noclip_exit_time > 0.0:
		_noclip_exit_time -= delta
		_update_noclip_exit_pulse()

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
	# Don't deal self fall damage during a bashdown (the slam is intentional).
	if is_bashing():
		_max_fall_speed = 0.0
		_was_airborne = false
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
	# Re-derive the player scale from the enlarge multiplier every tick.  This is
	# the only reliable place to set it: netfox re-applies global_transform from
	# its rollback history each tick, so a one-off scale write elsewhere is lost.
	scale = Vector3.ONE * _enlarge_scale

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

	# Shoulder charge trigger (deterministic — see PlayerInput.charge_trigger_dir).
	if player_input.charge_trigger_dir != Vector3.ZERO:
		_start_charge(player_input.charge_trigger_dir)

	# Bashdown trigger (deterministic — see PlayerInput.bashdown_trigger_dir).
	if player_input.bashdown_trigger_dir != Vector3.ZERO:
		_start_bashdown(player_input.bashdown_trigger_dir)

	# Teleport trigger (deterministic — see PlayerInput.teleport_trigger_dir).
	if player_input.teleport_trigger_dir != Vector3.ZERO:
		_do_teleport(player_input.teleport_trigger_dir)

	# Pinned by a shoulder charge — follow the charger every tick.  The pin is
	# set via RPC and persists across re-simulation (see _rpc_pin).  The carry
	# respects walls: if it would push us into geometry, we hold position and
	# flag the wall contact instead of noclipping through.
	if pinned_charger_name != "":
		var charger := GameManager.find_player(pinned_charger_name)
		if charger != null and charger.spawned:
			var target := charger.global_position + pinned_offset
			var motion := target - global_position
			if motion.length_squared() > 0.0001 and test_move(global_transform, motion):
				pinned_at_wall = true
			else:
				global_position = target
				pinned_at_wall = false
			velocity = Vector3.ZERO
			return
		pinned_charger_name = ""

	_apply_movement_from_input(delta)

	# Shoulder charge wall impact — end the charge deterministically when either
	# the charger hits a wall or any pinned player is pushed into one.  The release
	# + stun response is server-only; it's latched here and handled next frame.
	var charge_hit_wall := charge_time > 0.0 and is_on_wall()
	if charge_time > 0.0 and not charge_hit_wall:
		for node in get_tree().get_nodes_in_group("players"):
			var other := node as Player
			if other != null and other != self and other.pinned_charger_name == name and other.pinned_at_wall:
				charge_hit_wall = true
				break
	if charge_hit_wall:
		charge_time = 0.0
		charge_dir = Vector3.ZERO
		if multiplayer.is_server():
			_wall_slam_pending = true

	# Bashdown bump — deterministically detect the first enemy hit during the lunge
	# and transition to the slam.  Damage/pin is server-only; it's latched here.
	if bashdown_time > 0.0 and not bashdown_slamming:
		var target := _find_bashdown_target()
		if target != null:
			bashdown_time = 0.0
			bashdown_slamming = true
			if multiplayer.is_server():
				_bashdown_bump_enemy = target.name
				_bashdown_bump_grounded = target.is_on_floor()
				_bashdown_bump_pending = true
	# Bashdown slam landing — deterministically end the slam when the charger hits
	# the ground.  Slam damage/release is server-only; it's latched here.
	if bashdown_slamming and is_on_floor():
		bashdown_slamming = false
		if multiplayer.is_server():
			_bashdown_land_pending = true

func _force_update_is_on_floor():
	var old_velocity = velocity
	velocity = Vector3.ZERO
	move_and_slide()
	velocity = old_velocity


# ── Noclip free-fly ──────────────────────────────────────────────────────────
# Noclip removes gravity and all collision (walls, floors and players).  WASD
# moves the player along the camera's full 3D basis — W is the camera forward
# (including pitch), A/D strafe — so the ghost can fly through geometry.

## Free-fly movement for the noclip state: camera-relative 3D steering with no
## gravity and no collision.  Replaces the normal movement sim entirely.
func _noclip_move(delta: float) -> void:
	var cam_basis: Basis = _movement_basis()
	var fwd := -cam_basis.z
	var rgt := cam_basis.x
	var input := player_input.input_dir
	# input_dir.y is -1 for forward (W) and +1 for backward (S), so negate it to
	# steer along the true camera-forward vector.
	var wish := fwd * (-input.y) + rgt * input.x
	var wish_dir := wish.normalized() if wish.length_squared() > 0.0001 else Vector3.ZERO

	speed = ADS_SPEED if ads else NORMAL_SPEED
	var calc_speed: float = _cmult(speed, _character.speed_mult if _character else 1.0)
	var weapons := weapon_controller.get_weapons()
	if not weapons.is_empty():
		calc_speed = calc_speed * weapons[weapon_controller.current_weapon_index].player_speed_multiplier
		calc_speed = calc_speed * weapon_controller.get_active_fire_speed_mult()
	calc_speed *= get_status_speed_mult()

	if wish_dir == Vector3.ZERO:
		# No input: damp velocity to a stop on all axes.
		var fric: float = _cmult(friction, _character.friction_mult if _character else 1.0)
		velocity = velocity.move_toward(Vector3.ZERO, fric * delta)
	else:
		var accel: float = _cmult(acceleration, _character.acceleration_mult if _character else 1.0)
		var target := wish_dir * calc_speed
		velocity.x = move_toward(velocity.x, target.x, accel * delta)
		velocity.y = move_toward(velocity.y, target.y, accel * delta)
		velocity.z = move_toward(velocity.z, target.z, accel * delta)

	# Integrate directly — no move_and_slide, so nothing blocks the body.  This
	# path advances by the tick delta itself (delta == NetworkTime.ticktime), so
	# velocity must NOT be scaled by physics_factor: that factor converts between
	# the tick delta and move_and_slide()'s own delta, which is not used here.
	# Scaling it anyway made noclip fly at 2/3 speed at 90 Hz / 60 fps.  The
	# knockback term is added un-scaled, matching what the normal path stores.
	velocity += knockback_velocity
	global_position += velocity * delta

	var knockback_decay: float = velocity.length() ** 2 * 10
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)


## Enable/disable the player's hurtbox areas.  Disabled during noclip so
## bullets/projectiles pass straight through (damage is also gated in
## change_health).
func _set_hurtboxes_active(active: bool) -> void:
	# Hurtboxes are now PhysicalBone3D hurtboxes held by HurtComponent2, not
	# Area3D direct children.  Toggle each one's collision layer directly.
	for hb in $HurtComponent2.hurtbox_components:
		if hb != null:
			hb.collision_layer = 4 if active else 0


## Begin the post-noclip 999-damage overlap window (server only).  Called by
## NoclipEffect._on_remove when noclip is cancelled or cleared on death.
func _start_noclip_exit_pulse() -> void:
	if not multiplayer.is_server() or not spawned:
		return
	_noclip_exit_time = 1.0
	_noclip_exit_hit.clear()


## Deal 999 damage to every enemy overlapping this player's body, once each.
## Called each physics frame while [_noclip_exit_time] is positive.
func _update_noclip_exit_pulse() -> void:
	if not multiplayer.is_server() or not spawned:
		return
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = collider.shape
	params.transform = global_transform
	params.collision_mask = 2  # PLAYER_COLLISION
	params.exclude = [get_rid()]
	var hits := get_world_3d().direct_space_state.intersect_shape(params, 32)
	for hit in hits:
		var other := hit.get("collider") as Player
		if other == null or other == self or not _is_enemy_of(other):
			continue
		if _noclip_exit_hit.has(other.name):
			continue
		_noclip_exit_hit[other.name] = true
		other.change_health(-999.0, name)


func apply_knockback(force: Vector3) -> void:
	if force.length() < 0.01:
		return
	# The only impulse write to knockback_velocity — every other reference is a
	# reset.  No tick-domain conversion happens here: the impulse is converted
	# where it is integrated, so this is a pure per-character feel multiplier.
	var mult: float = _character.knockback_multiplier if _character else 1.0
	knockback_velocity += force * mult

# ── Shoulder charge (server-authoritative carry/stun) ──────────────────

## Begin a shoulder charge deterministically from a queued trigger direction.
func _start_charge(dir: Vector3) -> void:
	var duration: float = _charge_ability.charge_duration if _charge_ability else 4.0
	charge_time = duration
	charge_dir = dir.normalized()


# ── Bashdown (server-authoritative bump/slam) ────────────────────────────

## Begin a bashdown deterministically from a queued trigger direction.
func _start_bashdown(dir: Vector3) -> void:
	bashdown_dir = dir.normalized()
	bashdown_time = _bashdown_ability.lunge_duration if _bashdown_ability else 0.5
	bashdown_slamming = false


## Apply a deterministic teleport from a queued trigger direction.  The target is
## clamped against geometry so the player never ends up inside a wall.  Position
## and velocity are rollback state, so every peer replays the same jump.
func _do_teleport(dir: Vector3) -> void:
	var dist: float = _teleport_ability.teleport_distance if _teleport_ability else 3.0
	var motion := dir.normalized() * dist
	if dist > 0.0 and test_move(global_transform, motion):
		# Back off from the full distance until the motion clears the geometry.
		var travel := motion
		for i in range(8, 0, -1):
			travel = motion * (float(i) / 8.0)
			if not test_move(global_transform, travel):
				break
		global_position += travel
	else:
		global_position += motion
	velocity = Vector3.ZERO
	tick_interpolator.teleport()


## Server-side per-frame driver: consume the bump/land latches set in _rollback_tick.
func _update_bashdown() -> void:
	if not multiplayer.is_server() or not spawned:
		return
	if _bashdown_bump_pending:
		_bashdown_bump_pending = false
		var enemy := GameManager.find_player(_bashdown_bump_enemy)
		if enemy != null and enemy.spawned:
			_pin_bashdown_player(enemy)
	if _bashdown_land_pending:
		_bashdown_land_pending = false
		_release_bashdown_pinned()


## Deterministic: first enemy within grab_radius and roughly in front of the dive.
## Must NOT read server-only state (e.g. _bashdown_pinned) so every peer agrees.
func _find_bashdown_target() -> Player:
	var radius: float = _bashdown_ability.grab_radius if _bashdown_ability else 1.5
	for node in get_tree().get_nodes_in_group("players"):
		var other := node as Player
		if other == null or other == self:
			continue
		if not _is_enemy_of(other) or other.pinned_charger_name != "":
			continue
		var to := other.global_position - global_position
		var dist := to.length()
		if dist > radius:
			continue
		if dist > 0.001 and to.normalized().dot(bashdown_dir) < 0.3:
			continue
		return other
	return null


## Bump: deal bump damage, then carry the victim (server only).
func _pin_bashdown_player(other: Player) -> void:
	other.change_health(-(_bashdown_ability.bump_damage if _bashdown_ability else 20.0), name)
	if not other.spawned:
		return
	_bashdown_pinned.append(other.name)
	_bashdown_victim_grounded[other.name] = _bashdown_bump_grounded
	other._rpc_pin.rpc(name, other.global_position - global_position)
	var pinned := PinnedEffect.new()
	pinned.base_duration = 4.0   # fallback; released by the slam landing, not the timer
	if other.status_effect_manager:
		other.status_effect_manager.apply_effect(pinned, name)


## Slam landing: release victims; apply slam damage only if they were grounded at grab.
func _release_bashdown_pinned() -> void:
	if not multiplayer.is_server():
		return
	for victim_name in _bashdown_pinned:
		var victim := GameManager.find_player(victim_name)
		if victim != null:
			victim._rpc_unpin.rpc()
			if victim.status_effect_manager:
				victim.status_effect_manager.remove_effect("pinned")
			if victim.spawned and _bashdown_victim_grounded.get(victim_name, false):
				victim.change_health(-(_bashdown_ability.slam_damage if _bashdown_ability else 30.0), name)
	_bashdown_pinned.clear()
	_bashdown_victim_grounded.clear()


## Server-side per-frame driver: grab nearby enemies while charging, and release
## any pinned players once the charge ends.
func _update_shoulder_charge() -> void:
	if not multiplayer.is_server() or not spawned:
		return
	if _wall_slam_pending:
		_wall_slam_pending = false
		_release_all_pinned(true)
	if charge_time > 0.0:
		_grab_nearby_enemies()
	elif not _pinned_players.is_empty():
		_release_all_pinned(false)


## Grab enemy players within grab radius and roughly in front of the charger.
func _grab_nearby_enemies() -> void:
	var radius: float = _charge_ability.grab_radius if _charge_ability else 1.5
	for node in get_tree().get_nodes_in_group("players"):
		var other := node as Player
		if other == null or other == self or not other.spawned:
			continue
		if not _is_enemy_of(other):
			continue
		if _pinned_players.has(other.name) or other.pinned_charger_name != "":
			continue
		var to := other.global_position - global_position
		to.y = 0.0
		var dist := to.length()
		if dist > radius:
			continue
		if dist > 0.001 and to.normalized().dot(charge_dir) < 0.3:
			continue
		_pin_player(other)


## Pin [param other] to this charger: deal impact damage, then carry them and
## mark them with the pinned status effect.  Server only.
func _pin_player(other: Player) -> void:
	# Impact damage first — if it kills, don't pin the corpse.
	other.change_health(-_charge_impact_damage(), name)
	if not other.spawned:
		return
	_pinned_players.append(other.name)
	other._rpc_pin.rpc(name, other.global_position - global_position)
	var pinned := PinnedEffect.new()
	pinned.base_duration = charge_time + 0.5
	if other.status_effect_manager:
		other.status_effect_manager.apply_effect(pinned, name)


## Release every pinned player, slamming them (stun + wall damage) if they were
## slammed into a wall.  Server only.
func _release_all_pinned(stun: bool) -> void:
	if not multiplayer.is_server():
		return
	for victim_name in _pinned_players:
		var victim := GameManager.find_player(victim_name)
		if victim:
			victim._rpc_unpin.rpc()
			if victim.status_effect_manager:
				victim.status_effect_manager.remove_effect("pinned")
			if stun:
				_apply_wall_slam(victim)
	_pinned_players.clear()


## Wall-slam a released victim: stun them and deal wall damage.  Server only.
## Stun is applied before damage so a lethal slam is cleared on respawn.
func _apply_wall_slam(victim: Player) -> void:
	if victim.status_effect_manager:
		var stun := StunEffect.new()
		stun.base_duration = _charge_stun_duration()
		victim.status_effect_manager.apply_effect(stun, name)
	victim.change_health(-_charge_wall_damage(), name)


## RPC: mark this player as pinned to [param charger_name] at [param offset].
@rpc("any_peer", "call_local", "reliable")
func _rpc_pin(charger_name: String, offset: Vector3) -> void:
	pinned_charger_name = charger_name
	pinned_offset = offset
	pinned_at_wall = false


## RPC: clear this player's pinned state.
@rpc("any_peer", "call_local", "reliable")
func _rpc_unpin() -> void:
	pinned_charger_name = ""
	pinned_offset = Vector3.ZERO
	pinned_at_wall = false


## RPC: apply the enlarged player scale and max health on every peer.
## Called by EnlargeEffect (server-side) to sync the buff's visual/attribute
## changes, which are otherwise not replicated.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_enlarge(scale_mult: float, max_health: float) -> void:
	set_enlarge_scale(scale_mult)
	if attribute_component:
		attribute_component.starting_health = max_health

## Set the enlarge scale multiplier (Rampage).  1.0 = normal size, 2.0 = doubled.
## The multiplier is stored persistently so _rollback_tick re-applies it every
## tick; `scale` is also set immediately for the current frame.
func set_enlarge_scale(mult: float) -> void:
	_enlarge_scale = mult
	scale = Vector3.ONE * mult

## Reset all stamina / dash / air-action state on respawn.
func _reset_movement_tech() -> void:
	stamina = float(get_max_stamina())
	dash_held_prev = false
	jump_held_prev = false
	crouch_held_prev = false
	air_jumps_used = 0
	air_dashes_used = 0
	dash_time = 0.0
	active_dash_dir = Vector3.ZERO
	dash_grounded = false
	dash_jump_locked = false
	crouch_tap_timer = 0.0
	charge_time = 0.0
	charge_dir = Vector3.ZERO
	bashdown_time = 0.0
	bashdown_dir = Vector3.ZERO
	bashdown_slamming = false
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


func _process(_delta: float) -> void:
	# Scope FOV + mouse sensitivity are visual/local, so update them every
	# rendered frame rather than inside the rollback tick (which re-simulates and
	# made the ADS zoom step/jitter).  The FOV is a pure function of `ads` + the
	# current weapon except while a scope transition lerps, so only recompute
	# sensitivity when the FOV actually changes — not every frame.
	const BASE_MOUSE_SENS: float = 0.002
	const BASE_FOV: float = 90.0
	var fov: float = weapon_controller.get_scope_fov()
	if fov != _applied_fov:
		_applied_fov = fov
		camera.fov = fov
		var fov_ratio: float = fov / BASE_FOV
		body.mouse_sens_x = BASE_MOUSE_SENS * fov_ratio
		body.mouse_sens_y = BASE_MOUSE_SENS * fov_ratio

	# Noclip: disable hurtboxes so bullets/projectiles pass through (mirrored on
	# all peers via the synced effect id).
	var noclip_active := status_effect_manager != null and status_effect_manager.has_effect("noclip")
	if _hurtboxes_active == noclip_active:
		_hurtboxes_active = not noclip_active
		_set_hurtboxes_active(_hurtboxes_active)

	_update_health_bar()
	_update_visibility(_delta)
	_update_aimbot()
	_update_third_person_aim()


func _apply_movement_from_input(delta):
	# Noclip is free-fly: no gravity, no collision, and WASD moves along the
	# camera's full 3D basis (W = camera forward incl. pitch).  It replaces the
	# normal movement simulation entirely.
	if status_effect_manager != null and status_effect_manager.has_effect("noclip"):
		_noclip_move(delta)
		return
	_force_update_is_on_floor()
	var on_floor := is_on_floor()

	# ── Crouch: snap the collider straight to the crouch/stand height ──
	# Smoothly interpolating the height every tick made the capsule float and
	# jitter (the integration fought netfox's rollback).  Crouch height is now a
	# pure function of the crouch input, so every peer derives the same shape.
	is_crouching = player_input.crouch and charge_time <= 0.0
	var shape: CapsuleShape3D = collider.shape as CapsuleShape3D
	var crouch_factor: float = 0.0
	if shape and _stand_collider_height > 0.0:
		var target_height: float = crouch_height if is_crouching else _stand_collider_height
		shape.height = target_height
		# Keep the capsule bottom fixed so the body doesn't bob up/down.
		collider.position.y = _stand_collider_y - (_stand_collider_height - target_height) * 0.67
		%Recoil.position.y = _stand_recoil_y - (_stand_collider_height - target_height) * 0.67
		crouch_factor = 1.0 if is_crouching else 0.0

	# Track grounded time so a minimum contact time can gate re-jumping.
	if on_floor:
		_ground_contact_time += delta
	else:
		_ground_contact_time = 0.0

	var input_dir := player_input.input_dir
	var cam_basis: Basis = _movement_basis()
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
		air_jumps_used = 0
		air_dashes_used = 0

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
		var gravity_scale: float = _character.gravity_scale if _character else 1.0
		velocity += get_gravity() * gravity_scale * delta * (-1.0 if gravity_flipped else 1.0)

	# -- Down dash --
	# Airborne double-tap of crouch: press crouch twice within DOWN_DASH_WINDOW.
	if crouch_pressed and charge_time <= 0.0:
		if not on_floor:
			if crouch_tap_timer > 0.0:
				crouch_tap_timer = 0.0
				if dash_time <= 0.0 and air_dashes_used < get_max_air_dashes() and stamina >= 1.0:
					stamina -= 1.0
					air_dashes_used += 1
					velocity.y = -down_dash_impulse
			else:
				crouch_tap_timer = DOWN_DASH_WINDOW
	crouch_tap_timer = maxf(0.0, crouch_tap_timer - delta)

	# -- Jump / double jump / dash jump --
	if jump_pressed and charge_time <= 0.0:
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
		elif air_jumps_used < get_max_air_jumps() and stamina >= 1.0:
			# Mid-air jump.
			stamina -= 1.0
			air_jumps_used += 1
			velocity.y = _cmult(JUMP_VELOCITY, _character.jump_mult if _character else 1.0)
	elif on_floor and player_input.jump_input and dash_time <= 0.0 and charge_time <= 0.0:
		# Auto bunny hop: holding jump re-jumps the moment the player lands.
		_grounded_jump()

	# -- Dash (grounded = fixed velocity, air = impulse) --
	if dash_pressed and dash_time <= 0.0 and charge_time <= 0.0:
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
			elif not on_floor and air_dashes_used < get_max_air_dashes() and stamina >= 1.0:
				# Air dash: impulse stacked onto current velocity.
				stamina -= 1.0
				air_dashes_used += 1
				velocity.x += dash_dir.x * air_dash_impulse
				velocity.z += dash_dir.z * air_dash_impulse

	# -- Grounded dash: lock horizontal velocity to the dash speed --
	if dash_time > 0.0:
		velocity.x = active_dash_dir.x * dash_speed
		velocity.z = active_dash_dir.z * dash_speed

	# Recover a stamina bar once every stamina_recovery_time seconds.
	var max_stamina: int = get_max_stamina()
	if stamina < max_stamina:
		stamina = minf(stamina + delta / stamina_recovery_time, float(max_stamina))

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

	# -- Shoulder charge: push forward along the current look direction --
	if charge_time > 0.0:
		charge_time = maxf(charge_time - delta, 0.0)
		# Follow the look direction dynamically (yaw only).  `right` is the
		# camera's horizontal right vector computed above.
		charge_dir = Vector3.UP.cross(right)
		velocity.x = charge_dir.x * _charge_speed()
		velocity.z = charge_dir.z * _charge_speed()

	# -- Bashdown: lunge in the cast direction, or slam straight down --
	if bashdown_slamming:
		velocity = Vector3.DOWN * (_bashdown_ability.slam_speed if _bashdown_ability else 30.0)
	elif bashdown_time > 0.0:
		bashdown_time = maxf(bashdown_time - delta, 0.0)
		velocity = bashdown_dir * (_bashdown_ability.lunge_speed if _bashdown_ability else 20.0)
		velocity.y += (_bashdown_ability.launch_up_speed if _bashdown_ability else 6.0)

	# move_and_slide() advances by its own delta (the frame delta when the tick
	# loop runs from _process), so everything it integrates has to be scaled the
	# same way — knockback included.  Adding knockback *outside* the sandwich made
	# it frame-delta scaled, roughly 1.5x too strong at 60 fps and 3.6x at 25 fps;
	# Character.knockback_multiplier's old 0.667 hid half of that at a nominal
	# 60 fps.  Both terms now scale identically and cancel exactly.
	velocity *= NetworkTime.physics_factor
	velocity += knockback_velocity * NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor

	var knockback_decay: float = velocity.length() ** 2 * 10
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)

	# Cap head turn speed while charging (0 = unlimited).
	body.max_turn_speed = (_charge_ability.turn_speed if _charge_ability else 1.5) if charge_time > 0.0 else 0.0

func change_health(health: float, changer: String, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false):
	# Invincible or noclipping players take no damage and are immune to effects.
	if health < 0.0 and status_effect_manager and (status_effect_manager.is_invincible() or status_effect_manager.has_effect("noclip")):
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
	$Body/Recoil/Head.add_child(instance)
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
		if ability_manager:
			ability_manager.set_abilities(char.abilities)
	_refresh_charge_ability()
	_refresh_bashdown_ability()
	_refresh_teleport_ability()
	_refresh_aimbot_ability()
	_spawn_character_model()
	character_changed.emit()


## The basis of the camera the local player is currently looking through, used to
## steer movement (WASD, dash, charge).  Third person uses the orbiting
## third-person camera; first person uses the head camera.
func _movement_basis() -> Basis:
	if third_person and third_person_camera != null:
		return third_person_camera.global_transform.basis
	return camera.global_transform.basis


## The camera's forward vector flattened to the XZ plane (never points up/down).
## The camera faces -Z, so forward = up × right (not right × up, which is backward).
func horizontal_forward() -> Vector3:
	var cam_basis: Basis = _movement_basis()
	var right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z).normalized()
	return Vector3.UP.cross(right)


## The camera's full 3D forward vector (includes pitch).  The camera faces -Z.
func camera_forward() -> Vector3:
	return -camera.global_transform.basis.z


## Cache the character's shoulder-charge ability (if any) for reading its
## tunables inside the rollback tick.
func _refresh_charge_ability() -> void:
	_charge_ability = null
	if ability_manager:
		for a in ability_manager.abilities:
			if a is ShoulderChargeAbility:
				_charge_ability = a
				return


## Cache the character's bashdown ability (if any) for reading its tunables
## inside the rollback tick.
func _refresh_bashdown_ability() -> void:
	_bashdown_ability = null
	if ability_manager:
		for a in ability_manager.abilities:
			if a is BashDownAbility:
				_bashdown_ability = a
				return


## Cache the character's teleport ability (if any) for reading its tunables
## inside the rollback tick.
func _refresh_teleport_ability() -> void:
	_teleport_ability = null
	if ability_manager:
		for a in ability_manager.abilities:
			if a is TeleportAbility:
				_teleport_ability = a
				return


## Cache the character's aimbot ability (if any) for reading its max angle and
## active state inside _process.
func _refresh_aimbot_ability() -> void:
	_aimbot_ability = null
	if ability_manager:
		for a in ability_manager.abilities:
			if a is AimbotAbility:
				_aimbot_ability = a
				return


## Whether a shoulder charge is currently active.
func is_charging() -> bool:
	return charge_time > 0.0


## Whether a bashdown lunge or slam is currently active.
func is_bashing() -> bool:
	return bashdown_time > 0.0 or bashdown_slamming


## Whether [param other] is on an opposing team (or everyone, in FFA).
func _is_enemy_of(other: Player) -> bool:
	return team == Team.FFA or other.team != team


## Whether the aimbot effect is currently active on this player.
func is_aimbot_active() -> bool:
	return status_effect_manager != null and status_effect_manager.has_effect("aimbot")


## The aimbot's max snap angle (degrees), or 0 when no aimbot ability is set.
func get_aimbot_max_angle_deg() -> float:
	return _aimbot_ability.max_angle_deg if _aimbot_ability else 0.0


## Aim-assist tick: while the aimbot is active, we are the local player, and we
## are actively firing, rotate the head toward the best enemy head in the cone.
func _update_aimbot() -> void:
	if not _is_own_model() or not spawned:
		return
	if not is_aimbot_active():
		return
	# Only track while shooting (any fire button held).
	if not (player_input.primary_fire_held or player_input.secondary_fire_held or player_input.tertiary_fire_held):
		return
	var target := aimbot_find_target()
	if target == null:
		return
	_aimbot_rotate_to(target)


## Best enemy head to track: spawned enemies within max_angle_deg of the
## crosshair, choosing the one most directly under the crosshair (highest dot).
func aimbot_find_target() -> Player:
	var max_angle := get_aimbot_max_angle_deg()
	if max_angle <= 0.0 or camera == null:
		return null
	var cam := camera as Camera3D
	var cam_pos := cam.global_position
	var cam_fwd := camera_forward()
	var cos_max := cos(deg_to_rad(max_angle))
	var best: Player = null
	var best_dot := cos_max
	for node in get_tree().get_nodes_in_group("players"):
		var other := node as Player
		if other == null or other == self or not other.spawned:
			continue
		if not _is_enemy_of(other):
			continue
		var to := (other.global_position + Vector3(0.0, 1.69, 0.0)) - cam_pos
		var dist := to.length()
		if dist < 0.0001:
			continue
		var d := cam_fwd.dot(to / dist)
		if d > best_dot:
			best_dot = d
			best = other
	return best


## Rotate the head (body yaw + head pitch) so the camera aims at `point`.
## `recoil_free` (third-person aim) uses a forward that ignores the Recoil node's
## offset, so recoil visibly kicks; the default (aimbot) uses the real camera
## forward and keeps compensating recoil.
func _aim_body_head_at_point(point: Vector3, recoil_free: bool = false) -> void:
	if camera == null or body == null:
		return
	var cam := camera as Camera3D
	var head_node := cam.get_parent() as Node3D
	if head_node == null:
		return
	var head_pos := cam.global_position
	# Measure the aim direction from a point on the body's yaw axis (at head
	# height) rather than the actual head position.  The head orbits the yaw axis
	# as the body turns, so using it as the origin feeds the yaw back into `dir`
	# and flips the body ~180° every frame when the crosshair is steep (flicker).
	var cam_pos := Vector3(body.global_position.x, head_pos.y, body.global_position.z)
	var dir: Vector3 = point - cam_pos
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()

	# Current aim forward.  Recoil-free reconstructs it from body yaw + head pitch
	# so the recoil (on the parent Recoil node) is not read back and canceled.
	var aim_fwd: Vector3
	if recoil_free:
		var cy := cos(body.rotation.y)
		var sy := sin(body.rotation.y)
		var cp := cos(head_node.rotation.x)
		var sp := sin(head_node.rotation.x)
		aim_fwd = Vector3(-sy * cp, sp, -cy * cp)
	else:
		aim_fwd = camera_forward()

	# Yaw: rotate the body around Y to align the horizontal component.  Skip when
	# the target is nearly straight up/down (the crosshair sits almost directly
	# over/under the player) — yaw is degenerate there and the body would flip
	# ~180° between frames, which reads as flicker.
	if absf(dir.y) < 0.99:
		var f0_h := Vector3(aim_fwd.x, 0.0, aim_fwd.z)
		var f1_h := Vector3(dir.x, 0.0, dir.z)
		if f0_h.length_squared() > 0.0001 and f1_h.length_squared() > 0.0001:
			body.rotation.y += f0_h.normalized().signed_angle_to(f1_h.normalized(), Vector3.UP)

	# Pitch: rotate the head node (camera's parent) around X.
	var pitch_delta := asin(clampf(dir.y, -1.0, 1.0)) - asin(clampf(aim_fwd.y, -1.0, 1.0))
	head_node.rotation.x = clampf(head_node.rotation.x + pitch_delta, -PI / 2.0, PI / 2.0)


## Aimbot: aim the head at the target's head bone.
func _aimbot_rotate_to(target: Player) -> void:
	var bone := target.get_node("Body/Mannequin/mannequin/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-spine_006") as Node3D
	if bone:
		_aim_body_head_at_point(bone.global_position)


## The world point the crosshair sits on in third person: the raycast hit, or a
## far point along the third-person camera's forward when nothing is hit.
func _third_person_aim_target() -> Vector3:
	if third_person_raycast and third_person_raycast.is_colliding():
		return third_person_raycast.get_collision_point()
	return third_person_camera.global_position + (-third_person_camera.global_transform.basis.z) * 10000.0


## Third-person aim tick: point the body/head at the crosshair so the character
## model visually aims where the third-person camera looks.
func _update_third_person_aim() -> void:
	if not third_person:
		return
	if not _is_own_model() or not spawned:
		return
	_aim_body_head_at_point(_third_person_aim_target(), true)


## Snap the third-person rig to the player's current facing (yaw on the root,
## pitch on the pitch node) when entering third person.  The over-shoulder offset
## is fixed on the SpringArm3D/camera pair, so it needs no syncing.
func _sync_third_person_rig() -> void:
	if third_person_root == null or third_person_pitch == null or body == null:
		return
	var head_node := camera.get_parent() as Node3D
	third_person_root.rotation.y = body.rotation.y
	third_person_pitch.rotation.x = head_node.rotation.x if head_node else 0.0


## The charge speed from the ability resource, or a sensible fallback.
func _charge_speed() -> float:
	return _charge_ability.charge_speed if _charge_ability else 14.0


## The wall-slam stun duration from the ability resource, or a fallback.
func _charge_stun_duration() -> float:
	return _charge_ability.wall_stun_duration if _charge_ability else 3.0


## The impact damage from the ability resource, or a fallback.
func _charge_impact_damage() -> float:
	return _charge_ability.impact_damage if _charge_ability else 30.0


## The wall-slam damage from the ability resource, or a fallback.
func _charge_wall_damage() -> float:
	return _charge_ability.wall_damage if _charge_ability else 40.0


## Show the built-in mannequin or spawn the selected character's world model.
## A spawned model mirrors the mannequin's animated pose.
func _spawn_character_model() -> void:
	var own := _is_own_model()

	# Free any previously spawned character world model (the mannequin is permanent).
	if model != null and model != mannequin:
		model.queue_free()
	model = null
	_pose_target = null
	_pose_map = PackedInt32Array()

	var scene: PackedScene = _character.character_scene if _character and _character.character_scene else null
	var world_instance: Node3D = null
	if scene != null:
		world_instance = scene.instantiate() as Node3D

	# --- Third-person world model (visible to other players) ---
	if world_instance == null:
		model = mannequin
		# Hide/show the built-in model's meshes rather than the whole node, so the
		# weapon (parented under Body) stays visible.
		_set_mannequin_meshes_visible(true)
	else:
		# Debug: keep the mannequin visible alongside the spawned character model
		# so their alignment can be compared directly.
		_set_mannequin_meshes_visible(debug_show_both_models)

		world_instance.transform = mannequin.transform
		world_instance.name = "Model"
		$Body.add_child(world_instance)
		model = world_instance
		_setup_pose_copy(world_instance)

	model_script = model as PlayerModel

	# Collect the meshes the wallhack outline can be applied to.  Character
	# model only — the mannequin placeholder is never revealed through walls.
	_outline_meshes.clear()
	if world_instance != null:
		for m in world_instance.find_children("*", "MeshInstance3D", true, false):
			_outline_meshes.append(m as MeshInstance3D)

	# Rebuild the team-colour skin list and re-apply the current team.
	_rebuild_skins()
	team = team

	# Our own model: strip the rim light and hide the head so it doesn't clip the
	# first-person camera (shown again if the local player is in third person).
	if own and model_script != null:
		model_script.disable_rim_layer()
		_set_own_head_visible(third_person)


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


## Re-tint every skin mesh to the current team colour while keeping its own
## texture.  FFA (no team) resolves to white — the identity tint — so the model
## renders with its authored materials instead of a flat colour.
#func _apply_team_color() -> void:
	#var color: Color = TEAM_COLORS.get(team, Color.WHITE)
	#for i in skins.size():
		#var skin: MeshInstance3D = skins[i]
		#if skin == null:
			#continue
		#var original: Material = _skin_original_materials[i] if i < _skin_original_materials.size() else null
		#if original == null:
			#continue
		## Identity tint (FFA) or an untintable shader — show the authored material.
		#if color.is_equal_approx(Color.WHITE) or not (original is BaseMaterial3D):
			#skin.set_surface_override_material(0, null)
			#continue
		#var tinted: Material = original.duplicate() as Material
		#(tinted as BaseMaterial3D).albedo_color = color
		#skin.set_surface_override_material(0, tinted)

func _apply_team_color() -> void:
	var color: Color = TEAM_COLORS.get(team, Color.WHITE)

	for i in skins.size():
		var skin: MeshInstance3D = skins[i]
		if skin == null:
			continue

		var original: Material = _skin_original_materials[i] if i < _skin_original_materials.size() else null
		if original == null:
			continue

		# FFA or materials that cannot be tinted: use the authored material.
		if color.is_equal_approx(Color.WHITE) or not (original is BaseMaterial3D):
			skin.set_surface_override_material(0, null)
			continue

		var tinted: BaseMaterial3D = original.duplicate() as BaseMaterial3D

		# Stronger tint: blend the team colour into the material's existing
		# albedo instead of merely multiplying it.
		var original_color := tinted.albedo_color
		tinted.albedo_color = original_color.lerp(color, 0.75)

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


# ── Wallhack reveal / health visibility (client-side rendering) ────────────


## Turn the through-wall outline on or off for this player's model.
## Purely visual and local — each client calls this on its own copies of other
## players.  [param color] tints the outline (ally vs enemy).
func set_wallhack_outline(enabled: bool, color: Color = ALLY_OUTLINE_COLOR) -> void:
	if _wallhack_outline_enabled == enabled and _wallhack_outline_color.is_equal_approx(color):
		return
	_wallhack_outline_enabled = enabled
	_wallhack_outline_color = color
	if _outline_material:
		_outline_material.set_shader_parameter("outline_color", color)
	for m in _outline_meshes:
		if is_instance_valid(m):
			m.material_override = _outline_material if enabled else null


## Show or hide this player's 2D health bar for the local viewer.
func set_public_health_visible(show: bool) -> void:
	if _health_bar == null:
		return
	if show:
		_health_bar.text = str(int(attribute_component.health)) if attribute_component else ""
	_health_bar.visible = show


## Project the 2D health bar above the head each frame.  Moves it off-screen
## when the target is behind the camera.
func _update_health_bar() -> void:
	if _health_bar == null or not _health_bar.visible:
		return
	# Hide projected health bars while a menu is open — they render on a
	# CanvasLayer above the menu's dim overlay.
	if PlayerInput.ui_open:
		_health_bar.position = Vector2(-10000.0, -10000.0)
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var world_pos := global_position + Vector3(0.0, 2.2, 0.0)
	if cam.is_position_behind(world_pos):
		_health_bar.position = Vector2(-10000.0, -10000.0)
		return
	_health_bar.position = cam.unproject_position(world_pos) - _health_bar.size * 0.5


## True when [param other] is on the same (non-FFA) team as this player.
func is_teammate_of(other: Player) -> bool:
	return team != Team.FFA and other.team == team


## True when there is world geometry between this player's camera and
## [param other].  Rays against the world layer (1) only, so player bodies are
## ignored.
func _is_occluded_by_wall(other: Player) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var from: Vector3 = camera.global_position
	var to: Vector3 = other.global_position + Vector3(0.0, 1.2, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.exclude = [get_rid(), other.get_rid()]
	return not space.intersect_ray(query).is_empty()


## True when there is a clear line of sight from this player's camera to
## [param other] (no world geometry between them).
func has_line_of_sight_to(other: Player) -> bool:
	return not _is_occluded_by_wall(other)


## Apply the ghost visual tier to this player's local model + weapon (client-side).
## NONE = normal; GLASS = translucent glass; BLACK = translucent black; HIDDEN =
## fully invisible (model, weapon and name label hidden).
func set_ghost_tier(tier: int) -> void:
	if _ghost_tier == tier:
		return
	_ghost_tier = tier

	var show := tier != GhostTier.HIDDEN
	var override: Material = null
	if tier == GhostTier.GLASS:
		override = INVISIBLE_GLASS
	elif tier == GhostTier.BLACK:
		override = NOCLIP_BLACK

	if model != null:
		model.visible = show
	for m in _outline_meshes:
		if is_instance_valid(m):
			m.visible = show
			m.material_override = override

	# The world weapon model (parented to the mannequin's hand bone).
	var weapon: Node3D = weapon_controller.current_weapon_model if weapon_controller else null
	if weapon != null:
		for m in weapon.find_children("*", "MeshInstance3D", true, false):
			var mesh := m as MeshInstance3D
			if mesh != null:
				mesh.visible = show
				mesh.material_override = override

## Per-viewer update: decide, for every other player, whether the local client
## should reveal their outline (through walls) and/or their health bar, and
## record whether each player is currently "seen".  Runs only on the local
## player's node, so exactly once per client.
func _update_visibility(delta: float) -> void:
	if not _is_own_model():
		return
	var sem := status_effect_manager
	if sem == null:
		return
	var i_wallhack := sem.has_effect("wallhacking")
	var i_see_health := _character != null and _character.passive_see_enemy_health

	# The local player's own ghost tier (this node is the local peer's model).
	var self_tier := GhostTier.NONE
	if sem.has_effect("noclip"):
		self_tier = GhostTier.BLACK
	elif sem.has_effect("invisible"):
		self_tier = GhostTier.GLASS
	set_ghost_tier(self_tier)

	# Occlusion raycasts (and the players-group query) are the only per-frame
	# cost here, and they cascade O(N²) across clients.  Throttle both to a fixed
	# interval and reuse the cached results in between (see #2 in
	# docs/05-known-issues.md).
	_occlusion_timer += delta
	if _occlusion_timer >= OCCLUSION_REFRESH_INTERVAL:
		_occlusion_timer = 0.0
		_visibility_players.clear()
		_occlusion_cache.clear()
		for node in get_tree().get_nodes_in_group("players"):
			if node == self:
				continue
			var p := node as Player
			if p == null:
				continue
			_visibility_players.append(p)
			_occlusion_cache[p.name] = _is_occluded_by_wall(p)

	for other in _visibility_players:
		if not is_instance_valid(other):
			continue

		var show_outline := false
		var show_health := false
		var outline_color := ALLY_OUTLINE_COLOR
		var tier := GhostTier.NONE

		if other.spawned and other.status_effect_manager:
			var osem := other.status_effect_manager
			var ally := is_teammate_of(other)
			var enemy := _is_enemy_of(other)

			# Ghost effect tier for this target (noclip wins over invisibility).
			if osem.has_effect("noclip"):
				tier = GhostTier.BLACK
			elif osem.has_effect("invisible"):
				tier = GhostTier.HIDDEN if enemy else GhostTier.GLASS

			# Whether a through-wall outline applies to this player.
			var outline_allowed := false
			if ally and osem.has_effect("wallhacked_team"):
				outline_allowed = true
			elif enemy and osem.has_effect("wallhacked_enemy"):
				outline_allowed = true
				outline_color = ENEMY_OUTLINE_COLOR
			elif enemy and i_wallhack:
				outline_allowed = true
				outline_color = ENEMY_OUTLINE_COLOR

			var occluded: bool = _occlusion_cache.get(other.name, false)

			# Outline shows only while occluded.  Teammate outlines fade out
			# after being behind a wall for a while to reduce distraction.
			if outline_allowed and occluded:
				if ally:
					var t: float = _teammate_occluded_time.get(other.name, 0.0) + delta
					_teammate_occluded_time[other.name] = t
					outline_color.a = _teammate_outline_alpha(t)
					show_outline = outline_color.a > 0.0
				else:
					show_outline = true
			else:
				_teammate_occluded_time[other.name] = 0.0

			# "Seen" = directly visible OR revealed through a (non-faded) wallhack.
			var seen := (not occluded) or show_outline
			other._seen_by_local = seen

			# Health: reveal when the viewer is allowed to see this player's
			# health, and they're currently "seen".
			var can_see_health := (ally and osem.has_effect("health_visible_team")) \
				or (enemy and osem.has_effect("health_visible_enemy")) \
				or (enemy and i_see_health)
			if can_see_health and seen:
				show_health = true

		# Ghost effects override reveal: an invisible enemy is fully hidden, and
		# glass/black override the material so the wallhack outline is suppressed.
		if tier == GhostTier.HIDDEN:
			show_outline = false
			show_health = false
		elif tier != GhostTier.NONE:
			show_outline = false

		if tier == GhostTier.NONE:
			other.set_ghost_tier(GhostTier.NONE)
			other.set_wallhack_outline(show_outline, outline_color)
		else:
			other.set_wallhack_outline(false, outline_color)
			other.set_ghost_tier(tier)
		other.set_public_health_visible(show_health)


## Outline alpha for a teammate that has been occluded for [param t] seconds:
## full opacity for the first TEAM_WALLHACK_FADE_DELAY seconds, then a smooth
## fade to transparent over TEAM_WALLHACK_FADE_TIME seconds.
func _teammate_outline_alpha(t: float) -> float:
	if t <= TEAM_WALLHACK_FADE_DELAY:
		return 1.0
	return clampf(1.0 - (t - TEAM_WALLHACK_FADE_DELAY) / TEAM_WALLHACK_FADE_TIME, 0.0, 1.0)


# ── Always-on passive status effects ───────────────────────────────────────


## Apply the always-on passive status effects (server-authoritative).  Called
## on every (re)spawn so the markers survive clear_all_effects().
func _apply_passive_effects() -> void:
	if not multiplayer.is_server():
		return
	if status_effect_manager == null:
		return
	_apply_flag_effect("wallhacked_team", "Wallhacked (Team)", true)
	_apply_flag_effect("health_visible_team", "Health Visible (Team)", true)


## Create and apply a (typically permanent) marker status effect.
func _apply_flag_effect(effect_id: String, display_name: String, permanent: bool, duration := 0.0) -> void:
	var effect := StatusEffect.new()
	effect.effect_id = effect_id
	effect.display_name = display_name
	effect.is_negative = false
	effect.is_permanent = permanent
	effect.base_duration = duration
	effect.tick_interval = 0.0
	status_effect_manager.apply_effect(effect, name)
