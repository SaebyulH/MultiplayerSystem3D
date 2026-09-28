extends Node
## Exports the TrenchBroom FGD and verifies every custom entity reached it.
##
## TrenchBroom only sees an entity whose .tres is listed in the FGD resource's
## `entity_definitions` array.  An entity missing from that array is not an error:
## `parser.gd:83-87` falls back to a bare Marker3D on map build, so placed props
## vanish silently (docs/05-known-issues.md #60).  This harness is the cheap check,
## and it also regenerates the display models the entities point at.
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/export_trenchbroom_fgd.tscn
##
## Exits with the number of failed assertions, so 0 means the FGD is complete.

const FGD_PATH := "res://trenchbroom/entities/multiplayer_system_3d_fgd.tres"
const MAP_SETTINGS_PATH := "res://trenchbroom/multiplayer_system_3d_map_settings.tres"

## classname -> substrings that must appear inside its `@PointClass` block in the
## exported .fgd.  `model(` is the TrenchBroom display-model keyword (`studio` is
## the Hammer spelling and TrenchBroom ignores it — see known-issues #61); `mangle(`
## is what makes the entity rotatable in the editor.
const EXPECTED := {
	"Forklift": ["model(", "size("],
	"Truck": ["model(", "size(", "mangle("],
	"mannequin": ["model(", "size("],
}

var _failures := 0


func _ready() -> void:
	var fgd := load(FGD_PATH) as FuncGodotFGDFile
	if fgd == null:
		printerr("FAIL: could not load %s" % FGD_PATH)
		get_tree().quit(1)
		return

	# 1. Registration — the classname has to resolve through the FGD resource.
	var definitions := fgd.get_entity_definitions()
	for classname in EXPECTED:
		if definitions.has(classname):
			print("ok   registered: %s" % classname)
		else:
			_failures += 1
			printerr("FAIL: %s is not in entity_definitions — it would build as a Marker3D" % classname)

	# 2. Export.  `_generate_model()` saves each ModelPointClass's display GLB from a
	# `call_deferred`, so the process has to survive a few idle frames for the .glb to
	# reach disk before we quit.
	fgd.do_export_file(FuncGodotFGDFile.FuncGodotTargetMapEditors.TRENCHBROOM)
	for _i in 4:
		await get_tree().process_frame

	# 3. Assert on the artifact TrenchBroom actually reads, not on the in-memory resource.
	var out_folder: String = FuncGodotLocalConfig.get_setting(FuncGodotLocalConfig.PROPERTY.FGD_OUTPUT_FOLDER)
	if out_folder.is_empty():
		_failures += 1
		printerr("FAIL: no FGD_OUTPUT_FOLDER configured in user://func_godot_config.json")
	else:
		var path: String = out_folder.path_join(fgd.fgd_name + ".fgd")
		print("exported: %s" % path)
		_check_file(path)

	# 3b. Rotation round-trip.  Declaring `mangle` in the FGD is only half of it —
	# the assembler has to turn that key into a rotated node on map build.  It adds
	# an unconditional +180 to yaw, so `mangle "0 90 0"` has to land at 270.
	if definitions.has("Truck"):
		_check_rotation(definitions["Truck"])
	else:
		print("skip rotation check — Truck is not registered")

	print("---")
	if _failures == 0:
		print("PASS: %d entities registered and exported" % EXPECTED.size())
	else:
		printerr("FAIL: %d assertion(s) failed" % _failures)
	get_tree().quit(_failures)


## Assembles a Truck from a synthetic entity dictionary the way a map build would,
## and checks that `scene_file` was instantiated and the mangle yaw applied.  This
## is the half of "rotatable in TrenchBroom" that the FGD text cannot prove.
func _check_rotation(definition: FuncGodotFGDPointClass) -> void:
	var settings := load(MAP_SETTINGS_PATH) as FuncGodotMapSettings
	if settings == null:
		_failures += 1
		printerr("FAIL: could not load %s" % MAP_SETTINGS_PATH)
		return

	var assembler := FuncGodotEntityAssembler.new(settings)
	var node: Node = assembler.generate_point_entity_node(null, "entity_0_Truck", {
		"classname": "Truck",
		"mangle": "0 90 0",
	}, definition)
	if node == null:
		_failures += 1
		printerr("FAIL: assembler returned no node for Truck")
		return

	# truck.tscn's collidable root is the CSGCombiner3D, so its presence proves the
	# entity resolved to the CSG prop rather than a fallback Node3D.
	var built_from_scene := node.find_child("CSGCombiner3D", true, false) != null
	var yaw: float = snappedf((node as Node3D).rotation_degrees.y, 0.01)
	# `apply_rotation_on_map_build = false` opts the entity out of the assembler's
	# rotation entirely, so the expectation flips rather than the check being dropped.
	var expected: float = 270.0 if definition.apply_rotation_on_map_build else 0.0
	if built_from_scene and is_equal_approx(yaw, expected):
		print("ok   rotation: Truck built from truck.tscn, yaw %.1f deg (apply_rotation_on_map_build=%s)" % [yaw, definition.apply_rotation_on_map_build])
	else:
		_failures += 1
		printerr("FAIL: Truck built from scene=%s, yaw=%s (expected truck.tscn at %s deg)" % [built_from_scene, yaw, expected])
	node.free()


## Two independent constraints on a point entity's `size` box, both of which fail
## silently in TrenchBroom rather than erroring.  Parsed straight out of the exported
## .fgd, so the check sees the same numbers TrenchBroom does whether `size` was
## authored by hand or derived by `generate_size_property`.
##
##   1. The box must contain the origin, or TrenchBroom will not preview the entity
##      at all (`TrenchBroom/TrenchBroom` #4573).  Applies to every entity.
##   2. A rotatable entity additionally needs the box centred on X and Y, or
##      TrenchBroom refuses to rotate it and just moves it (`#2498`).
func _check_bounds(classname: String, block: String, rotatable: bool) -> void:
	var re := RegEx.new()
	re.compile("size\\(\\s*(-?[\\d.]+) (-?[\\d.]+) (-?[\\d.]+),\\s*(-?[\\d.]+) (-?[\\d.]+) (-?[\\d.]+)\\s*\\)")
	var m := re.search(block)
	if m == null:
		_failures += 1
		printerr("FAIL: %s has no size(...) in the exported FGD" % classname)
		return

	var lo := Vector3(m.get_string(1).to_float(), m.get_string(2).to_float(), m.get_string(3).to_float())
	var hi := Vector3(m.get_string(4).to_float(), m.get_string(5).to_float(), m.get_string(6).to_float())

	if lo.x <= 0.0 and lo.y <= 0.0 and lo.z <= 0.0 and hi.x >= 0.0 and hi.y >= 0.0 and hi.z >= 0.0:
		print("ok   bounds: %s contains the origin" % classname)
	else:
		_failures += 1
		printerr("FAIL: %s bounds %s..%s exclude the origin — TrenchBroom will not preview it" % [classname, lo, hi])

	if not rotatable:
		return

	# `size(min, max)` in TrenchBroom units; centred means min == -max on X and Y.
	# Z is the vertical axis and deliberately not checked.
	var off_centre := Vector2(lo.x + hi.x, lo.y + hi.y)
	if off_centre.length() < 1.0:
		print("ok   bounds: %s centred on XY" % classname)
	else:
		_failures += 1
		printerr("FAIL: %s bounds off-centre on XY by %s — TrenchBroom will refuse to rotate it" % [classname, off_centre])


## Splits the exported .fgd on `@PointClass` and checks each expected classname's
## block carries the tokens it needs.  The classname is read back out of the block
## (`... = Truck : "..."`) rather than assumed from the expected list, so a block
## that failed to generate is reported as missing instead of silently matching.
func _check_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		_failures += 1
		printerr("FAIL: %s was not written" % path)
		return

	var blocks := {}
	for block in FileAccess.get_file_as_string(path).split("@PointClass"):
		var marker := block.find(" = ")
		if marker == -1:
			continue
		var classname := block.substr(marker + 3).split(" ")[0].strip_edges()
		if not classname.is_empty():
			blocks[classname] = block

	for classname in EXPECTED:
		if not blocks.has(classname):
			_failures += 1
			printerr("FAIL: no @PointClass for %s in the exported FGD" % classname)
			continue
		var missing := PackedStringArray()
		for token in EXPECTED[classname]:
			if not blocks[classname].contains(token):
				missing.append(token)
		if missing.is_empty():
			print("ok   exported: %s" % classname)
		else:
			_failures += 1
			printerr("FAIL: %s is missing %s in the exported FGD" % [classname, ", ".join(missing)])

		# `mangle(` contains `angle(`, so this one test covers all three rotation
		# spellings; an entity with no rotation property is only checked for the
		# origin-inside-bounds rule.
		_check_bounds(classname, blocks[classname], blocks[classname].contains("angle("))
