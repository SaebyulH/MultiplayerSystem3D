class_name PlayerSkin
extends Node3D

## PlayerSkin animation driver — reads the parent Player's velocity, weapon state, and
## input to drive the AnimationTree state machine and blend-space parameters.
##
## The AnimationTree should be configured with this structure:
##
##   AnimationNodeStateMachine "Root"
##   ├─ Idle      (AnimationNodeAnimation → idle clip)
##   ├─ Walk      (AnimationNodeBlendSpace2D → 8-directional walk clips)
##   ├─ Sprint    (AnimationNodeBlendSpace2D → 8-directional sprint/run clips)
##   ├─ Crouch    (AnimationNodeBlendSpace2D → crouch idle + crouch walk clips)
##   ├─ Air       (AnimationNodeAnimation → jump / fall clip)
##   ├─ Reload    (AnimationNodeAnimation → reload clip)
##   └─ Death     (AnimationNodeAnimation → death clip)
##
## BlendSpace2D axes: X = lateral (left/right), Y = forward/backward.
## Each BlendSpace2D should have 8+1 points: center=idle, plus 8 directional
## points at ~0.7 radius for walk, repeated at ~1.0 for sprint.
##
## State transitions are driven by speed, crouch flag, floor contact, reload
## timer, and alive state — all read from the Player / WeaponController nodes.

# ---------------------------------------------------------------------------
# Exported references — set in the scene or auto-resolved in _ready()
# ---------------------------------------------------------------------------

@export var animation_tree: AnimationTree
@export var player: Player
@export var weapon_controller: WeaponController
@export var player_input: PlayerInput
@export var body: Node3D

## When true the script will build a default state machine at runtime if the
## AnimationTree has no tree_root set in the editor.
@export var auto_setup_tree: bool = true

## Names of animations in the character's AnimationPlayer (imported FBX clips).
## Tweak these to match the names in your imported model.
@export_group("Animation Names", "anim_")
@export var anim_idle: StringName        = &"idle"
@export var anim_walk_forward: StringName = &"walk_forward"
@export var anim_walk_backward: StringName = &"walk_backward"
@export var anim_walk_left: StringName    = &"walk_left"
@export var anim_walk_right: StringName   = &"walk_right"
@export var anim_sprint_forward: StringName = &"run_forward"
@export var anim_sprint_backward: StringName = &"run_backward"
@export var anim_sprint_left: StringName  = &"run_left"
@export var anim_sprint_right: StringName = &"run_right"
@export var anim_crouch_idle: StringName  = &"crouch_idle"
@export var anim_crouch_walk_forward: StringName = &"crouch_walk_forward"
@export var anim_crouch_walk_backward: StringName = &"crouch_walk_backward"
@export var anim_crouch_walk_left: StringName  = &"crouch_walk_left"
@export var anim_crouch_walk_right: StringName = &"crouch_walk_right"
@export var anim_jump: StringName         = &"jump"
@export var anim_fall: StringName         = &"fall"
@export var anim_reload: StringName       = &"reload"
@export var anim_reload_pistol: StringName = &"reload_pistol"
@export var anim_death: StringName        = &"death"

## Speed thresholds for state transitions (world units / s).
@export_group("Thresholds")
@export var walk_threshold: float    = 0.3   ## Below this → Idle
@export var sprint_threshold: float  = 4.5   ## Above this & !ADS → Sprint
@export var crouch_blend_max: float  = 3.0   ## Speed where crouch blend reaches full lateral

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _state_playback: AnimationNodeStateMachinePlayback = null
var _current_state: StringName = &"Idle"
var _was_alive: bool   = true
var _reload_animated: bool = false
var _last_local_vel: Vector2 = Vector2.ZERO

# Transient shoot overlay — one-shot blended additively on the upper body when
# fire_held is active.  Set the WeaponFire index to play (0=primary, etc.).
var _active_fire_index: int = -1

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# ── Auto-resolve references ──────────────────────────────────────────
	if not animation_tree:
		animation_tree = _find_sibling(get_parent(), "AnimationTree") as AnimationTree
	if not player:
		player = _find_ancestor(self, "Player") as Player
	if not weapon_controller:
		weapon_controller = player.weapon_controller if player else null
	if not player_input:
		player_input = player.player_input if player else null
	if not body:
		body = player.body if player else null

	if not animation_tree:
		push_warning("Skin: no AnimationTree found — animation driver disabled.")
		set_process(false)
		return

	animation_tree.active = true

	if auto_setup_tree and not animation_tree.tree_root:
		_build_default_state_machine()

	# Cache the state-machine playback object.
	var playback_ref = animation_tree.get("parameters/StateMachine/playback")
	if playback_ref != null:
		_state_playback = playback_ref as AnimationNodeStateMachinePlayback

	# Connect weapon-change so we know the current weapon family.
	if weapon_controller:
		weapon_controller.weapon_changed.connect(_on_weapon_changed)


func _process(_delta: float) -> void:
	if not animation_tree or not player:
		return
	_update_animation_state()


# ---------------------------------------------------------------------------
# Core state update
# ---------------------------------------------------------------------------

func _update_animation_state() -> void:
	# ── Gather player state ──────────────────────────────────────────────
	var vel: Vector3 = player.velocity
	var h_speed: float = Vector2(vel.x, vel.z).length()
	var on_floor: bool = player.is_on_floor()
	var crouching: bool = player.is_crouching
	var ads: bool = player.ads
	var alive: bool = player.spawned
	var reloading: bool = false

	if weapon_controller:
		reloading = weapon_controller._is_reloading

	# ── Local-space velocity for blend positions ────────────────────────
	var local_vel: Vector2 = _world_to_local_velocity(vel)

	# Smooth the blend input so small jitter doesn't flicker animations.
	var blend_smooth: float = 15.0
	_last_local_vel = _last_local_vel.lerp(local_vel, blend_smooth * get_process_delta_time())

	var max_speed: float = player.speed  # 5.0 stand, 2.5 ADS
	var blend_input: Vector2 = Vector2(
		clampf(_last_local_vel.x / max_speed, -1.0, 1.0),
		clampf(_last_local_vel.y / max_speed, -1.0, 1.0)
	)

	# ── Determine target state ───────────────────────────────────────────
	var target_state: StringName = &"Idle"

	if not alive:
		target_state = &"Death"
	elif reloading and not _reload_animated:
		target_state = &"Reload"
		_reload_animated = true
	elif not on_floor:
		target_state = &"Air"
	elif crouching:
		target_state = &"Crouch"
	elif h_speed > sprint_threshold and not ads:
		target_state = &"Sprint"
	elif h_speed > walk_threshold:
		target_state = &"Walk"
	else:
		target_state = &"Idle"

	# Reset reload tracking when it ends.
	if not reloading:
		_reload_animated = false

	# Track death → alive transition for one-shot reset.
	if alive and not _was_alive:
		target_state = &"Idle"
	_was_alive = alive

	# ── Set blend-space positions ────────────────────────────────────────
	# Only set the blend for the active state to avoid wasted writes,
	# but walking/crouch threshold cross-fades work better if we set all.
	var crouch_blend: Vector2 = blend_input * (crouch_blend_max / max(max_speed, 0.01))
	_safe_set_param(&"Walk/blend_position", blend_input)
	_safe_set_param(&"Sprint/blend_position", blend_input)
	_safe_set_param(&"Crouch/blend_position", crouch_blend)

	# ── Transition the state machine ─────────────────────────────────────
	if target_state != _current_state and _state_playback:
		_state_playback.travel(target_state)
		_current_state = target_state

	# ── Upper-body shoot blend (additive / one-shot) ────────────────────
	_update_shoot_overlay()

	# ── Weapon-type skeleton mask / IK pose ──────────────────────────────
	_update_weapon_pose()


# ---------------------------------------------------------------------------
# Shoot overlay — plays a one-shot "fire" on the upper body via a BlendTree
# or triggers the weapon's AnimationPlayer.
# ---------------------------------------------------------------------------

func _update_shoot_overlay() -> void:
	if not player_input:
		return
	# The weapon AnimationPlayer at WeaponHandle already handles the gun model
	# recoil / slide.  If you have a full-body fire animation on the character
	# skeleton, you can drive it here.
	var shooting_now: bool = player_input.primary_fire_held \
		or player_input.secondary_fire_held \
		or player_input.tertiary_fire_held

	if shooting_now and _active_fire_index < 0:
		_active_fire_index = 0
		_safe_set_param(&"Shoot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	elif not shooting_now:
		_active_fire_index = -1


# ---------------------------------------------------------------------------
# Weapon pose — blends between rifle / pistol / empty-hand IK targets.
# ---------------------------------------------------------------------------

func _update_weapon_pose() -> void:
	if not weapon_controller:
		return
	var weapons := weapon_controller.get_weapons()
	if weapons.is_empty():
		return
	var idx: int = weapon_controller.current_weapon_index
	if idx < 0 or idx >= weapons.size():
		return
	# Stub: future expansion for per-weapon-family upper-body poses.
	# e.g. _safe_set_param(&"WeaponPose/weapon_type", weapon.animation_pose)


func _on_weapon_changed(_index: int, _weapon: Weapon) -> void:
	_active_fire_index = -1


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Convert world-space horizontal velocity into local space relative to the
## player body's facing direction.  X = lateral, Y = forward.
func _world_to_local_velocity(velocity: Vector3) -> Vector2:
	if not body:
		return Vector2.ZERO
	var basis: Basis = body.global_transform.basis
	var local: Vector3 = basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
	return Vector2(local.x, -local.z)   # -Z is forward in Godot


func _safe_set_param(param: StringName, value) -> void:
	if animation_tree == null:
		return
	# Only set if the path exists on the tree — avoids spurious console errors
	# when a branch hasn't been created in the editor.
	var full := StringName("parameters/" + param)
	var existing = animation_tree.get(full)
	if existing == null and animation_tree.get("parameters/" + param.get_slice("/", 0)) == null:
		return
	animation_tree.set(full, value)


## Walk up the tree to find a node of the given class.
func _find_ancestor(from: Node, cls: StringName) -> Node:
	var cur: Node = from
	while cur:
		if cur.is_class(cls):
			return cur
		cur = cur.get_parent()
	return null


## Search direct siblings (and the parent) for a node matching `name`.
func _find_sibling(from: Node, node_name: String) -> Node:
	if not from:
		return null
	var p := from.get_parent()
	if not p:
		p = from
	# Check children of parent (siblings of `from`).
	for child in p.get_children():
		if child.name == node_name:
			return child
	# Also check `from`'s own children.
	for child in from.get_children():
		if child.name == node_name:
			return child
	return null


# ---------------------------------------------------------------------------
# Programmatic AnimationTree builder
# ---------------------------------------------------------------------------
# Called once in _ready() when auto_setup_tree is true and the AnimationTree
# has no tree_root configured in the editor.  This creates a reasonable default
# state machine so the Skin works out-of-the-box.
#
# You are encouraged to replace this with an editor-authored tree once the
# animation clip names are finalised — the editor gives you a visual preview
# that this code cannot.

func _build_default_state_machine() -> void:
	if not animation_tree:
		return

	# Determine the AnimationPlayer on the character model.
	var anim_player: AnimationPlayer = _find_sibling(self, "AnimationPlayer") as AnimationPlayer
	if not anim_player:
		# The imported FBX may have placed the AnimationPlayer under "Rig" or at root.
		var rig := get_node_or_null("../Rig")
		if rig:
			anim_player = _find_sibling(rig, "AnimationPlayer") as AnimationPlayer
	if not anim_player:
		push_warning("Skin: cannot find AnimationPlayer for the character skeleton.  " \
			+ "Set anim_player on the AnimationTree manually in the editor.")
		return

	animation_tree.anim_player = anim_player.get_path()

	# ── Root state machine ───────────────────────────────────────────
	var sm := AnimationNodeStateMachine.new()
	sm.name = "StateMachine"

	# ── Idle ──────────────────────────────────────────────────────────
	var idle_node := AnimationNodeAnimation.new()
	idle_node.animation = anim_idle
	sm.add_node("Idle", idle_node)

	# ── Walk BlendSpace2D ─────────────────────────────────────────────
	var walk_bs := AnimationNodeBlendSpace2D.new()
	walk_bs.blend_mode = AnimationNodeBlendSpace2D.BLEND_MODE_DISCRETE
	walk_bs.min_space = Vector2(-1, -1)
	walk_bs.max_space = Vector2(1, 1)
	walk_bs.snap = Vector2(0.01, 0.01)
	_add_blend_point(walk_bs, anim_idle,                Vector2(0, 0))
	_add_blend_point(walk_bs, anim_walk_forward,        Vector2(0, 1))
	_add_blend_point(walk_bs, anim_walk_backward,       Vector2(0, -0.7))
	_add_blend_point(walk_bs, anim_walk_left,           Vector2(-0.7, 0))
	_add_blend_point(walk_bs, anim_walk_right,          Vector2(0.7, 0))
	_add_blend_point(walk_bs, anim_walk_forward,        Vector2(0.3, 1))   # NE
	_add_blend_point(walk_bs, anim_walk_forward,        Vector2(-0.3, 1))  # NW
	_add_blend_point(walk_bs, anim_walk_backward,       Vector2(0.3, -0.7))# SE
	_add_blend_point(walk_bs, anim_walk_backward,       Vector2(-0.3, -0.7))# SW
	sm.add_node("Walk", walk_bs)

	# ── Sprint BlendSpace2D ───────────────────────────────────────────
	var sprint_bs := AnimationNodeBlendSpace2D.new()
	sprint_bs.blend_mode = AnimationNodeBlendSpace2D.BLEND_MODE_DISCRETE
	sprint_bs.min_space = Vector2(-1, -1)
	sprint_bs.max_space = Vector2(1, 1)
	sprint_bs.snap = Vector2(0.01, 0.01)
	_add_blend_point(sprint_bs, anim_idle,               Vector2(0, 0))
	_add_blend_point(sprint_bs, anim_sprint_forward,     Vector2(0, 1))
	_add_blend_point(sprint_bs, anim_sprint_backward,    Vector2(0, -0.7))
	_add_blend_point(sprint_bs, anim_sprint_left,        Vector2(-0.7, 0))
	_add_blend_point(sprint_bs, anim_sprint_right,       Vector2(0.7, 0))
	_add_blend_point(sprint_bs, anim_sprint_forward,     Vector2(0.3, 1))
	_add_blend_point(sprint_bs, anim_sprint_forward,     Vector2(-0.3, 1))
	_add_blend_point(sprint_bs, anim_sprint_backward,    Vector2(0.3, -0.7))
	_add_blend_point(sprint_bs, anim_sprint_backward,    Vector2(-0.3, -0.7))
	sm.add_node("Sprint", sprint_bs)

	# ── Crouch BlendSpace2D ───────────────────────────────────────────
	var crouch_bs := AnimationNodeBlendSpace2D.new()
	crouch_bs.blend_mode = AnimationNodeBlendSpace2D.BLEND_MODE_DISCRETE
	crouch_bs.min_space = Vector2(-1, -1)
	crouch_bs.max_space = Vector2(1, 1)
	crouch_bs.snap = Vector2(0.01, 0.01)
	_add_blend_point(crouch_bs, anim_crouch_idle,             Vector2(0, 0))
	_add_blend_point(crouch_bs, anim_crouch_walk_forward,     Vector2(0, 1))
	_add_blend_point(crouch_bs, anim_crouch_walk_backward,    Vector2(0, -0.7))
	_add_blend_point(crouch_bs, anim_crouch_walk_left,        Vector2(-0.7, 0))
	_add_blend_point(crouch_bs, anim_crouch_walk_right,       Vector2(0.7, 0))
	sm.add_node("Crouch", crouch_bs)

	# ── Air ───────────────────────────────────────────────────────────
	var air_node := AnimationNodeAnimation.new()
	air_node.animation = anim_jump
	sm.add_node("Air", air_node)

	# ── Reload ────────────────────────────────────────────────────────
	var reload_node := AnimationNodeAnimation.new()
	reload_node.animation = anim_reload
	sm.add_node("Reload", reload_node)

	# ── Death ─────────────────────────────────────────────────────────
	var death_node := AnimationNodeAnimation.new()
	death_node.animation = anim_death
	sm.add_node("Death", death_node)

	# ── State-machine transitions ────────────────────────────────────
	# Idle ↔ Walk
	_add_transition(sm, "Idle",   "Walk",    &"to_walk")
	_add_transition(sm, "Walk",   "Idle",    &"to_idle")
	# Walk ↔ Sprint
	_add_transition(sm, "Walk",   "Sprint",  &"to_sprint")
	_add_transition(sm, "Sprint", "Walk",    &"to_walk_from_sprint")
	# Idle/Walk/Sprint → Crouch
	_add_transition(sm, "Idle",   "Crouch",  &"to_crouch")
	_add_transition(sm, "Walk",   "Crouch",  &"to_crouch")
	_add_transition(sm, "Sprint", "Crouch",  &"to_crouch")
	# Crouch → Idle
	_add_transition(sm, "Crouch", "Idle",    &"to_stand")
	# Any → Air
	_add_transition(sm, "Idle",   "Air",     &"to_air")
	_add_transition(sm, "Walk",   "Air",     &"to_air")
	_add_transition(sm, "Sprint", "Air",     &"to_air")
	_add_transition(sm, "Crouch", "Air",     &"to_air")
	# Air → Idle
	_add_transition(sm, "Air",    "Idle",    &"to_land")
	# Any → Reload
	_add_transition(sm, "Idle",   "Reload",  &"to_reload")
	_add_transition(sm, "Walk",   "Reload",  &"to_reload")
	_add_transition(sm, "Sprint", "Reload",  &"to_reload")
	_add_transition(sm, "Crouch", "Reload",  &"to_reload")
	# Reload → Idle
	_add_transition(sm, "Reload", "Idle",    &"to_idle_from_reload")
	# Any → Death
	_add_transition(sm, "Idle",   "Death",   &"to_death")
	_add_transition(sm, "Walk",   "Death",   &"to_death")
	_add_transition(sm, "Sprint", "Death",   &"to_death")
	_add_transition(sm, "Crouch", "Death",   &"to_death")
	_add_transition(sm, "Air",    "Death",   &"to_death")
	_add_transition(sm, "Reload", "Death",   &"to_death")

	# ── Add optional Shoot one-shot as an overlay state ───────────────
	var shoot_os := AnimationNodeOneShot.new()
	shoot_os.fadein_time  = 0.02
	shoot_os.fadeout_time = 0.15
	shoot_os.autorestart  = true
	shoot_os.autorestart_delay = 0.0
	shoot_os.autorestart_random_delay = 0.0
	sm.add_node("Shoot", shoot_os)

	# Assign the root and make the state machine start at Idle.
	animation_tree.tree_root = sm
	sm.set_start_node("Idle")

	# Re-cache the playback reference now that the tree exists.
	var playback_ref = animation_tree.get("parameters/StateMachine/playback")
	if playback_ref != null:
		_state_playback = playback_ref as AnimationNodeStateMachinePlayback

	print("Skin: built default AnimationTree state machine with ", sm.get_node_count(), " nodes.")


func _add_blend_point(bs: AnimationNodeBlendSpace2D, anim_name: StringName, pos: Vector2) -> void:
	var node := AnimationNodeAnimation.new()
	node.animation = anim_name
	bs.add_blend_point(node, pos)


func _add_transition(sm: AnimationNodeStateMachine, from: String, to: String, advance_condition: StringName) -> void:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
	t.advance_condition_name = advance_condition
	sm.add_transition(from, to, t)
