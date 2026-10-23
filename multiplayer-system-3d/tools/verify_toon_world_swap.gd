extends Node

## Harness for [ToonMaterialConverter] — the logic behind `maps/map.gd`'s two
## "Painted Toon World" buttons.
##
##   "C:/tools/godot/godot_console.exe" --path . res://tools/verify_toon_world_swap.tscn
##
## Exit code is the number of failed checks, so a clean run exits 0.
##
## This drives the converter against a synthetic tree, not a real map: it is the
## *mapping* (which properties survive, what is skipped, what the cache collapses) that
## can fail silently, and every one of those is cheaper to assert here than in the game.
## The shader itself is covered by `verification/toon_shader_harness.gd` — a shader only
## compiles when something is actually drawn, which never happens headless.
##
## Delete after use.

const PRESET_PATH := "res://assets/materials/painted_toon_world.tres"

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

	# Stand in for "the user edited the preset": values nothing in the source materials
	# below could produce.  Every scalar on a converted material must now match these.
	preset.set_shader_parameter("roughness", 0.17)
	preset.set_shader_parameter("metallic", 0.83)
	preset.set_shader_parameter("toon_steps", 6)
	preset.set_shader_parameter("albedo_color", Color(0.5, 0.5, 0.5, 1.0))

	# --- The source materials ------------------------------------------------
	var opaque := StandardMaterial3D.new()
	opaque.albedo_color = Color(0.8, 0.3, 0.2)
	opaque.albedo_texture = _checker()
	opaque.roughness = 0.3
	opaque.metallic = 0.25
	opaque.vertex_color_use_as_albedo = true

	# Shares `opaque` with the second mesh below; the cache must collapse them to one
	# generated material.  This is the `maps/bind.tscn` case — 1233 surfaces, one material.
	var shared := opaque

	var other := StandardMaterial3D.new()
	other.albedo_color = Color(0.1, 0.6, 0.9)
	other.roughness = 0.9

	var blended := StandardMaterial3D.new()
	blended.albedo_color = Color(1, 1, 1, 0.4)
	blended.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var custom := ShaderMaterial.new()
	custom.shader = preset.shader

	# --- The tree ------------------------------------------------------------
	var root := Node3D.new()
	add_child(root)

	var mesh_a := _mesh(opaque)
	root.add_child(mesh_a)

	var mesh_b := _mesh(shared)
	root.add_child(mesh_b)

	var mesh_c := _mesh(other)
	root.add_child(mesh_c)

	var mesh_blended := _mesh(blended)
	root.add_child(mesh_blended)

	var mesh_custom := _mesh(custom)
	root.add_child(mesh_custom)

	var mesh_bare := MeshInstance3D.new()
	mesh_bare.mesh = BoxMesh.new()          # a surface, but no material anywhere
	root.add_child(mesh_bare)

	# The func_godot case (`maps/hyb_castle.tscn`): the material lives on the [Mesh]
	# resource, with no override on the node at all.
	var baked := StandardMaterial3D.new()
	baked.albedo_color = Color(0.4, 0.7, 0.2)
	var baked_mesh := BoxMesh.new()
	baked_mesh.surface_set_material(0, baked)
	var mesh_from_mesh_resource := MeshInstance3D.new()
	mesh_from_mesh_resource.mesh = baked_mesh
	root.add_child(mesh_from_mesh_resource)

	var combiner := CSGCombiner3D.new()
	combiner.material_override = other
	root.add_child(combiner)
	var box := CSGBox3D.new()               # no material — inherits the combiner's
	combiner.add_child(box)

	# Editor-only decoration: the swap must not walk into a spawn's mannequin.
	var spawn := PlayerSpawn.new()
	root.add_child(spawn)
	var spawn_mesh := _mesh(other)
	spawn.add_child(spawn_mesh)

	# `_ready` (and therefore PlayerSpawn's own tinting) has run by now; snapshot after it.
	await get_tree().process_frame

	var before := {
		"a": mesh_a.get_surface_override_material(0),
		"b": mesh_b.get_surface_override_material(0),
		"c": mesh_c.get_surface_override_material(0),
		"blended": mesh_blended.get_surface_override_material(0),
		"custom": mesh_custom.get_surface_override_material(0),
		"bare": mesh_bare.get_surface_override_material(0),
		"from_mesh": mesh_from_mesh_resource.get_surface_override_material(0),
		"combiner": combiner.material_override,
		"box": box.material_override,
		"spawn": spawn_mesh.get_surface_override_material(0),
	}
	_check("the tree starts from unswapped originals",
		before["a"] == opaque and before["from_mesh"] == null
		and before["combiner"] == other and before["custom"] == custom)

	# --- Swap ----------------------------------------------------------------
	var result := ToonMaterialConverter.swap_under(root, preset)
	var converted: int = result["converted"]
	var skipped: int = result["skipped"]

	# a, b, c and the mesh-resource one (4 mesh surfaces) + the combiner (1 CSG node).
	_check("converted count", converted == 5, str(converted))
	# the blended surface and the custom-shader surface.
	_check("skipped count", skipped == 2, str(skipped))

	# --- What landed ---------------------------------------------------------
	# The preset's scalars are deliberately distinctive and deliberately *different* from
	# what `opaque` carries (0.3 roughness, 0.25 metallic, vertex colour on), so each check
	# below can only pass if the preset won.  This is the property the tool exists to
	# guarantee: editing a parameter in `painted_toon_world.tres` re-tunes the map.
	var toon_a := mesh_a.get_surface_override_material(0) as ShaderMaterial
	_check("mesh swapped to a ShaderMaterial", toon_a != null)
	if toon_a != null:
		_check("uses the toon world shader", toon_a.shader == preset.shader)
		_check("the source's albedo texture reaches the toon material",
			toon_a.get_shader_parameter("albedo_texture") == opaque.albedo_texture)
		_check("and its use_albedo_texture switch is thrown",
			toon_a.get_shader_parameter("use_albedo_texture") == true)
		_check("the preset's roughness wins over the source's 0.3",
			is_equal_approx(toon_a.get_shader_parameter("roughness"), 0.17),
			str(toon_a.get_shader_parameter("roughness")))
		_check("the preset's metallic wins over the source's 0.25",
			is_equal_approx(toon_a.get_shader_parameter("metallic"), 0.83),
			str(toon_a.get_shader_parameter("metallic")))
		_check("the preset's albedo colour tints the source's rather than replacing it",
			toon_a.get_shader_parameter("albedo_color")
				== (preset.get_shader_parameter("albedo_color") as Color) * opaque.albedo_color,
			str(toon_a.get_shader_parameter("albedo_color")))
		_check("...so a flat-coloured surface keeps its own colour",
			toon_a.get_shader_parameter("albedo_color") != preset.get_shader_parameter("albedo_color"))
		_check("the preset's vertex-colour flag wins over the source's",
			toon_a.get_shader_parameter("use_vertex_color")
				== preset.get_shader_parameter("use_vertex_color"))
		_check("an untouched toon knob still comes straight from the preset",
			toon_a.get_shader_parameter("toon_steps") == 6,
			str(toon_a.get_shader_parameter("toon_steps")))
		_check("uv_scale is left at the preset's value",
			toon_a.get_shader_parameter("uv_scale") == preset.get_shader_parameter("uv_scale"))

	var toon_from_mesh := mesh_from_mesh_resource.get_surface_override_material(0) as ShaderMaterial
	_check("a material taken from the mesh resource is converted",
		toon_from_mesh != null and toon_from_mesh.shader == preset.shader
		and is_equal_approx(toon_from_mesh.get_shader_parameter("roughness"), 0.17))

	# The cache: two surfaces on the same source must share one generated material.
	_check("shared source material yields one ShaderMaterial",
		mesh_a.get_surface_override_material(0) == mesh_b.get_surface_override_material(0))
	_check("a different source material yields a different one",
		mesh_a.get_surface_override_material(0) != mesh_c.get_surface_override_material(0))

	# --- What must be left alone --------------------------------------------
	_check("blended material is not converted",
		mesh_blended.get_surface_override_material(0) == before["blended"])
	_check("custom shader material is not converted",
		mesh_custom.get_surface_override_material(0) == before["custom"])
	_check("a surface with no material is untouched",
		mesh_bare.get_surface_override_material(0) == null)

	var combiner_override := combiner.material_override as ShaderMaterial
	_check("CSG combiner is swapped", combiner_override != null
		and combiner_override.shader == preset.shader)
	_check("a CSG child with no material is left alone", box.material_override == null)
	_check("a PlayerSpawn subtree is not walked",
		spawn_mesh.get_surface_override_material(0) == before["spawn"])

	# --- Live refresh --------------------------------------------------------
	# One entry per *distinct* source material, not per surface: `opaque` backs two meshes
	# and `other` backs a mesh and the CSG combiner, so three surfaces collapse away.
	_check("one generated material per distinct source, not per surface",
		result["generated"].size() == 3, str(result["generated"].size()))

	# What `Map._process` calls when `painted_toon_world.tres` changes under the map.
	var before_refresh := mesh_a.get_surface_override_material(0)
	preset.set_shader_parameter("roughness", 0.05)
	preset.set_shader_parameter("toon_steps", 2)
	var refreshed: int = ToonMaterialConverter.refresh(result["generated"], preset)
	_check("refresh rewrote every generated material", refreshed == 3, str(refreshed))
	_check("...in place, without reallocating anything",
		mesh_a.get_surface_override_material(0) == before_refresh)
	var refreshed_mat := mesh_a.get_surface_override_material(0) as ShaderMaterial
	_check("...and the new preset values landed on it",
		refreshed_mat != null
		and is_equal_approx(refreshed_mat.get_shader_parameter("roughness"), 0.05)
		and refreshed_mat.get_shader_parameter("toon_steps") == 2)

	# --- Idempotence ---------------------------------------------------------
	# Swapping a tree that is already swapped must convert nothing: the effective sources
	# are now toon ShaderMaterials, which are not a BaseMaterial3D and so are skipped.
	# This is exactly why `Map.replace_with_painted_toon_world()` strips before it swaps.
	var naive := ToonMaterialConverter.swap_under(root, preset)
	_check("swapping an already-swapped tree converts nothing",
		naive["converted"] == 0, str(naive["converted"]))
	_check("...and captures nothing to restore", naive["state"].is_empty())

	# --- Restore -------------------------------------------------------------
	var restored := ToonMaterialConverter.restore(result["state"])
	_check("restore reports the touched nodes", restored == 5, str(restored))

	_check("mesh override cleared", mesh_a.get_surface_override_material(0) == before["a"])
	_check("second mesh override cleared", mesh_b.get_surface_override_material(0) == before["b"])
	_check("third mesh override cleared", mesh_c.get_surface_override_material(0) == before["c"])
	_check("the override written for a mesh-resource material is cleared again",
		mesh_from_mesh_resource.get_surface_override_material(0) == before["from_mesh"])
	_check("skipped surfaces unchanged",
		mesh_blended.get_surface_override_material(0) == before["blended"]
		and mesh_custom.get_surface_override_material(0) == before["custom"])
	_check("CSG override restored to the original material object",
		combiner.material_override == before["combiner"])

	# A second round trip has to derive from the originals again, not from the conversion
	# it just undid — that is the property `Map`'s buttons depend on.
	var again := ToonMaterialConverter.swap_under(root, preset)
	_check("re-swapping after a restore converts the same surfaces",
		again["converted"] == 5, str(again["converted"]))
	ToonMaterialConverter.restore(again["state"])
	_check("second restore put the mesh back",
		mesh_a.get_surface_override_material(0) == before["a"])

	_check("restoring an empty state is a no-op",
		ToonMaterialConverter.restore({}) == 0)

	print("")
	print("checks: ", _checks, "  fails: ", _fails)
	get_tree().quit(_fails)


func _mesh(material: Material) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = BoxMesh.new()
	mesh_instance.set_surface_override_material(0, material)
	return mesh_instance


func _checker() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			var on := ((x / 4) + (y / 4)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.85) if on else Color(0.2, 0.2, 0.25))
	return ImageTexture.create_from_image(img)
