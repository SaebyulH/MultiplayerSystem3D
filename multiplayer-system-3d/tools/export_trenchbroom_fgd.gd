extends Node
## Exports the TrenchBroom FGD and verifies every custom entity reached it.
##
## TrenchBroom only sees an entity whose .tres is listed in the FGD resource's
## `entity_definitions` array.  An entity missing from that array is not an error:
## `parser.gd:83-87` falls back to a bare Marker3D on map build, so placed props
## vanish silently (docs/05-known-issues.md #60).  This harness is the cheap check,
## and it also regenerates the display models the entities point at.
##
## All three FGD kinds are covered: `@PointClass` (props, spawns — the only kind that
## carries a bounding box), `@SolidClass` (brush entities, shaped by the volume the
## mapper draws) and `@BaseClass` (shared property sets).
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/export_trenchbroom_fgd.tscn
##
## Exits with the number of failed assertions, so 0 means the FGD is complete.

const FGD_PATH := "res://trenchbroom/entities/multiplayer_system_3d_fgd.tres"
const MAP_SETTINGS_PATH := "res://trenchbroom/multiplayer_system_3d_map_settings.tres"
const GAME_CONFIG_PATH := "res://trenchbroom/trenchbroom_config.tres"


const ENTITIES_DIR := "res://trenchbroom/entities/"


## The FGD class prefixes func_godot emits, mapped to the kind this harness reasons about.
##
## Splitting on `@PointClass` alone — which is what `_check_file` used to do — finds
## neither a `@SolidClass` nor a `@BaseClass`, so the first brush entity added to this
## project failed the harness with a misleading "no @PointClass for trigger".
const CLASS_PREFIXES := {
	"@PointClass": "point",
	"@SolidClass": "solid",
	"@BaseClass": "base",
}

## Characters a classname may contain, for cutting one out of a declaration line.
const CLASSNAME_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

var _failures := 0


func _ready() -> void:
	var fgd := load(FGD_PATH) as FuncGodotFGDFile
	if fgd == null:
		printerr("FAIL: could not load %s" % FGD_PATH)
		get_tree().quit(1)
		return

	# 1. Registration — every entity `.tres` in the folder has to resolve through the FGD
	# resource.  Scanned rather than hardcoded: an entity missing from
	# `entity_definitions` is invisible to TrenchBroom *and* rebuilds as a Marker3D
	# (#60), and a hand-maintained list is exactly what gets forgotten when one is added.
	var definitions := fgd.get_entity_definitions()
	# Base classes are checked against the raw array instead, because
	# `get_entity_definitions()` returns only the two *placeable* kinds
	# (`func_godot_fgd_file.gd:130`) — it folds a base class's properties into its
	# descendants rather than exposing it.  A base class must still be listed: the FGD
	# writer walks the raw array to emit the `@BaseClass` blocks (`:88-98`), so an
	# unlisted one would vanish from the FGD and take every inherited property with it.
	var listed: Dictionary = {}
	for entry in fgd.entity_definitions:
		if entry is FuncGodotFGDEntityClass:
			listed[entry.classname] = true

	var checked: Dictionary = {}
	for path in _entity_files():
		var definition := load(path) as FuncGodotFGDEntityClass
		if definition == null:
			_failures += 1
			printerr("FAIL: could not load %s" % path)
			continue
		if definition is FuncGodotFGDBaseClass:
			if listed.has(definition.classname):
				print("ok   registered: %s (@BaseClass)" % definition.classname)
				checked[definition.classname] = definition
			else:
				_failures += 1
				printerr("FAIL: %s is not in entity_definitions — no @BaseClass block would be written" % definition.classname)
		elif definitions.has(definition.classname):
			print("ok   registered: %s" % definition.classname)
			checked[definition.classname] = definition
		else:
			_failures += 1
			printerr("FAIL: %s is not in entity_definitions — it would build as a Marker3D" % definition.classname)

	# 2. Export.  The game config's export does the whole job — icon, GameConfig.cfg
	# (which is where the entity-scale expression lives) and the FGD.  `_generate_model()`
	# saves each ModelPointClass's display GLB from a `call_deferred`, so the process has
	# to survive a few idle frames for the .glb to reach disk before we quit.
	var game_config := load(GAME_CONFIG_PATH) as TrenchBroomGameConfig
	if game_config == null:
		_failures += 1
		printerr("FAIL: could not load %s — falling back to an FGD-only export" % GAME_CONFIG_PATH)
		fgd.do_export_file(FuncGodotFGDFile.FuncGodotTargetMapEditors.TRENCHBROOM)
	else:
		game_config.export_file()
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
		_check_file(path, checked)
	_check_game_config()

	# 3b. Rotation round-trip.  Declaring `mangle` in the FGD is only half of it —
	# the assembler has to turn that key into a rotated node on map build.  It adds
	# an unconditional +180 to yaw, so `mangle "0 90 0"` has to land at 270.
	if definitions.has("Truck"):
		_check_rotation(definitions["Truck"])
	else:
		print("skip rotation check — Truck is not registered")

	print("---")
	if _failures == 0:
		print("PASS: %d entities registered and exported" % checked.size())
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
		"scale": "2 3 4",
	}, definition)
	if node == null:
		_failures += 1
		printerr("FAIL: assembler returned no node for Truck")
		return

	# truck.tscn's collidable root is the CSGCombiner3D, so its presence proves the
	# entity resolved to the CSG prop rather than a fallback Node3D.
	if node.find_child("CSGCombiner3D", true, false) == null:
		_failures += 1
		printerr("FAIL: Truck did not resolve to truck.tscn")
		node.free()
		return

	# `apply_rotation_on_map_build = false` opts the entity out of the assembler's
	# rotation entirely, so the expectation flips rather than the check being dropped.
	var yaw: float = snappedf((node as Node3D).rotation_degrees.y, 0.01)
	var expected_yaw: float = 270.0 if definition.apply_rotation_on_map_build else 0.0
	if is_equal_approx(yaw, expected_yaw):
		print("ok   rotation: Truck built from truck.tscn, yaw %.1f deg" % yaw)
	else:
		_failures += 1
		printerr("FAIL: Truck built at yaw %s (expected %s)" % [yaw, expected_yaw])

	# `mangle`/`scale` strings are TB (x, y, z); the assembler swaps them to Godot
	# (y, z, x) the same way it swaps `origin`.  "2 3 4" must land as (3, 4, 2).
	var scale: Vector3 = (node as Node3D).scale
	if not definition.apply_scale_on_map_build:
		print("skip scale check — apply_scale_on_map_build is false")
	elif scale.is_equal_approx(Vector3(3, 4, 2)):
		print("ok   scale: Truck built at scale %s from \"2 3 4\"" % scale)
	else:
		_failures += 1
		printerr("FAIL: Truck built at scale %s (expected (3, 4, 2) from \"2 3 4\")" % scale)

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
## GameConfig.cfg is TrenchBroom's own format, not strict JSON — the entity-scale
## expression is written raw and unquoted, so a substring check is the honest test.
## If this ever reverts to a bare number, every converted entity silently stops
## honouring its `scale` key.
## Every entity `.tres` in the folder, excluding the FGD resource itself.  Sorted, so a
## run is reproducible and the report reads in a stable order.
func _entity_files() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(ENTITIES_DIR)
	if dir == null:
		_failures += 1
		printerr("FAIL: could not open %s" % ENTITIES_DIR)
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".tres") and entry != FGD_PATH.get_file():
			out.append(ENTITIES_DIR + entry)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _check_game_config() -> void:
	var folder: String = FuncGodotLocalConfig.get_setting(FuncGodotLocalConfig.PROPERTY.TRENCHBROOM_GAME_CONFIG_FOLDER)
	if folder.is_empty():
		_failures += 1
		printerr("FAIL: no TRENCHBROOM_GAME_CONFIG_FOLDER configured")
		return

	var path: String = folder.path_join("GameConfig.cfg")
	if not FileAccess.file_exists(path):
		_failures += 1
		printerr("FAIL: %s was not written" % path)
		return

	# Deliberately a literal.  A property-driven expression makes an entity with no
	# `scale` key — every freshly placed prop, and every entity-browser preview, since
	# the browser has no entity to read a property from — fail to draw at all.
	# See known-issues #65.
	if FileAccess.get_file_as_string(path).contains('"scale": 32'):
		print("ok   game config: entity scale is a literal (props always draw)")
	else:
		_failures += 1
		printerr("FAIL: %s has no literal entity scale — props may not draw" % path)


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


## Splits the exported .fgd on every class prefix and checks each registered classname's
## block carries the tokens its kind needs.  The classname is read back out of the block
## (`... = Truck : "..."`) rather than assumed from the expected list, so a block that
## failed to generate is reported as missing instead of silently matching.
func _check_file(path: String, checked: Dictionary) -> void:
	if not FileAccess.file_exists(path):
		_failures += 1
		printerr("FAIL: %s was not written" % path)
		return

	var blocks := _split_classes(FileAccess.get_file_as_string(path))

	for classname in checked:
		var definition: FuncGodotFGDEntityClass = checked[classname]
		if not blocks.has(classname):
			_failures += 1
			printerr("FAIL: no FGD class for %s in the exported FGD" % classname)
			continue

		var block: String = blocks[classname]["block"]
		match blocks[classname]["kind"]:
			"solid":
				_check_solid(classname, block)
				_check_declared_properties(classname, block, definition)
			"base":
				_check_declared_properties(classname, block, definition)
			_:
				_check_point(classname, block, definition)


## Cuts the exported FGD into one entry per class declaration, keyed by classname.
##
## A class's text runs from its own prefix to whichever prefix comes next, [b]of any
## kind[/b].  Splitting on a single prefix — which this used to do — lets a block run on
## into every class that follows it.  That was harmless while the only question asked was
## whether a token was [i]present[/i], but it is wrong the moment a check asks whether one
## is [i]absent[/i], because the following class's `model(` and `size(` sit inside the
## block under test.  It is exactly how four correct brush entities failed their first run.
func _split_classes(text: String) -> Dictionary:
	var starts: Array[Dictionary] = []
	for prefix in CLASS_PREFIXES:
		var at := text.find(prefix)
		while at != -1:
			starts.append({ "at": at, "kind": CLASS_PREFIXES[prefix], "length": prefix.length() })
			at = text.find(prefix, at + 1)
	starts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["at"]) < int(b["at"]))

	var blocks: Dictionary = {}
	for i in starts.size():
		var head: Dictionary = starts[i]
		var from: int = int(head["at"]) + int(head["length"])
		var to: int = int(starts[i + 1]["at"]) if i + 1 < starts.size() else text.length()
		var block := text.substr(from, to - from)

		var classname := _classname_in(block)
		if classname.is_empty():
			continue
		blocks[classname] = { "block": block, "kind": head["kind"] }
	return blocks


## The classname a class block declares, read out of its first ` = `.
##
## Cutting at the first space is not enough.  A `@PointClass` or `@SolidClass` is written
## `= Truck : "description"`, so the name is a clean first token — but a `@BaseClass`
## carries no description and is written `= Target` followed by a newline and then its
## property list.  A space-split therefore swallows the newline and the first property
## into the name, and the class reads as missing from the file entirely.
func _classname_in(block: String) -> String:
	var marker := block.find(" = ")
	if marker == -1:
		return ""
	var rest := block.substr(marker + 3).strip_edges(true, false)
	var end := 0
	while end < rest.length() and CLASSNAME_CHARS.contains(rest[end]):
		end += 1
	return rest.substr(0, end)


## Point entities are the only kind TrenchBroom draws a bounding box for, so the
## `model(`/`size(` tokens and the scale expression are checked here and nowhere else.
func _check_point(classname: String, block: String, definition: FuncGodotFGDEntityClass) -> void:
	# `model(` and `size(` are on every point entity.  `mangle(`/`scale(` are not:
	# the spawn carries neither, so expecting them universally would fail on correct
	# output.  Take the expectation from the definition's own class properties.
	var has_scale: bool = definition.class_properties.has("scale")
	var tokens: Array[String] = ["model(", "size("]
	if definition.class_properties.has("mangle"):
		tokens.append("mangle(")
	if has_scale:
		tokens.append("scale(")

	var missing := PackedStringArray()
	for token in tokens:
		if not block.contains(token):
			missing.append(token)
	if missing.is_empty():
		print("ok   exported: %s (@PointClass)" % classname)
	else:
		_failures += 1
		printerr("FAIL: %s is missing %s in the exported FGD" % [classname, ", ".join(missing)])

	if has_scale:
		if block.contains("scale(float)"):
			print("ok   scale key: %s declares a numeric scale" % classname)
		else:
			_failures += 1
			printerr("FAIL: %s does not declare scale as a float — an unset scale leaves the prop undrawn" % classname)

		# The scale expression must carry a branch that does not need the property.
		# The entity browser evaluates model expressions with no entity behind them,
		# so a form that *requires* the property leaves the thumbnail blank — and so
		# does a freshly placed prop before its `scale` is touched (#65, #4253).
		if block.contains("scale == undefined -> 32"):
			print("ok   fallback: %s scale expression has a property-free branch" % classname)
		else:
			_failures += 1
			printerr("FAIL: %s has no property-free scale branch — its preview will not draw" % classname)

	# `mangle(` contains `angle(`, so this one test covers all three rotation
	# spellings; an entity with no rotation property is only checked for the
	# origin-inside-bounds rule.
	_check_bounds(classname, block, block.contains("angle("))


## Brush entities are defined by the volume the mapper draws, never by a bounding box.
## `build_def_text` skips `size` and `model` for `@SolidClass` outright
## (`func_godot_fgd_entity_class.gd:82-87`), so finding either means the definition has
## been given a shape it cannot honour.
func _check_solid(classname: String, block: String) -> void:
	var stray := PackedStringArray()
	for token in ["model(", "size("]:
		if block.contains(token):
			stray.append(token)
	if stray.is_empty():
		print("ok   exported: %s (@SolidClass)" % classname)
	else:
		_failures += 1
		printerr("FAIL: %s is a brush entity but declares %s — a brush's shape comes from the volume in the map" % [classname, ", ".join(stray)])


## Checks one class block's property list, in the two halves it actually has.
##
## Only the definition's [b]own[/b] `class_properties` appear inline.  Inherited ones are
## declared through the FGD `base(...)` keyword and resolved by TrenchBroom, not copied
## into the derived block — `trigger` is the proof, exporting an empty `[]` while its
## `target` and `targetname` arrive entirely via `base(Target, Targetname)`.  So
## inheritance is asserted separately: a `base_classes` list that failed to flatten leaves
## the mapper without those keys, the map still builds, and nothing else would notice.
func _check_declared_properties(classname: String, block: String, definition: FuncGodotFGDEntityClass) -> void:
	var missing := PackedStringArray()
	for property in definition.class_properties:
		if not block.contains(property + "("):
			missing.append(property)
	if missing.is_empty():
		print("ok   properties: %s declares all %d of its own" % [classname, definition.class_properties.size()])
	else:
		_failures += 1
		printerr("FAIL: %s does not declare %s in the exported FGD" % [classname, ", ".join(missing)])

	var inherited := PackedStringArray()
	for base_class in definition.base_classes:
		if base_class is FuncGodotFGDEntityClass:
			inherited.append(base_class.classname)
	if inherited.is_empty():
		return

	# Token-exact rather than a substring test: `Target` is a prefix of `Targetname`, so
	# `contains` would call a missing `Target` present.
	var declared := _base_list(block).split(",", false)
	var absent := PackedStringArray()
	for name in inherited:
		var found := false
		for entry in declared:
			if entry.strip_edges() == name:
				found = true
				break
		if not found:
			absent.append(name)
	if absent.is_empty():
		print("ok   bases: %s inherits %s" % [classname, ", ".join(inherited)])
	else:
		_failures += 1
		printerr("FAIL: %s does not declare base(%s) — a mapper would see none of those keys" % [classname, ", ".join(absent)])


## The text inside a class declaration's `base(...)`, or "" when it declares none.
func _base_list(block: String) -> String:
	var at := block.find("base(")
	if at == -1:
		return ""
	var close := block.find(")", at)
	if close == -1:
		return ""
	return block.substr(at + 5, close - at - 5)
