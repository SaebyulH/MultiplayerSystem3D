@tool
extends Node
## One-shot tool that pre-renders every weapon's 3D model into a PNG icon
## for the kill feed.
##
## The model is rendered normally (lit, with its real materials), then a
## full-screen post-process pass inside the SubViewport:
##   1. converts the image to grayscale
##   2. boosts brightness by BRIGHTNESS_BOOST (clamped, so mid-tones survive)
##   3. sets alpha = brightness, so dark areas become transparent
##
## HOW TO USE:
##   1. Create a new empty scene (Scene → New Scene)
##   2. Add a Node as the root, attach this script to it
##   3. Press F6 (Run Current Scene) — icons are generated, then the scene
##      auto-quits after 0.5 seconds.
##
## Re-run whenever you add or change a weapon model.

const OUTPUT_DIR := "res://killfeed_icons"
const ICON_WIDTH := 256
const ICON_HEIGHT := 144

## Fraction of the viewport the model should fill (0–1).
const FRAME_FILL := 0.36

# ── post-process / lighting tuning ───────────────────────────────────

## Gain applied after grayscale. 1.0 = no boost. Around 2–3 pushes most of
## the weapon toward white while keeping some gray gradation. Very high
## values approach a hard-edged silhouette.
const BRIGHTNESS_BOOST := 4.0


## The render is lit before post-processing, so the lighting decides which
## parts read as "bright" (opaque) vs "dark" (transparent).
const AMBIENT_ENERGY := 0.7
const KEY_LIGHT_ENERGY := 0.8

const POSTFX_SHADER := """
shader_type canvas_item;

// Replace the pixel outright instead of alpha-blending over the 3D render,
// otherwise transparent (dark) areas would show the original colors.
render_mode blend_disabled;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;
uniform float brightness_boost = 2.2;

void fragment() {
	vec4 src = texture(screen_tex, SCREEN_UV);

	// 1. Grayscale (Rec. 601 luma). Multiplying by src.a keeps empty
	//    background pixels at zero regardless of what RGB they carry.
	float gray = dot(src.rgb, vec3(0.299, 0.587, 0.114)) * src.a;

	// 2. Brightness boost: strong, but clamped so it isn't all-or-nothing.
	float lit = clamp(gray * brightness_boost, 0.0, 1.0);

	// 3. Alpha follows brightness: dark = transparent.
	COLOR = vec4(vec3(lit), lit);
}
"""


var _started := false
var _weapon_files: Array[String] = []
var _weapon_index := 0
var _generated := 0
var _done := false


func _ready() -> void:
	if _started:
		return
	if Engine.is_editor_hint():
		print("Killfeed Icon Generator attached. Press F6 to run.")
		return

	_started = true
	print("──────────────────────────────────────────")
	print("Killfeed Icon Generator — %dx%d icons" % [ICON_WIDTH, ICON_HEIGHT])
	print("──────────────────────────────────────────")

	if DirAccess.make_dir_recursive_absolute(OUTPUT_DIR) != OK:
		printerr("Failed to create: ", OUTPUT_DIR)
		get_tree().quit(1)
		return

	# Chicken-and-egg: weapon .tres files reference killfeed_icon PNGs that
	# may not exist yet. Godot's ResourceLoader will refuse to load the .tres
	# if a dependency is missing. Stub any missing PNG first so the .tres
	# files load successfully, then the real capture overwrites both.
	_stub_missing_icons()

	_find_weapon_files("res://weapon", _weapon_files)
	print("Found %d weapon .tres files." % _weapon_files.size())

	if _weapon_files.is_empty():
		print("Nothing to do.")
		get_tree().quit()
		return

	_process_next()


func _process_next() -> void:
	if _done:
		return

	if _weapon_index >= _weapon_files.size():
		_finish()
		return

	var file_path := _weapon_files[_weapon_index]
	_weapon_index += 1

	var weapon: Weapon = load(file_path) as Weapon
	if not weapon or not weapon.weapon_model:
		print("  SKIP %s" % file_path)
		_process_next.call_deferred()
		return

	var icon_name := _safe_filename(weapon.display_name) + ".png"
	var icon_path := OUTPUT_DIR + "/" + icon_name

	print("  %s  →  %s …" % [weapon.display_name, icon_path])

	var vp := _build_viewport(weapon.weapon_model)
	add_child(vp)

	# Defer the capture so the SubViewport gets at least one full render
	# cycle in the tree before we try to grab its texture.
	_capture_deferred.call_deferred(vp, weapon, file_path, icon_path)


# ── viewport builder ─────────────────────────────────────────────────


func _build_viewport(model_scene: PackedScene) -> SubViewport:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.handle_input_locally = false
	vp.size = Vector2i(ICON_WIDTH, ICON_HEIGHT)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.transparent_bg = true

	var root_3d := Node3D.new()
	root_3d.name = "IconRoot"
	vp.add_child(root_3d)

	# Orthographic camera viewing the weapon from the side (+X side,
	# looking toward -X).
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	root_3d.add_child(cam)

	# The viewport has its own World3D, so without lights the model would
	# render black. Light it so the grayscale pass has something to work with.
	_add_lighting(root_3d, cam)

	# Spawn the weapon model with its normal materials.
	var model: Node3D = model_scene.instantiate()
	model.position = Vector3.ZERO
	root_3d.add_child(model)

	# Full-screen post-process: grayscale → brightness boost → alpha.
	_add_postprocess(vp)

	# ─────────────────────────────────────────────────────────────────
	# AUTHORED BOUNDING BOX
	#
	# Expected hierarchy:
	#
	#   WeaponModel
	#   ├── meshes...
	#   ├── Muzzle
	#   └── BoundingBox (Area3D)
	#       └── CollisionShape3D (BoxShape3D)
	#
	# The BoundingBox defines the area that should be considered when
	# framing the weapon icon.
	# ─────────────────────────────────────────────────────────────────

	var visibility_aabb := _get_visibility_aabb(model)

	if visibility_aabb.has_volume():
		var center: Vector3 = visibility_aabb.get_center()
		var aspect: float = float(ICON_WIDTH) / float(ICON_HEIGHT)

		# Camera3D.size uses the same half-height convention as the
		# original mesh-AABB framing.
		#
		# Fit whichever projected dimension requires more space.
		#
		# Y = vertical screen dimension
		# Z = horizontal screen dimension
		var required_vertical: float = (
			visibility_aabb.size.y * 0.5 / FRAME_FILL
		)

		var required_horizontal: float = (
			visibility_aabb.size.z * 0.5 / (FRAME_FILL * aspect)
		)

		cam.size = maxf(
			maxf(required_vertical, required_horizontal),
			0.12
		)

		# Orthographic projection means camera distance does not affect
		# apparent size. Only center the camera on the authored bounds.
		cam.position = Vector3(
			2.0,
			center.y,
			center.z
		)

	else:
		# ─────────────────────────────────────────────────────────────
		# OLD FALLBACK
		#
		# If there is no valid BoundingBox, use the original mesh-based
		# vertex calculation.
		# ─────────────────────────────────────────────────────────────

		var verts: Array[Vector3] = []
		_collect_vertices(model, Transform3D.IDENTITY, verts)

		var aabb := _aabb_from_vertices(verts)
		var aspect := float(ICON_WIDTH) / float(ICON_HEIGHT)

		if aabb.has_volume():
			var center := aabb.get_center()

			var needed_h := (
				aabb.size.y * 0.5 / FRAME_FILL
			)

			var needed_w := (
				aabb.size.z * 0.5 / (FRAME_FILL * aspect)
			)

			cam.size = maxf(
				maxf(needed_h, needed_w),
				0.12
			)

			# Camera on the +X side looking back at the model.
			cam.position = Vector3(
				aabb.end.x + 2.0,
				center.y,
				center.z
			)

		else:
			# Final fallback — no usable vertex data.
			# Use Muzzle position as a rough scale hint, same as the
			# original runtime kill-feed.
			var muzzle := model.get_node_or_null("Muzzle") as Node3D

			var dist := maxf(
				muzzle.position.length() if muzzle else 1.0,
				1.0
			)

			cam.size = maxf(
				dist * 2.7 + 0.4,
				2.0
			) * tan(deg_to_rad(11.0))

			cam.position = Vector3(
				dist * 2.7 + 0.4,
				0.15,
				0.0
			)

	return vp


# ── lighting / post-process ──────────────────────────────────────────


## Flat-ish lighting: white ambient plus a soft key light from the camera
## side (slightly from above). Background stays transparent.
func _add_lighting(root_3d: Node3D, cam: Camera3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = AMBIENT_ENERGY
	cam.environment = env

	var key_light := DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.rotation_degrees = Vector3(-35.0, 90.0, 0.0)
	key_light.light_energy = KEY_LIGHT_ENERGY
	key_light.shadow_enabled = false
	root_3d.add_child(key_light)


## Adds a full-viewport ColorRect running POSTFX_SHADER. It reads the 3D
## render through hint_screen_texture and overwrites it with the
## grayscale / boosted / brightness-as-alpha result.
func _add_postprocess(vp: SubViewport) -> void:
	var shader := Shader.new()
	shader.code = POSTFX_SHADER

	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("brightness_boost", BRIGHTNESS_BOOST)

	var rect := ColorRect.new()
	rect.name = "PostProcess"
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = mat
	vp.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# ── authored bounding box ────────────────────────────────────────────


## Gets the authored visibility bounds from:
##
##   WeaponModel
##   └── BoundingBox (Area3D)
##       └── CollisionShape3D
##
## The BoundingBox is treated purely as an authoring volume. It does not
## need to participate in collision detection.
##
## Currently supports BoxShape3D. If the BoundingBox is missing, malformed,
## or uses another Shape3D, an empty AABB is returned and the caller falls
## back to the mesh-based method.
func _get_visibility_aabb(model: Node3D) -> AABB:
	var bounding_box := model.get_node_or_null("BoundingBox") as Area3D

	if not bounding_box:
		return AABB()

	var collision := bounding_box.get_node_or_null(
		"CollisionShape3D"
	) as CollisionShape3D

	if not collision or not collision.shape:
		return AABB()

	var box := collision.shape as BoxShape3D

	if not box:
		return AABB()

	# BoxShape3D.size is local to the CollisionShape3D.
	var half := box.size * 0.5

	# All 8 corners are transformed through:
	#
	#   CollisionShape3D → BoundingBox → WeaponModel
	#
	# This handles arbitrary position/rotation/scale on either node.
	var local_corners := [
		Vector3(-half.x, -half.y, -half.z),
		Vector3(-half.x, -half.y,  half.z),
		Vector3(-half.x,  half.y, -half.z),
		Vector3(-half.x,  half.y,  half.z),
		Vector3( half.x, -half.y, -half.z),
		Vector3( half.x, -half.y,  half.z),
		Vector3( half.x,  half.y, -half.z),
		Vector3( half.x,  half.y,  half.z),
	]

	var shape_to_model := (
		bounding_box.transform
		* collision.transform
	)

	var result := AABB()
	var first := true

	for corner in local_corners:
		var point: Vector3 = shape_to_model * corner

		if first:
			result = AABB(point, Vector3.ZERO)
			first = false
		else:
			result = result.expand(point)

	return result


# ── vertex collection ───────────────────────────────────────────────


## Recursively walks `node` and extracts every vertex from every
## MeshInstance3D, transformed to model-local space via `parent_xform`.
func _collect_vertices(
	node: Node,
	parent_xform: Transform3D,
	out_verts: Array[Vector3]
) -> void:
	# Only Node3D carries a 3D transform; plain Node children
	# (e.g. Timers, AnimationPlayers) just pass the parent transform
	# through unchanged.
	var xform := parent_xform

	if node is Node3D:
		xform = parent_xform * (node as Node3D).transform

	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh

		if mesh:
			var arrays: Array = []

			if mesh is ArrayMesh:
				for s in (mesh as ArrayMesh).get_surface_count():
					arrays.append(
						(mesh as ArrayMesh).surface_get_arrays(s)
					)

			elif mesh is PrimitiveMesh:
				arrays.append(
					(mesh as PrimitiveMesh).get_mesh_arrays()
				)

			# ImporterMesh and other types are skipped silently.

			for arr in arrays:
				if arr.size() > Mesh.ARRAY_VERTEX:
					var verts: PackedVector3Array = \
						arr[Mesh.ARRAY_VERTEX]

					for v in verts:
						out_verts.append(xform * v)

	for child in node.get_children():
		_collect_vertices(child, xform, out_verts)


## Builds a bounding box from `vertices`, filtering out outlier points
## that are far from the main cluster (bone helpers, armature artifacts).
## Uses IQR (interquartile range) with a conservative 3.0× multiplier so
## legitimate elongated shapes like rifle barrels are kept.
func _aabb_from_vertices(vertices: Array[Vector3]) -> AABB:
	if vertices.is_empty():
		return AABB()

	# Centroid of all points.
	var centroid := Vector3.ZERO

	for v in vertices:
		centroid += v

	centroid /= float(vertices.size())

	# Squared distances from centroid, with their indices.
	var n := vertices.size()
	var dists: Array[float] = []
	dists.resize(n)

	for i in n:
		dists[i] = centroid.distance_squared_to(vertices[i])

	# Sort distances to find Q1 / Q3 / IQR.
	var sorted: Array = dists.duplicate()
	sorted.sort()

	var q1: float = sorted[n / 4]
	var q3: float = sorted[3 * n / 4]
	var iqr: float = q3 - q1

	var cutoff := q3 + 3.0 * iqr

	# Build AABB from kept vertices.
	var aabb := AABB()
	var first := true

	for i in n:
		if dists[i] <= cutoff:
			if first:
				aabb = AABB(vertices[i], Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(vertices[i])

	return aabb


# ── capture / save ───────────────────────────────────────────────────


func _capture_deferred(
	vp: SubViewport,
	weapon: Weapon,
	file_path: String,
	icon_path: String
) -> void:
	# SubViewport with UPDATE_ONCE renders on the first frame after
	# being added to the tree. Two process_frame waits guarantee the
	# render has completed and the texture buffer is populated before
	# we read it.
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

	# Write the captured frame to disk so the kill-feed UI can load it
	# as an external texture at runtime.
	if img.save_png(icon_path) != OK:
		print("    FAILED (save PNG to %s)" % icon_path)
		_process_next.call_deferred()
		return

	# Build an ImageTexture directly from the image we already have in
	# memory, then claim the PNG path via take_over_path(). This avoids
	# a save-then-reload round-trip that fails on Windows when
	# ResourceLoader tries to open the file before the OS has flushed it.
	#
	# ResourceSaver will write an ExtResource reference into the .tres
	# so the kill-feed reloads the PNG properly at runtime.
	var icon_tex := ImageTexture.create_from_image(img)
	icon_tex.take_over_path(icon_path)

	weapon.killfeed_icon = icon_tex

	if ResourceSaver.save(weapon, file_path) != OK:
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
	print(
		"Done — %d icons written to %s/"
		% [_generated, OUTPUT_DIR]
	)
	print(
		"Re-open any open .tres files to see the new killfeed_icon field."
	)
	print("──────────────────────────────────────────")

	get_tree().create_timer(0.5).timeout.connect(
		func(): get_tree().quit()
	)


# ── filesystem helpers ───────────────────────────────────────────────


func _find_weapon_files(
	dir: String,
	out_files: Array[String]
) -> void:
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
			_find_weapon_files(full, out_files)

		elif entry.ends_with(".tres"):
			var res := load(full)

			if res is Weapon:
				out_files.append(full)

		entry = d.get_next()

	d.list_dir_end()


## Scan every .tres under [root_dir] for killfeed_icons/*.png references.
## For any referenced PNG that doesn't exist on disk, write a 1×1 transparent
## stub so the .tres can be loaded without a missing-dependency error.
func _stub_missing_icons() -> void:
	var tres_paths: Array[String] = []

	_collect_tres_paths("res://weapon", tres_paths)

	var stubbed := 0

	for path in tres_paths:
		var text: String = FileAccess.get_file_as_string(path)

		if text.is_empty():
			continue

		# Lines look like:
		#
		# [ext_resource type="Texture2D"
		# path="res://killfeed_icons/foo.png" id="1_xxx"]
		#
		for line in text.split("\n"):
			var start := line.find("res://killfeed_icons/")

			if start == -1:
				continue

			var end_quote := line.find("\"", start)

			if end_quote == -1:
				continue

			var png_path := line.substr(
				start,
				end_quote - start
			)

			if (
				png_path.ends_with(".png")
				and not FileAccess.file_exists(png_path)
			):
				var img := Image.create(
					1,
					1,
					false,
					Image.FORMAT_RGBA8
				)

				img.fill(Color(0, 0, 0, 0))

				if img.save_png(png_path) == OK:
					stubbed += 1
					print(
						"  STUB  %s  (missing dependency)"
						% png_path
					)

	if stubbed > 0:
		print(
			"Stubbed %d missing PNG(s) so .tres files can load."
			% stubbed
		)


## Recursively collects every .tres file path under [dir] into [out_paths].
func _collect_tres_paths(
	dir: String,
	out_paths: Array[String]
) -> void:
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
			_collect_tres_paths(full, out_paths)

		elif entry.ends_with(".tres"):
			out_paths.append(full)

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
