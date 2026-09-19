@tool
extends Node
## One-shot tool that pre-renders every character's 3D model into a square
## full-colour PNG portrait.
##
## Unlike the kill-feed icon generator there is no grayscale/alpha
## post-process pass: portraits keep their real materials, rendered over a
## transparent background.
##
## Each model can ship its own camera — the first Camera3D found anywhere
## inside the model scene is used as-is.  If there is no camera, a default one
## is placed in front of the model and framed on the head and shoulders.
##
## HOW TO USE:
##   1. Open this scene (player/character_portrait_generator.tscn).
##   2. Press F6 (Run Current Scene) — portraits are generated, then the scene
##      auto-quits after 0.5 seconds.
##
## Re-run whenever you add or change a character model.

const OUTPUT_DIR := "res://character_portraits"
const PORTRAIT_SIZE := 256

# ── default-camera framing ────────────────────────────────────────────

## FOV for the fallback camera (matches world/character_subviewport_preview.tscn).
const DEFAULT_FOV := 30.0

## Fraction of the frame the bust should fill (1.0 = edge to edge).
const FRAME_FILL := 0.85

## Head-and-shoulders framing ratios, all relative to the model's visual AABB.
const BUST_HEIGHT_FRACTION := 0.4
const BUST_CENTER_OFFSET := 0.35
const SHOULDER_WIDTH_FRACTION := 0.6
const HEAD_FALLBACK_FRACTION := 0.85
const MIN_BUST_HEIGHT := 0.35

# ── lighting (mirrors character_subviewport_preview.tscn) ─────────────

const AMBIENT_ENERGY := 0.7
const KEY_ENERGY := 1.3
const FILL_ENERGY := 2.0
const RIM_ENERGY := 1.5


var _started := false
var _character_files: Array[String] = []
var _character_index := 0
var _generated := 0
var _done := false


func _ready() -> void:
	if _started:
		return
	if Engine.is_editor_hint():
		print("Character Portrait Generator attached. Press F6 to run.")
		return

	_started = true
	print("──────────────────────────────────────────")
	print("Character Portrait Generator — %dx%d portraits" % [PORTRAIT_SIZE, PORTRAIT_SIZE])
	print("──────────────────────────────────────────")

	if DirAccess.make_dir_recursive_absolute(OUTPUT_DIR) != OK:
		printerr("Failed to create: ", OUTPUT_DIR)
		get_tree().quit(1)
		return

	_find_character_files("res://player/characters", _character_files)
	print("Found %d character .tres files." % _character_files.size())

	if _character_files.is_empty():
		print("Nothing to do.")
		get_tree().quit()
		return

	_process_next()


func _process_next() -> void:
	if _done:
		return

	if _character_index >= _character_files.size():
		_finish()
		return

	var file_path := _character_files[_character_index]
	_character_index += 1

	var character: Character = load(file_path) as Character
	if not character or not character.character_scene:
		print("  SKIP %s" % file_path)
		_process_next.call_deferred()
		return

	var portrait_name := _safe_filename(character.character_name) + ".png"
	var portrait_path := OUTPUT_DIR + "/" + portrait_name

	print("  %s  →  %s …" % [character.character_name, portrait_path])

	var vp := _build_viewport(character)
	add_child(vp)

	# Defer the capture so the SubViewport gets at least one full render
	# cycle in the tree before we try to grab its texture.
	_capture_deferred.call_deferred(vp, character, file_path, portrait_path)


# ── viewport builder ─────────────────────────────────────────────────


func _build_viewport(character: Character) -> SubViewport:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.handle_input_locally = false
	vp.size = Vector2i(PORTRAIT_SIZE, PORTRAIT_SIZE)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.transparent_bg = true

	var root := Node3D.new()
	root.name = "PortraitRoot"
	vp.add_child(root)

	# The portrait is a static pose — disable processing so nothing on the
	# model (animations, jigglebones, scripts) ticks while it renders.
	var model: Node3D = character.character_scene.instantiate()
	model.process_mode = Node.PROCESS_MODE_DISABLED
	model.position = Vector3.ZERO
	root.add_child(model)

	var cam := _resolve_camera(model, root)

	# The viewport has its own World3D, so without lights the model would
	# render black. Light it and give the camera an environment.
	_add_lighting(root, cam)

	return vp


## Uses the first Camera3D found inside the model (an author pre-positioned it),
## or builds a default head-and-shoulders camera if there is none.
func _resolve_camera(model: Node3D, root: Node3D) -> Camera3D:
	var cameras := model.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		return cameras[0] as Camera3D

	var cam := _build_default_camera(model)
	root.add_child(cam)
	return cam


func _build_default_camera(model: Node3D) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "PortraitCamera"
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = DEFAULT_FOV

	_pose_model(model)

	# Model-local bounds. The model sits at identity, so local == world.
	var box := _visual_aabb(model)
	if box.size.length_squared() <= 0.0001:
		box = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.8, 1.0))

	var head_y := _find_head_y(model, box)

	var bust_height := maxf(box.size.y * BUST_HEIGHT_FRACTION, MIN_BUST_HEIGHT)
	var bust_center := Vector3(0.0, head_y - bust_height * BUST_CENTER_OFFSET, 0.0)

	# Frame the square on the larger of the bust height and an estimated
	# shoulder width, so narrow heads don't get clipped at the sides.
	var frame_size := maxf(bust_height, box.size.x * SHOULDER_WIDTH_FRACTION)
	var distance := (frame_size * 0.5) / tan(deg_to_rad(cam.fov) * 0.5) * FRAME_FILL

	# Camera in front (-Z side) looking toward +Z, matching the loadout preview.
	cam.position = Vector3(0.0, bust_center.y, -distance)
	cam.look_at(bust_center)
	return cam


## Freezes the model on an idle pose if it has one, so the portrait isn't a
## T-pose. Poses are applied via seek() so this works even with processing off.
func _pose_model(model: Node3D) -> void:
	var anims := model.find_children("*", "AnimationPlayer", true, false)
	if anims.is_empty():
		return
	var anim := anims[0] as AnimationPlayer

	var anim_name := ""
	if anim.has_animation("walk/idle"):
		anim_name = "walk/idle"
	elif anim.has_animation("walk/walk_w"):
		anim_name = "walk/walk_w"
	if anim_name == "":
		return

	anim.play(anim_name)
	anim.seek(anim.current_animation_length * 0.5, true)
	anim.pause()


## Returns the model-local Y of the head bone, or a top-of-AABB estimate when
## no Skeleton3D / head bone is present.
func _find_head_y(model: Node3D, box: AABB) -> float:
	var skel := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		var bone := skel.find_bone("DEF-head")
		if bone == -1:
			for i in skel.get_bone_count():
				if "head" in skel.get_bone_name(i).to_lower():
					bone = i
					break
		if bone != -1:
			return skel.get_bone_global_pose(bone).origin.y

	return box.position.y + box.size.y * HEAD_FALLBACK_FRACTION


# ── lighting ──────────────────────────────────────────────────────────


## Ambient fill plus a key light and two rim/fill omnis, matching the loadout
## preview rig. Background stays transparent.
func _add_lighting(root: Node3D, cam: Camera3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = AMBIENT_ENERGY
	cam.environment = env

	var key := DirectionalLight3D.new()
	key.name = "KeyLight"
	key.rotation_degrees = Vector3(-35.0, 45.0, 0.0)
	key.light_energy = KEY_ENERGY
	key.shadow_enabled = false
	root.add_child(key)

	var fill := OmniLight3D.new()
	fill.name = "FillLight"
	fill.position = Vector3(-2.0, 1.2, -2.0)
	fill.light_energy = FILL_ENERGY
	fill.shadow_enabled = false
	root.add_child(fill)

	var rim := OmniLight3D.new()
	rim.name = "RimLight"
	rim.position = Vector3(2.0, 1.0, -1.0)
	rim.light_color = Color(0.6, 0.7, 1.0)
	rim.light_energy = RIM_ENERGY
	rim.shadow_enabled = false
	root.add_child(rim)


# ── visual AABB (from world/loadout_menu.gd) ─────────────────────────


func _visual_aabb(root: Node3D) -> AABB:
	var box := AABB()
	if root is VisualInstance3D:
		var aabb := (root as VisualInstance3D).get_aabb()
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


# ── capture / save ───────────────────────────────────────────────────


func _capture_deferred(
	vp: SubViewport,
	character: Character,
	file_path: String,
	portrait_path: String
) -> void:
	# SubViewport with UPDATE_ONCE renders on the first frame after being
	# added to the tree. Two process_frame waits guarantee the render has
	# completed and the texture buffer is populated before we read it.
	await get_tree().process_frame
	await get_tree().process_frame

	var tex := vp.get_texture()

	if not tex:
		print("    FAILED (no texture — viewport may be empty)")
		_cleanup_and_next(vp)
		return

	var img := tex.get_image()

	if not img:
		print("    FAILED (get_image returned null)")
		_cleanup_and_next(vp)
		return

	remove_child(vp)
	vp.queue_free()

	if img.save_png(portrait_path) != OK:
		print("    FAILED (save PNG to %s)" % portrait_path)
		_process_next.call_deferred()
		return

	# Build an ImageTexture directly from the image we already have in memory,
	# then claim the PNG path via take_over_path(). This avoids a
	# save-then-reload round-trip that fails on Windows when ResourceLoader
	# tries to open the file before the OS has flushed it.
	var portrait_tex := ImageTexture.create_from_image(img)
	portrait_tex.take_over_path(portrait_path)

	character.portrait = portrait_tex

	if ResourceSaver.save(character, file_path) != OK:
		print("    FAILED (save .tres to %s)" % file_path)
		_process_next.call_deferred()
		return

	_generated += 1
	print("    OK")

	_process_next.call_deferred()


func _cleanup_and_next(vp: SubViewport) -> void:
	remove_child(vp)
	vp.queue_free()
	_process_next.call_deferred()


func _finish() -> void:
	if _done:
		return

	_done = true

	print("──────────────────────────────────────────")
	print("Done — %d portraits written to %s/" % [_generated, OUTPUT_DIR])
	print("Re-open any open .tres files to see the new portrait field.")
	print("──────────────────────────────────────────")

	get_tree().create_timer(0.5).timeout.connect(
		func(): get_tree().quit()
	)


# ── filesystem helpers ───────────────────────────────────────────────


## Recursively collects every .tres under [dir] that loads as a Character.
func _find_character_files(dir: String, out_files: Array[String]) -> void:
	var d := DirAccess.open(dir)

	if not d:
		return

	d.include_hidden = false
	d.include_navigational = false
	d.list_dir_begin()

	var entry := d.get_next()

	while entry != "":
		var full := dir + "/" + entry

		if d.current_is_dir():
			_find_character_files(full, out_files)

		elif entry.ends_with(".tres"):
			var res := load(full)

			if res is Character:
				out_files.append(full)

		entry = d.get_next()

	d.list_dir_end()


func _safe_filename(s: String) -> String:
	var out := ""

	for ch in s.to_lower():
		if ch == " ":
			out += "_"
		elif ch.is_valid_identifier() or ch == "_":
			out += ch

	return out.lstrip("_").rstrip("_")
