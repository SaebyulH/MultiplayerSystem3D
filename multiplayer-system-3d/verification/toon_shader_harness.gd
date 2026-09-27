extends Node3D

## Throwaway verification harness for assets/materials/painted_toon.gdshader.
##
##   "C:/tools/godot/godot_console.exe" --path . res://verification/toon_shader_harness.tscn
##
## Exit code is the number of failed checks.
##
## A shader cannot be validated by parsing it — Godot only compiles a variant
## when a material is actually drawn, and the dummy driver behind --headless
## never gets that far.  So this harness renders a real frame against a real
## GPU and the *console log* is half the test: grep the run for
## "SHADER ERROR" / "Shader compilation failed".  The in-script checks only
## cover the parts that fail silently (uniforms going missing, parameters not
## being settable).
##
## Delete after use.

const SHADER_PATH := "res://assets/materials/painted_toon.gdshader"
const MATERIAL_PATH := "res://assets/materials/painted_toon.tres"

var _checks: int = 0
var _fails: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("PASS  ", label)
	else:
		_fails += 1
		print("FAIL  ", label, "   ", detail)


func _ready() -> void:
	var shader := load(SHADER_PATH) as Shader
	_check("shader loads", shader != null)
	if shader == null:
		get_tree().quit(1)
		return

	# get_shader_uniform_list() reflects the *parsed* shader, so a uniform that
	# fails to parse simply will not be here.
	var names: Array[String] = []
	for u in shader.get_shader_uniform_list():
		names.append(u["name"])
	print("uniforms parsed: ", names.size())

	var expected := [
		"use_albedo_texture", "albedo_texture", "albedo_color", "use_vertex_color",
		"uv_scale", "use_normal_map", "normal_texture", "normal_strength",
		"use_orm_texture", "orm_texture", "metallic", "roughness", "specular",
		"use_ao_texture", "ao_texture", "ao_strength", "toon_steps",
		"toon_softness", "shadow_wrap", "shadow_tint", "light_tint",
		"tint_strength", "albedo_gain", "paint_scale", "paint_terminator_jitter",
		"paint_value_jitter", "toon_specular_strength", "toon_specular_size",
		"toon_specular_softness", "rim_enabled", "rim_color", "rim_strength",
		"rim_width", "rim_softness", "rim_top_bias", "rim_albedo_mix",
		"use_emission_texture", "emission_texture", "emission_color",
		"emission_energy",
	]
	for name in expected:
		_check("uniform %s" % name, name in names, "missing from shader")

	var mat := load(MATERIAL_PATH) as ShaderMaterial
	_check("preset material loads", mat != null)
	if mat == null:
		get_tree().quit(1)
		return
	_check("preset uses the shader", mat.shader == shader, str(mat.shader))

	# `mat` is deliberately left exactly as the preset ships — no overrides at
	# all — so the third sphere in the preview is literally "drop
	# painted_toon.tres on a mesh and change nothing".  That is the shot worth
	# judging the defaults from.

	var textured := ShaderMaterial.new()
	textured.shader = shader
	textured.set_shader_parameter("use_albedo_texture", true)
	textured.set_shader_parameter("albedo_texture", _checker())

	# --- A scene that actually draws ----------------------------------------
	var env := _environment()
	add_child(env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30.0, 40.0, 0.0)
	light.shadow_enabled = true
	add_child(light)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 3.6)
	cam.fov = 40.0
	add_child(cam)
	cam.current = true

	# Three spheres, left to right, so the shot answers the three questions
	# that matter and that the checks above cannot:
	#
	#   1. StandardMaterial3D reference.  Its exposure is correct by
	#      definition, so #2 sitting next to it proves the hand-rolled
	#      `light_color * brdf * (1/PI) * attenuation` matches the engine's
	#      own brightness rather than being off by a factor of PI.
	#   2. The toon ramp flattened back to a smooth gradient with no tint and
	#      no wrap — i.e. plain Lambert through our pipeline.  Should look
	#      like #1.
	#   3. The real thing: banded, tinted, painted, with the back rim on.
	var reference := StandardMaterial3D.new()
	reference.albedo_color = Color(0.85, 0.35, 0.3)
	reference.roughness = 0.55
	reference.metallic = 0.0

	var flattened := ShaderMaterial.new()
	flattened.shader = shader
	flattened.set_shader_parameter("albedo_color", Color(0.85, 0.35, 0.3))
	flattened.set_shader_parameter("roughness", 0.55)
	flattened.set_shader_parameter("toon_steps", 1)
	flattened.set_shader_parameter("toon_softness", 1.0)
	flattened.set_shader_parameter("shadow_wrap", 0.0)
	flattened.set_shader_parameter("tint_strength", 0.0)
	flattened.set_shader_parameter("paint_terminator_jitter", 0.0)
	flattened.set_shader_parameter("paint_value_jitter", 0.0)

	var row := [-1.5, 0.0, 1.5]
	var setups := [reference, flattened, mat]
	var meshes: Array[MeshInstance3D] = []
	for i in 3:
		var mesh := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.62
		sphere.height = 1.24
		mesh.mesh = sphere
		mesh.material_override = setups[i]
		mesh.position = Vector3(row[i], 0.0, 0.0)
		add_child(mesh)
		meshes.append(mesh)

	DisplayServer.window_set_size(Vector2i(1200, 480))
	await _settle(12)
	await _capture("user://toon_preview.png")

	# Measure rather than eyeball.  Sphere 1 is the engine's own answer, so the
	# other two are only meaningful as a ratio against it; #2 isolates the
	# exposure question (same Lambert through our light() pipeline), #3 is the
	# real look.
	var img := Image.load_from_file(
		ProjectSettings.globalize_path("user://toon_preview.png"))
	var blobs := _blob_means(img)
	if blobs.size() == 3:
		print("")
		print("mean over each sphere, sRGB:")
		print("  standard  (truth)  (%.3f %.3f %.3f)" % blobs[0])
		print("  flattened  ours    (%.3f %.3f %.3f)" % blobs[1])
		print("  stylised   ours    (%.3f %.3f %.3f)" % blobs[2])
		var r := _ratio(blobs[1], blobs[0])
		print("  flattened / standard = %.3f  (1.0 = same exposure)" % r)
	else:
		print("sphere scan found ", blobs.size(), " blobs, expected 3")

	# --- Pass 2: no lights at all -------------------------------------------
	# The whole point of the rim is that it does not need a light to be behind
	# the subject — it fakes one from the view direction.  So kill every light
	# and the ambient, and it must still be there.  This is the one property of
	# the shader that a static screenshot of a lit scene cannot demonstrate.
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.BLACK
	env.environment.ambient_light_energy = 0.0
	light.visible = false

	# Sweep rim_width in the dark.  With every light off, everything on screen
	# is the rim, so this reads the width mapping directly: narrow accent,
	# default, broad wash.  It also doubles as the proof that the rim needs no
	# light — if any of these were leaked illumination the others would be too,
	# and they track the slider instead.
	var dark_variants: Array[ShaderMaterial] = []
	for width in [0.25, 0.5, 0.8]:
		var v := ShaderMaterial.new()
		v.shader = shader
		v.set_shader_parameter("albedo_color", Color(0.85, 0.35, 0.3))
		v.set_shader_parameter("toon_steps", 3)
		v.set_shader_parameter("rim_width", width)
		dark_variants.append(v)
	for i in 3:
		meshes[i].material_override = dark_variants[i]

	await _settle(6)
	await _capture("user://toon_preview_dark.png")

	print("checks: ", _checks, "  fails: ", _fails)
	get_tree().quit(_fails)


## Mean colour of each sphere, found by scanning the middle scanline for runs
## of lit pixels.  The background is a sky gradient, so "lit" means "brighter
## than the row's own background", which the sky's flatness makes workable.
func _blob_means(img: Image) -> Array:
	var y := img.get_height() / 2
	# The sky is a purely vertical gradient, so along a scanline the background
	# is constant — compare against the row's first pixel rather than keying on
	# a colour channel, which stops working once a sphere goes near-white.
	var bg := img.get_pixel(0, y)
	var runs: Array[Vector2i] = []
	var start := -1
	for x in img.get_width():
		var c := img.get_pixel(x, y)
		var lit := absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b) > 0.08
		if lit and start < 0:
			start = x
		elif not lit and start >= 0:
			runs.append(Vector2i(start, x - 1))
			start = -1
	if start >= 0:
		runs.append(Vector2i(start, img.get_width() - 1))

	var out: Array = []
	for run in runs:
		if run.y - run.x < 20:
			continue
		var acc := Vector3.ZERO
		var n := 0
		for yy in range(y - 30, y + 30):
			for xx in range(run.x + 10, run.y - 10):
				if xx < 0 or yy < 0 or xx >= img.get_width() or yy >= img.get_height():
					continue
				var c := img.get_pixel(xx, yy)
				acc += Vector3(c.r, c.g, c.b)
				n += 1
		acc /= maxf(n, 1)
		out.append([acc.x, acc.y, acc.z])
	return out


func _ratio(a: Array, b: Array) -> float:
	return (a[0] + a[1] + a[2]) / maxf(b[0] + b[1] + b[2], 1e-5)


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("preview: ", ProjectSettings.globalize_path(path))


func _environment() -> WorldEnvironment:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.42, 0.5, 0.62)
	sky_mat.sky_horizon_color = Color(0.62, 0.6, 0.56)
	sky_mat.ground_bottom_color = Color(0.2, 0.19, 0.18)
	sky_mat.ground_horizon_color = Color(0.55, 0.53, 0.5)
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 0.4
	env.environment = e
	return env


func _checker() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var on := ((x / 8) + (y / 8)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.85) if on else Color(0.25, 0.25, 0.3))
	return ImageTexture.create_from_image(img)
