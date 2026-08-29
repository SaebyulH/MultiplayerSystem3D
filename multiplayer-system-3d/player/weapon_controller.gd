class_name WeaponController extends Node

## Random pitch variation applied to every weapon sound.
## 0.0 = all sounds play at their original pitch.
## 0.05 = pitch varies Ã‚Â±5 % (0.95 Ã¢â‚¬â€œ 1.05).  Higher values sound more chaotic.
const PITCH_RANGE: float = 0.05
const RIM_LAYER := 1 << 9  # render layer 10, the shared rim-light layer
## Name of the AnimationTree blend node that holds the weapon's hold (arm) animation.
const HOLD_ANIM_NODE := &"Hold"
## Name of the AnimationTree one-shot node that plays the reload over the hold.
const RELOAD_ONESHOT_NODE := &"Reload"
## Name of the AnimationNodeAnimation feeding the Reload one-shot (its input 1).
const RELOAD_ANIM_NODE := &"Animation 2"
## Name of the AnimationNodeTimeScale that wraps the reload clip (Reload one-shot input 1).
const RELOAD_TIMESCALE_NODE := &"ReloadTimeScale"
## Name of the AnimationTree one-shot node that plays the pull-out over the hold.
const PULLOUT_ONESHOT_NODE := &"Pullout"
## Name of the AnimationNodeAnimation feeding the Pull-out one-shot (its input 1).
const PULLOUT_ANIM_NODE := &"Animation 4"
## Name of the AnimationNodeTimeScale that wraps the pull-out clip (Pull-out one-shot input 1).
const PULLOUT_TIMESCALE_NODE := &"PulloutTimeScale"
## Fallback arm animation when the weapon has no hold animation (or isn't a WeaponModel).
const ARMS_ANIM_RESET := &"other_movement/a_pose"

var _bullet_hole_scene: PackedScene = preload("res://effects/bullet_hole.tscn")
var _tracer_scene: PackedScene = preload("res://weapon/tracer.tscn")
var _hit_sound: AudioStream = preload("res://assets/sounds/Hitsound.wav")
var _hit_heal_sound: AudioStream = preload("res://assets/sounds/medkit_sound.mp3")
var _crit_sound: AudioStream = preload("res://assets/sounds/Crit_received1.wav")
var _backshot_sound: AudioStream = preload("res://assets/sounds/backshot.mp3")



# ---------------------------------------------------------------------------
# Architecture notes
# ---------------------------------------------------------------------------
# Fire authority model:
#   Ã¢â‚¬Â¢ PlayerInput.fire_held / fire_just_released are NOT in the rollback
#     synchronizer. Netfox would stomp them on re-simulation ticks.
#     WeaponController reads them raw in _physics_process every frame.
#   Ã¢â‚¬Â¢ The OWNING CLIENT runs _process_fire() every physics frame.
#     It maintains its own cooldown/pending state for responsiveness.
#     When the gate passes it sends fire_intent.rpc_id(1).
#   Ã¢â‚¬Â¢ The SERVER re-validates everything in fire_intent before acting.
#     Ammo is only deducted once Ã¢â‚¬â€ authoritatively on the server.
#     The client UI optimistically shows -1 mag; the server corrects via
#     mag_changed if it rejects the shot.
#   Ã¢â‚¬Â¢ Host-as-player skips the RPC and calls fire_intent() directly,
#     but uses a separate code path so it never pre-sets _fire_cooldown
#     before the server validation gate runs.
# ---------------------------------------------------------------------------

var _is_reloading: bool     = false
var _reload_timer: float    = 0.0
var _pending_fire: bool     = false

# Background reload: timers keyed by weapon index. The server ticks these
# independently so weapons with reload_in_background keep loading when holstered.
var _bg_reload_timers: Array[float] = []
var _bg_reload_active: Array[bool] = []
var _pending_fire_index: int = 0
var _queued_interrupt: bool = false
var _any_fire_was_held: bool = false

## Throttle timer to prevent mouse-wheel double-scroll (multiple input events
## per notch).  Weapon switches are ignored while this is above zero.
var _weapon_switch_cooldown: float = 0.0
const WEAPON_SWITCH_THROTTLE: float = 0.08

## Weapon-switch transition state machine.  While != IDLE the active weapon is
## locked (can't fire/reload/ADS/shield) and new switches are ignored.
enum SwitchPhase { IDLE, PUT_AWAY, PULLOUT }
var _switch_phase: SwitchPhase = SwitchPhase.IDLE
var _switch_timer: float = 0.0
## pullout_time of the incoming weapon, applied once put-away finishes.
var _switch_pullout_time: float = 0.0

## True while the weapon is in any part of the fire cycle (pre-delay, burst, post-delay).
## Used by get_active_fire_speed_mult().  Managed locally — no RPC needed.
var _is_firing: bool = false
var _firing_remaining: float = 0.0
var _firing_fire_index: int = -1


var _pre_fire_timer: float  = 0.0
var _fire_cooldown: float   = 0.0
var _current_spread: float  = 0.0
var _fired_this_press: Dictionary[int, bool] = {}

signal mag_changed(current: int, mag_max: int)
signal weapon_changed(index: int, weapon: Weapon)
## Emitted when a SIGNAL-type fire mode is activated.  Projectiles can
## connect to this to trigger custom behaviour (e.g. detonate mines).
## [param target] — world position the player is looking at via raycast
##   (or 10 000 units ahead if nothing is hit).
## [param player_transform] — shooter's world position.
signal signal_activated(target: Vector3, player_transform: Vector3)

# Use @export only for editor-assigned defaults. All runtime mutation goes
# through set_weapons() so the setter invariant is always enforced.
@export var _weapons: Array[Weapon]:
	set(value):
		if value == _weapons:
			return
		_weapons = value
		_on_weapon_index_changed()
		_emit_weapon_changed()

@export var current_weapon_index: int = 0:
	set(value):
		if value == current_weapon_index:
			return
		var prev := current_weapon_index
		current_weapon_index = clamp(value, 0, _weapons.size() - 1)
		_on_weapon_index_changed(prev)
		_emit_weapon_changed()

@export var weapon_model_parent: Node3D
@export var projectile_spawn_parent: Node3D
@export var player_input: PlayerInput
@export var recoil: Recoil
@export var _parent_player: Player
@export var _raycast: RayCast3D
@export var shoot_animation: AnimationPlayer

var current_weapon_model: Node3D = null

# Muzzle nodes on the current weapon model, discovered recursively by name.
# Weapons with multiple muzzles (twin barrels, etc.) fire them alternately.
var _muzzle_nodes: Array[Node3D] = []
var _muzzle_index: int = 0

# Weapon indices whose human anims have already been injected into the mannequin's
# AnimationPlayer.  Prevents re-adding a library on every weapon switch.
var _added_human_anims: Dictionary = {}

#region Reload animation – save/restore hand targets
# The reload animation moves WeaponHandle, LeftHandTarget, and RightHandTarget
# to baked values. Since different weapon models place hand targets at different
# positions, we snapshot the live values before the animation plays and restore
# them when the animation finishes (or is cancelled).
var _reload_anim_saved: bool = false
var _saved_weapon_handle_pos: Vector3
var _saved_weapon_handle_rot: Vector3
var _saved_left_hand_pos: Vector3
var _saved_left_hand_rot: Vector3
var _saved_right_hand_pos: Vector3
var _saved_right_hand_rot: Vector3

func _save_transform_for_reload() -> void:
	_saved_weapon_handle_pos = weapon_model_parent.position
	_saved_weapon_handle_rot = weapon_model_parent.rotation
	_saved_left_hand_pos   = %LeftHandTarget.position
	_saved_left_hand_rot   = %LeftHandTarget.rotation
	_saved_right_hand_pos  = %RightHandTarget.position
	_saved_right_hand_rot  = %RightHandTarget.rotation
	_reload_anim_saved = true

func _restore_transform_after_reload() -> void:
	if not _reload_anim_saved:
		return
	weapon_model_parent.position = _saved_weapon_handle_pos
	weapon_model_parent.rotation = _saved_weapon_handle_rot
	%LeftHandTarget.position  = _saved_left_hand_pos
	%LeftHandTarget.rotation  = _saved_left_hand_rot
	%RightHandTarget.position = _saved_right_hand_pos
	%RightHandTarget.rotation = _saved_right_hand_rot
	_reload_anim_saved = false

func _on_reload_anim_finished(anim_name: StringName) -> void:
	if anim_name == &"reload":
		_restore_transform_after_reload()
#endregion

#region Readiness
# Central invariant check. Every RPC and fire path that touches _weapons or
# current_weapon_model calls this first. One place to fix, one place to read.
func _is_ready() -> bool:
	return not _weapons.is_empty() \
		and current_weapon_index < _weapons.size() \
		and current_weapon_model != null \
		and is_instance_valid(current_weapon_model)

## Returns the FOV to use when ADS is active for the current weapon.
## Falls back to 20.0 if the weapon has no ADS fire mode.
func get_ads_zoom_fov() -> float:
	if _weapons.is_empty() or current_weapon_index >= _weapons.size():
		return 20.0
	var weapon: Weapon = _weapons[current_weapon_index]
	for fire in weapon.weapon_fires:
		if fire.action_type == WeaponFire.ActionType.ADS:
			return fire.zoom_fov
	return 20.0
#endregion

#region Lifecycle
func _ready() -> void:
	# Deep-copy every Weapon resource so this WeaponController instance owns
	# its own mutable state. Without this, both the client-side and server-side
	# WeaponController nodes share the same Weapon objects in memory, causing
	# mag_current mutations from one peer to silently affect the other.
	var deep_weapons: Array[Weapon] = []
	for w: Weapon in _weapons:
		deep_weapons.append(w.duplicate(true) as Weapon)
	_weapons = deep_weapons

	if not _weapons.is_empty() and _weapons[current_weapon_index] != null:
		spawn_weapon_model()

	player_input.previous_weapon.connect(previous_weapon)
	player_input.next_weapon.connect(next_weapon)
	player_input.reload.connect(start_reload)
	if shoot_animation:
		shoot_animation.animation_finished.connect(_on_reload_anim_finished)

func _physics_process(delta: float) -> void:
	_tick_timers(delta)

	if _parent_player.is_bot:
		_process_fire()  # server drives bot firing directly
	else:
		var my_id: int = multiplayer.get_unique_id()
		var owner_id: int = _parent_player.name.to_int()
		if my_id == owner_id:
			_process_fire()

func _tick_timers(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta
	if _weapon_switch_cooldown > 0.0:
		_weapon_switch_cooldown -= delta
	if _switch_phase != SwitchPhase.IDLE:
		_switch_timer -= delta
		if _switch_timer <= 0.0:
			_advance_switch_phase()
	if _firing_remaining > 0.0:
		_firing_remaining -= delta
		if _firing_remaining <= 0.0:
			_is_firing = false
			_firing_remaining = 0.0

	# Spread decay when not actively firing.
	if _is_ready():
		var weapon: Weapon = _weapons[current_weapon_index]
		var firing_now: bool = player_input.primary_fire_held or player_input.secondary_fire_held or player_input.tertiary_fire_held
		if not firing_now and _current_spread > weapon.min_spread:
			_current_spread = maxf(_current_spread - weapon.spread_decay * delta, weapon.min_spread)

	# Reload timer ticks on all peers for client-side visual progress.
	# Only the server triggers the actual reload completion.
	if _is_reloading:
		_reload_timer -= delta
		if multiplayer.is_server() and _reload_timer <= 0.0:
			_finish_reload()

	# Background reload: server ticks timers for holstered weapons.
	if multiplayer.is_server():
		for i in _weapons.size():
			if i == current_weapon_index:
				continue
			if not _bg_reload_active[i]:
				continue
			var bg_weapon: Weapon = _weapons[i]
			if not bg_weapon.reload_in_background:
				_bg_reload_active[i] = false
				continue
			if bg_weapon.mag_current >= bg_weapon.mag_size:
				_bg_reload_active[i] = false
				continue
			_bg_reload_timers[i] -= delta
			if _bg_reload_timers[i] <= 0.0:
				_bg_finish_reload(i)

	if _pending_fire:
		if player_input.primary_fire_held or player_input.secondary_fire_held or player_input.tertiary_fire_held:
			_pre_fire_timer -= delta
		else:
			_pending_fire = false

		if _pre_fire_timer <= 0.0:
			_pending_fire = false
			if multiplayer.is_server():
				fire_intent(current_weapon_index, _pending_fire_index)
			else:
				_do_fire_client()

func reset() -> void:
	_is_reloading = false
	_reload_timer = 0.0
	_pending_fire = false
	_fire_cooldown = 0.0
	_current_spread = 0.0
	_queued_interrupt = false
	_any_fire_was_held = false
	_bg_reload_timers.clear()
	_bg_reload_active.clear()
	_ensure_bg_arrays()
	_is_firing = false
	_firing_remaining = 0.0
	_switch_phase = SwitchPhase.IDLE
	_switch_timer = 0.0
	_switch_pullout_time = 0.0
	current_weapon_index = 0
	for weapon in _weapons:
		weapon.reset()

	# Server broadcasts authoritative mag values to all peers after reset.
	if not _weapons.is_empty():
		if multiplayer.is_server():
			var mags: Array[int] = []
			for w in _weapons:
				mags.append(w.mag_current)
			_sync_all_mags.rpc(mags)
		_emit_weapon_changed()

@rpc("authority", "call_local", "reliable")
func _sync_all_mags(mags: Array[int]) -> void:
	if _weapons.is_empty():
		return
	for i in mini(mags.size(), _weapons.size()):
		_weapons[i].mag_current = clamp(mags[i], 0, _weapons[i].mag_size)
	mag_changed.emit(
		_weapons[current_weapon_index].mag_current,
		_weapons[current_weapon_index].mag_size
	)


func _set_mag(value: int) -> void:
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon.mag_current = clamp(value, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)


func _emit_weapon_changed() -> void:
	if _weapons.is_empty():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon_changed.emit(current_weapon_index, weapon)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)
#endregion


#region Loadout
# The only correct way to assign weapons at runtime. Enforces all invariants:
# deep-copies resources, resets timers, spawns the model, emits signals.
# Nothing should ever write to _weapons directly outside of _ready().
func set_weapons(new_weapons: Array[Weapon]) -> void:
	var deep_weapons: Array[Weapon] = []
	for w: Weapon in new_weapons:
		deep_weapons.append(w.duplicate(true) as Weapon)
	_added_human_anims.clear()
	_weapons = deep_weapons

	# Reset all firing state so stale cooldowns/reload flags from the previous
	# loadout cannot bleed into the new one.
	_is_reloading   = false
	_reload_timer   = 0.0
	_pending_fire   = false
	_fire_cooldown  = 0.0
	_current_spread = 0.0
	_bg_reload_timers.clear()
	_bg_reload_active.clear()
	_ensure_bg_arrays()

	_emit_weapon_changed()


func get_weapons() -> Array[Weapon]:
	return _weapons

## Returns the active fire mode's movement-speed multiplier (1.0 = normal).
## Stays active while _fire_cooldown > 0 or during burst-firing.
func get_active_fire_speed_mult() -> float:
	if not _is_ready() or not _is_firing:
		return 1.0
	if _firing_fire_index >= 0 and _firing_fire_index < _weapons[current_weapon_index].weapon_fires.size():
		return _weapons[current_weapon_index].weapon_fires[_firing_fire_index].move_speed_mult_while_shooting
	return 1.0

## True while the weapon is in any part of its fire cycle (pre-delay, burst,
## or post-delay).  Read by the weapon-tilt shake so it can stop the instant
## firing ends.
func is_firing() -> bool:
	return _is_firing


## True while a weapon-switch transition (put-away or pull-out) is in progress.
## While true the active weapon is locked and cannot be fired, reloaded, or
## activated (ADS/shield/signal).
func is_switching() -> bool:
	return _switch_phase != SwitchPhase.IDLE


## Current accumulated spread in degrees (0 = no spread).  Grows while firing
## and decays toward [member Weapon.min_spread] when not firing.  Read by the
## weapon-tilt sway so it can wobble harder as spread builds up.
func get_current_spread() -> float:
	return _current_spread


## Total duration of a fire cycle including pre-delay, burst, and post-delay.
func _fire_cycle_duration(weapon: Weapon, fire_index: int) -> float:
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	var rate_mult: float = _parent_player._character.shoot_delay_mult if _parent_player._character else 1.0
	var d := fire.pre_shoot_delay + fire.post_shoot_delay * rate_mult
	if fire.multishot_mode == WeaponFire.MultishotMode.BURST:
		d += (fire.multishot_data.size() - 1) * fire.burst_post_shoot_delay
	return d

## Mark the fire cycle as started so speed multipliers stay active.
func _start_firing(weapon: Weapon, fire_index: int) -> void:
	_is_firing = true
	_firing_fire_index = fire_index
	_firing_remaining = _fire_cycle_duration(weapon, fire_index)

## Total ammo this fire-mode would consume.  For burst weapons with
## burst_ammo_per_shot > 0, it's per-bullet × bullet-count.
func _get_fire_ammo_cost(weapon: Weapon, fire_index: int) -> int:
	if weapon.has_infinite_ammo:
		return 0
	var fire: WeaponFire = weapon.weapon_fires[fire_index]
	if fire.multishot_mode == WeaponFire.MultishotMode.BURST and fire.burst_ammo_per_shot > 0:
		return fire.burst_ammo_per_shot * fire.multishot_data.size()
	return fire.ammo_cost

## Returns reload info for UI: {active: bool, progress: float (0-1)}.
## -1 progress means "not reloading".
func get_reload_info(weapon_index: int) -> Dictionary:
	if weapon_index < 0 or weapon_index >= _weapons.size():
		return {"active": false, "progress": -1.0}
	var w: Weapon = _weapons[weapon_index]
	if w.has_infinite_ammo or w.mag_current >= w.mag_size:
		return {"active": false, "progress": -1.0}
	var reload_mult: float = _parent_player._character.reload_speed_mult if _parent_player._character else 1.0
	var total: float = w.reload_time / max(reload_mult, 0.01)
	# Active weapon check.
	if weapon_index == current_weapon_index:
		if _is_reloading and _reload_timer > 0.0:
			return {"active": true, "progress": 1.0 - (_reload_timer / total)}
		return {"active": false, "progress": -1.0}
	# Background weapon check.
	if _bg_reload_active[weapon_index] and _bg_reload_timers[weapon_index] > 0.0:
		return {"active": true, "progress": 1.0 - (_bg_reload_timers[weapon_index] / total)}
	return {"active": false, "progress": -1.0}

func _auto_switch_to_next_loaded() -> void:
	"""Switch to the first weapon that can shoot. Synced to all peers.
	Priority: primary (0), secondary (1), melee (2)."""
	if not multiplayer.is_server():
		return
	if is_switching():
		return
	for i in _weapons.size():
		if i == current_weapon_index:
			continue
		var w: Weapon = _weapons[i]
		if w.has_infinite_ammo or w.mag_current > 0:
			_switch_slot.rpc(i)
			return

@rpc("authority", "call_local", "reliable")
func _switch_slot(index: int) -> void:
	current_weapon_index = clamp(index, 0, _weapons.size() - 1)

func _ensure_bg_arrays() -> void:
	while _bg_reload_timers.size() < _weapons.size():
		_bg_reload_timers.append(0.0)
		_bg_reload_active.append(false)
#endregion


#region Helpers
func _play_sound(stream: AudioStream, speed: float = 1.0) -> void:
	if stream == null:
		return
	AudioPool.play(
		self,
		stream,
		weapon_model_parent.global_transform,
		speed * (1.0 + randf_range(-PITCH_RANGE, PITCH_RANGE))
	)


func spawn_weapon_model() -> void:
	if current_weapon_model != null:
		current_weapon_model.queue_free()
		current_weapon_model = null
	if _weapons.is_empty():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if weapon.weapon_model == null:
		return
	current_weapon_model          = weapon.weapon_model.instantiate() as Node3D
	current_weapon_model.position = weapon.weapon_offset
	
	
	
	current_weapon_model.rotation = weapon.weapon_rotation
	current_weapon_model.scale    = weapon.weapon_scale
	weapon_model_parent.add_child(current_weapon_model)

	_refresh_muzzles()

	# Rim-light the weapon too (render layer 10), unless it's our own
	# first-person weapon which should never be rim-lit.
	var own_weapon := _parent_player.body.is_multiplayer_authority() and not _parent_player.is_bot
	if not own_weapon:
		for mesh in current_weapon_model.find_children("*", "MeshInstance3D", true, false):
			mesh.layers |= RIM_LAYER
	
	##HAND IK
	#if current_weapon_model.has_node("LeftHandTarget"):
		#%LeftHandTarget.global_position = current_weapon_model.get_node("LeftHandTarget").global_position
	#if current_weapon_model.has_node("RightHandTarget"):
		#%RightHandTarget.global_position = current_weapon_model.get_node("RightHandTarget").global_position


## Discover every node under the weapon model whose name contains "Muzzle".
## Replaces the old single `get_node("Muzzle")` lookup so muzzles work whether
## they are direct children or buried under bones / sub-scenes, and so weapons
## with multiple muzzles are all found.  Called after each model (re)spawn.
func _refresh_muzzles() -> void:
	_muzzle_nodes.clear()
	_muzzle_index = 0
	if current_weapon_model == null:
		return
	for node in current_weapon_model.find_children("*", "Node3D", true, false):
		if node.name.to_lower().contains("muzzle"):
			_muzzle_nodes.append(node as Node3D)
	# Deterministic alternation order (e.g. Muzzle, Muzzle2, Muzzle3).
	_muzzle_nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.name.naturalnocasecmp_to(b.name) < 0)


## Return the next muzzle to fire from, cycling through _muzzle_nodes so
## multi-muzzle weapons alternate barrels on successive shots.  Returns null
## if the model has no muzzle node.
func _next_muzzle() -> Node3D:
	if _muzzle_nodes.is_empty():
		return null
	var muzzle: Node3D = _muzzle_nodes[_muzzle_index % _muzzle_nodes.size()]
	_muzzle_index += 1
	return muzzle

#endregion


#region Weapon model anims
# Weapons that use the WeaponModel script carry their own first-person anims (on
# the model's AnimationPlayer) plus a matching human AnimationLibrary.  We inject
# that human library into the mannequin's AnimationPlayer (once per weapon) and
# point the AnimationTree's arm node at the current weapon's hold animation.
# Legacy weapons (no WeaponModel script) are left untouched for backwards
# compatibility.

## Resolve the mannequin's AnimationPlayer via the player's AnimationTree.
func _get_mannequin_anim_player() -> AnimationPlayer:
	if _parent_player == null or _parent_player.animation_tree == null:
		return null
	return _parent_player.animation_tree.get_node_or_null(_parent_player.animation_tree.anim_player) as AnimationPlayer


## Point the AnimationTree's "Hold" node at [param anim].  Returns false when the
## tree / node isn't ready yet (the caller can retry later).
func _set_hold_anim(anim: StringName) -> bool:
	if _parent_player == null or _parent_player.animation_tree == null:
		return false
	var root := _parent_player.animation_tree.tree_root as AnimationNodeBlendTree
	if root == null:
		return false
	var hold_node := root.get_node(HOLD_ANIM_NODE) as AnimationNodeAnimation
	if hold_node == null:
		return false
	hold_node.animation = anim
	return true


## Inject the current weapon's human anims (once per weapon) and point the arm
## node at the weapon's hold animation.  Falls back to the a_pose reset when the
## current model is not a WeaponModel, or when its hold animation is missing.
func _apply_weapon_model_anims() -> void:
	# Default to the reset pose; replaced by the weapon's hold when available.
	var arms_anim := ARMS_ANIM_RESET

	if current_weapon_model is WeaponModel:
		var model := current_weapon_model as WeaponModel

		# Add the weapon's human library to the mannequin once per weapon.  Skipped
		# while the mannequin isn't ready yet (it gets retried on the next change).
		if not _added_human_anims.get(current_weapon_index, false):
			var anim_player := _get_mannequin_anim_player()
			if anim_player != null:
				if model.human_anims != null:
					var lib_name := model.get_human_library_name()
					# The library may already be present (baked into the mannequin
					# scene, or added on a previous loadout that cleared the cache
					# above) — never add the same library twice.
					if lib_name != &"" and not anim_player.has_animation_library(lib_name):
						anim_player.add_animation_library(lib_name, model.human_anims)
				_added_human_anims[current_weapon_index] = true

		var hold := model.get_human_anim_path(WeaponAnimGroup.AnimSlot.HOLD)
		if hold != &"":
			arms_anim = hold

	_set_hold_anim(arms_anim)


## Play the current weapon model's reload animation (if it has one), stretched to
## the actual reload duration [param duration].  No-ops for legacy weapons.
func _play_weapon_reload_anim(duration: float) -> void:
	if current_weapon_model is WeaponModel:
		(current_weapon_model as WeaponModel).play_anim_scaled(WeaponAnimGroup.AnimSlot.RELOAD, duration)


## Play the current weapon model's pull-out animation (first-person gun anim, if
## it has one), stretched to [param duration].  Mirrors _play_weapon_reload_anim.
func _play_weapon_pullout_anim(duration: float) -> void:
	if current_weapon_model is WeaponModel:
		(current_weapon_model as WeaponModel).play_anim_scaled(WeaponAnimGroup.AnimSlot.PULLOUT, duration)


## Fire the AnimationTree's "Reload" one-shot with the current weapon's human
## reload animation, time-scaled to last [param duration] seconds via the
## "ReloadTimeScale" node.  No-ops for legacy weapons or when the tree isn't ready.
func _play_weapon_human_reload_anim(duration: float) -> void:
	if not (current_weapon_model is WeaponModel):
		return
	var model := current_weapon_model as WeaponModel
	var reload_path := model.get_human_anim_path(WeaponAnimGroup.AnimSlot.RELOAD)
	if reload_path == &"":
		print("[reload-debug] no human reload anim for weapon index ", current_weapon_index)
		return
	if _parent_player == null or _parent_player.animation_tree == null:
		print("[reload-debug] no animation_tree; can't fire reload one-shot")
		return
	var root := _parent_player.animation_tree.tree_root as AnimationNodeBlendTree
	if root == null:
		print("[reload-debug] animation_tree has no blend tree root")
		return
	var reload_anim_node := root.get_node(RELOAD_ANIM_NODE) as AnimationNodeAnimation
	if reload_anim_node == null:
		print("[reload-debug] '", RELOAD_ANIM_NODE, "' node not found in blend tree")
		return
	reload_anim_node.animation = reload_path

	# Playback speed is set via the ReloadTimeScale node's `scale` parameter (there's
	# no per-node speed in code).  Stretch the clip to the reload duration.
	var scale := 1.0
	var anim_player := _get_mannequin_anim_player()
	if anim_player != null and duration > 0.0:
		var anim := anim_player.get_animation(reload_path)
		if anim != null and anim.length > 0.0:
			scale = anim.length / duration
	_parent_player.animation_tree.set("parameters/" + str(RELOAD_TIMESCALE_NODE) + "/scale", scale)

	_parent_player.animation_tree.set(
		"parameters/" + str(RELOAD_ONESHOT_NODE) + "/request",
		AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	)
	print("[reload-debug] fired '", RELOAD_ONESHOT_NODE, "' one-shot with ", reload_path, " (scale=", scale, ")")


## Fire the AnimationTree's "Pullout" one-shot with the current weapon's human
## pull-out animation, time-scaled to last [param duration] seconds via the
## "PulloutTimeScale" node.  Mirrors _play_weapon_human_reload_anim; no-ops for
## legacy weapons, weapons without a pull-out anim, or when the tree isn't ready.
func _play_weapon_human_pullout_anim(duration: float) -> void:
	if not (current_weapon_model is WeaponModel):
		return
	var model := current_weapon_model as WeaponModel
	var pullout_path := model.get_human_anim_path(WeaponAnimGroup.AnimSlot.PULLOUT)
	if pullout_path == &"":
		return
	if _parent_player == null or _parent_player.animation_tree == null:
		return
	var root := _parent_player.animation_tree.tree_root as AnimationNodeBlendTree
	if root == null:
		return
	var pullout_anim_node := root.get_node(PULLOUT_ANIM_NODE) as AnimationNodeAnimation
	if pullout_anim_node == null:
		return
	pullout_anim_node.animation = pullout_path

	# Stretch the clip to the pull-out duration via the PulloutTimeScale node,
	# exactly like reload uses ReloadTimeScale.
	var scale := 1.0
	var anim_player := _get_mannequin_anim_player()
	if anim_player != null and duration > 0.0:
		var anim := anim_player.get_animation(pullout_path)
		if anim != null and anim.length > 0.0:
			scale = anim.length / duration
	_parent_player.animation_tree.set("parameters/" + str(PULLOUT_TIMESCALE_NODE) + "/scale", scale)

	_parent_player.animation_tree.set(
		"parameters/" + str(PULLOUT_ONESHOT_NODE) + "/request",
		AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	)
#endregion


#region Weapon switching
func _on_weapon_index_changed(previous_index: int = -1) -> void:
	_ensure_bg_arrays()

	# Save/restore background reload state across weapon switches.
	if previous_index >= 0 and previous_index < _weapons.size():
		var old_weapon: Weapon = _weapons[previous_index]
		if old_weapon.reload_in_background and _is_reloading:
			_bg_reload_timers[previous_index] = _reload_timer
			_bg_reload_active[previous_index] = true

	var new_weapon: Weapon = _weapons[current_weapon_index] if not _weapons.is_empty() else null
	if new_weapon and new_weapon.reload_in_background and _bg_reload_active[current_weapon_index]:
		# Restore the background reload for this weapon.
		_is_reloading = true
		_reload_timer = _bg_reload_timers[current_weapon_index]
		_bg_reload_active[current_weapon_index] = false
		# Sync the restored timer to clients so their UI shows correct progress.
		if multiplayer.is_server():
			_notify_bg_restore.rpc(current_weapon_index, _reload_timer)
	else:
		_is_reloading   = false
		_reload_timer   = 0.0

	_pending_fire   = false
	_fire_cooldown  = 0.0
	_current_spread = 0.0
	_queued_interrupt = false
	_any_fire_was_held = false
	_is_firing = false
	_firing_remaining = 0.0
	if shoot_animation:
		shoot_animation.stop()
	_restore_transform_after_reload()

	# Swap the visible model.  A real switch (previous_index >= 0) animates the
	# put-away of the outgoing weapon, then the pull-out of the incoming one;
	# an initial load spawns the model immediately.
	if not _weapons.is_empty():
		_begin_switch(previous_index)

	# Only broadcast cancel_reload for non-background weapons — background
	# reloads keep ticking silently and the server syncs mags via _bg_sync_mag.
	var old_had_bg: bool = false
	if previous_index >= 0 and previous_index < _weapons.size():
		old_had_bg = _weapons[previous_index].reload_in_background
	if is_multiplayer_authority() and not old_had_bg:
		_cancel_reload.rpc()
	# Retract shield when switching away from a shield weapon.
	_parent_player.retract_shield()


## Begin the put-away → pull-out sequence for a weapon switch (or spawn the
## incoming weapon immediately when there is no outgoing weapon, i.e. initial
## load).  [param previous_index] is -1 for an initial load.
func _begin_switch(previous_index: int) -> void:
	var old_weapon: Weapon = _weapons[previous_index] if previous_index >= 0 and previous_index < _weapons.size() else null
	var new_weapon: Weapon = _weapons[current_weapon_index] if not _weapons.is_empty() and current_weapon_index < _weapons.size() else null

	var put_away := old_weapon.put_away_time if old_weapon else 0.0
	var pullout := new_weapon.pullout_time if new_weapon else 0.0
	_switch_pullout_time = pullout

	# Initial load: no outgoing weapon to put away — just pull out.
	if old_weapon == null:
		_do_swap_model()
		_play_weapon_pullout_anim(pullout)
		_play_weapon_human_pullout_anim(pullout)
		if pullout > 0.0:
			_switch_phase = SwitchPhase.PULLOUT
			_switch_timer = pullout
		else:
			_finish_switch()
		return

	if put_away > 0.0:
		_switch_phase = SwitchPhase.PUT_AWAY
		_switch_timer = put_away
	elif pullout > 0.0:
		_do_swap_model()
		_play_weapon_pullout_anim(pullout)
		_play_weapon_human_pullout_anim(pullout)
		_switch_phase = SwitchPhase.PULLOUT
		_switch_timer = pullout
	else:
		_do_swap_model()
		_finish_switch()


## Advance the switch state machine when a phase timer elapses.
func _advance_switch_phase() -> void:
	match _switch_phase:
		SwitchPhase.PUT_AWAY:
			_do_swap_model()
			if _switch_pullout_time > 0.0:
				_switch_phase = SwitchPhase.PULLOUT
				_switch_timer = _switch_pullout_time
				_play_weapon_pullout_anim(_switch_pullout_time)
				_play_weapon_human_pullout_anim(_switch_pullout_time)
			else:
				_finish_switch()
		SwitchPhase.PULLOUT:
			_finish_switch()
		_:
			_finish_switch()


## Spawn the incoming weapon's model and finalize server-side switch logic.
func _do_swap_model() -> void:
	if _weapons.is_empty():
		_finish_switch()
		return
	spawn_weapon_model()
	_apply_weapon_model_anims()
	_finalize_switch_server()


func _finish_switch() -> void:
	_switch_phase = SwitchPhase.IDLE
	_switch_timer = 0.0
	_switch_pullout_time = 0.0


## Server-only bookkeeping that must run once the incoming weapon's model is
## in place (after the swap).
func _finalize_switch_server() -> void:
	if not multiplayer.is_server() or _weapons.is_empty() or current_weapon_index >= _weapons.size():
		return
	var switched_weapon: Weapon = _weapons[current_weapon_index]

	# Auto-reload if switching to a weapon that is already empty — covers
	# weapon-switch and spawn/respawn cases that fire_intent() never sees.
	# Bypass the is_switching() gate in start_reload(): this reload is the
	# whole point of the switch, not a manual request.
	if not switched_weapon.has_infinite_ammo and switched_weapon.mag_current <= 0:
		_begin_reload_server()

	# Reset ADS when switching to a weapon that has no ADS fire mode.
	var has_ads: bool = false
	for fire in switched_weapon.weapon_fires:
		if fire.action_type == WeaponFire.ActionType.ADS:
			has_ads = true
			break
	if not has_ads and _parent_player.ads:
		toggle_ads_synced.rpc()


@rpc("call_local")
func _cancel_reload() -> void:
	_is_reloading = false
	_reload_timer = 0.0
	_queued_interrupt = false
	if shoot_animation and shoot_animation.has_animation("reload"):
		shoot_animation.stop()
		_restore_transform_after_reload()


## Returns true if this weapon slot cannot be manually selected (e.g. empty
## auto-switch weapon that hasn't reloaded yet).
func _is_weapon_locked(index: int) -> bool:
	if index < 0 or index >= _weapons.size():
		return true
	var w: Weapon = _weapons[index]
	if w.auto_switch_when_empty and not w.has_infinite_ammo and w.mag_current <= 0:
		return true
	return false

## Find the next selectable weapon in the given direction, wrapping around.
## Returns current index if all weapons are locked.
func _find_next_selectable(direction: int) -> int:
	var count := _weapons.size()
	if count <= 1:
		return 0
	var start := current_weapon_index
	for _i in range(1, count):
		start = (start + direction) % count
		if start < 0:
			start += count
		if not _is_weapon_locked(start):
			return start
	return current_weapon_index

func next_weapon() -> void:
	if _weapon_switch_cooldown > 0.0 or is_switching():
		return
	_weapon_switch_cooldown = WEAPON_SWITCH_THROTTLE
	if multiplayer.is_server():
		current_weapon_index = _find_next_selectable(1)
	else:
		_next_weapon_server.rpc_id(1)

func previous_weapon() -> void:
	if _weapon_switch_cooldown > 0.0 or is_switching():
		return
	_weapon_switch_cooldown = WEAPON_SWITCH_THROTTLE
	if multiplayer.is_server():
		current_weapon_index = _find_next_selectable(-1)
	else:
		_previous_weapon_server.rpc_id(1)

@rpc("any_peer", "call_local")
func _next_weapon_server() -> void:
	if is_multiplayer_authority():
		if _weapon_switch_cooldown > 0.0 or is_switching():
			return
		_weapon_switch_cooldown = WEAPON_SWITCH_THROTTLE
		current_weapon_index = _find_next_selectable(1)

@rpc("any_peer", "call_local")
func _previous_weapon_server() -> void:
	if is_multiplayer_authority():
		if _weapon_switch_cooldown > 0.0 or is_switching():
			return
		_weapon_switch_cooldown = WEAPON_SWITCH_THROTTLE
		current_weapon_index = _find_next_selectable(-1)
#endregion


#region Reload
# Reload is fully server-authoritative.
# The client calls request_reload.rpc_id(1) Ã¢â‚¬â€ the server validates, runs the
# timer, and when done calls _confirm_reload_done.rpc() on all peers.
# The client sets _is_reloading = true immediately for local gate purposes
# (so it doesn't spam fire RPCs during reload), but the flag is only cleared
# by _confirm_reload_done arriving from the server. This means the client
# gate and server gate are always in sync Ã¢â‚¬â€ no timer drift divergence.

func start_reload() -> void:
	if not _is_ready():
		return
	if is_switching():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if _is_reloading or weapon.has_infinite_ammo:
		return
	if weapon.mag_current == weapon.mag_size:
		return
	if multiplayer.is_server():
		_begin_reload_server()
	else:
		_is_reloading = true
		request_reload.rpc_id(1)

@rpc("any_peer")
func request_reload() -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if not _parent_player.is_bot:
		var owner_id: int = _parent_player.name.to_int()
		if sender_id != 0 and sender_id != owner_id:
			return
	if not _begin_reload_server():
		if sender_id != 0 and sender_id != 1:
			_reload_rejected.rpc_id(sender_id)

func _begin_reload_server() -> bool:
	if not _is_ready():
		return false
	var weapon: Weapon = _weapons[current_weapon_index]
	if _is_reloading or weapon.has_infinite_ammo:
		return false
	if weapon.mag_current == weapon.mag_size:
		return false
	_is_reloading = true
	var reload_mult: float = _parent_player._character.reload_speed_mult if _parent_player._character else 1.0
	var base_time: float = weapon.reload_time / max(reload_mult, 0.01)
	# For individual-reload weapons, fold the remaining fire cooldown into
	# the reload so one shell can't be loaded faster than the weapon's
	# intended cycle rate (reload + post_shoot_delay).
	if weapon.reload_individually and _fire_cooldown > 0.0:
		base_time += _fire_cooldown
	_reload_timer = base_time
	_notify_reload_started.rpc(_reload_timer)
	return true


@rpc("call_local")
func _notify_reload_started(timer_value: float) -> void:
	if not _is_ready():
		return
	_is_reloading = true
	_reload_timer = timer_value
	print("[reload-debug] _notify_reload_started | shoot_animation(legacy path)=", shoot_animation,
		" | current model is WeaponModel=", current_weapon_model is WeaponModel)
	var reload_stream := _weapons[current_weapon_index].reload_sound
	var sound_len := reload_stream.get_length() if reload_stream else 1.0
	_play_sound(reload_stream, sound_len / max(timer_value, 0.01))
	if shoot_animation and shoot_animation.has_animation("reload"):
		_save_transform_for_reload()
		shoot_animation.stop()
		shoot_animation.play("reload", -1, 2.0 / max(timer_value, 0.01))
	_play_weapon_reload_anim(timer_value)
	_play_weapon_human_reload_anim(timer_value)
	mag_changed.emit(
		_weapons[current_weapon_index].mag_current,
		_weapons[current_weapon_index].mag_size
	)

@rpc("authority", "call_local", "reliable")
func _reload_rejected() -> void:
	_is_reloading = false

@rpc("authority", "call_remote", "reliable")
func _notify_bg_restore(weapon_index: int, timer_value: float) -> void:
	"""Client-side: restore background reload state when switching to a weapon
	that was reloading in the background."""
	if weapon_index != current_weapon_index:
		return
	_is_reloading = true
	_reload_timer = timer_value
	if shoot_animation and shoot_animation.has_animation("reload"):
		_save_transform_for_reload()
		shoot_animation.stop()
		shoot_animation.play("reload", -1, 2.0 / max(timer_value, 0.01))
	_play_weapon_reload_anim(timer_value)
	_play_weapon_human_reload_anim(timer_value)

func _finish_reload() -> void:
	if not _is_ready():
		_is_reloading = false
		_reload_timer = 0.0
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	if weapon.reload_individually:
		_set_mag(weapon.mag_current + 1)
		# Sync each shell to clients so the ammo counter updates incrementally.
		_sync_mag.rpc(weapon.mag_current)
		_is_reloading = false
		if weapon.mag_current < weapon.mag_size:
			if _queued_interrupt:
				_queued_interrupt = false
				_confirm_reload_done.rpc(weapon.mag_current)
			elif not _begin_reload_server():
				_confirm_reload_done.rpc(weapon.mag_current)
		else:
			_confirm_reload_done.rpc(weapon.mag_current)
	else:
		_set_mag(weapon.mag_size)
		_is_reloading = false
		_confirm_reload_done.rpc(weapon.mag_size)


func _bg_finish_reload(weapon_index: int) -> void:
	"""Server-only: complete one reload cycle for a background weapon."""
	if weapon_index < 0 or weapon_index >= _weapons.size():
		return
	var bg_weapon: Weapon = _weapons[weapon_index]
	if bg_weapon.has_infinite_ammo or bg_weapon.mag_current >= bg_weapon.mag_size:
		_bg_reload_active[weapon_index] = false
		return

	if bg_weapon.reload_individually:
		bg_weapon.mag_current = clamp(bg_weapon.mag_current + 1, 0, bg_weapon.mag_size)
		_bg_sync_mag.rpc(weapon_index, bg_weapon.mag_current)
		if bg_weapon.mag_current < bg_weapon.mag_size:
			# Continue loading next shell.
			var reload_mult: float = _parent_player._character.reload_speed_mult if _parent_player._character else 1.0
			_bg_reload_timers[weapon_index] = bg_weapon.reload_time / max(reload_mult, 0.01)
		else:
			_bg_reload_active[weapon_index] = false
	else:
		bg_weapon.mag_current = bg_weapon.mag_size
		_bg_reload_active[weapon_index] = false
		_bg_sync_mag.rpc(weapon_index, bg_weapon.mag_current)

	# If this is now the active weapon, emit UI updates.
	if weapon_index == current_weapon_index:
		mag_changed.emit(bg_weapon.mag_current, bg_weapon.mag_size)

@rpc("authority", "call_local", "reliable")
func _bg_sync_mag(weapon_index: int, authoritative_mag: int) -> void:
	"""Sync a background weapon's mag to all peers."""
	if weapon_index < 0 or weapon_index >= _weapons.size():
		return
	var w: Weapon = _weapons[weapon_index]
	w.mag_current = clamp(authoritative_mag, 0, w.mag_size)
	if weapon_index == current_weapon_index:
		mag_changed.emit(w.mag_current, w.mag_size)

@rpc("call_local")
func _confirm_reload_done(new_mag: int) -> void:
	if _weapons.is_empty() or current_weapon_index >= _weapons.size():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon.mag_current = clamp(new_mag, 0, weapon.mag_size)
	_is_reloading      = false
	mag_changed.emit(weapon.mag_current, weapon.mag_size)

	# When the player is still holding fire as reload completes, clear per‑press
	# memory so the held button immediately resumes shooting.  This makes both
	# full‑reload and individual‑reload weapons feel responsive when the reload
	# finishes — no need to release and re‑press the trigger.
	if player_input.primary_fire_held or player_input.secondary_fire_held or player_input.tertiary_fire_held:
		_fired_this_press.clear()
#endregion

#region Firing Ã¢â‚¬â€ input processing (owning peer only)
func _process_fire() -> void:
	if not _is_ready():
		return
	if is_switching():
		return

	var weapon: Weapon = _weapons[current_weapon_index]

	_handle_fire_input(weapon, 0, player_input.primary_fire_held)
	_handle_fire_input(weapon, 1, player_input.secondary_fire_held)
	_handle_fire_input(weapon, 2, player_input.tertiary_fire_held)

	# Track whether any fire was held this frame so the next frame can
	# detect a fresh press (for queued individual-reload interrupt).
	_any_fire_was_held = player_input.primary_fire_held or player_input.secondary_fire_held or player_input.tertiary_fire_held


func _handle_fire_input(weapon: Weapon, fire_index: int, input_held: bool) -> void:
	if fire_index >= weapon.weapon_fires.size():
		return
	if not input_held:
		_fired_this_press.erase(fire_index)
		# Hold-to-shield: retract when the button is released.
		var released_fire: WeaponFire = weapon.weapon_fires[fire_index]
		if released_fire.action_type == WeaponFire.ActionType.SHIELD:
			retract_shield_synced.rpc()
		return
	if _fired_this_press.get(fire_index, false):
		return

	# Stunned players cannot take any actions.
	if _parent_player.status_effect_manager and _parent_player.status_effect_manager.is_stunned():
		return

	var fire: WeaponFire = weapon.weapon_fires[fire_index]

	if fire.action_type == WeaponFire.ActionType.ADS:
		toggle_ads_synced.rpc()
		_fired_this_press[fire_index] = true
		return

	if fire.action_type == WeaponFire.ActionType.SHIELD:
		deploy_shield_synced.rpc(fire_index)
		_fired_this_press[fire_index] = true
		return

	if fire.action_type == WeaponFire.ActionType.SIGNAL:
		_send_signal.rpc()
		_fired_this_press[fire_index] = true
		return

	if fire.action_type == WeaponFire.ActionType.SHOOT:
		# Shield blocks shooting unless can_shoot_while_shielded is set.
		if _parent_player.shield_blocks_shooting():
			return

		# Queue an interrupt for individual-reload weapons when fire is
		# newly pressed mid-reload (not a continued hold from before
		# the reload started).  The reload stops after the current
		# shell finishes loading.
		if _is_reloading and weapon.reload_individually and not _any_fire_was_held:
			_queued_interrupt = true

		var required := _get_fire_ammo_cost(weapon, fire_index)
		if not weapon.has_infinite_ammo and weapon.mag_current < required:
			_play_empty.rpc(fire_index)
			_fired_this_press[fire_index] = true
			# Trigger reload when trying to fire an empty magazine � covers
			# weapon-switch cases where auto-reload in fire_intent() never ran.
			if not _is_reloading:
				start_reload()
			return

	_try_fire(fire_index)

	if not weapon.weapon_fires[fire_index].automatic:
		_fired_this_press[fire_index] = true
#endregion



@rpc("any_peer", "call_local")
func toggle_ads_synced():
	_parent_player.ads = not _parent_player.ads


@rpc("any_peer", "call_local")
func deploy_shield_synced(fire_index: int) -> void:
	# Prevent stacking multiple shields.
	if _parent_player.is_shield_active():
		return
	var fire: WeaponFire = _weapons[current_weapon_index].weapon_fires[fire_index]
	_parent_player.deploy_shield(fire)


@rpc("any_peer", "call_local")
func retract_shield_synced() -> void:
	_parent_player.retract_shield()


@rpc("any_peer", "call_local")
func _send_signal() -> void:
	var camera: Camera3D = _raycast.get_parent() as Camera3D
	var target_pos: Vector3
	if _raycast and _raycast.is_colliding():
		target_pos = _raycast.get_collision_point()
	else:
		target_pos = camera.global_position + (-camera.global_transform.basis.z) * 10000.0
	signal_activated.emit(target_pos, _parent_player.global_position)



func _try_fire(weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	if _fire_cooldown > 0.0 or _is_reloading or _pending_fire or _is_firing or is_switching():
		return

	var weapon: Weapon   = _weapons[current_weapon_index]
	var pre_delay: float = weapon.weapon_fires[weapon_fire_index].pre_shoot_delay


	var fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]
	var required := _get_fire_ammo_cost(weapon, weapon_fire_index)
	if not weapon.has_infinite_ammo and weapon.mag_current < required:
		return

	var data: RecoilData = _weapons[current_weapon_index].weapon_fires[weapon_fire_index].recoil_data

	var data_dict := {
		"recoil": data.recoil,
		"aim_recoil": data.aim_recoil,
		"snappiness": data.snappiness,
		"return_speed": data.return_speed
	}

	var r: Vector3      = recoil.recoil
	var rolled: Vector3 = Vector3(
		r.x,
		randf_range(-r.y, r.y),
		randf_range(-r.z, r.z)
	)

	_apply_recoil_rpc.rpc(data_dict, rolled)


	# Mark the start of the fire cycle so speed multipliers stay active.
	_start_firing(weapon, weapon_fire_index)

	if pre_delay > 0.0:
		_pending_fire   = true
		_pending_fire_index = weapon_fire_index
		_pre_fire_timer = pre_delay
	else:
		if multiplayer.is_server():
			fire_intent(current_weapon_index, weapon_fire_index)
		else:
			# Client: send fire intent to the server for authoritative processing.
			# We optimistically set the cooldown for responsive feel; the server
			# will sync the authoritative mag back via _sync_mag.
			_fire_cooldown = _weapons[current_weapon_index].weapon_fires[weapon_fire_index].post_shoot_delay * (_parent_player._character.shoot_delay_mult if _parent_player._character else 1.0)
			fire_intent.rpc_id(1, current_weapon_index, weapon_fire_index)



func _do_fire_client() -> void:
	if not _is_ready():
		return
	_fire_cooldown = _weapons[current_weapon_index].post_shoot_delay * (_parent_player._character.shoot_delay_mult if _parent_player._character else 1.0)
	fire_intent.rpc_id(1, current_weapon_index, _pending_fire_index)
#endregion


#region RPCs
@rpc("any_peer", "call_local")
func _play_empty(weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	if weapon_fire_index < 0 or weapon_fire_index >= _weapons[current_weapon_index].weapon_fires.size():
		return
	_play_sound(_weapons[current_weapon_index].weapon_fires[weapon_fire_index].empty_sound)


@rpc("any_peer")
func fire_intent(weapon_index: int, weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	if is_switching():
		return
	var weapon: Weapon = _weapons[weapon_index]
	var fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]

	# Compute ammo cost. Burst weapons can optionally cost ammo per bullet.
	var total_cost: int = _get_fire_ammo_cost(weapon, weapon_fire_index)

	# Gate: must have enough ammo to fire.  (Already checked on client,
	# but re-validated here on the server.)
	if total_cost > 0 and weapon.mag_current < total_cost:
		return

	_fire_cooldown = fire.post_shoot_delay * (_parent_player._character.shoot_delay_mult if _parent_player._character else 1.0)
	_start_firing(weapon, weapon_fire_index)

	# Self-damage / self-heal on firing (applied once per trigger pull).
	if fire.self_health_delta_on_shoot != 0.0:
		_parent_player.change_health(fire.self_health_delta_on_shoot, _parent_player.name)

	var is_burst := fire.multishot_mode == WeaponFire.MultishotMode.BURST

	if is_burst:
		# Burst fires asynchronously (coroutine).  Deduct the first bullet's
		# ammo now (or the flat ammo_cost if burst_ammo_per_shot is 0).
		# _fire_burst will deduct remaining bullets and handle auto-reload /
		# auto-switch when the burst actually completes.
		if not weapon.has_infinite_ammo:
			var first_cost: int = fire.burst_ammo_per_shot if fire.burst_ammo_per_shot > 0 else fire.ammo_cost
			_set_mag(weapon.mag_current - first_cost)
		_sync_mag.rpc(_weapons[current_weapon_index].mag_current)
		_execute_fire(weapon, weapon_fire_index)
		_play_shoot_sound.rpc(weapon_fire_index)
	else:
		# Non-burst: execute synchronously, then deduct ammo.
		_execute_fire(weapon, weapon_fire_index)
		_play_shoot_sound.rpc(weapon_fire_index)
		if total_cost > 0:
			_set_mag(weapon.mag_current - total_cost)
		_sync_mag.rpc(_weapons[current_weapon_index].mag_current)

		# Auto-reload when the magazine runs dry.
		if not weapon.has_infinite_ammo and weapon.mag_current <= 0 and not _is_reloading:
			start_reload()

		# Auto-switch to another weapon when this one is empty.
		if weapon.auto_switch_when_empty and weapon.mag_current <= 0 and not weapon.has_infinite_ammo:
			_auto_switch_to_next_loaded()


@rpc("any_peer", "call_local")
func _sync_mag(authoritative_mag: int) -> void:
	if not _is_ready():
		return
	var weapon: Weapon = _weapons[current_weapon_index]
	weapon.mag_current = clamp(authoritative_mag, 0, weapon.mag_size)
	mag_changed.emit(weapon.mag_current, weapon.mag_size)

func _execute_fire(weapon: Weapon, weapon_fire_index: int) -> void:
	if not _is_ready():
		return

	var weapon_fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]

	# Don't apply recoil here for BURST Ã¢â‚¬â€ it handles its own
	if weapon_fire.multishot_mode != WeaponFire.MultishotMode.BURST:
		var basis: Basis = weapon_model_parent.global_transform.basis
		var recoil: Vector3 = basis * weapon_fire.recoil_knockback
		if multiplayer.is_server():
			get_parent().apply_knockback(recoil)
		else:
			_knockback_player_on_server.rpc_id(1, recoil)

	match weapon_fire.multishot_mode:
		WeaponFire.MultishotMode.SHOTGUN:
			_fire_all_shots(weapon, weapon_fire_index, false)
		WeaponFire.MultishotMode.BURST:
			_fire_burst(weapon, weapon_fire_index)
		WeaponFire.MultishotMode.SHAPE:
			_fire_all_shots(weapon, weapon_fire_index, true)


func _fire_burst(weapon: Weapon, weapon_fire_index: int) -> void:
	var weapon_fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]
	var is_server := multiplayer.is_server()
	for i in weapon_fire.multishot_data.size():
		if i == 0 or weapon_fire.burst_fire_has_recoil:
			var basis: Basis = weapon_model_parent.global_transform.basis
			var recoil: Vector3 = basis * weapon_fire.recoil_knockback
			if is_server:
				get_parent().apply_knockback(recoil)
			else:
				_knockback_player_on_server.rpc_id(1, recoil)
		_fire_single_shot(weapon, weapon_fire_index, weapon_fire.multishot_data[i], null)

		# Per-bullet self-damage / self-heal during burst.
		if is_server and weapon_fire.self_health_delta_per_burst_bullet != 0.0:
			_parent_player.change_health(weapon_fire.self_health_delta_per_burst_bullet, _parent_player.name)

		# Deduct ammo for bullets after the first (first was deducted in fire_intent).
		if i > 0 and is_server and not weapon.has_infinite_ammo and weapon_fire.burst_ammo_per_shot > 0:
			weapon.mag_current = clamp(weapon.mag_current - weapon_fire.burst_ammo_per_shot, 0, weapon.mag_size)
			_sync_mag.rpc(weapon.mag_current)

		if i < weapon_fire.multishot_data.size() - 1:
			await get_tree().create_timer(weapon_fire.burst_post_shoot_delay).timeout

	# Burst complete — handle auto-reload and auto-switch on the server.
	if is_server and not weapon.has_infinite_ammo:
		if weapon.mag_current <= 0 and not _is_reloading:
			start_reload()
		if weapon.auto_switch_when_empty and weapon.mag_current <= 0:
			_auto_switch_to_next_loaded()

func _fire_all_shots(weapon: Weapon, weapon_fire_index: int, is_shape: bool) -> void:
	var weapon_fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]
	var shape_hits: Dictionary = {}
	var shotgun_hit_players: Dictionary = {}
	for shot_dir in weapon_fire.multishot_data:
		if is_shape:
			_fire_single_shot(weapon, weapon_fire_index, shot_dir, shape_hits)
		else:
			var hit_name := _fire_single_shot(weapon, weapon_fire_index, shot_dir, null, false)
			if hit_name != "":
				shotgun_hit_players[hit_name] = true

	if is_shape:
		_apply_shape_damage(weapon, weapon_fire_index, shape_hits)
	else:
		for player_name in shotgun_hit_players:
			_apply_on_hit_effects(weapon_fire, player_name)


func _fire_single_shot(weapon: Weapon, weapon_fire_index: int, shot_dir: Vector3, shape_hits, apply_on_hit: bool = true) -> String:
	var weapon_fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]
	var _hit_player: String = ""
	var camera: Camera3D = _raycast.get_parent() as Camera3D

	var world_dir: Vector3 = camera.global_transform.basis * shot_dir.normalized()

	# Movement inaccuracy (CS-style floor).  Your spread can never be *better*
	# than the movement penalty — even on the first bullet when standing still.
	if weapon_fire.movement_spread > 0.0:
		var h_vel: Vector2 = Vector2(_parent_player.velocity.x, _parent_player.velocity.z)
		var h_speed: float = h_vel.length()
		var max_speed: float = _parent_player.speed
		if max_speed > 0.0:
			var move_floor: float = weapon_fire.movement_spread * (h_speed / max_speed)
			_current_spread = maxf(_current_spread, move_floor)

	# Apply weapon spread (shared by hitscan and projectile).
	if weapon.spread_per_shot > 0.0 or weapon.min_spread > 0.0:
		_current_spread = minf(maxf(_current_spread, weapon.min_spread) + weapon.spread_per_shot, weapon.max_spread)
		var spread_rad: float = deg_to_rad(_current_spread)
		var angle: float = randf() * TAU
		var radius: float = randf() * spread_rad
		var right: Vector3 = world_dir.cross(Vector3.UP).normalized()
		if right.length_squared() < 0.01:
			right = world_dir.cross(Vector3.RIGHT).normalized()
		var up: Vector3 = world_dir.cross(right).normalized()
		world_dir = world_dir.rotated(right, sin(angle) * radius)
		world_dir = world_dir.rotated(up, cos(angle) * radius)
		world_dir = world_dir.normalized()

	if weapon_fire.bullet_type == WeaponFire.BulletType.HITSCAN:
		var muzzle_node: Node3D = _next_muzzle()
		var muzzle_pos: Vector3 = muzzle_node.global_position if muzzle_node else current_weapon_model.global_position
		var flash_color: Color = MuzzleFlash.SCI_COLOR if _parent_player.team == Player.Team.SCI else MuzzleFlash.DEFAULT_COLOR
		_flash_muzzle_flash.rpc(muzzle_pos, flash_color, world_dir)

		var space_state: PhysicsDirectSpaceState3D = _parent_player.get_world_3d().direct_space_state
		var origin: Vector3 = camera.global_position
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			origin,
			origin + world_dir * weapon_fire.hitscan_range
		)
		var exclude_rids := [_parent_player.get_rid(), $"../HeadHurtbox".get_rid(), $"../BodyHurtbox".get_rid(), $"../BodyHurtbox2".get_rid()]
		# Also exclude the player's own shield so they can't damage it.
		if _parent_player.shield_instance and is_instance_valid(_parent_player.shield_instance):
			var shield_area := _parent_player.shield_instance.get_node_or_null("ShieldArea") as Area3D
			if shield_area:
				exclude_rids.append(shield_area.get_rid())
		query.exclude = exclude_rids
		query.collide_with_areas = true
		query.collision_mask = (1 << 0) | (1 << 2)
		var result: Dictionary = space_state.intersect_ray(query)

		if not result.is_empty():
			_on_hitscan_hit.rpc(result.position, result.normal, muzzle_pos, flash_color)
			var collider: Node3D = result.collider
			if collider is HurtboxComponent:
				if shape_hits != null:
					var player_name: String = collider.get_parent().name
					var distance: float = origin.distance_to(result.position)
					if not shape_hits.has(player_name):
						shape_hits[player_name] = {
							"is_head": collider.is_head,
							"collider": collider,
							"distance": distance,
						}
					elif collider.is_head:
						shape_hits[player_name]["is_head"] = true
				else:
					var distance := origin.distance_to(result.position)
					var mult := _compute_falloff_multiplier(weapon, weapon_fire_index, distance)
					var damage := weapon_fire.hitscan_damage * mult
					var is_headshot := false
					if collider.is_head and not is_equal_approx(weapon_fire.headshot_multiplier, 1.0):
						damage *= weapon_fire.headshot_multiplier
						is_headshot = true
					# Shield hurtbox Ã¢â‚¬â€ absorb all damage, no overflow to player.
					if collider.get_parent() is PlayerShield:
						(collider.get_parent() as PlayerShield).absorb_damage(damage)
					else:
						var victim := collider.get_parent() as Player
						var is_backshot := _is_backshot(victim)
						# Backshot: shooter is behind the victim - apply bonus.
						if not is_equal_approx(weapon_fire.backshot_multiplier, 1.0) and is_backshot:
							damage *= weapon_fire.backshot_multiplier
							if not _parent_player.is_bot:
								play_backshot_sound.rpc_id(_parent_player.name.to_int())
						var player_name = victim.name
						if victim.team == get_parent().team and victim.team != Player.Team.FFA:
							damage *= Player.FRIENDLY_FIRE_MULTIPLIER
						if multiplayer.is_server():
							_apply_damage_direct(player_name, -damage, _parent_player.name, is_headshot, mult, is_backshot)
							_hit_player = player_name
							if apply_on_hit:
								_apply_on_hit_effects(weapon_fire, _parent_player.name)
							_apply_status_effects(player_name, weapon_fire.status_effects, _parent_player.name, is_headshot, is_backshot)
							if weapon_fire.hit_knockback > 0.0:
								_apply_hit_knockback(player_name, world_dir, weapon_fire.hit_knockback)
						else:
							_change_health_on_server.rpc_id(1, player_name, -damage, _parent_player.name, is_headshot, mult, is_backshot)
							if weapon_fire.hit_knockback > 0.0:
								_apply_hit_knockback_on_server.rpc_id(1, player_name, world_dir, weapon_fire.hit_knockback)
		else:
			if weapon_fire.hitscan_range >= 1000000000.0 / 10.0:
				var far_pos: Vector3 = origin + world_dir * 10000.0
				var fake_normal: Vector3 = -world_dir
				_on_hitscan_hit.rpc(far_pos, fake_normal, muzzle_pos, flash_color)

	elif weapon_fire.bullet_type == WeaponFire.BulletType.PROJECTILE:
		_spawn_projectile_on_server.rpc_id(
			1, weapon_fire_index, world_dir, Basis(),
			_parent_player.name, _parent_player.team
		)

	return _hit_player

func _apply_shape_damage(weapon: Weapon, weapon_fire_index: int, shape_hits: Dictionary) -> void:
	var weapon_fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]
	for key in shape_hits:
		var hit: Dictionary = shape_hits[key]
		var collider: HurtboxComponent = hit["collider"]
		var distance: float = hit["distance"]
		var mult: float = _compute_falloff_multiplier(weapon, weapon_fire_index, distance)
		var damage: float = weapon_fire.hitscan_damage * mult
		var is_headshot := false
		if hit["is_head"] and not is_equal_approx(weapon_fire.headshot_multiplier, 1.0):
			damage *= weapon_fire.headshot_multiplier
			is_headshot = true
		# Shield hurtbox Ã¢â‚¬â€ absorb all damage, no overflow to player.
		if collider.get_parent() is PlayerShield:
			(collider.get_parent() as PlayerShield).absorb_damage(damage)
			continue
		var player_name: String = key
		var victim := collider.get_parent() as Player
		var is_backshot := _is_backshot(victim)
		if not is_equal_approx(weapon_fire.backshot_multiplier, 1.0) and is_backshot:
			damage *= weapon_fire.backshot_multiplier
			if not _parent_player.is_bot:
				play_backshot_sound.rpc_id(_parent_player.name.to_int())
		if victim.team == get_parent().team and victim.team != Player.Team.FFA:
			damage *= Player.FRIENDLY_FIRE_MULTIPLIER
		if multiplayer.is_server():
			_apply_damage_direct(player_name, -damage, _parent_player.name, is_headshot, mult, is_backshot)
			_apply_on_hit_effects(weapon_fire, _parent_player.name)
			_apply_status_effects(player_name, weapon_fire.status_effects, _parent_player.name, is_headshot, is_backshot)
			if weapon_fire.hit_knockback > 0.0:
				var target_p: Player = GameManager.find_player(player_name)
				if target_p:
					var kb_dir: Vector3 = (target_p.global_position - _parent_player.global_position).normalized()
					_apply_hit_knockback(player_name, kb_dir, weapon_fire.hit_knockback)
		else:
			_change_health_on_server.rpc_id(1, player_name, -damage, _parent_player.name, is_headshot, mult, is_backshot)
			if weapon_fire.hit_knockback > 0.0:
				var target_p: Player = GameManager.find_player(player_name)
				if target_p:
					var kb_dir: Vector3 = (target_p.global_position - _parent_player.global_position).normalized()
					_apply_hit_knockback_on_server.rpc_id(1, player_name, kb_dir, weapon_fire.hit_knockback)


@rpc("any_peer", "call_local", "unreliable")
func _knockback_player_on_server(vector: Vector3):
	get_parent().apply_knockback(vector)


## Apply knockback to a player by name.  Server-only.
func _apply_hit_knockback(target_name: String, shot_dir: Vector3, force: float) -> void:
	var target: Player = GameManager.find_player(target_name)
	if not target:
		return
	target.apply_knockback(shot_dir * force)


@rpc("any_peer", "call_local", "reliable")
func _apply_hit_knockback_on_server(target_name: String, shot_dir: Vector3, force: float) -> void:
	if not is_multiplayer_authority():
		return
	_apply_hit_knockback(target_name, shot_dir, force)


@rpc("any_peer", "call_local", "reliable")
func _spawn_projectile_on_server(weapon_fire_index, shot_dir, basis, parent_player_name, team):
	if not _is_ready():
		return
	var weapon: Weapon    = _weapons[current_weapon_index]
	var shot_dir_v3: Vector3 = shot_dir as Vector3
	var world_dir: Vector3   = basis * shot_dir_v3.normalized()

	if not weapon_fire_index < weapon.weapon_fires.size() or not weapon.weapon_fires[weapon_fire_index].projectile_scene:
		return
	var projectile_scene: Node3D  = weapon.weapon_fires[weapon_fire_index].projectile_scene.instantiate() as Node3D
	projectile_scene.global_transform = %Head.global_transform#weapon_model_parent.global_transform
	projectile_scene.shooter_name     = parent_player_name

	var speed: float = projectile_scene.linear_velocity.length()
	projectile_scene.linear_velocity = world_dir * speed
	projectile_scene.shooter_team = team
	# Copy status effects and knockback from the WeaponFire to the projectile.
	var weapon_fire: WeaponFire = weapon.weapon_fires[weapon_fire_index]
	var hb: HitboxComponent = projectile_scene.get_node_or_null("HitboxComponent") as HitboxComponent
	if hb:
		hb.hit_knockback = weapon_fire.hit_knockback
		if not weapon_fire.status_effects.is_empty():
			hb.status_effects = weapon_fire.status_effects
	var ec: ExplosionComponent = projectile_scene.get_node_or_null("ExplosionComponent") as ExplosionComponent
	if ec and not weapon_fire.status_effects.is_empty():
		ec.status_effects = weapon_fire.status_effects
	projectile_spawn_parent.add_child(projectile_scene, true)


## Apply on-hit effects (self-heal / self-damage) from a WeaponFire to the
## shooter.  Called once per unique opponent for shotgun / shape modes.
func _apply_on_hit_effects(fire: WeaponFire, shooter_name: String) -> void:
	if fire.self_health_delta_on_hit != 0.0:
		var shooter := GameManager.find_player(shooter_name)
		if shooter:
			shooter.change_health(fire.self_health_delta_on_hit, shooter_name)


## Apply status effects from a WeaponFire to the hit target.
func _apply_status_effects(target_name: String, effects: Array, shooter_name: String, is_headshot: bool = false, is_backshot: bool = false) -> void:
	if effects.is_empty():
		return
	var target: Player = GameManager.find_player(target_name)
	if not target:
		push_warning("[StatusEffect] Could not find player '" + target_name + "' to apply effects.")
		return
	if not target.status_effect_manager:
		push_warning("[StatusEffect] Player '" + target_name + "' has no StatusEffectManager node.  Make sure player.tscn was saved and the project was reloaded.")
		return
	for effect in effects:
		if effect and effect.should_trigger(is_headshot, is_backshot):
			target.status_effect_manager.apply_effect(effect, shooter_name)

func _apply_damage_direct(collider_name: String, delta: float, parent_player_name: String, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false) -> void:
	var target: Player = GameManager.find_player(collider_name)
	if target:
		# Apply shooter's damage amp.
		var shooter: Player = GameManager.find_player(parent_player_name)
		var dmg_mult: float = shooter._character.damage_amp_mult if shooter and shooter._character else 1.0
		target.change_health(delta * dmg_mult, parent_player_name, is_headshot, falloff_mult, is_backshot)
		# Lifesteal: heal shooter for a percentage of damage dealt.
		if delta < 0.0 and shooter and shooter._character:
			var lifesteal: float = abs(delta * dmg_mult) * shooter._character.lifesteal_percent
			if lifesteal > 0.0:
				shooter.change_health(lifesteal, parent_player_name)

@rpc("any_peer", "call_local", "reliable")
func _change_health_on_server(collider_name: String, delta, parent_player_name, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false):
	if not is_multiplayer_authority():
		return
	_apply_damage_direct(collider_name, delta, parent_player_name, is_headshot, falloff_mult, is_backshot)


func _compute_falloff_multiplier(weapon: Weapon, weapon_fire_index: int, distance: float) -> float:

	var weapon_fire = weapon.weapon_fires[weapon_fire_index]

	if not weapon_fire.has_damage_falloff or weapon_fire.falloff_curve == null:
		return 1.0
	var t: float
	if weapon_fire.falloff_end == weapon_fire.falloff_start:
		t = 0.0
	else:
		t = (distance - weapon_fire.falloff_start) / (weapon_fire.falloff_end - weapon_fire.falloff_start)
	t = clamp(t, 0.0, 1.0)
	var curve: Curve = weapon_fire.falloff_curve.curve
	if curve == null:
		return 1.0
	return curve.sample(t)


## True when the shooter (_parent_player) is behind [param victim] — inside the
## victim's rear 180° hemisphere, using the victim's body yaw only (no head pitch
## or head rotation).
func _is_backshot(victim: Player) -> bool:
	var forward := -victim.body.global_transform.basis.z
	forward.y = 0.0
	var to_shooter := _parent_player.global_position - victim.global_position
	to_shooter.y = 0.0
	if to_shooter.length_squared() < 0.01:
		return false  # same spot — direction is undefined, don't count as a backshot
	return forward.normalized().dot(to_shooter.normalized()) < 0.0


@rpc("any_peer", "call_local")
func _flash_muzzle_flash(start_position: Vector3, flash_color: Color, direction: Vector3) -> void:
	if not _is_ready():
		return
	var muzzle_flash = $MuzzleFlash
	# Aim the flash along the shot direction instead of copying the weapon
	# model's rotation (the model is now skeleton-oriented, not raycast-aligned).
	if direction.length_squared() > 0.0001:
		muzzle_flash.global_transform.basis = Basis.looking_at(direction.normalized(), Vector3.UP)
	muzzle_flash.global_position = start_position
	muzzle_flash.fire(flash_color)

@rpc("any_peer", "call_local")
func _on_hitscan_hit(hit_position: Vector3, hit_normal: Vector3, start_position: Vector3, flash_color: Color) -> void:
	var bullet_hole: Node3D = _bullet_hole_scene.instantiate() as Node3D
	projectile_spawn_parent.add_child(bullet_hole)
	bullet_hole.global_position        = hit_position
	bullet_hole.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal))
	# Timer is a child of bullet_hole Ã¢â‚¬â€ if bullet_hole is freed (parent cleanup),
	# the timer is freed too, so the timeout never fires with a stale reference.
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 7.0
	timer.timeout.connect(bullet_hole.queue_free)
	bullet_hole.add_child(timer)
	timer.start()

	var tracer: Tracer = _tracer_scene.instantiate() as Tracer
	projectile_spawn_parent.add_child(tracer)
	tracer.fire(start_position, hit_position, flash_color)


@rpc("any_peer", "call_local")
func _apply_recoil_rpc(data: Dictionary, rolled: Vector3) -> void:
	if _weapons.is_empty():
		return
	recoil.recoil       = data.recoil
	recoil.aim_recoil   = data.aim_recoil
	recoil.snappiness   = data.snappiness
	recoil.return_speed = data.return_speed

	recoil.target_rotation += rolled


@rpc("any_peer", "call_local")
func _play_shoot_sound(weapon_fire_index: int) -> void:
	if not _is_ready():
		return
	if weapon_fire_index < 0 or weapon_fire_index >= _weapons[current_weapon_index].weapon_fires.size():
		return
	_play_sound(_weapons[current_weapon_index].weapon_fires[weapon_fire_index].shoot_sound)
	if shoot_animation and shoot_animation.has_animation("shoot"):
		shoot_animation.stop()
		shoot_animation.play("shoot")

## Played when you hit someone, called by attribute component
@rpc("any_peer", "call_local")
func play_hit_sound() -> void:
	if not _is_ready():
		return
	_play_sound(_hit_sound)

##Played when you heal someone, called by attribute component
@rpc("any_peer", "call_local")
func play_hit_heal_sound() -> void:
	if not _is_ready():
		return
	_play_sound(_hit_heal_sound)

## Played when you land a headshot, called by attribute component
@rpc("any_peer", "call_local")
func play_crit_sound() -> void:
	if not _is_ready():
		return
	_play_sound(_crit_sound)


## Played when you land a backshot, called by the weapon / hurt component.
@rpc("any_peer", "call_local")
func play_backshot_sound() -> void:
	if not _is_ready():
		return
	_play_sound(_backshot_sound)

#endregion
