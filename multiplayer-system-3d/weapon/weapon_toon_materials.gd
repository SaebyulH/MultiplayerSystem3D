class_name WeaponToonMaterials
extends RefCounted

## Re-shades a spawned weapon model through the painted-toon shader so a toon
## character holding it is not interrupted by a PBR gun, keeping every texture the
## weapon material carried.
##
## [b]Why runtime, and why not authored `.tres` files.[/b]  Weapon models are
## instantiated at runtime from ~40 scenes whose meshes mostly live inside imported
## GLBs, with inline [StandardMaterial3D] sub-resources and [member MeshInstance3D.material_override]
## on top.  Authoring per-surface `.tres` files the way the characters do would mean the
## same fragility `05-known-issues.md` #54 records, spread over forty scenes.  One pass at
## the single spawn site (`WeaponController.spawn_weapon_model()`) covers the first-person
## weapon, every remote player's weapon and every bot's.
##
## [b]The preset owns the look; the source keeps its surface detail.[/b]  Gunmetal, wood and
## polymer differ in roughness and metallic in ways the preset cannot know, so it owns the
## toon *look* (ramp, noise, rim, gain, specular shaping) and the source keeps albedo,
## normal, AO, emission, and the [i]separate[/i] metallic/roughness maps with their channel
## selectors, which is what [member BaseMaterial3D.metallic_texture] and
## [member BaseMaterial3D.roughness_texture] actually are.
##
## [b]Nothing here is networked.[/b]  Like the old team tinting, this is cosmetic and local:
## every peer derives the same materials from the same scene.  Weapon models are
## re-instantiated on a swap, never un-tooned, so there is no restore or refresh path.


## Re-shades every mesh and CSG surface under [param root] and returns
## [code]{"converted": int, "skipped": int}[/code].
##
## A surface whose effective material is missing is left alone rather than handed a flat
## toon material, and a material that is not a [BaseMaterial3D] or is not opaque is skipped:
## the toon shader is opaque, so converting a scope's blended glass would render it solid —
## the same exception the character materials make for `blackhat`'s glasses.
##
## The cache is keyed by source material and is local to this call, so a weapon whose
## surfaces share one GLB material builds exactly one [ShaderMaterial].
static func apply(root: Node, preset: ShaderMaterial) -> Dictionary:
	var result := { "converted": 0, "skipped": 0 }
	if root == null or preset == null or preset.shader == null:
		return result

	var ctx := { "preset": preset, "cache": {}, "converted": 0, "skipped": 0 }
	_visit(root, ctx)

	result["converted"] = ctx["converted"]
	result["skipped"] = ctx["skipped"]
	return result


## Builds one toon [ShaderMaterial] for [param source], or `null` when it must be left
## alone (see the skip rules on [method apply]).  Static and public so the harness can test
## the property mapping without a scene.
static func convert_material(source: Material, preset: ShaderMaterial) -> ShaderMaterial:
	if preset == null or preset.shader == null:
		return null
	if not (source is BaseMaterial3D):
		return null

	# A converted material is a ShaderMaterial, which is not a BaseMaterial3D, so applying
	# twice converts nothing the second time — same idempotence rule the map converter has.
	var base := source as BaseMaterial3D
	if base == null:
		return null
	if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return null

	var toon := ShaderMaterial.new()
	_apply(base, preset, toon)
	return toon


# ─────────────────────────────────────────────
#  INTERNALS
# ─────────────────────────────────────────────

## Depth-first from [param node] itself, so a mesh root is handled too.
static func _visit(node: Node, ctx: Dictionary) -> void:
	if node is CSGShape3D:
		_swap_csg(node as CSGShape3D, ctx)
	elif node is MeshInstance3D:
		_swap_mesh(node as MeshInstance3D, ctx)
	for child in node.get_children():
		_visit(child, ctx)


## A weapon mesh can carry one material for every surface ([member MeshInstance3D.material_override],
## common on the hand-authored weapon scenes) or one override per surface (the GLB case),
## falling back to the material baked into the [Mesh] resource itself.  Converting per
## surface rather than writing a single node override keeps a multi-material mesh's parts
## distinct.
static func _swap_mesh(mesh_instance: MeshInstance3D, ctx: Dictionary) -> void:
	var override := mesh_instance.material_override
	if override != null:
		var toon := _toon_for(override, ctx)
		if toon == null:
			ctx["skipped"] = ctx["skipped"] + 1
			return
		mesh_instance.material_override = toon
		ctx["converted"] = ctx["converted"] + 1
		return

	var mesh := mesh_instance.mesh
	if mesh == null:
		return

	for i in mesh.get_surface_count():
		var source: Material = mesh_instance.get_surface_override_material(i)
		if source == null:
			source = mesh.surface_get_material(i)
		if source == null:
			continue

		var toon := _toon_for(source, ctx)
		if toon == null:
			ctx["skipped"] = ctx["skipped"] + 1
			continue

		mesh_instance.set_surface_override_material(i, toon)
		ctx["converted"] = ctx["converted"] + 1


## CSG weapons (the shuriken, MRE, kiss-of-death and impact-grenade models) author their
## material on the node's [member CSGShape3D.material_override].  A CSG node with no
## material of its own is left alone — its parent's override already covers it.
static func _swap_csg(csg: CSGShape3D, ctx: Dictionary) -> void:
	var override := csg.material_override
	if override == null:
		return
	var toon := _toon_for(override, ctx)
	if toon == null:
		ctx["skipped"] = ctx["skipped"] + 1
		return
	csg.material_override = toon
	ctx["converted"] = ctx["converted"] + 1


## The cached conversion for [param source].  A `null` result is cached too, so an
## unconvertible material shared by many surfaces is only examined once.
static func _toon_for(source: Material, ctx: Dictionary) -> ShaderMaterial:
	var cache: Dictionary = ctx["cache"]
	if not cache.has(source):
		cache[source] = convert_material(source, ctx["preset"])
	return cache[source]


## Writes [param preset]'s look and [param base]'s surface detail onto [param toon].
##
## One implementation for every conversion, so there is no second mapping to keep in step.
static func _apply(base: BaseMaterial3D, preset: ShaderMaterial, toon: ShaderMaterial) -> void:
	toon.shader = preset.shader

	# The preset is the look: ramp, painted noise, rim, brightness gain, specular shaping.
	# Unset parameters come back as null and would wipe the shader's own default, so they
	# are skipped rather than written.
	for uniform in preset.shader.get_shader_uniform_list():
		var uniform_name: String = uniform["name"]
		var value: Variant = preset.get_shader_parameter(uniform_name)
		if value != null:
			toon.set_shader_parameter(uniform_name, value)

	# The source keeps its surface detail.  Albedo colour is a tint over the preset's
	# (white by default), so a textured weapon's own colour survives.
	var preset_albedo: Variant = toon.get_shader_parameter("albedo_color")
	var tint: Color = preset_albedo if preset_albedo is Color else Color.WHITE
	toon.set_shader_parameter("albedo_color", tint * base.albedo_color)
	if base.albedo_texture != null:
		toon.set_shader_parameter("use_albedo_texture", true)
		toon.set_shader_parameter("albedo_texture", base.albedo_texture)

	toon.set_shader_parameter("use_vertex_color", base.vertex_color_use_as_albedo)
	# glTF materials can carry a texture transform; unlike func_godot maps, nothing bakes
	# the repeat into the weapon UVs.  Only the scale is expressible in this shader.
	toon.set_shader_parameter("uv_scale", Vector2(base.uv1_scale.x, base.uv1_scale.y))

	if base.normal_enabled and base.normal_texture != null:
		toon.set_shader_parameter("use_normal_map", true)
		toon.set_shader_parameter("normal_texture", base.normal_texture)
		toon.set_shader_parameter("normal_strength", base.normal_scale)

	# Deliberately NOT copied from the source.  These are the three knobs that define the
	# character look — a non-metal, matte surface (`metallic` 0 leaves the whole diffuse
	# ramp live, and the character materials sit around roughness 0.85 with no stylised
	# highlight) — so the preset owns them and every weapon reads as the same family.  A
	# source gunmetal material is metallic 1.0, which under this shader removes its diffuse
	# entirely and leaves only highlights; copying that is exactly what made weapons look
	# unlike the characters.  Their *maps* are still carried below, so the surface keeps its
	# metal/roughness detail on top of the preset's level.

	# StandardMaterial3D keeps metallic and roughness as *separate* maps with a channel
	# selector each (the ak, for one, samples both from green), which is the shape the
	# shader's metallic/roughness uniforms take.
	if base.metallic_texture != null:
		toon.set_shader_parameter("use_metallic_texture", true)
		toon.set_shader_parameter("metallic_texture", base.metallic_texture)
		toon.set_shader_parameter("metallic_channel", int(base.metallic_texture_channel))
	if base.roughness_texture != null:
		toon.set_shader_parameter("use_roughness_texture", true)
		toon.set_shader_parameter("roughness_texture", base.roughness_texture)
		toon.set_shader_parameter("roughness_channel", int(base.roughness_texture_channel))

	if base.ao_enabled and base.ao_texture != null:
		toon.set_shader_parameter("use_ao_texture", true)
		toon.set_shader_parameter("ao_texture", base.ao_texture)

	if base.emission_enabled:
		if base.emission_texture != null:
			toon.set_shader_parameter("use_emission_texture", true)
			toon.set_shader_parameter("emission_texture", base.emission_texture)
		toon.set_shader_parameter("emission_color", base.emission)
		toon.set_shader_parameter("emission_energy", base.emission_energy_multiplier)
