class_name SpectatorController
extends Node3D

## Local-only spectator camera + target cycling.
##
## Created by world_1.gd beside the dev menu (a sibling of SpawnParent, never
## replicated).  It does nothing until the local player's replicated
## `is_spectating` flag turns on, then renders from a dedicated camera that
## follows the selected player's replicated first-person camera transform.
##
## Controls (handled here, not by PlayerInput, which is gated off while
## spectating): LMB next target, RMB previous, F first/third person, Esc exit.
##
## The camera is deliberately a separate Camera3D rather than making a remote
## player's camera current: `Player.spawn()/despawn()` rewrites `current` on
## every peer, and the target's third-person rig is not replicated.  Following
## the first-person camera's live transform works for humans and bots alike.

const THIRD_PERSON_LENGTH := 3.0
const THIRD_PERSON_MARGIN := 0.2
const THIRD_PERSON_RADIUS := 0.25

## Run after the players (and their camera_3d.gd trackers) have updated.
const PROCESS_PRIORITY := 100

var _arm: SpringArm3D
var _cam: Camera3D

var _overlay: CanvasLayer
var _title: Label
var _hint: Label

var _local: Player = null
var _target: Player = null
var _targets: Array[Player] = []
var _third_person := false
var _active := false
## Last camera transform the local player had while spawned.  Used when
## spectator mode starts with nobody to watch, so the view still has a camera
## (despawn() turns the player's own cameras off).
var _fallback_transform := Transform3D(Basis.IDENTITY, Vector3(0, 12, 0))


func _ready() -> void:
	process_priority = PROCESS_PRIORITY
	_build_rig()
	_build_overlay()


# ─────────────────────────────────────────────────────────────
#  Per-frame
# ─────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	var local := _local_player()
	var active := local != null and is_instance_valid(local) and local.is_spectating
	if active != _active:
		_set_active(active)
	if not _active:
		_cache_free_camera(local)
		return

	# Keep cycling reliable even if the mouse was released by a menu.
	if not PlayerInput.ui_open and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	_ensure_target()
	_update_overlay()

	if _target != null and is_instance_valid(_target) and _target.spawned:
		_apply_camera(_target)


func _set_active(active: bool) -> void:
	_active = active
	_overlay.visible = active

	if not active:
		_unbind_target()
		_targets.clear()
		return

	_third_person = false
	_target = null
	_targets.clear()
	_ensure_target()
	if _target != null:
		_apply_camera(_target)
	else:
		# No one to watch: still own the viewport, or despawn()'s camera-off
		# would leave the screen with no current camera at all.
		_show_fallback_camera()
	# The dev menu closes itself when the toggle turns on, which captures the
	# mouse; this covers entering while it was already closed.
	if not PlayerInput.ui_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _cache_free_camera(local: Player) -> void:
	if local == null or not is_instance_valid(local) or not local.spawned:
		return
	var cam := local.camera as Camera3D
	if cam != null:
		_fallback_transform = cam.global_transform


func _show_fallback_camera() -> void:
	_arm.global_transform = _fallback_transform
	_arm.spring_length = 0.0
	_cam.fov = 90.0
	if not _cam.current:
		_cam.make_current()


func _apply_camera(target: Player) -> void:
	var src := target.camera as Camera3D
	if src == null:
		return
	_arm.global_transform = Transform3D(src.global_transform.basis, src.global_position)
	_arm.spring_length = THIRD_PERSON_LENGTH if _third_person else 0.0
	_cam.fov = src.fov
	if not _cam.current:
		_cam.make_current()
	# First person sits inside the head, so hide the target's head meshes.
	# Re-applied every frame: a model rebuild or a ghost-tier repaint can
	# otherwise re-show them; it is an idempotent loop over a handful of meshes.
	target._set_own_head_visible(_third_person)


# ─────────────────────────────────────────────────────────────
#  Target selection
# ─────────────────────────────────────────────────────────────

## The local peer's own Player.  Cached: `find_player()` is a linear scan and
## this runs per frame; it is only re-resolved before the node exists.
func _local_player() -> Player:
	if _local == null or not is_instance_valid(_local):
		_local = GameManager.find_player(str(multiplayer.get_unique_id()))
	return _local


## Every player this peer may watch right now: alive, not itself spectating,
## and not the local player.  Sorted by node name for deterministic cycling.
func _collect_targets() -> Array[Player]:
	var out: Array[Player] = []
	if not is_instance_valid(GameManager.spawn_parent):
		return out
	var local := _local_player()
	for child in GameManager.spawn_parent.get_children():
		var p := child as Player
		if p == null or p == local or p.is_spectating or not p.spawned:
			continue
		out.append(p)
	out.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return out


## Refresh the list and keep the current target if it is still valid; otherwise
## advance to the next player by name (or the first when none is left).
func _ensure_target() -> void:
	# The common case: the target is still alive and playing, so nothing to do.
	# `_targets` is only needed to pick the next one; _cycle() and the invalid
	# path below rebuild it.
	if _target != null and is_instance_valid(_target) and _target.spawned \
			and not _target.is_spectating and _target != _local_player():
		return

	_targets = _collect_targets()
	var next: Player = null
	if not _targets.is_empty():
		next = _targets[0]
		if _target != null and is_instance_valid(_target):
			var old_name := String(_target.name)
			for p in _targets:
				if String(p.name) > old_name:
					next = p
					break
	_set_target(next)


func _set_target(target: Player) -> void:
	# A freed target compares equal to null, so it must be checked explicitly —
	# otherwise a dead bot could leave the dangling reference in place forever.
	if target == _target and (target == null or is_instance_valid(target)):
		return
	if is_instance_valid(_target):
		_unbind_target()
	else:
		# The old target was freed (disconnect / bot removal): drop the viewer
		# reference too, or _update_visibility would keep a dangling pointer.
		var old_local := _local_player()
		if old_local != null and old_local.spectator_target == _target:
			old_local.spectator_target = null
		_target = null
	_target = target
	if _target == null:
		return
	var local := _local_player()
	if local != null:
		local.spectator_target = _target
	var hud := _target.get_node_or_null("Body/PlayerUI") as PlayerBodyUI
	if hud != null:
		hud.set_spectator_active(true)


func _unbind_target() -> void:
	if _target != null and is_instance_valid(_target):
		# Restore the head for the next viewer / when leaving spectator mode.
		_target._set_own_head_visible(true)
		var hud := _target.get_node_or_null("Body/PlayerUI") as PlayerBodyUI
		if hud != null:
			hud.set_spectator_active(false)
	var local := _local_player()
	if local != null and local.spectator_target == _target:
		local.spectator_target = null
	_target = null


func _cycle(dir: int) -> void:
	_targets = _collect_targets()
	if _targets.is_empty():
		_set_target(null)
		return
	var idx := _targets.find(_target)
	if idx < 0:
		idx = 0 if dir > 0 else _targets.size() - 1
	else:
		idx = posmod(idx + dir, _targets.size())
	_set_target(_targets[idx])


# ─────────────────────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	# Menus keep ownership of the mouse/keyboard while open.
	if not _active or PlayerInput.ui_open:
		return

	if event.is_action_pressed("primary_fire"):
		_cycle(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("secondary_fire"):
		_cycle(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_camera"):
		_third_person = not _third_person
		if _target != null and is_instance_valid(_target):
			_apply_camera(_target)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		var local := _local_player()
		if local != null:
			local.dev_set_spectating(false)
		get_viewport().set_input_as_handled()


# ─────────────────────────────────────────────────────────────
#  Construction
# ─────────────────────────────────────────────────────────────

func _build_rig() -> void:
	_arm = SpringArm3D.new()
	_arm.name = "SpectatorSpringArm"
	_arm.spring_length = 0.0
	_arm.margin = THIRD_PERSON_MARGIN
	# World geometry only; player bodies must not push the spectator camera.
	_arm.collision_mask = 1
	var shape := SphereShape3D.new()
	shape.radius = THIRD_PERSON_RADIUS
	_arm.shape = shape
	add_child(_arm)

	_cam = Camera3D.new()
	_cam.name = "SpectatorCamera"
	_cam.fov = 90.0
	_cam.current = false
	_arm.add_child(_cam)


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.name = "SpectatorOverlay"
	_overlay.layer = 4
	_overlay.visible = false
	add_child(_overlay)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(root)

	var top := CenterContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = 16.0
	top.offset_bottom = 108.0
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(vb)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	_title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
	_title.add_theme_constant_override("outline_size", 6)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_title)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	_hint.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
	_hint.add_theme_constant_override("outline_size", 4)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_hint)


func _update_overlay() -> void:
	_overlay.visible = not PlayerInput.ui_open
	if _target == null or not is_instance_valid(_target):
		_title.text = "SPECTATING"
		_hint.text = "No players to spectate"
		return
	_title.text = "SPECTATING  %s" % String(_target.name)
	_hint.text = "%s   ·   LMB / RMB switch   ·   F first/third   ·   Esc exit" % [
		"THIRD PERSON" if _third_person else "FIRST PERSON",
	]
