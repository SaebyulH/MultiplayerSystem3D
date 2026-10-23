class_name ToonMaterialConverter
extends RefCounted

## Re-shades a map's geometry through the painted-toon shader while keeping each
## surface's own texture and colour, and can put the originals back exactly.
##
## [b]What it does that [MaterialReplacer] does not.[/b]  [MaterialReplacer] assigns
## [i]one[/i] material to every mesh, so a whole map becomes a single flat surface — all
## of its texture work is gone.  This builds a [ShaderMaterial] per source material,
## keeping that material's textures (albedo, normal, AO, emission) on the toon shader, so
## the map keeps its texture work and only the [i]shading[/i] changes.
##
## [b]The preset owns the look; the source owns only its textures.[/b]  Every generated
## material is seeded from [param preset]'s full uniform set, and the only thing layered on
## top is the source's own textures — see [method convert_material] for why that line is
## drawn where it is.  The practical consequence, and the point: editing a parameter in
## `painted_toon_world.tres` re-tunes every surface in the map, because nothing the source
## material happens to carry can override it.
##
## [b]Nothing here is networked.[/b]  A swapped material is cosmetic and local, exactly
## like [MaterialReplacer]'s and like the old team tinting: every peer derives the same
## materials from the same extracted map scene, so it needs no RPC.  See
## `docs/02-netcode.md` and `docs/04-optimization.md`.
##
## [b]Pure logic, no scene.[/b]  Like [PayloadPathLinker], this class touches no files and
## owns no node, so `tools/verify_toon_world_swap.tscn` can drive it headlessly and
## `maps/map.gd` is a thin button around it.

## Per-node capture keys.  A mesh records one entry per surface; a CSG node records the
## single override Property it had.
const STATE_SURFACES := "surfaces"
const STATE_OVERRIDE := "override"


## Re-shades every mesh and CSG node under [param root] and returns a record of what was
## there before:
##
## [code]{
##     "state":     Dictionary,  # node -> captured originals, feed to [method restore]
##     "converted": int,         # surfaces/nodes put on the toon shader
##     "skipped":   int,         # surfaces/nodes left alone (see the skip rules below)
## }[/code]
##
## Only surfaces that already carry a material are touched — an untextured surface keeps
## Godot's default rather than being handed a flat toon one, so the swap is predictable
## and never invents state the mapper did not author.  Materials that are not a
## [BaseMaterial3D], and materials that are not opaque, are skipped too: the toon shader
## is opaque, so converting a blended surface (glass) would render it solid, and a custom
## shader (the payload route line, the wallhack outline) has no textures to lift.
##
## A converted surface keeps its own **textures** and nothing else — every scalar and
## colour comes from the preset.  See [method convert_material].
static func swap_under(root: Node, preset: ShaderMaterial) -> Dictionary:
	var state: Dictionary = {}
	# One entry per *distinct* generated material, for [method refresh] to re-write later.
	var generated: Array = []
	var result := { "state": state, "generated": generated, "converted": 0, "skipped": 0 }
	if root == null or preset == null or preset.shader == null:
		return result

	# One ShaderMaterial per distinct source material.  This is not an optimisation but a
	# correctness-of-scale matter: `maps/bind.tscn`'s 1233 surfaces all point at a single
	# shared material, so without the cache the swap would build 1233 identical materials.
	# Dictionaries are reference types, so the counters below accumulate through `ctx`.
	var ctx := {
		"preset": preset,
		"cache": {},
		"state": state,
		"generated": generated,
		"converted": 0,
		"skipped": 0,
	}

	_walk(root, ctx)

	result["converted"] = ctx["converted"]
	result["skipped"] = ctx["skipped"]
	return result


## Puts every node in [param state] back the way [method swap_under] found it, and returns
## how many nodes were restored.  Nodes that have since been freed are skipped, so a state
## captured before a map swap is safe to restore after one.
static func restore(state: Dictionary) -> int:
	var restored := 0
	for node in state.keys():
		if not is_instance_valid(node):
			continue
		var record: Dictionary = state[node]

		if node is CSGShape3D:
			(node as CSGShape3D).material_override = record[STATE_OVERRIDE]
			restored += 1
			continue

		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			var mesh := mesh_instance.mesh
			if mesh == null:
				continue
			var surfaces: Array = record[STATE_SURFACES]
			for i in mini(surfaces.size(), mesh.get_surface_count()):
				mesh_instance.set_surface_override_material(i, surfaces[i])
			restored += 1

	return restored


## Builds one toon [ShaderMaterial] for [param source], or `null` when the source must be
## left alone (see the skip rules on [method swap_under]).  Static and public so a harness
## can test the property mapping without a scene.
##
## Named [i]convert_material[/i], not `convert`, on purpose: `convert` is a
## `@GlobalScope` utility, and a Variant-typed argument here (`ctx["preset"]`) makes the
## call dynamically dispatched, which silently picks the global one up instead of this.
## [b]What the source contributes, and what it does not.[/b]  Only its [i]textures[/i] —
## albedo, normal, AO and emission, plus the `use_*` switch each one needs before the shader
## will sample it at all.  Every scalar comes from [param preset] instead (`metallic`,
## `roughness`, `normal_strength`, `ao_strength`, the emission tint and energy,
## `use_vertex_color`), so editing those in `painted_toon_world.tres` re-tunes the whole map
## the moment the swap is re-run.  The one shared value is `albedo_color`, which is applied
## as a [i]tint[/i] over the surface's own colour rather than replacing it — see the comment
## in the body for why that exception is worth making.
##
## The split is deliberate.  A shared preset cannot know a surface's textures, but it can
## express its roughness perfectly well — and letting the source win for those made the
## preset look broken, because a property the user had just edited was silently overridden
## by whatever the map's materials happened to carry.  It was not hypothetical: the generated
## func_godot materials leave `roughness` at its `StandardMaterial3D` default of 1.0, so
## *every* surface came out fully rough no matter what the preset said.
static func convert_material(source: Material, preset: ShaderMaterial) -> ShaderMaterial:
	if preset == null or preset.shader == null:
		return null
	if not (source is BaseMaterial3D):
		return null

	var base := source as BaseMaterial3D
	if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return null

	var toon := ShaderMaterial.new()
	_apply(base, preset, toon)
	return toon


## Writes [param preset]'s look and [param base]'s textures onto [param toon], in place.
##
## Shared by [method convert_material], which has just made the material, and
## [method refresh], which is re-writing one that already exists — one implementation, so a
## live parameter edit and a fresh swap cannot drift apart.
static func _apply(base: BaseMaterial3D, preset: ShaderMaterial, toon: ShaderMaterial) -> void:
	toon.shader = preset.shader

	# Seed from the preset so every uniform it authors survives.  That seed *is* the look —
	# the only thing layered on top of it below is the surface's own textures.
	for uniform in preset.shader.get_shader_uniform_list():
		var uniform_name: String = uniform["name"]
		toon.set_shader_parameter(uniform_name, preset.get_shader_parameter(uniform_name))

	# Albedo colour is a *tint* on top of whatever the surface already is, not a
	# replacement for it: `preset.albedo_color * source.albedo_color`, which the shader
	# then multiplies by the texture as it already did.
	#
	# That is the one place the preset does not simply win, and it earns the exception.  A
	# map whose geometry is coloured flat rather than textured would otherwise lose its
	# identity — `maps/2fort.tscn` is a single teal `StandardMaterial3D` for its whole CSG
	# world, and `maps/courtyard.tscn` a single grey one — while editing a *tint* still
	# re-tunes every surface, which is the property the rule exists to protect.  On a
	# textured surface the source colour is white, so this is just the preset's value.
	var preset_albedo: Variant = preset.get_shader_parameter("albedo_color")
	if preset_albedo is Color:
		toon.set_shader_parameter("albedo_color", (preset_albedo as Color) * base.albedo_color)
	else:
		toon.set_shader_parameter("albedo_color", base.albedo_color)

	# Textures, and the switch that makes each one sampled.
	#
	# `uv_scale` is deliberately not sourced from `uv1_scale`: func_godot bakes tiling into
	# the mesh UVs themselves (`func_godot_util.gd` `get_valve_uv` / `get_quake_uv`), so the
	# source materials leave `uv1_scale` at 1 and the mesh UVs already carry the repeat.
	if base.albedo_texture != null:
		toon.set_shader_parameter("use_albedo_texture", true)
		toon.set_shader_parameter("albedo_texture", base.albedo_texture)

	if base.normal_enabled and base.normal_texture != null:
		toon.set_shader_parameter("use_normal_map", true)
		toon.set_shader_parameter("normal_texture", base.normal_texture)

	if base.ao_enabled and base.ao_texture != null:
		toon.set_shader_parameter("use_ao_texture", true)
		toon.set_shader_parameter("ao_texture", base.ao_texture)

	if base.emission_enabled and base.emission_texture != null:
		toon.set_shader_parameter("use_emission_texture", true)
		toon.set_shader_parameter("emission_texture", base.emission_texture)


## Re-writes every material a [method swap_under] produced, from the *current* state of
## [param preset].  This is what makes editing the preset update a tooned map live.
##
## The generated materials are mutated in place, so nothing in the scene is touched, no
## [ShaderMaterial] is reallocated and no node property is reassigned — which matters,
## because reassigning overrides would re-dirty the scene on every slider tick.  The cost
## is one pass per *distinct* material, not per surface: the swap caches by source material,
## so a real map lands in the single digits (`maps/hyb_castle.tscn` converts ~110 surfaces
## out of a handful of materials).
##
## [param generated] is the `"generated"` array from a [method swap_under] result.
static func refresh(generated: Array, preset: ShaderMaterial) -> int:
	if preset == null or preset.shader == null:
		return 0

	var count := 0
	for entry in generated:
		var toon: ShaderMaterial = entry["material"]
		var source: Material = entry["source"]
		# A freed generated material means the map was torn down under us; skip rather
		# than resurrect it.
		if not is_instance_valid(toon) or not (source is BaseMaterial3D):
			continue
		_apply(source as BaseMaterial3D, preset, toon)
		count += 1
	return count


# ─────────────────────────────────────────────
#  INTERNALS
# ─────────────────────────────────────────────

## Depth-first from [param node]'s children.  A [PlayerSpawn] subtree is pruned rather
## than walked: its mannequin is an editor-only team-tint marker that `hide()`s itself
## outside the editor, so re-shading it would only add noise to the preview.
static func _walk(node: Node, ctx: Dictionary) -> void:
	for child in node.get_children():
		if child is PlayerSpawn:
			continue
		if child is CSGShape3D:
			_swap_csg(child, ctx)
		elif child is MeshInstance3D:
			_swap_mesh(child, ctx)
		_walk(child, ctx)


## Mesh surfaces are swapped one override at a time, because a single mesh can carry a
## different material per surface — `maps/hyb_castle.tscn`'s func_godot world is one
## [MeshInstance3D] holding every textured surface of the map.
static func _swap_mesh(mesh_instance: MeshInstance3D, ctx: Dictionary) -> void:
	var mesh := mesh_instance.mesh
	if mesh == null:
		return

	# Captured for every surface, not only the swapped ones: restoring an index to the
	# value it already had is a no-op, and it keeps the record complete if the mesh's
	# surface count ever changes under us.
	var previous: Array = []
	var touched := false

	for i in mesh.get_surface_count():
		var prev := mesh_instance.get_surface_override_material(i)
		previous.append(prev)

		# The *effective* material: an override wins over the mesh's own.  This is what
		# makes `maps/bind.tscn` work, where the authored materials are the surface
		# overrides themselves rather than properties of the shared [Mesh].
		var source: Material = prev
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
		touched = true

	if touched:
		ctx["state"][mesh_instance] = { STATE_SURFACES: previous }


## CSG geometry goes through `material_override` on the node that carries it — in the
## CSG-authored maps that is the [CSGCombiner3D] root, with the [CSGBox3D] children
## carrying nothing and inheriting from it (see `maps/2fort.tscn`).  A node with no
## authored material is therefore left alone rather than handed a flat one: its parent's
## swap already covers it, and writing here would only risk clobbering that.
static func _swap_csg(csg: CSGShape3D, ctx: Dictionary) -> void:
	pass
	#var prev_override := csg.material_override
#
	#var source: Material = prev_override
	#if source == null:
		#source = csg.material
	#if source == null:
		#return
#
	#var toon := _toon_for(source, ctx)
	#if toon == null:
		#ctx["skipped"] = ctx["skipped"] + 1
		#return
#
	#csg.material_override = toon
	#ctx["state"][csg] = { STATE_OVERRIDE: prev_override }
	#ctx["converted"] = ctx["converted"] + 1


## The cached conversion for [param source].  A `null` result is cached too, so a material
## that is not convertible is only ever examined once.
static func _toon_for(source: Material, ctx: Dictionary) -> ShaderMaterial:
	var cache: Dictionary = ctx["cache"]
	if not cache.has(source):
		var toon := convert_material(source, ctx["preset"])
		cache[source] = toon
		# Recorded here, at the cache-miss, so there is exactly one entry per distinct
		# generated material however many surfaces share it.
		if toon != null:
			ctx["generated"].append({ "material": toon, "source": source })
	return cache[source]
