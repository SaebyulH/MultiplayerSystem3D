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
const ZOOM_MIN := 0.55
const ZOOM_MAX := 1.8
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


func _ready() -> void:
	_viewport = get_viewport() as SubViewport
	_render_timer = Timer.new()
	_render_timer.wait_time = RENDER_INTERVAL
	_render_timer.timeout.connect(render_once)
	add_child(_render_timer)
	_render_timer.start()


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
	_zoom = clampf(_zoom - steps * 0.1, ZOOM_MIN, ZOOM_MAX)
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


## Right-drag: pan the character in the camera plane.
func pan(delta_x: float, delta_y: float) -> void:
	if is_zero_approx(delta_x) and is_zero_approx(delta_y):
		return
	_pan.x = clampf(_pan.x - delta_x * 0.004, -3.0, 3.0)
	_pan.y = clampf(_pan.y - delta_y * 0.004, -3.0, 3.0)
	_apply_pan()
	render_once()


func _apply_pan() -> void:
	if _pivot != null:
		_pivot.position = _center_offset + Vector3(_pan.x, _pan.y, 0.0)
	# The floor travels with the agent so panning never leaves it floating.
	if _ground != null and is_instance_valid(_ground):
		_ground.position = Vector3(_pan.x, _floor_y + _pan.y, 0.0)


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
	_model = null
	_model_skeleton = null
	_gun_attach = null
	_weapon_mount = null
	_pose_map = PackedInt32Array()


func get_displayed_weapon() -> Weapon:
	return _weapon


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
	_camera.position = Vector3(
		sin(_orbit_yaw) * cos_pitch * distance,
		sin(_orbit_pitch) * distance,
		-cos(_orbit_yaw) * cos_pitch * distance)
	_camera.look_at(Vector3.ZERO)


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
