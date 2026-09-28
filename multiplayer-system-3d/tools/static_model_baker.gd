class_name StaticModelBaker

## Bakes a rigged source scene into a STATIC display model for TrenchBroom.
##
## TrenchBroom renders display models through Assimp, and a model carrying a skin —
## `skins`, `JOINTS_0`, `WEIGHTS_0`, a bone hierarchy — previews as **nothing at all**,
## while every static model draws. That is empirical (docs/05-known-issues.md #66): the
## mechanism inside Assimp is not pinned down, but `skins: 0` is the reliable test.
##
## This strips the rig: every `MeshInstance3D`'s geometry is rebound to a fresh
## `ArrayMesh` with the bone/weight arrays removed, and each node's transform is baked
## down onto the flat result. Vertex positions are already in bind-pose space, so the
## output is the model in its rest pose.
##
## A prop that merely *should not* be rigged in the editor wants this too — the game
## keeps building the original `scene_file`, only the preview changes.
##
## Static, so both the manual escape hatch (`tools/bake_static_model.gd`) and the
## generator (`tools/generate_prop_entities.gd`) share one implementation.

## The 180° yaw the assembler adds on map build (`entity_assembler.gd:199`) but
## TrenchBroom's glTF display does not. Baking it into the display model is what makes
## the editor preview agree with the built node — see docs/06.
const DEFAULT_ROTATION_OFFSET := Vector3(0, 180, 0)


## Instantiates `packed`, strips the rig, and writes a static `.glb` to `out_path`.
##
## `host` is only a place to park the instance while its transforms resolve — under a
## rig, mesh nodes often sit under bones, and dropping the hierarchy without baking the
## transform down would scatter the pieces. The instance is freed before returning.
##
## Coroutine: awaits a frame so the parked scene settles. Callers must `await` it.
static func bake(host: Node, packed: PackedScene,
		out_path: String, rotation_offset: Vector3 = DEFAULT_ROTATION_OFFSET) -> bool:
	var src := packed.instantiate() as Node3D
	if src == null:
		printerr("FAIL: source is not a Node3D scene")
		return false

	host.add_child(src)
	await host.get_tree().process_frame

	var out_root := Node3D.new()
	out_root.name = "static"
	var to_local := src.global_transform.affine_inverse()

	var baked := 0
	for node in src.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var mesh := mi.mesh as ArrayMesh
		if mesh == null:
			continue

		var stripped := ArrayMesh.new()
		for s in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(s)
			arrays[Mesh.ARRAY_BONES] = null
			arrays[Mesh.ARRAY_WEIGHTS] = null
			# Flags are left at their default so the format is re-derived from the
			# arrays.  Carrying the source surface's format over would keep the stale
			# skinning flags set for a surface that no longer has bones.
			stripped.add_surface_from_arrays(
				mesh.surface_get_primitive_type(s), arrays)
			var material := mesh.surface_get_material(s)
			if material != null:
				stripped.surface_set_material(stripped.get_surface_count() - 1, material)

		if stripped.get_surface_count() == 0:
			continue

		var out_mi := MeshInstance3D.new()
		out_mi.name = str(mi.name).replace(".", "_")
		out_mi.mesh = stripped
		out_mi.transform = to_local * mi.global_transform
		out_root.add_child(out_mi)
		baked += 1

	src.queue_free()

	if baked == 0:
		printerr("FAIL: no MeshInstance3D with geometry found in the source scene")
		out_root.free()
		return false

	# Godot's transpose is unambiguous: rotate about Y before export, matching what
	# `FuncGodotFGDModelPointClass.rotation_offset` does for a generated display model.
	out_root.rotate_x(deg_to_rad(rotation_offset.x))
	out_root.rotate_y(deg_to_rad(rotation_offset.y))
	out_root.rotate_z(deg_to_rad(rotation_offset.z))

	var ok := save(out_root, out_path)
	out_root.free()
	return ok


## Writes `root` (which must not be in the tree) to a `.glb` at a `res://` path.
static func save(root: Node3D, out_path: String) -> bool:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(root, state) != OK:
		printerr("FAIL: append_from_scene failed for %s" % out_path)
		return false

	var path := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if doc.write_to_filesystem(state, path) != OK:
		printerr("FAIL: could not write %s" % path)
		return false
	return true
