extends Node3D

## Throwaway A/B for the toon swap on juggernaut.tscn.
##
##   "C:/tools/godot/godot_console.exe" --path . res://verification/juggernaut_inspect.tscn
##
## Renders the model with its ORIGINAL materials, then with the toon swap, then
## with each factor of the toon diffuse sum added in turn, from an identical
## camera and light.  Every statistic is taken over the character's silhouette,
## which is measured by rendering a mask rather than guessed from coordinates —
## guessing put the "torso" region on the sky twice.

const SCENE := "res://assets/character_models/character_scenes/juggernaut.tscn"

var _bbox := Rect2i()
var _env: WorldEnvironment
var _light: DirectionalLight3D


func _ready() -> void:
	var packed := load(SCENE) as PackedScene
	if packed == null:
		print("FAILED to load ", SCENE)
		get_tree().quit(1)
		return

	var root := packed.instantiate()
	# Suppress the automatic swap so the un-modified materials render first.
	var swap := root.get_node_or_null("ToonMaterialSwap")
	if swap != null:
		swap.apply_on_ready = false
	add_child(root)

	_add_light_and_camera()
	for i in 10:
		await get_tree().process_frame

	# --- Mask, for measurement only -----------------------------------------
	_bbox = await _silhouette(root)
	if _bbox.size.x == 0:
		print("could not measure the silhouette")
		get_tree().quit(1)
		return
	print("silhouette bbox: ", _bbox)

	var orig := await _shot("user://juggernaut_original.png")

	# --- Convert and shoot again --------------------------------------------
	var shader := load("res://assets/materials/painted_toon.gdshader") as Shader
	print("converted surfaces: ", ToonMaterialSwap.convert_under(root, shader))
	var materials := _toon_materials(root, shader)
	var toon := await _shot("user://juggernaut_toon.png")

	for mat in materials:
		_flatten(mat)
	var flat := await _shot("user://juggernaut_toon_flat.png")

	# --- Tuning variants ----------------------------------------------------
	# The toon ramp is Lambert-shaped where StandardMaterial3D defaults to
	# Burley, so the swap loses exposure (measured: 0.72x on a controlled
	# sphere).  The cool shadow tint compounds it on a dark uniform, because it
	# multiplies the darkest bands down and desaturates them.  Render the two
	# knobs that address it so the difference is visible, not theoretical.
	# A/B of the retune itself.  Both parameter sets are stated in full, so the
	# only difference between the two rows is the change under test — the
	# "before" row is the previous shipped defaults, the "after" row the new
	# ones.  Without this the two numbers come from different harness versions
	# and are not comparable.
	# Sweep diffuse_gain against everything else fixed at the new shipped
	# values.  The matte settings (specular 0, no toon highlight) cost real
	# light, so the question is only how much gain buys back — this answers it
	# instead of guessing.
	var variants: Array = [["albedo_gain 1.0 (matte)", 1.0], ["albedo_gain 1.5 (shipped)", 1.5],
			["albedo_gain 2.5", 2.5], ["albedo_gain 4.0", 4.0]]
	var rows: Array[Array] = []
	for variant in variants:
		for mat in materials:
			mat.set_shader_parameter("toon_steps", 3)
			mat.set_shader_parameter("toon_softness", 0.45)
			mat.set_shader_parameter("shadow_wrap", 0.35)
			mat.set_shader_parameter("tint_strength", 0.3)
			mat.set_shader_parameter("specular", 0.0)
			mat.set_shader_parameter("toon_specular_strength", 0.0)
			mat.set_shader_parameter("rim_enabled", true)
			mat.set_shader_parameter("paint_terminator_jitter", 0.05)
			mat.set_shader_parameter("paint_value_jitter", 0.06)
			mat.set_shader_parameter("albedo_gain", variant[1])
		rows.append([variant[0], await _shot("user://juggernaut_%s.png" % variant[0])])

	# --- Report --------------------------------------------------------------
	print("")
	print("mean over the character's torso band, sRGB:")
	print("  %-22s %s   <- reference" % ["ORIGINAL (PBR)", orig])
	print("  %-22s %s" % ["toon (as shipped)", toon])
	print("  %-22s %s" % ["toon (neutral ramp)", flat])
	print("")
	for row in rows:
		print("  %-22s %s" % row)

	get_tree().quit(0)


## Mean colour over the middle 30% of the character's bounding box, which is
## torso and jacket in every shot here.
func _shot(path: String) -> String:
	await _settle(4)
	await _capture(path)
	return _mean_in_bbox(path)


func _mean_in_bbox(path: String) -> String:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		return "(missing)"
	var band := Rect2i(
		_bbox.position.x + int(_bbox.size.x * 0.30), _bbox.position.y + int(_bbox.size.y * 0.35),
		int(_bbox.size.x * 0.40), int(_bbox.size.y * 0.30)
	)
	var acc := Vector3.ZERO
	var n := 0
	for y in range(band.position.y, band.end.y):
		for x in range(band.position.x, band.end.x):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	acc /= maxf(n, 1)
	return "(%.3f %.3f %.3f)" % [acc.x, acc.y, acc.z]


## Bounding box of the character, measured by flattening it to unshaded white
## against a black background with every light off.
func _silhouette(root: Node) -> Rect2i:
	var white := ShaderMaterial.new()
	var s := Shader.new()
	s.code = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() { ALBEDO = vec3(1.0); }"
	white.shader = s

	var meshes := _meshes(root)
	var saved: Array[Material] = []
	for mi in meshes:
		saved.append((mi as MeshInstance3D).material_override)
		(mi as MeshInstance3D).material_override = white

	var saved_bg := _env.environment.background_mode
	var saved_src := _env.environment.ambient_light_source
	var saved_energy := _env.environment.ambient_light_energy
	_env.environment.background_mode = Environment.BG_COLOR
	_env.environment.background_color = Color.BLACK
	_env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.environment.ambient_light_color = Color.BLACK
	_env.environment.ambient_light_energy = 0.0
	var saved_light := _light.visible
	_light.visible = false

	await _settle(4)
	await _capture("user://juggernaut_mask.png")
	var box := _bbox_of("user://juggernaut_mask.png")

	for i in meshes.size():
		(meshes[i] as MeshInstance3D).material_override = saved[i]
	_env.environment.background_mode = saved_bg
	_env.environment.ambient_light_source = saved_src
	_env.environment.ambient_light_energy = saved_energy
	_light.visible = saved_light
	return box


func _bbox_of(path: String) -> Rect2i:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	var min_x := img.get_width()
	var min_y := img.get_height()
	var max_x := -1
	var max_y := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).r > 0.5:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if max_x < 0:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _flatten(toon: ShaderMaterial) -> void:
	toon.set_shader_parameter("toon_steps", 1)
	toon.set_shader_parameter("toon_softness", 1.0)
	toon.set_shader_parameter("shadow_wrap", 0.0)
	toon.set_shader_parameter("tint_strength", 0.0)
	toon.set_shader_parameter("paint_terminator_jitter", 0.0)
	toon.set_shader_parameter("paint_value_jitter", 0.0)
	toon.set_shader_parameter("rim_enabled", false)


func _toon_materials(root: Node, shader: Shader) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for node in _meshes(root):
		var mi := node as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if mat is ShaderMaterial and (mat as ShaderMaterial).shader == shader:
				if not out.has(mat):
					out.append(mat as ShaderMaterial)
	return out


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)


func _add_light_and_camera() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.46, 0.6)
	sky_mat.sky_horizon_color = Color(0.6, 0.58, 0.55)
	sky_mat.ground_bottom_color = Color(0.18, 0.17, 0.16)
	sky_mat.ground_horizon_color = Color(0.5, 0.48, 0.45)
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 0.35
	env.environment = e
	add_child(env)
	_env = env

	# Yaw 215 puts the light behind the camera, which sits on -Z — the side the
	# model faces, since the GLB root is rotated 180 degrees about Y.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-25.0, 215.0, 0.0)
	# Shadows OFF: with them on, ATTENUATION measured ~0 over the whole torso —
	# the character was shadowing itself against no ground geometry — so the
	# direct-light term contributed nothing and every comparison below was
	# really just comparing ambient.  That is a property of this test scene, not
	# of the shader.
	light.shadow_enabled = false
	add_child(light)
	_light = light

	var cam := Camera3D.new()
	cam.fov = 45.0
	add_child(cam)
	cam.look_at_from_position(Vector3(0.3, 1.45, -2.4), Vector3(0.0, 1.2, 0.0), Vector3.UP)
	cam.current = true


func _meshes(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out
