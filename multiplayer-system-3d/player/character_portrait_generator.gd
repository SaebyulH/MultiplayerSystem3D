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
## LIGHTING: the character .tscn files carry no lights and no WorldEnvironment,
## so what you see when you open one in the editor is Godot's per-scene *preview*
## sun and environment.  That is editor metadata, not scene data, and this tool
## reads it back out of res://.godot/editor/ and rebuilds it as real nodes in the
## portrait's own World3D — see _load_preview_settings().  A model that ever
## ships its own WorldEnvironment or DirectionalLight3D keeps it instead.
##
## Because .godot/ is gitignored, this is machine-local: off this machine the
## lookup falls through to a plain white sun.  docs/05-known-issues.md #58.
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

# ── lighting: the scene's editor preview sun + environment ────────────

## Where the editor keeps its per-scene state.  The file for a scene is
## "<file name>-editstate-<md5 of the scene's res:// path>.cfg".
const EDITSTATE_DIR := "res://.godot/editor"

## Frames to let the SubViewport render before its texture is read.  The sky
## radiance bake happens inside the same render pass as the opaque geometry, so
## one render is already enough; the second frame is margin.
const RENDER_SETTLE_FRAMES := 2

## Node3DEditor::_load_default_preview_settings() — the last resort for a scene
## with no editstate file at all.  Keys match "preview_sun_env" exactly.
const DEFAULT_PREVIEW := {
	"environ_enabled": true,
	"environ_energy": 1.0,
	"environ_sky_color": Color(0.385, 0.454, 0.55),
	"environ_ground_color": Color(0.2, 0.169, 0.133),
	"environ_glow_enabled": true,
	"environ_tonemap_enabled": true,
	"environ_ao_enabled": false,
	"environ_gi_enabled": false,
	"sun_enabled": true,
	"sun_color": Color.WHITE,
	"sun_energy": 1.0,
	"sun_rotation": Vector2(-1.0471976, 2.6179938),
	"sun_shadow_max_distance": 100.0,
}


var _started := false
var _character_files: Array[String] = []
var _character_index := 0
var _generated := 0
var _done := false

## Which editstate file the current portrait's lighting came from, for the
## per-character log line.
var _editstate_source := "<engine defaults>"


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

	# The viewport has its own World3D, so the model would render black without
	# lights. Reproduce whatever the editor shows for this model's scene.
	_apply_lighting(root, cam, model, _load_preview_settings(character.character_scene.resource_path))

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


## Gives the portrait the editor's preview lighting for [model], unless the
## model scene authored its own.  Mirrors the engine's precedence: the preview
## is only a fallback for a scene with no WorldEnvironment and no
## DirectionalLight3D — which is every character model today.
func _apply_lighting(root: Node3D, cam: Camera3D, model: Node3D, s: Dictionary) -> void:
	var env_desc := "authored"

	# Camera3D.environment outranks a WorldEnvironment in Godot, and a
	# WorldEnvironment inside the model already belongs to this SubViewport's
	# own World3D — so both cases are simply left where they are.
	var has_authored_env := (
		cam.environment != null
		or not model.find_children("*", "WorldEnvironment", true, false).is_empty()
	)

	if has_authored_env:
		pass
	elif s["environ_enabled"]:
		cam.environment = _build_preview_environment(s)
		env_desc = "sky=%s ground=%s e=%.2f" % [
			Color(s["environ_sky_color"]).to_html(false),
			Color(s["environ_ground_color"]).to_html(false),
			s["environ_energy"],
		]
	else:
		env_desc = "off"

	var sun_desc := "authored"

	# The engine only suppresses the preview sun for a DirectionalLight3D; an
	# OmniLight3D in the scene does not count.
	var has_authored_sun := not model.find_children("*", "DirectionalLight3D", true, false).is_empty()

	if has_authored_sun:
		pass
	elif s["sun_enabled"]:
		var sun := _build_preview_sun(s)
		root.add_child(sun)
		var fwd := -sun.transform.basis.z
		sun_desc = "sun %s e=%.2f fwd=(%.2f, %.2f, %.2f)" % [
			sun.light_color.to_html(false),
			sun.light_energy,
			fwd.x, fwd.y, fwd.z,
		]
	else:
		sun_desc = "off"

	# Diagnose from the log, not only from the pixels: a missing .godot/editor
	# file or a wrong sun rotation still produces a plausible-looking portrait.
	print("    lighting: %s | %s | %s | glow=%s tonemap=%s ao=%s gi=%s" % [
		_editstate_source.trim_prefix(EDITSTATE_DIR + "/"),
		sun_desc,
		env_desc,
		s["environ_glow_enabled"],
		s["environ_tonemap_enabled"],
		s["environ_ao_enabled"],
		s["environ_gi_enabled"],
	])


## The editor's preview sun: a shadow-casting DirectionalLight3D.  The stored
## rotation is (pitch, yaw) in radians and the engine applies it with
## Basis::from_euler(Vector3(x, y, 0)) — the same YXZ order Node3D.rotation uses,
## so assigning rotation directly is exact.
func _build_preview_sun(s: Dictionary) -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "PreviewSun"

	var rot: Vector2 = s["sun_rotation"]
	sun.rotation = Vector3(rot.x, rot.y, 0.0)

	sun.light_color = s["sun_color"]
	sun.light_energy = s["sun_energy"]

	# Both hardcoded on the engine's preview sun rather than stored in the cfg.
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = s["sun_shadow_max_distance"]

	return sun


## The editor's preview environment, reproducing what Node3DEditor::
## _preview_settings_changed() configures: a procedural sky that drives the
## ambient light, plus the glow / tonemap / AO / GI toggles.
##
## background_mode stays BG_CLEAR_COLOR so the render keeps its alpha — Godot
## skips the sky draw whenever the viewport is transparent, leaving the sky to
## act purely as a light source.  Reading the ambient from the sky rather than
## from the background (as the editor does) is deliberate: BG would make the
## ambient depend on background_mode, and both paths read the same radiance
## cubemap, so the light contribution is identical.
func _build_preview_environment(s: Dictionary) -> Environment:
	var sky_color: Color = s["environ_sky_color"]
	var ground_color: Color = s["environ_ground_color"]

	var hz := _preview_horizon_color(sky_color, ground_color)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.energy_multiplier = s["environ_energy"]
	sky_mat.sky_top_color = sky_color
	sky_mat.sky_horizon_color = hz
	sky_mat.ground_bottom_color = ground_color
	sky_mat.ground_horizon_color = hz

	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssao_enabled = s["environ_ao_enabled"]
	env.glow_enabled = s["environ_glow_enabled"]
	# SDFGI cannot converge within the single frame this tool renders; no
	# character turns it on today, so it is mapped faithfully and left there.
	env.sdfgi_enabled = s["environ_gi_enabled"]

	if s["environ_tonemap_enabled"]:
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	else:
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	return env


## The engine's derived horizon colour, copied from _preview_settings_changed():
## midway between sky and ground, then pulled halfway toward its own luminance.
func _preview_horizon_color(sky_color: Color, ground_color: Color) -> Color:
	var hz := sky_color.lerp(ground_color, 0.5)
	var lum := hz.get_luminance() * 3.333
	return hz.lerp(Color(lum, lum, lum), 0.5)


# ── editor preview settings ───────────────────────────────────────────


## The preview sun/environment the editor would show for [scene_path], laid over
## the engine defaults.  Always returns every DEFAULT_PREVIEW key.
func _load_preview_settings(scene_path: String) -> Dictionary:
	var out := {}
	for key in DEFAULT_PREVIEW:
		out[key] = DEFAULT_PREVIEW[key]

	var found := _read_editstate_preview(scene_path)
	for key in found:
		# A type mismatch means the file is not the schema we expect; keep the
		# default rather than a value we cannot use.
		if out.has(key) and typeof(found[key]) == typeof(DEFAULT_PREVIEW[key]):
			out[key] = found[key]

	return out


## The newest usable editstate file's preview_sun_env, or {} if none parse.
func _read_editstate_preview(scene_path: String) -> Dictionary:
	for path in _editstate_candidates(scene_path):
		var parsed := _parse_editstate(path)
		if not parsed.is_empty():
			_editstate_source = path
			return parsed

	_editstate_source = "<engine defaults>"
	return {}


## Editstate paths for [scene_path], best first: the exact hash the editor
## derives from the scene's res:// path, then any other file left behind for a
## scene of the same file name (a renamed or moved scene keeps its old one).
func _editstate_candidates(scene_path: String) -> PackedStringArray:
	var out := PackedStringArray()

	if scene_path.is_empty():
		return out

	var base := scene_path.get_file()
	var exact := "%s/%s-editstate-%s.cfg" % [EDITSTATE_DIR, base, scene_path.md5_text()]
	out.append(exact)

	var prefix := base + "-editstate-"
	var stale: Array[String] = []

	for entry in DirAccess.get_files_at(EDITSTATE_DIR):
		if entry.begins_with(prefix) and entry.ends_with(".cfg"):
			var full := EDITSTATE_DIR + "/" + entry
			if full != exact:
				stale.append(full)

	# Newest first: the most recently opened session is the best guess when the
	# exact-hash file is gone.
	stale.sort_custom(
		func(a: String, b: String) -> bool:
			return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b)
	)
	out.append_array(stale)

	return out


## Parses one editstate .cfg down to its "preview_sun_env" dictionary.  Returns
## {} for a missing file, a malformed one, or one that does not look like ours —
## a foreign file must never half-light a portrait.
func _parse_editstate(path: String) -> Dictionary:
	var cfg := ConfigFile.new()

	if cfg.load(path) != OK:
		# res:// is not guaranteed to reach into the hidden .godot/, so retry on
		# the real OS path before giving up.
		if not path.begins_with("res://") or cfg.load(ProjectSettings.globalize_path(path)) != OK:
			return {}

	var states: Variant = cfg.get_value("editor_states", "3D", {})
	if not states is Dictionary:
		return {}

	var preview: Variant = (states as Dictionary).get("preview_sun_env", {})
	if not preview is Dictionary:
		return {}

	var d := preview as Dictionary
	if not (d.has("sun_rotation") and d.has("environ_sky_color") and d.has("sun_energy")):
		return {}

	return d


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
	# added to the tree. RENDER_SETTLE_FRAMES waits guarantee the render has
	# completed and the texture buffer is populated before we read it.
	for i in RENDER_SETTLE_FRAMES:
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
