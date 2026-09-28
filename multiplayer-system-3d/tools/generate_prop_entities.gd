extends Node
## Generates a TrenchBroom entity definition for every model dropped into assets/props/.
##
## Adding a prop entity by hand means a `.tres` with eleven settings, six of which
## mis-default *silently* — each one was found by hitting the bug it causes
## (docs/05-known-issues.md #60-#66). This encodes all of them, so a new prop is:
## drop the model in `assets/props/<name>/`, run this, re-export, reload TrenchBroom.
##
## It is **create-missing-only**: an entity that already exists is never rewritten, so
## hand-tuned work survives (`Truck`'s authored size, `mannequin`'s static-bake pointer,
## `test.tres`). To regenerate one, delete its `.tres` and re-run.
##
## It does **not** export. `tools/export_trenchbroom_fgd.tscn` stays the step that
## validates — a generator that also published would hide its own mistakes.
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/generate_prop_entities.tscn
##
## Exits non-zero if an entity could not be written.

const PROPS_DIR := "res://assets/props/"
const ENTITIES_DIR := "res://trenchbroom/entities/"
const DISPLAY_DIR := "res://trenchbroom/models/"
const FGD_PATH := "res://trenchbroom/entities/multiplayer_system_3d_fgd.tres"

## Anything that imports as a `PackedScene` can be a prop source.
const MODEL_EXTENSIONS := ["glb", "gltf", "fbx", "obj", "dae", "tscn"]

## func_godot/default_inverse_scale_factor — TrenchBroom units per Godot unit.
const SCALE := 32.0

## The 180° yaw the assembler adds at map build but TrenchBroom's display does not.
const ROTATION_OFFSET := Vector3(0, 180, 0)

## MUST include the `undefined` branch: the entity browser evaluates this with no
## entity behind it, so a form that requires the property leaves the prop undrawn
## (#65). Do not "simplify" it to `scale * 32`.
const SCALE_EXPRESSION := "{{ scale == undefined -> 32, scale * 32 }}"

const MODELS_SUB_FOLDER := "trenchbroom/models"

# Scripts the generated resources point at.  Uids are from the .uid files beside them.
const PATH_DISPLAY_DESCRIPTOR := "res://addons/func_godot/src/fgd/func_godot_fgd_point_class_display_descriptor.gd"
const UID_DISPLAY_DESCRIPTOR := "uid://d1nwwgcrner8b"
const PATH_POINT_CLASS := "res://addons/func_godot/src/fgd/func_godot_fgd_point_class.gd"
const UID_POINT_CLASS := "uid://cxsqwtsqd8w33"
const PATH_MODEL_POINT_CLASS := "res://addons/func_godot/src/fgd/func_godot_fgd_model_point_class.gd"
const UID_MODEL_POINT_CLASS := "uid://ldfqjtq0br35"

const PATH_BASE_FGD := "res://addons/func_godot/fgd/func_godot_fgd.tres"
const UID_BASE_FGD := "uid://crgpdahjaj"
const PATH_FGD_SCRIPT := "res://addons/func_godot/src/fgd/func_godot_fgd_file.gd"
const UID_FGD_SCRIPT := "uid://drlmgulwbjwqu"

var _failures := 0


func _ready() -> void:
	var models := _scan(PROPS_DIR)
	if models.is_empty():
		print("no model files found under %s" % PROPS_DIR)

	var registered := _registered_classnames()
	var created := 0
	for path in models:
		if await _ensure_entity(path, registered):
			created += 1

	# Rewritten every run, not only when something was added: `entity_definitions` has to
	# mirror the folder, or deleting an entity's `.tres` leaves the FGD referencing a file
	# that no longer exists.  Rebuilt sorted and deduped, so the result is reproducible.
	_rewrite_definitions()

	print("---")
	print("%d model(s) scanned, %d entity(s) created" % [models.size(), created])
	if _failures > 0:
		printerr("FAIL: %d problem(s)" % _failures)
	get_tree().quit(_failures)


# --- scanning ---------------------------------------------------------------------

func _scan(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	_walk(dir_path, found)
	# DirAccess order is filesystem-dependent; sort so a run is reproducible.
	found.sort()
	return found


func _walk(dir_path: String, found: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				_walk(full + "/", found)
			elif entry.get_extension().to_lower() in MODEL_EXTENSIONS:
				found.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## classname -> definition, for every entity already registered on the FGD.
##
## A load failure is a warning, not a failure: the usual cause is a deleted `.tres` that
## `entity_definitions` still points at, which `_rewrite_definitions()` repairs in this
## same run.  Proceeding with nothing registered is what lets that repair happen.
func _registered_classnames() -> Dictionary:
	var fgd := load(FGD_PATH) as FuncGodotFGDFile
	if fgd == null:
		printerr("warn: could not load %s — rebuilding it from the folder" % FGD_PATH)
		return {}
	return fgd.get_entity_definitions()


# --- one model --------------------------------------------------------------------

func _ensure_entity(model_path: String, registered: Dictionary) -> bool:
	var classname := _classname_for(model_path)
	var entity_path := ENTITIES_DIR + model_path.get_file().get_basename().to_snake_case() + ".tres"

	# Create-missing-only. The classname check catches a same-named entity living under
	# a different filename, which would collide in the FGD rather than on disk.
	if registered.has(classname):
		print("skip  %-14s already registered" % classname)
		return false
	if FileAccess.file_exists(entity_path):
		print("skip  %-14s %s already exists" % [classname, entity_path])
		return false

	var packed := load(model_path) as PackedScene
	if packed == null:
		_failures += 1
		printerr("FAIL: %s does not import as a PackedScene" % model_path)
		return false

	var inst := packed.instantiate() as Node3D
	if inst == null:
		_failures += 1
		printerr("FAIL: %s is not a Node3D scene" % model_path)
		return false
	add_child(inst)
	await get_tree().process_frame

	var box := _measure(inst)
	var rigged := _is_rigged(inst)
	remove_child(inst)
	inst.queue_free()

	if box.size == Vector3.ZERO:
		_failures += 1
		printerr("FAIL: %s has no mesh geometry — cannot derive a size box" % model_path)
		return false

	var size := _tb_size(box)

	# A rigged model draws as NOTHING in TrenchBroom (#66), so it gets a baked static
	# display model while keeping the rigged scene as what the map builds.
	var display := ""
	if rigged:
		display = DISPLAY_DIR + classname.capitalize().replace(" ", "") + "_static.glb"
		if not await StaticModelBaker.bake(self, packed, display, ROTATION_OFFSET):
			_failures += 1
			return false

	var text := _entity_text(classname, model_path, size, display)
	if not _write(entity_path, text):
		return false

	print("new   %-14s %s%s" % [classname, entity_path, "  (rigged -> baked display)" if rigged else ""])
	return true


func _classname_for(model_path: String) -> String:
	var base := model_path.get_file().get_basename()
	# A generically-named file (model.glb, prop.fbx) is better named for its folder.
	if base.to_lower() in ["model", "prop", "mesh", "scene", "untitled"]:
		base = model_path.get_base_dir().get_file()
	return base.to_pascal_case()


func _measure(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var to_local := root.global_transform.affine_inverse()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		# `MeshInstance3D.get_aabb()` is in the instance's own space, so transform it
		# into the scene root's space before merging.
		var transformed: AABB = (to_local * mi.global_transform) * mi.get_aabb()
		box = transformed if first else box.merge(transformed)
		first = false
	return box


func _is_rigged(root: Node3D) -> bool:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.skin != null:
			return true
		var mesh := mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var bones: Variant = mesh.surface_get_arrays(s)[Mesh.ARRAY_BONES]
			if bones != null and not (bones as PackedInt32Array).is_empty():
				return true
	return false


## Godot AABB -> TrenchBroom `size` box.
##
## Three conversions, each of which was a bug when missed:
##   - the assembler's axis swap: TB.x = Godot.z, TB.y = Godot.x, TB.z = Godot.y
##   - X and Y symmetric about the origin, or TrenchBroom refuses to rotate (#63)
##   - Z spanning the origin, or TrenchBroom draws no model at all (#64)
##
## Returned as `AABB(min, max)`: func_godot's FGD writer emits `position` and `size` as
## two corners, so the second vector is the MAX corner, not an extent.
func _tb_size(godot_box: AABB) -> AABB:
	var lo := godot_box.position * SCALE
	var hi := (godot_box.position + godot_box.size) * SCALE
	var tb_lo := Vector3(lo.z, lo.x, lo.y)
	var tb_hi := Vector3(hi.z, hi.x, hi.y)

	var half_x: float = maxf(absf(tb_lo.x), absf(tb_hi.x))
	var half_y: float = maxf(absf(tb_lo.y), absf(tb_hi.y))
	tb_lo.x = -half_x
	tb_hi.x = half_x
	tb_lo.y = -half_y
	tb_hi.y = half_y
	tb_lo.z = minf(tb_lo.z, 0.0)
	tb_hi.z = maxf(tb_hi.z, 0.0)

	return AABB(
		Vector3(roundf(tb_lo.x), roundf(tb_lo.y), roundf(tb_lo.z)),
		Vector3(roundf(tb_hi.x), roundf(tb_hi.y), roundf(tb_hi.z)))


# --- writing ----------------------------------------------------------------------

func _entity_text(classname: String, model_path: String, size: AABB, display: String) -> String:
	var scene_uid := ResourceLoader.get_resource_uid(model_path)
	var scene_ref := '[ext_resource type="PackedScene" uid="%s" path="%s" id="2_scene"]' % [
		ResourceUID.id_to_text(scene_uid), model_path]
	if scene_uid == ResourceUID.INVALID_ID:
		scene_ref = '[ext_resource type="PackedScene" path="%s" id="2_scene"]' % model_path

	var properties := "" \
		+ 'class_properties = Dictionary[String, Variant]({\n' \
		+ '"mangle": "0 0 0",\n' \
		+ '"scale": 1.0\n' \
		+ '})\n' \
		+ 'class_property_descriptions = Dictionary[String, Variant]({\n' \
		+ '"mangle": "Pitch Yaw Roll",\n' \
		+ '"scale": "Scale multiplier"\n' \
		+ '})\n'

	var meta := "" \
		+ 'meta_properties = Dictionary[String, Variant]({\n' \
		+ '"color": Color(0.8, 0.8, 0.8, 1),\n' \
		+ '"size": AABB(%d, %d, %d, %d, %d, %d)\n' % [
			size.position.x, size.position.y, size.position.z,
			size.size.x, size.size.y, size.size.z] \
		+ '})\n'

	var head := '[gd_resource type="Resource" script_class="%s" format=3]\n\n' % (
		"FuncGodotFGDPointClass" if display != "" else "FuncGodotFGDModelPointClass")

	var body := 'classname = "%s"\n' % classname \
		+ 'description = "%s"\n' % classname \
		+ properties + meta

	if display == "":
		# Static source: let func_godot generate the display model from `scene_file`.
		return head \
			+ '[ext_resource type="Script" uid="%s" path="%s" id="1_dscpt"]\n' % [UID_DISPLAY_DESCRIPTOR, PATH_DISPLAY_DESCRIPTOR] \
			+ scene_ref + "\n" \
			+ '[ext_resource type="Script" uid="%s" path="%s" id="3_mpc"]\n\n' % [UID_MODEL_POINT_CLASS, PATH_MODEL_POINT_CLASS] \
			+ "[resource]\n" \
			+ 'script = ExtResource("3_mpc")\n' \
			+ "target_map_editor = 1\n" \
			+ 'models_sub_folder = "%s"\n' % MODELS_SUB_FOLDER \
			+ 'scale_expression = "%s"\n' % SCALE_EXPRESSION \
			+ "rotation_offset = Vector3(0, 180, 0)\n" \
			+ 'scene_file = ExtResource("2_scene")\n' \
			+ body \
			+ 'metadata/_custom_type_script = "%s"\n' % UID_MODEL_POINT_CLASS

	# Rigged source: point at the baked static display rather than regenerating one.
	return head \
		+ '[ext_resource type="Script" uid="%s" path="%s" id="1_pntcl"]\n' % [UID_POINT_CLASS, PATH_POINT_CLASS] \
		+ scene_ref + "\n" \
		+ '[ext_resource type="Script" uid="%s" path="%s" id="3_dscpt"]\n\n' % [UID_DISPLAY_DESCRIPTOR, PATH_DISPLAY_DESCRIPTOR] \
		+ '[sub_resource type="Resource" id="Resource_display"]\n' \
		+ 'script = ExtResource("3_dscpt")\n' \
		+ 'display_asset_path = "\\"%s\\""\n' % display \
		+ 'scale = "%s"\n\n' % SCALE_EXPRESSION \
		+ "[resource]\n" \
		+ 'script = ExtResource("1_pntcl")\n' \
		+ 'scene_file = ExtResource("2_scene")\n' \
		+ 'display_descriptors = Array[FuncGodotFGDPointClassDisplayDescriptor]([SubResource("Resource_display")])\n' \
		+ body \
		+ 'metadata/_custom_type_script = "%s"\n' % UID_POINT_CLASS


func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_failures += 1
		printerr("FAIL: could not write %s" % path)
		return false
	f.store_string(text)
	f.close()
	return true


## Rebuilds `entity_definitions` sorted and deduped, preserving every existing entry and
## its uid.  Never drops an entry — an entity missing from this array is invisible to
## TrenchBroom *and* rebuilds as a Marker3D (#60).
func _rewrite_definitions() -> void:
	var dir := DirAccess.open(ENTITIES_DIR)
	if dir == null:
		_failures += 1
		printerr("FAIL: could not open %s" % ENTITIES_DIR)
		return

	var files: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".tres") and entry != FGD_PATH.get_file():
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	files.sort()

	var fgd_uid := _header_uid(FGD_PATH)
	var refs := ""
	var entries: Array[String] = []
	for i in files.size():
		var path := ENTITIES_DIR + files[i]
		var id := "4_%d" % i
		var uid := _header_uid(path)
		refs += '[ext_resource type="Resource"%s path="%s" id="%s"]\n' % [
			' uid="%s"' % uid if uid != "" else "", path, id]
		entries.append('ExtResource("%s")' % id)

	var text := '[gd_resource type="Resource" script_class="FuncGodotFGDFile" format=3%s]\n\n' % (
			' uid="%s"' % fgd_uid if fgd_uid != "" else "") \
		+ '[ext_resource type="Resource" uid="%s" path="%s" id="1_fopi5"]\n' % [UID_BASE_FGD, PATH_BASE_FGD] \
		+ '[ext_resource type="Script" uid="%s" path="%s" id="3_pir0d"]\n' % [UID_FGD_SCRIPT, PATH_FGD_SCRIPT] \
		+ refs + "\n" \
		+ "[resource]\n" \
		+ 'script = ExtResource("3_pir0d")\n' \
		+ 'fgd_name = "MultiplayerSystem3D"\n' \
		+ 'base_fgd_files = Array[Resource]([ExtResource("1_fopi5")])\n' \
		+ 'entity_definitions = Array[Resource]([%s])\n' % ", ".join(entries) \
		+ 'metadata/_custom_type_script = "%s"\n' % UID_FGD_SCRIPT

	if _write(FGD_PATH, text):
		print("wrote %s — %d entity definition(s)" % [FGD_PATH, files.size()])


func _header_uid(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var first := f.get_line()
	f.close()
	var m := RegEx.create_from_string('uid="([^"]+)"').search(first)
	return m.get_string(1) if m != null else ""
