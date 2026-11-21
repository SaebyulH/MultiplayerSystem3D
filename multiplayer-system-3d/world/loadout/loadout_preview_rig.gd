extends Node3D
class_name LoadoutPreviewRig

## Drives the character-select preview from the SAME rig the game uses.
##
## A dormant `player.tscn` is instantiated (its root never enters the tree, so
## `Player._ready` never runs) and only its `Body` subtree is kept: the mannequin
## skeleton, the full `AnimationTree` blend tree, the aim `CCDIK3D`, both
## `CopyTransformModifier3D`s, `RotationDir`, `WeaponTilt` and the `GunAttach`
## weapon mount.  Gameplay nodes (PlayerUI, synchronizers, hurtboxes, the camera,
## the physical-bone simulator) are stripped, and every script that dereferences
## the Player parent is cleared before the subtree is added.
##
## The selected Character model is parented the way `Player._spawn_character_model`
## does it and mirrors the mannequin's bones through `_copy_mannequin_pose`.  The
## weapon mounts and shades exactly like `WeaponController.spawn_weapon_model`.
## The AnimationTree is driven at a synthetic forward walk (HoldBlend 0, walk
## blend (0, -1)), so the agent plays the in-game walk cycle — including the aim
## IK — instead of the weapon-hold idle that reads as facing sideways.
##
## If player.tscn / weapon_controller.gd change their hierarchy or mount, this
## file must follow (docs/05-known-issues.md #152).

const PLAYER_SCENE := preload("res://player/player.tscn")
const MANNEQUIN_SCENE := preload("res://assets/character_models/mannequin/mannequin.tscn")

enum PreviewMode { STANDING, WALKING, RUNNING }
const WEAPON_TOON_PRESET := preload("res://assets/materials/weapon_toon.tres")
const WEAPON_TOON_CONVERTER := preload("res://weapon/weapon_toon_materials.gd")

## Fallback mount if the extracted rig is missing its GunAttach (should not
## happen; kept so a rig change fails softly instead of dropping the weapon).
const BONE_NAME := "DEF-spine.003"
const BONE_ATTACH_TRANSFORM := Transform3D(Basis(), Vector3(0.0007132123, 1.3045969, 0.011971066))
const INNER_MOUNT_TRANSFORM := Transform3D(Basis(), Vector3(0.0, -1.307, 0.009))

## 30 Hz is enough for a smooth walk and far cheaper than a per-frame second
## World3D render.
const RENDER_INTERVAL := 0.033
const ZOOM_MIN := 0.1
const ZOOM_MAX := 8.0
const WALK_FORWARD := Vector2(0, -1)

var _viewport: SubViewport
var _pivot: Node3D
var _body: Node3D
var _mannequin: Node3D
var _mannequin_skeleton: Skeleton3D
var _mannequin_animation: AnimationPlayer
var _tree: AnimationTree
var _model: Node3D
var _model_skeleton: Skeleton3D
var _pose_map: PackedInt32Array = PackedInt32Array()
var _ghost := false
var _ghost_material: StandardMaterial3D
var _gun_attach: BoneAttachment3D
var _weapon_mount: Node3D
var _weapon_model: Node3D
var _weapon: Weapon
## Hidden walk/sprint source.  When the main tree is on the armed hold chain
## (HoldBlend 1) it has no locomotion, so the legs are copied from this second
## mannequin and everything above the hips from the real tree.
var _leg_source: Node3D
var _leg_source_skeleton: Skeleton3D
var _leg_source_animation: AnimationPlayer
var _leg_map: PackedInt32Array = PackedInt32Array()
var _leg_override := false
var _mode := PreviewMode.WALKING
var _camera: Camera3D
var _ground: Node3D
var _base_distance := 4.0
var _zoom := 1.0
## Camera orbit around the agent: the model itself never rotates, so lift/drag
## always feels like circling it rather than tumbling it.
var _orbit_yaw := 0.0
var _orbit_pitch := 0.08
var _pan := Vector2.ZERO
var _center_offset := Vector3.ZERO
var _floor_y := 0.0
var _render_timer: Timer

# ── Asset-viewer extensions (inert for the loadout screen) ───────────
enum ViewMode { CHARACTER, EFFECT }
var _view_mode := ViewMode.CHARACTER
## Camera look-at target.  Always Vector3.ZERO in character mode.
var _focus := Vector3.ZERO
## Un-panned focus for the effect stage (the effect spawn point).  Pan is added
## on top so the first drag does not snap the camera away from the stage.
var _base_focus := Vector3.ZERO
var _effect_root: Node3D = null
## Raw-animation state.  While true the AnimationTree stays disabled or the
## blend tree fights the AnimationPlayer clip.
var _raw_anim_mode := false
var _raw_weapon_anim := false
## AnimationTree has no speed_scale in Godot 4.7.  Non-1.0 preview speeds put
## the tree in MANUAL callback mode and advance() is driven from _process.
var _tree_manual := false
var _tree_speed := 1.0
## True while the human clip was started by play_weapon_animation (paired anim),
## so stopping the weapon also releases the human skeleton.
var _weapon_human_sync := false
var _anim_serial := 0
## Runtime AnimationLibrary holding the duplicated (loop-mode-adjusted) clips.
## Removed on stop so nothing accumulates and the authored GLB library is never
## mutated.
const PREVIEW_LIB := &"__viewer"


func _ready() -> void:
	# The preview owns its own AnimationTree stepping (see set_animation_speed),
	# so keep it on native processing instead of the global 12 Hz pacing.
	AnimationPacing.exempt(self)
	_viewport = get_viewport() as SubViewport
	_render_timer = Timer.new()
	_render_timer.wait_time = RENDER_INTERVAL
	_render_timer.timeout.connect(render_once)
	add_child(_render_timer)
	_render_timer.start()


func _process(delta: float) -> void:
	# Only the preview tree uses manual processing (see set_animation_speed).
	if not _tree_manual or _tree == null or not is_instance_valid(_tree):
		return
	if _render_timer == null or _render_timer.is_stopped():
		return
	_tree.advance(delta * _tree_speed)


func set_active(on: bool) -> void:
	if _render_timer == null:
		return
	if on:
		_render_timer.start()
	else:
		_render_timer.stop()


## Show [param char].  The player rig is built once and reused; only the
## character model is swapped.  [param ghost] makes the model translucent, used
## for the hover preview of an agent that is not selected yet.
func show_character(char: Character, initial_weapon: Weapon, ghost := false) -> void:
	_ghost = ghost
	# Returning from the asset viewer's Effects tab restores the agent view.
	# A raw animation clip must release the skeleton before the tree drives it.
	_stop_raw_human_anim()
	_view_mode = ViewMode.CHARACTER
	_focus = Vector3.ZERO
	if _pivot != null and is_instance_valid(_pivot):
		_pivot.visible = true
	if _tree != null:
		_tree.active = true
	if char == null or char.character_scene == null:
		clear()
		return

	if _pivot == null or _body == null or not is_instance_valid(_body):
		clear()
		_pivot = Node3D.new()
		_pivot.name = "CharacterPreviewPivot"
		add_child(_pivot)
		if not _build_player_body():
			return
		_hide_mannequin_meshes()
		_build_leg_source()
		if _mannequin_skeleton != null \
				and not _mannequin_skeleton.skeleton_updated.is_connected(_copy_mannequin_pose):
			_mannequin_skeleton.skeleton_updated.connect(_copy_mannequin_pose)

	_apply_model(char, ghost)
	set_weapon(initial_weapon)
	render_once()


func _apply_model(char: Character, ghost: bool) -> void:
	if _model != null and is_instance_valid(_model):
		_body.remove_child(_model)
		_model.queue_free()
	_model = null
	_model_skeleton = null

	var model := char.character_scene.instantiate() as Node3D
	if model == null:
		return
	_model = model
	# The character model's own animation does not run: its pose comes from the
	# mannequin, exactly like the in-game world model.
	model.process_mode = Node.PROCESS_MODE_DISABLED
	# Player._spawn_character_model uses the mannequin's transform.
	if _mannequin != null:
		model.transform = _mannequin.transform
	_body.add_child(model)
	_model_skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D

	_build_pose_map()
	_build_leg_map()
	_copy_mannequin_pose()

	var box := _visual_aabb(model)
	if box.size.length_squared() <= 0.0001:
		box = AABB(Vector3(-0.5, -0.9, -0.5), Vector3(1.0, 1.8, 1.0))
	# Centre in the body's space (the model already carries the mannequin scale).
	var body_space := _aabb_transformed(box, model.transform)
	_center_offset = -body_space.get_center()
	_pan = Vector2.ZERO
	_apply_pan()
	_frame_camera(box)

	if ghost:
		_apply_ghost_material(model)

	if OS.is_debug_build():
		var meshes := model.find_children("*", "MeshInstance3D", true, false).size()
		print("[DEBUG PREVIEW] '%s' meshes=%d bones=%d tree=%s ghost=%s" % [
			char.character_name, meshes,
			_model_skeleton.get_bone_count() if _model_skeleton else 0,
			"on" if _tree != null and _tree.active else "off", ghost])


func set_weapon(weapon: Weapon) -> void:
	# The old model (and any runtime preview animations registered on it) is
	# about to be freed.
	_raw_weapon_anim = false
	_weapon_human_sync = false
	_weapon = weapon
	_clear_weapon()
	if _body == null:
		return
	if weapon != null and weapon.weapon_model != null:
		_attach_weapon(weapon)
	_apply_animation_state(weapon)
	render_once()


func zoom(steps: float) -> void:
	if _camera == null:
		return
	# Multiplicative so the wide range is reachable in a handful of notches.
	_zoom = clampf(_zoom * pow(0.85, steps), ZOOM_MIN, ZOOM_MAX)
	_apply_camera()
	render_once()


## Left-drag: orbit the camera around the agent (yaw + elevation).
func orbit(delta_x: float, delta_y: float) -> void:
	if is_zero_approx(delta_x) and is_zero_approx(delta_y):
		return
	_orbit_yaw += delta_x * 0.01
	_orbit_pitch = clampf(_orbit_pitch + delta_y * 0.01, -0.25, 1.25)
	_apply_camera()
	render_once()


## Right-drag: pan in the camera's own right/up plane.  World X/Y panning broke
## as soon as the camera orbited.  X follows the pointer (grab), Y is inverted
## because screen-down is world-down.
func pan(delta_x: float, delta_y: float) -> void:
	if is_zero_approx(delta_x) and is_zero_approx(delta_y):
		return
	_pan.x = clampf(_pan.x + delta_x * 0.004, -3.0, 3.0)
	_pan.y = clampf(_pan.y - delta_y * 0.004, -3.0, 3.0)
	_apply_pan()
	render_once()


func _apply_pan() -> void:
	var basis := Basis.IDENTITY
	if _camera != null and is_instance_valid(_camera):
		basis = _camera.global_basis.orthonormalized()
	var offset := basis.x * _pan.x + basis.y * _pan.y
	if _view_mode == ViewMode.EFFECT:
		# No agent to move: pan the camera target through the camera plane.
		# Opposite sign from the character pivot: moving the camera shifts the
		# stationary effect the other way on screen.
		_focus = _base_focus - offset
		if _camera != null:
			_apply_camera()
		return
	if _pivot != null:
		_pivot.position = _center_offset + offset
	# The floor travels with the agent so panning never leaves it floating.
	if _ground != null and is_instance_valid(_ground):
		_ground.position = Vector3(0.0, _floor_y, 0.0) + offset


func set_preview_mode(mode: int) -> void:
	_mode = clampi(mode, 0, 2)
	_apply_animation_state(_weapon)
	render_once()


func get_preview_mode() -> int:
	return int(_mode)


func render_once() -> void:
	# Copy every tick, not only on the mannequin's skeleton_updated: with the
	# armed hold chain the main pose can be static while the leg source animates.
	_copy_mannequin_pose()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func clear() -> void:
	_clear_weapon()
	_raw_anim_mode = false
	_raw_weapon_anim = false
	if _pivot != null and is_instance_valid(_pivot):
		remove_child(_pivot)
		_pivot.queue_free()
	_pivot = null
	_body = null
	_mannequin = null
	_mannequin_skeleton = null
	_mannequin_animation = null
	_leg_source = null
	_leg_source_skeleton = null
	_leg_source_animation = null
	_leg_map = PackedInt32Array()
	_leg_override = false
	_tree = null
	_tree_manual = false
	_model = null
	_model_skeleton = null
	_gun_attach = null
	_weapon_mount = null
	_pose_map = PackedInt32Array()


func get_displayed_weapon() -> Weapon:
	return _weapon


# ─────────────────────────────────────────────
#  Asset viewer: effect view
# ─────────────────────────────────────────────

## Retime the render timer.  The loadout screen keeps 30 Hz; the asset viewer
## uses 60 Hz so fast one-shot effects read smoothly.
func set_render_interval(seconds: float) -> void:
	if _render_timer == null:
		return
	_render_timer.wait_time = maxf(seconds, 0.001)
	if not _render_timer.is_stopped():
		_render_timer.start()


## Switch to the effect stage: the agent is hidden (and its blend tree stopped)
## while the camera keeps the same orbit/pan/zoom controls.
func enter_effect_view() -> void:
	# Re-entering from character mode resets pan/focus once.  Calling this again
	# while already in effect mode (switching effects) keeps the user's camera.
	var entering := _view_mode != ViewMode.EFFECT
	_view_mode = ViewMode.EFFECT
	_stop_raw_human_anim()
	_stop_raw_weapon_anim()
	if _tree != null:
		_tree.active = false
	if _pivot != null and is_instance_valid(_pivot):
		_pivot.visible = false
	if entering:
		_pan = Vector2.ZERO
		_focus = _base_focus
		_center_offset = Vector3.ZERO
		_ensure_camera()
		if _ground != null and is_instance_valid(_ground):
			_ground.position = Vector3.ZERO
		_apply_camera()
	render_once()


## Reset the character preview's orbit/pan/zoom to its default framing.  The
## asset viewer calls this when entering the Agents tab so camera state never
## carries over from the Effects tab (or vice versa).
func reset_character_view() -> void:
	_orbit_yaw = 0.0
	_orbit_pitch = 0.08
	_zoom = 1.0
	_pan = Vector2.ZERO
	_focus = Vector3.ZERO
	_ensure_camera()
	if _camera != null:
		_apply_camera()


## Frame the effect stage.  `distance` is the orbit radius; `focus` is the
## camera look-at point (effect spawn point).
func frame_effect(distance: float, focus := Vector3.ZERO) -> void:
	_view_mode = ViewMode.EFFECT
	_base_focus = focus
	_focus = focus
	_base_distance = maxf(distance, 0.2)
	_zoom = 1.0
	_orbit_yaw = 0.0
	_orbit_pitch = 0.12
	_pan = Vector2.ZERO
	_ensure_camera()
	_apply_camera()
	render_once()


## Node the asset viewer spawns effects under.  Sibling of the (hidden) agent
## pivot so hiding the character never hides the effect.
func get_effect_root() -> Node3D:
	if _effect_root == null or not is_instance_valid(_effect_root):
		_effect_root = Node3D.new()
		_effect_root.name = "EffectRoot"
		add_child(_effect_root)
	return _effect_root


func clear_effect_nodes() -> void:
	if _effect_root == null or not is_instance_valid(_effect_root):
		return
	for child in _effect_root.get_children():
		_effect_root.remove_child(child)
		child.queue_free()


func get_preview_camera() -> Camera3D:
	_ensure_camera()
	return _camera


## Map a normalized SubViewportContainer position (0..1) to a world point on
## the plane facing the camera through [param plane_point].  Uses the viewport's
## own pixel size, because the SubViewportContainer stretches the viewport.
func screen_to_stage(uv: Vector2, plane_point := Vector3.ZERO) -> Vector3:
	_ensure_camera()
	if _viewport == null or _camera == null:
		return plane_point
	var pixel := Vector2(uv.x * _viewport.size.x, uv.y * _viewport.size.y)
	var origin := _camera.project_ray_origin(pixel)
	var direction := _camera.project_ray_normal(pixel)
	var normal := _camera.global_basis.z.normalized()
	var plane := Plane(normal, normal.dot(plane_point))
	var hit: Variant = plane.intersects_ray(origin, direction)
	if hit is Vector3:
		return hit
	return plane_point


func _ensure_camera() -> void:
	if _camera == null:
		_camera = _find_camera()
	if _ground == null or not is_instance_valid(_ground):
		if _viewport != null:
			_ground = _viewport.find_child("Ground", true, false) as Node3D


# ─────────────────────────────────────────────
#  Asset viewer: raw animation browsing
# ─────────────────────────────────────────────

## Every animation available on the mannequin, including the weapon human-anim
## library injected by set_weapon().  Includes the hidden "library/" prefix.
func list_human_animations() -> PackedStringArray:
	var out := PackedStringArray()
	if _mannequin_animation == null:
		return out
	for name in _mannequin_animation.get_animation_list():
		if String(name).begins_with("__viewer/"):
			continue
		out.append(name)
	out.sort()
	return out


## Play [param name] on the mannequin as a raw clip.  The clip is duplicated so
## loop mode never mutates the shared GLB animation resource.
func play_human_animation(name: StringName, loop := true, speed := 1.0) -> bool:
	if _mannequin_animation == null or _tree == null:
		return false
	var resolved := _resolve_preview_animation(_mannequin_animation, name)
	if resolved == &"":
		return false
	return _play_raw_human_clip(resolved, loop, speed)


## Shared path for the human list and the weapon→human pair.  [param resolved]
## must already be an animation name present on the mannequin.
func _play_raw_human_clip(resolved: StringName, loop: bool, speed: float) -> bool:
	if _mannequin_animation == null or _tree == null:
		return false
	_raw_anim_mode = true
	_tree.active = false
	_leg_override = false
	if _leg_source_animation != null:
		_leg_source_animation.stop()
	_clear_preview_library(_mannequin_animation)
	var runtime := _register_preview_animation(_mannequin_animation, resolved, loop)
	if runtime == &"":
		_raw_anim_mode = false
		_tree.active = true
		return false
	_mannequin_animation.speed_scale = maxf(speed, 0.01)
	_mannequin_animation.play(runtime)
	render_once()
	return true


func stop_human_animation() -> void:
	_stop_raw_human_anim()
	_apply_animation_state(_weapon)
	render_once()


func _stop_raw_human_anim() -> void:
	if _raw_anim_mode and _mannequin_animation != null:
		_mannequin_animation.stop()
		_clear_preview_library(_mannequin_animation)
	_raw_anim_mode = false
	if _tree != null:
		_tree.active = true


## Live speed for whichever player is currently driving the preview.  Raw clips
## use AnimationPlayer.speed_scale; the blend tree has no speed property, so it
## switches to manual processing and is advanced from _process.
func set_animation_speed(speed: float) -> void:
	var value := maxf(speed, 0.01)
	_tree_speed = value
	if _mannequin_animation != null:
		_mannequin_animation.speed_scale = value
	var weapon_player := _weapon_anim_player()
	if weapon_player != null:
		weapon_player.speed_scale = value
	_apply_tree_speed()


func _apply_tree_speed() -> void:
	if _tree == null or not is_instance_valid(_tree):
		return
	var manual := not is_equal_approx(_tree_speed, 1.0)
	if manual and not _tree_manual:
		_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		_tree_manual = true
	elif not manual and _tree_manual:
		_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
		_tree_manual = false


func list_weapon_animations() -> PackedStringArray:
	var out := PackedStringArray()
	var player := _weapon_anim_player()
	if player == null:
		return out
	for name in player.get_animation_list():
		if String(name).begins_with("__viewer/"):
			continue
		out.append(name)
	out.sort()
	return out


func play_weapon_animation(name: StringName, loop := true, speed := 1.0) -> bool:
	var player := _weapon_anim_player()
	if player == null:
		return false
	var resolved := _resolve_preview_animation(player, name)
	if resolved == &"":
		return false
	_raw_weapon_anim = true
	if _weapon_model is WeaponModel:
		var wm := _weapon_model as WeaponModel
		if wm.anim_tree != null:
			wm.anim_tree.active = false
	_clear_preview_library(player)
	var runtime := _register_preview_animation(player, resolved, loop)
	if runtime == &"":
		_raw_weapon_anim = false
		return false
	player.speed_scale = maxf(speed, 0.01)
	player.play(runtime)
	# Play the paired human clip (shoot/reload/hold/…) in lock-step with the
	# weapon clip.  The human library is injected by _apply_animation_state.
	var human_anim := _paired_human_animation(resolved)
	_weapon_human_sync = human_anim != &"" and _play_raw_human_clip(human_anim, loop, speed)
	render_once()
	return true


func stop_weapon_animation() -> void:
	_stop_raw_weapon_anim()
	render_once()


func _stop_raw_weapon_anim() -> void:
	var had_human_sync := _weapon_human_sync
	_weapon_human_sync = false
	var player := _weapon_anim_player()
	if player != null:
		player.stop()
		player.speed_scale = 1.0
		_clear_preview_library(player)
	_raw_weapon_anim = false
	if _weapon_model is WeaponModel:
		var wm := _weapon_model as WeaponModel
		if wm.anim_tree != null:
			wm.anim_tree.active = true
		if wm.anim_player != null:
			wm.play_anim_loop(WeaponAnimGroup.AnimSlot.HOLD)
	if had_human_sync:
		_stop_raw_human_anim()


func _weapon_anim_player() -> AnimationPlayer:
	if _weapon_model == null or not is_instance_valid(_weapon_model):
		return null
	if _weapon_model is WeaponModel:
		var wm := _weapon_model as WeaponModel
		if wm.anim_player != null:
			return wm.anim_player
	var players := _weapon_model.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		return null
	return players[0] as AnimationPlayer


## Human animation paired with a weapon clip through its WeaponAnimGroup.
## Returns the fully-qualified "library/animation" path, or &"".  The library is
## already on the mannequin because _apply_animation_state injected the weapon's
## human_anims when the weapon was set.
func _paired_human_animation(gun_anim: StringName) -> StringName:
	if not (_weapon_model is WeaponModel):
		return &""
	var wm := _weapon_model as WeaponModel
	var player := _weapon_anim_player()
	var trimmed := String(gun_anim).strip_edges()
	for group in wm.anim_groups:
		if group == null:
			continue
		var candidate := group.gun_anim
		if player != null:
			var resolved := _resolve_preview_animation(player, group.gun_anim)
			if resolved != &"":
				candidate = resolved
		if String(candidate).strip_edges() != trimmed \
				and String(group.gun_anim).strip_edges() != trimmed:
			continue
		var path := wm.get_human_anim_path(group.slot)
		if path != &"":
			return path
	return &""


## Drive the real locomotion blend tree from the asset viewer's joystick and
## CROUCH/WALK/SPRINT buttons.  [param state] is -1 crouch, 0 walk, 1 sprint;
## [param direction] is the 8-way input vector (unit length or zero).  HoldBlend
## is forced to 0.0 so the preview is pure locomotion, weapon or not.
func set_locomotion_state(state: int, direction: Vector2) -> void:
	if _tree == null or _mannequin_animation == null:
		return
	_stop_raw_human_anim()
	_stop_raw_weapon_anim()
	_leg_override = false
	if _leg_source_animation != null:
		_leg_source_animation.stop()
	if _tree != null:
		_tree.active = true
	var dir := Vector2.ZERO
	if direction.length_squared() > 0.0001:
		dir = direction.normalized()
	_tree.set("parameters/WalkBlendSpace/blend_position", dir)
	_tree.set("parameters/CrouchBlendSpace/blend_position", dir)
	_tree.set("parameters/SprintBlendSpace/blend_position", dir)
	_tree.set("parameters/CrouchWalkSprintBlend3/blend_amount", float(clampi(state, -1, 1)))
	_tree.set("parameters/JumpBlend/blend_amount", 0.0)
	_tree.set("parameters/HoldBlend/blend_amount", 0.0)
	render_once()


## Resolve the authored name, tolerating the whitespace drift the imported GLB
## clip names carry (the same rule as WeaponModel._resolve_animation).
func _resolve_preview_animation(player: AnimationPlayer, name: StringName) -> StringName:
	if name == &"":
		return &""
	if player.has_animation(name):
		return name
	var stripped := String(name).strip_edges()
	for candidate in player.get_animation_list():
		if String(candidate).strip_edges() == stripped:
			return StringName(candidate)
	return &""


## Duplicate an animation into the runtime library so loop mode can be changed
## without touching the shared resource.  Returns the "library/animation" name.
func _register_preview_animation(player: AnimationPlayer, source: StringName,
		loop: bool) -> StringName:
	var src := player.get_animation(source)
	if src == null:
		return &""
	var library: AnimationLibrary = null
	if player.has_animation_library(PREVIEW_LIB):
		library = player.get_animation_library(PREVIEW_LIB)
	if library == null:
		library = AnimationLibrary.new()
		player.add_animation_library(PREVIEW_LIB, library)
	_anim_serial += 1
	var short_name := StringName("anim_%d" % _anim_serial)
	var dup := src.duplicate(true) as Animation
	if dup == null:
		return &""
	dup.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	library.add_animation(short_name, dup)
	return StringName(str(PREVIEW_LIB) + "/" + str(short_name))


func _clear_preview_library(player: AnimationPlayer) -> void:
	if player == null:
		return
	if player.has_animation_library(PREVIEW_LIB):
		player.remove_animation_library(PREVIEW_LIB)


# ─────────────────────────────────────────────
#  Player rig extraction
# ─────────────────────────────────────────────

## Instance player.tscn detached, keep only its presentation `Body` subtree,
## strip gameplay, and add it under the pivot.  Returns false if the scene shape
## is not what this expects.
func _build_player_body() -> bool:
	var player := PLAYER_SCENE.instantiate()
	var body := player.get_node_or_null("Body") as Node3D
	if body == null:
		player.free()
		return false
	player.remove_child(body)
	_strip_body(body)
	# The rest of the Player scene (controller, colliders, input, rollback) is
	# never used and must not enter the tree.
	player.free()
	_body = body
	_pivot.add_child(body)

	_mannequin = body.find_child("Mannequin", true, false) as Node3D
	if _mannequin == null:
		return false
	_mannequin_skeleton = _mannequin.find_child("Skeleton3D", true, false) as Skeleton3D
	var players := _mannequin.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		_mannequin_animation = players[0] as AnimationPlayer
	_tree = body.get_node_or_null("AnimationTree") as AnimationTree
	if _tree != null:
		# Never share the blend tree resource across instances.
		_tree.tree_root = _tree.tree_root.duplicate(true) as AnimationNodeBlendTree
		_tree.active = true
		_apply_tree_speed()
	return _mannequin_skeleton != null


## Remove everything that needs the Player parent or gameplay, before the
## subtree enters the tree so no `_ready` can dereference a missing Player.
func _strip_body(body: Node3D) -> void:
	body.set_script(null)
	var recoil := body.get_node_or_null("Recoil")
	if recoil:
		recoil.set_script(null)
	var camera := body.get_node_or_null("Recoil/Head/Camera3D")
	if camera:
		camera.get_parent().remove_child(camera)
		camera.free()
	var tilt := body.get_node_or_null("WeaponTilt")
	if tilt:
		tilt.set_script(null)
	var tree := body.get_node_or_null("AnimationTree")
	if tree:
		tree.set_script(null)
	for node_name in ["MultiplayerSynchronizer", "PlayerUI", "AmmoBarPublic",
			"HealthBarPublic", "NamePublic"]:
		var node := body.get_node_or_null(node_name)
		if node:
			body.remove_child(node)
			node.free()
	# Physical bones would simulate in the preview and carry hitboxes.
	var skeleton := body.find_child("Skeleton3D", true, false)
	var physics := skeleton.get_node_or_null("PhysicalBoneSimulator3D") if skeleton else null
	if physics:
		skeleton.remove_child(physics)
		physics.free()


## Second, hidden mannequin that only supplies the leg bones while the real tree
## is on the armed hold chain (which contains no locomotion).
func _build_leg_source() -> void:
	_leg_source = MANNEQUIN_SCENE.instantiate() as Node3D
	if _leg_source == null:
		return
	_leg_source.name = "LegPoseSource"
	_leg_source.visible = false
	if _mannequin != null:
		_leg_source.transform = _mannequin.transform
	_pivot.add_child(_leg_source)
	_leg_source_skeleton = _leg_source.find_child("Skeleton3D", true, false) as Skeleton3D
	var players := _leg_source.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		_leg_source_animation = players[0] as AnimationPlayer


func _build_leg_map() -> void:
	_leg_map = PackedInt32Array()
	if _leg_source_skeleton == null or _mannequin_skeleton == null:
		return
	_leg_map.resize(_mannequin_skeleton.get_bone_count())
	for src_idx in _mannequin_skeleton.get_bone_count():
		_leg_map[src_idx] = _leg_source_skeleton.find_bone(_mannequin_skeleton.get_bone_name(src_idx))


func _is_leg_bone(bone_name: StringName) -> bool:
	var name := String(bone_name)
	return name.contains("thigh") or name.contains("shin") \
		or name.contains("foot") or name.contains("toe")


func _hide_mannequin_meshes() -> void:
	if _mannequin == null:
		return
	for node in _mannequin.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).visible = false


# ─────────────────────────────────────────────
#  Pose mirroring (Player._copy_mannequin_pose)
# ─────────────────────────────────────────────

func _build_pose_map() -> void:
	_pose_map = PackedInt32Array()
	if _model_skeleton == null or _mannequin_skeleton == null:
		return
	_pose_map.resize(_mannequin_skeleton.get_bone_count())
	for src_idx in _mannequin_skeleton.get_bone_count():
		_pose_map[src_idx] = _model_skeleton.find_bone(_mannequin_skeleton.get_bone_name(src_idx))


func _copy_mannequin_pose() -> void:
	if _model_skeleton == null or _mannequin_skeleton == null:
		return
	var use_legs := _leg_override and _leg_source_skeleton != null and not _leg_map.is_empty()
	for src_idx in _mannequin_skeleton.get_bone_count():
		var dst_idx := _pose_map[src_idx] if src_idx < _pose_map.size() else -1
		if dst_idx < 0:
			continue
		var src_bone := src_idx
		var src_skeleton := _mannequin_skeleton
		if use_legs and _is_leg_bone(_mannequin_skeleton.get_bone_name(src_idx)):
			var leg_idx := _leg_map[src_idx] if src_idx < _leg_map.size() else -1
			if leg_idx >= 0:
				src_skeleton = _leg_source_skeleton
				src_bone = leg_idx
		_model_skeleton.set_bone_pose_position(dst_idx,
			src_skeleton.get_bone_pose_position(src_bone))
		_model_skeleton.set_bone_pose_rotation(dst_idx,
			src_skeleton.get_bone_pose_rotation(src_bone))
		_model_skeleton.set_bone_pose_scale(dst_idx,
			src_skeleton.get_bone_pose_scale(src_bone))


# ─────────────────────────────────────────────
#  AnimationTree state (subset of player/animation_tree.gd)
# ─────────────────────────────────────────────

func _apply_animation_state(weapon: Weapon) -> void:
	# A raw AnimationPlayer clip owns the skeleton while the asset viewer browses
	# animations; do not let set_weapon / show_character re-arm the blend tree.
	if _raw_anim_mode:
		return
	if _tree == null or _mannequin_animation == null:
		return

	var hold_path := &""
	if _weapon_model is WeaponModel:
		var wm := _weapon_model as WeaponModel
		var lib := wm.get_human_library_name()
		if lib != &"" and wm.human_anims != null \
				and not _mannequin_animation.has_animation_library(lib):
			_mannequin_animation.add_animation_library(lib, wm.human_anims)
		hold_path = wm.get_human_anim_path(WeaponAnimGroup.AnimSlot.HOLD)

	# The hold chain's animation node, exactly as WeaponController._set_hold_anim.
	var root := _tree.tree_root as AnimationNodeBlendTree
	if root != null and root.has_node("HoldAnim"):
		var hold_node := root.get_node("HoldAnim") as AnimationNodeAnimation
		if hold_node != null and hold_path != &"":
			hold_node.animation = hold_path

	# A weapon with its own human hold animation uses the exact in-game armed
	# pose (arms on the weapon — the same HoldBlend 1 the Player uses in combat).
	# That chain has no locomotion, so while walking/running the legs are taken
	# from the hidden leg source instead (see _copy_mannequin_pose).
	var armed_hold: bool = hold_path != &"" \
		and _mannequin_animation.has_animation(hold_path)
	var standing := _mode == PreviewMode.STANDING
	var running := _mode == PreviewMode.RUNNING
	_leg_override = armed_hold and not standing \
		and _leg_source_skeleton != null and _leg_source_animation != null

	# Forward walk; the rig has no velocity, so feed the blend spaces directly.
	var blend_pos := Vector2.ZERO if standing else WALK_FORWARD
	_tree.set("parameters/WalkBlendSpace/blend_position", blend_pos)
	_tree.set("parameters/CrouchBlendSpace/blend_position", blend_pos)
	_tree.set("parameters/SprintBlendSpace/blend_position", blend_pos)
	_tree.set("parameters/CrouchWalkSprintBlend3/blend_amount", 1.0 if running and not armed_hold else 0.0)
	_tree.set("parameters/JumpBlend/blend_amount", 0.0)
	# 0 = locomotion (walk/sprint), 1 = the weapon-hold / one-shot chain.
	_tree.set("parameters/HoldBlend/blend_amount", 1.0 if armed_hold else 0.0)

	if _leg_source_animation != null:
		if _leg_override:
			var leg_clip := &"sprint/sprint_w" if running else &"walk/walk_w"
			if _leg_source_animation.has_animation(leg_clip):
				_leg_source_animation.play(leg_clip)
		else:
			_leg_source_animation.stop()

	# The weapon model runs its own paired hold/idle animation.
	if _weapon_model is WeaponModel:
		(_weapon_model as WeaponModel).play_anim_loop(WeaponAnimGroup.AnimSlot.HOLD)


# ─────────────────────────────────────────────
#  Weapon mount (WeaponController.spawn_weapon_model)
# ─────────────────────────────────────────────

func _attach_weapon(weapon: Weapon) -> void:
	if _mannequin_skeleton == null:
		return
	_gun_attach = _mannequin_skeleton.get_node_or_null("GunAttach") as BoneAttachment3D
	if _gun_attach == null or not is_instance_valid(_gun_attach):
		_gun_attach = BoneAttachment3D.new()
		_gun_attach.name = "GunAttach"
		_gun_attach.bone_name = BONE_NAME
		_gun_attach.transform = BONE_ATTACH_TRANSFORM
		_mannequin_skeleton.add_child(_gun_attach)
	_weapon_mount = _gun_attach.get_node_or_null("GunAttach") as Node3D
	if _weapon_mount == null:
		_weapon_mount = Node3D.new()
		_weapon_mount.name = "GunAttach"
		_weapon_mount.transform = INNER_MOUNT_TRANSFORM
		_gun_attach.add_child(_weapon_mount)

	var instance := weapon.weapon_model.instantiate() as Node3D
	if instance == null:
		return
	instance.position = weapon.weapon_offset
	instance.rotation = weapon.weapon_rotation
	instance.scale = weapon.weapon_scale
	if instance is WeaponModel:
		_weapon_mount.add_child(instance)
	else:
		# Legacy scenes are authored relative to the hand bone — same correction
		# WeaponController.spawn_weapon_model applies.
		instance.position += Vector3(-0.2, 0.1, 0.5)
		instance.rotation.y = deg_to_rad(180)
		_gun_attach.add_child(instance)
	_weapon_model = instance
	WEAPON_TOON_CONVERTER.apply(_weapon_model, WEAPON_TOON_PRESET)
	if _ghost:
		_apply_ghost_material(_weapon_model)


## Blue hologram look for the hover preview: replaces every mesh material with
## an unlit translucent blue + emission, so the model reads as a projection of
## the agent that is not selected yet.
func _apply_ghost_material(root: Node3D) -> void:
	if _ghost_material == null:
		_ghost_material = StandardMaterial3D.new()
		_ghost_material.albedo_color = Color(0.22, 0.68, 1.0, 0.18)
		_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_material.emission_enabled = true
		_ghost_material.emission = Color(0.16, 0.60, 1.0)
		_ghost_material.emission_energy_multiplier = 1.7
		_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Light-bleed edges sell the projection without hiding the silhouette.
		_ghost_material.rim_enabled = true
		_ghost_material.rim = 0.6
		_ghost_material.rim_tint = 0.3
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		var geo := node as GeometryInstance3D
		geo.transparency = 0.0
		geo.material_override = _ghost_material


func _clear_weapon() -> void:
	if _weapon_model != null and is_instance_valid(_weapon_model):
		var parent := _weapon_model.get_parent()
		if parent != null:
			parent.remove_child(_weapon_model)
		_weapon_model.queue_free()
	_weapon_model = null


# ─────────────────────────────────────────────
#  Camera framing / zoom
# ─────────────────────────────────────────────

## Frame the camera on the character bounds only.  Including the weapon would
## re-zoom the preview on every hover.
func _frame_camera(box: AABB) -> void:
	_camera = _find_camera()
	if _camera == null:
		return
	var radius := box.size.length() * 0.5
	var fov := deg_to_rad(_camera.fov)
	_base_distance = radius / tan(fov * 0.5)
	_base_distance = maxf(_base_distance * 1.02, radius + 0.4)
	_place_ground(box)
	_apply_camera()


## Orbit the camera on a sphere around the model.  The rig itself is never
## rotated, so the horizon and the ground grid stay level.
func _apply_camera() -> void:
	if _camera == null:
		return
	var distance := _base_distance * _zoom
	var cos_pitch := cos(_orbit_pitch)
	_camera.position = _focus + Vector3(
		sin(_orbit_yaw) * cos_pitch * distance,
		sin(_orbit_pitch) * distance,
		-cos(_orbit_yaw) * cos_pitch * distance)
	_camera.look_at(_focus)


func _place_ground(box: AABB) -> void:
	if _viewport == null:
		return
	if _ground == null or not is_instance_valid(_ground):
		_ground = _viewport.find_child("Ground", true, false) as Node3D
	_floor_y = -box.size.y * 0.5
	if _ground != null:
		_ground.position = Vector3(_pan.x, _floor_y + _pan.y, 0.0)


func _find_camera() -> Camera3D:
	if _viewport == null:
		return null
	return _viewport.find_child("Camera3D", true, false) as Camera3D


func _visual_aabb(root: Node3D) -> AABB:
	var box := AABB()
	if root is VisualInstance3D:
		var aabb: AABB = (root as VisualInstance3D).get_aabb()
		if aabb.size.length_squared() > 0.0:
			box = box.merge(aabb)
	for child in root.get_children():
		if not child is Node3D:
			continue
		var child_box := _visual_aabb(child as Node3D)
		if child_box.size.length_squared() > 0.0:
			box = box.merge(_aabb_transformed(child_box, (child as Node3D).transform))
	return box


func _aabb_transformed(aabb: AABB, xform: Transform3D) -> AABB:
	var out := AABB()
	out = out.expand(xform * aabb.position)
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, 0, 0)))
	out = out.expand(xform * (aabb.position + Vector3(0, aabb.size.y, 0)))
	out = out.expand(xform * (aabb.position + Vector3(0, 0, aabb.size.z)))
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, aabb.size.y, 0)))
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, 0, aabb.size.z)))
	out = out.expand(xform * (aabb.position + Vector3(0, aabb.size.y, aabb.size.z)))
	out = out.expand(xform * (aabb.position + aabb.size))
	return out
