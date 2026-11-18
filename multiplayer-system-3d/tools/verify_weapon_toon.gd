extends Node

## Harness for [WeaponToonMaterials] — the runtime re-shading every spawned weapon model
## goes through in `WeaponController.spawn_weapon_model()`.
##
##   "C:/tools/godot/godot_console.exe" --path . res://tools/verify_weapon_toon.tscn
##
## Exit code is the number of failed checks, so a clean run exits 0.
##
## Two passes.  The first drives the mapping against a synthetic tree: which material
## sources are handled (surface override / node override / mesh resource / CSG), which are
## skipped, and that every texture the source carries — including StandardMaterial3D's
## *separate* metallic and roughness maps with their channel selectors — reaches the toon
## material.  The second instantiates every weapon scene on disk and asserts that no
## opaque StandardMaterial3D survives, which is the failure that would otherwise be silent.
##
## The shader itself only compiles when something is actually drawn, which never happens
## headless; the visual half has to be eyeballed in game.

const PRESET_PATH := "res://assets/materials/weapon_toon.tres"
const WEAPON_DIR := "res://weapon"
# Preloaded rather than reached through its `class_name`: a headless run does not rescan
# the global class cache, so a freshly added class would fail to resolve.
const Converter := preload("res://weapon/weapon_toon_materials.gd")

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
	var preset := load(PRESET_PATH) as ShaderMaterial
	_check("preset loads", preset != null)
	if preset == null or preset.shader == null:
		get_tree().quit(1)
		return
	_check("preset is the character painted-toon shader",
		preset.shader.resource_path == "res://assets/materials/painted_toon.gdshader",
		preset.shader.resource_path)
	_check("preset enables the rim (characters have it)", preset.get_shader_parameter("rim_enabled") == true)
	# The character materials are non-metal, matte, and carry no stylised highlight; the
	# preset has to match or weapons read as a different shading family.
	_check("preset is matte and non-metal like the characters",
		is_zero_approx(preset.get_shader_parameter("metallic"))
		and (preset.get_shader_parameter("roughness") as float) > 0.8
		and is_zero_approx(preset.get_shader_parameter("toon_specular_strength")))

	_synthetic_pass(preset)
	_real_pass(preset)

	print("")
	print("checks: ", _checks, "  fails: ", _fails)
	get_tree().quit(_fails)


# ─────────────────────────────────────────────
#  Synthetic pass — the property mapping
# ─────────────────────────────────────────────

func _synthetic_pass(preset: ShaderMaterial) -> void:
	var tex := _checker()

	var src := StandardMaterial3D.new()
	src.albedo_color = Color(0.8, 0.4, 0.2)
	src.albedo_texture = tex
	src.metallic = 0.9
	src.roughness = 0.4
	src.metallic_specular = 0.22
	src.metallic_texture = tex
	src.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	src.roughness_texture = tex
	src.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	src.normal_enabled = true
	src.normal_scale = 0.1
	src.normal_texture = tex
	src.uv1_scale = Vector3(2.0, 3.0, 1.0)
	src.emission_enabled = true
	src.emission = Color(1.0, 0.5, 0.0)
	src.emission_energy_multiplier = 1.5
	src.emission_texture = tex

	var blended := StandardMaterial3D.new()
	blended.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	blended.albedo_color = Color(1, 1, 1, 0.3)

	var custom := ShaderMaterial.new()
	custom.shader = load("res://assets/materials/painted_toon.gdshader")

	var root := Node3D.new()
	add_child(root)

	var mesh_override := _mesh(BoxMesh.new(), src)          # per-surface override
	root.add_child(mesh_override)

	var mesh_node_override := _mesh(BoxMesh.new(), null)     # MeshInstance3D.material_override
	mesh_node_override.material_override = src
	root.add_child(mesh_node_override)

	var baked_mesh := BoxMesh.new()                          # material on the Mesh resource
	baked_mesh.surface_set_material(0, src)
	var mesh_from_resource := _mesh(baked_mesh, null)
	root.add_child(mesh_from_resource)

	var combiner := CSGCombiner3D.new()                      # CSG weapon case
	combiner.material_override = src
	root.add_child(combiner)

	var mesh_blended := _mesh(BoxMesh.new(), blended)
	root.add_child(mesh_blended)

	var mesh_custom := _mesh(BoxMesh.new(), custom)
	root.add_child(mesh_custom)

	var mesh_bare := _mesh(BoxMesh.new(), null)
	root.add_child(mesh_bare)

	var result := Converter.apply(root, preset)

	_check("four material sources converted (surface, node override, mesh, CSG)",
		result["converted"] == 4, str(result["converted"]))
	_check("transparent and custom-shader surfaces skipped",
		result["skipped"] == 2, str(result["skipped"]))

	var toon := mesh_override.get_surface_override_material(0) as ShaderMaterial
	_check("surface override is now a ShaderMaterial on the preset's shader",
		toon != null and toon.shader == preset.shader)
	if toon != null:
		_check("albedo texture kept",
			toon.get_shader_parameter("albedo_texture") == tex
			and toon.get_shader_parameter("use_albedo_texture") == true)
		_check("albedo colour tinted by the preset's (white) rather than replaced",
			toon.get_shader_parameter("albedo_color") == src.albedo_color,
			str(toon.get_shader_parameter("albedo_color")))
		_check("the preset's metallic wins over the source's 0.9 (diffuse stays live)",
			is_zero_approx(toon.get_shader_parameter("metallic")),
			str(toon.get_shader_parameter("metallic")))
		_check("the preset's roughness wins over the source's 0.4",
			is_equal_approx(toon.get_shader_parameter("roughness"), 0.85),
			str(toon.get_shader_parameter("roughness")))
		_check("the preset's specular wins over the source's 0.22",
			is_zero_approx(toon.get_shader_parameter("specular")),
			str(toon.get_shader_parameter("specular")))
		_check("separate metallic map kept",
			toon.get_shader_parameter("use_metallic_texture") == true
			and toon.get_shader_parameter("metallic_texture") == tex)
		_check("metallic channel selector kept",
			toon.get_shader_parameter("metallic_channel") == BaseMaterial3D.TEXTURE_CHANNEL_BLUE,
			str(toon.get_shader_parameter("metallic_channel")))
		_check("separate roughness map kept",
			toon.get_shader_parameter("use_roughness_texture") == true
			and toon.get_shader_parameter("roughness_texture") == tex)
		_check("roughness channel selector kept",
			toon.get_shader_parameter("roughness_channel") == BaseMaterial3D.TEXTURE_CHANNEL_GREEN,
			str(toon.get_shader_parameter("roughness_channel")))
		_check("normal map kept, with the source's scale",
			toon.get_shader_parameter("use_normal_map") == true
			and toon.get_shader_parameter("normal_texture") == tex
			and is_equal_approx(toon.get_shader_parameter("normal_strength"), 0.1))
		_check("texture transform scale kept",
			toon.get_shader_parameter("uv_scale") == Vector2(2, 3))
		_check("emission kept",
			toon.get_shader_parameter("use_emission_texture") == true
			and toon.get_shader_parameter("emission_color") == src.emission
			and is_equal_approx(toon.get_shader_parameter("emission_energy"), 1.5))

	_check("node material_override converted",
		mesh_node_override.material_override is ShaderMaterial)
	_check("mesh-resource material converted",
		mesh_from_resource.get_surface_override_material(0) is ShaderMaterial)
	_check("CSG material_override converted",
		combiner.material_override is ShaderMaterial)

	_check("shared source material collapses to one generated material",
		mesh_override.get_surface_override_material(0)
			== mesh_from_resource.get_surface_override_material(0))
	_check("skipped surfaces are untouched",
		mesh_blended.get_surface_override_material(0) == blended
		and mesh_custom.get_surface_override_material(0) == custom)
	_check("a surface with no material stays bare",
		mesh_bare.get_surface_override_material(0) == null)

	var again := Converter.apply(root, preset)
	_check("applying twice converts nothing the second time",
		again["converted"] == 0, str(again["converted"]))

	root.queue_free()


# ─────────────────────────────────────────────
#  Real pass — every weapon scene on disk
# ─────────────────────────────────────────────

func _real_pass(preset: ShaderMaterial) -> void:
	var scenes := _scan_tscn(WEAPON_DIR)
	_check("weapon scenes found", scenes.size() > 20, str(scenes.size()))

	var total_converted := 0
	var leftovers := 0
	var scenes_with_materials := 0

	for path in scenes:
		var packed := load(path) as PackedScene
		if packed == null:
			print("      skipped (not loadable): ", path)
			continue
		var model := packed.instantiate()
		if model == null:
			print("      skipped (not instantiable): ", path)
			continue

		var had_material := _opaque_material_count(model) > 0
		if had_material:
			scenes_with_materials += 1

		var result := Converter.apply(model, preset)
		total_converted += result["converted"]
		leftovers += _opaque_material_count(model)

		# The generated materials are dropped first: freeing a converted CSG model under the
		# headless dummy renderer otherwise raises a spurious "Parameter material is null".
		_strip_materials(model)
		model.free()

	_check("weapon scenes with opaque materials found", scenes_with_materials > 20,
		str(scenes_with_materials))
	_check("every weapon scene converted at least one surface",
		total_converted >= scenes_with_materials, str(total_converted))
	_check("no opaque StandardMaterial3D left on any weapon",
		leftovers == 0, str(leftovers))


## Opaque [BaseMaterial3D]s still attached anywhere under [param node].  Zero after a swap
## is the invariant: whatever is left is a surface the conversion silently missed.
func _opaque_material_count(node: Node) -> int:
	var count := 0
	if node is CSGShape3D:
		var csg_mat: Material = (node as CSGShape3D).material_override
		if csg_mat is BaseMaterial3D \
				and (csg_mat as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			count += 1
	elif node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.material_override != null:
			if _all_opaque(mesh_instance.material_override):
				count += 1
		elif mesh_instance.mesh != null:
			for i in mesh_instance.mesh.get_surface_count():
				var source: Material = mesh_instance.get_surface_override_material(i)
				if source == null:
					source = mesh_instance.mesh.surface_get_material(i)
				if source != null and _all_opaque(source):
					count += 1
	for child in node.get_children():
		count += _opaque_material_count(child)
	return count


## Drops every material reference under [param node] before it is freed, so the headless
## dummy renderer is not asked to sync a material that is about to die with it.
func _strip_materials(node: Node) -> void:
	if node is CSGShape3D:
		(node as CSGShape3D).material_override = null
	elif node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.material_override = null
		if mesh_instance.mesh != null:
			for i in mesh_instance.mesh.get_surface_count():
				mesh_instance.set_surface_override_material(i, null)
	for child in node.get_children():
		_strip_materials(child)


func _all_opaque(material: Material) -> bool:
	return material is BaseMaterial3D \
		and (material as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED


func _scan_tscn(dir_path: String) -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return found
	for file in dir.get_files():
		if file.ends_with(".tscn"):
			found.append(dir_path.path_join(file))
	for sub in dir.get_directories():
		found.append_array(_scan_tscn(dir_path.path_join(sub)))
	return found


# ─────────────────────────────────────────────
#  Fixtures
# ─────────────────────────────────────────────

func _mesh(mesh: Mesh, material: Material) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	if material != null:
		mesh_instance.set_surface_override_material(0, material)
	return mesh_instance


func _checker() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			var on := ((x / 4) + (y / 4)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.85) if on else Color(0.2, 0.2, 0.25))
	return ImageTexture.create_from_image(img)
