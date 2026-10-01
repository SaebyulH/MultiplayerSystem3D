extends RefCounted
class_name PayloadPathLinker

## Writes an explicit `target`/`targetname` chain into a TrenchBroom `.map`, so a mapper never
## has to type one.
##
## [b]Why this exists outside TrenchBroom.[/b] A route chains by placement order by default —
## draw the waypoints front to back and they connect themselves (`PayloadPathBuilder`). That
## is pleasant but fragile: a point inserted into the middle of an existing route is created
## last, so it appends to the end of the chain instead of slotting in, and the route silently
## takes a wrong leg. Baking the links in once removes that. TrenchBroom cannot do it for us:
## upstream has no scripting or plugin API — extensibility there is game configs, FGD entity
## definitions and mods, all data — and the feature that would have done exactly this
## (auto-incrementing numbered `targetname`/`target` on duplicate, requested for `path_track`
## chains) is unimplemented. So the linking lives on the Godot side, driven by the
## [code]Auto Setup Payload Path[/code] button on `maps/map.gd`.
##
## [b]The core is text in, text out.[/b] [method link_map_text] touches no files, which is what
## lets `tools/verify_payload_path.tscn` drive it over synthetic maps and over a copy of a real
## one. The button is a thin file read/write around it.
##
## [b]It fills gaps; it does not overwrite decisions.[/b] A point that already has a name keeps
## it, and a point that already has a `target` keeps it. Running it twice is a no-op the second
## time, which is the property everything else here is arranged around.
##
## [b]Nothing outside the lines it changes is touched.[/b] The `.map` is edited line by line
## rather than re-serialised, so blank lines, comments, indentation and — importantly — the
## CRLF line endings TrenchBroom writes are all preserved exactly. A round trip over an
## unmodified map produces byte-identical text.

## The entity this links.
const CLASSNAME: String = "PayloadPathPoint"

## Names are `<prefix>_<n>`, numbered from 1.
const DEFAULT_PREFIX: String = "path"


## Names and links every [constant CLASSNAME] entity in [param text], and returns the result.
##
## [codeblock]
## { "text": String, "named": int, "linked": int, "messages": Array[String] }
## [/codeblock]
##
## `text` is the input unchanged when there is nothing to do, so a caller can compare the two
## and skip the write.
static func link_map_text(text: String, prefix: String = DEFAULT_PREFIX) -> Dictionary:
	var messages: Array[String] = []
	var result := { "text": text, "named": 0, "linked": 0, "messages": messages }

	if prefix.is_empty():
		prefix = DEFAULT_PREFIX

	var lines := text.split("\n")
	var entities := _read_entities(lines)

	# File order is placement order — TrenchBroom writes entities in the order they were
	# created, which is the same order func_godot then builds them in.
	var points: Array[Dictionary] = []
	for entity in entities:
		if entity["classname"] == CLASSNAME:
			points.append(entity)

	if points.size() < 2:
		messages.append(
			"Found %d %s entities, and a route needs at least 2. Nothing was changed."
			% [points.size(), CLASSNAME])
		return result

	# Every name already used anywhere in the map, not just on path points, so a generated
	# name cannot collide with a trigger's targetname.
	var taken: Dictionary = {}
	for entity in entities:
		var existing := _value(entity, "targetname")
		if not existing.is_empty():
			taken[existing] = true

	# Match whatever the file already uses, or an inserted line would rewrite the whole file
	# as far as git is concerned.
	#
	# This is the carriage return alone, not the full `\r\n`: lines were split on `"\n"` and
	# are rejoined with it, so a line's terminator is the `\r` it carries and nothing else.
	# Appending a whole `\r\n` here and then joining would put a blank line after every
	# insertion.
	var terminator := "\r" if text.contains("\r\n") else ""

	var edit := { "lines": lines, "replacements": {}, "insertions": {} }

	# 1. Name the unnamed, in placement order.
	var counter := 1
	for point in points:
		if not _value(point, "targetname").is_empty():
			continue
		var name := ""
		while true:
			name = "%s_%d" % [prefix, counter]
			counter += 1
			if not taken.has(name):
				break
		taken[name] = true
		_set_property(edit, point, "targetname", name, terminator)
		result["named"] += 1

	# 2. Chain each point to the next. The last one is deliberately left alone: there is
	#    nothing after it, and clearing a `target` it already had would be deleting someone
	#    else's work.
	for i in points.size() - 1:
		var point: Dictionary = points[i]
		if not _value(point, "target").is_empty():
			continue
		var next_name := _value(points[i + 1], "targetname")
		if next_name.is_empty():
			continue
		_set_property(edit, point, "target", next_name, terminator)
		result["linked"] += 1

	if result["named"] == 0 and result["linked"] == 0:
		messages.append(
			"All %d %s entities are already named and linked. Nothing was changed."
			% [points.size(), CLASSNAME])
		return result

	messages.append(
		"Named %d and linked %d of %d %s entities."
		% [result["named"], result["linked"], points.size(), CLASSNAME])
	result["text"] = _assemble(lines, edit)
	return result


# ─────────────────────────────────────────────
#  READING THE MAP
# ─────────────────────────────────────────────

## Every top-level `{ … }` block, in file order.
##
## The depth counter is load-bearing rather than defensive: a brush entity nests one `{ … }`
## per brush, and every face line inside one starts with `(` and contains no quotes — but the
## block structure has to be tracked regardless, because a property line read from inside a
## brush would be attributed to the entity and then rewritten there.
static func _read_entities(lines: PackedStringArray) -> Array[Dictionary]:
	var entities: Array[Dictionary] = []
	var depth := 0
	var current: Dictionary = {}

	for i in lines.size():
		var line := lines[i].strip_edges()

		if line.begins_with("{"):
			depth += 1
			if depth == 1:
				current = {
					"props": {},
					"prop_lines": {},
					# Where a missing property would be inserted: after the last one the
					# entity already has, which keeps it on the property side of any brush
					# blocks rather than after them.
					"last_prop_line": i,
				}
			continue

		if line.begins_with("}"):
			if depth == 1 and not current.is_empty():
				entities.append(current)
				current = {}
			depth -= 1
			continue

		if depth != 1:
			continue

		var parts := _parse_property(line)
		if parts.size() < 2:
			continue
		current["props"][parts[0]] = parts[1]
		current["prop_lines"][parts[0]] = i
		current["last_prop_line"] = i

	for entity in entities:
		entity["classname"] = String(entity["props"].get("classname", ""))

	return entities


## The two quoted strings of a `"key" "value"` line, or an empty array for anything else.
##
## Handles the `\"` escape rather than splitting on quotes, so a value containing one is read
## correctly. Values here are entity names and `.map` scalars, so this is belt and braces —
## but an escape misread as a delimiter would silently truncate the value.
static func _parse_property(line: String) -> PackedStringArray:
	var parts := PackedStringArray()
	var index := 0
	var length := line.length()

	while parts.size() < 2:
		while index < length and (line[index] == " " or line[index] == "\t"):
			index += 1
		if index >= length or line[index] != "\"":
			break
		index += 1

		var value := ""
		while index < length:
			if line[index] == "\\" and index + 1 < length:
				value += line[index + 1]
				index += 2
				continue
			if line[index] == "\"":
				break
			value += line[index]
			index += 1
		parts.append(value)
		index += 1  # the closing quote

	return parts


# ─────────────────────────────────────────────
#  EDITING
# ─────────────────────────────────────────────

## Sets one property on [param entity], recorded as either a line replacement or an insertion.
##
## Edits are collected rather than applied, because every line index in [param entity] was
## measured against the original file and inserting a line shifts all of them. Assembling once,
## at the end, is what keeps those indices valid.
static func _set_property(edit: Dictionary, entity: Dictionary, key: String, value: String,
		terminator: String) -> void:
	var props: Dictionary = entity["props"]
	var prop_lines: Dictionary = entity["prop_lines"]
	props[key] = value

	if prop_lines.has(key):
		var index: int = prop_lines[key]
		# Keep the line's own terminator rather than the file's, so a line that differs from
		# its neighbours is not silently normalised.
		var own_terminator := "\r" if String(edit["lines"][index]).ends_with("\r") else ""
		edit["replacements"][index] = _property_line(key, value, own_terminator)
		return

	var anchor: int = int(entity["last_prop_line"]) + 1
	if not edit["insertions"].has(anchor):
		edit["insertions"][anchor] = []
	edit["insertions"][anchor].append(_property_line(key, value, terminator))


static func _property_line(key: String, value: String, terminator: String) -> String:
	return "\"%s\" \"%s\"%s" % [key, value, terminator]


## Applies the collected edits, walking the original lines once.
static func _assemble(lines: PackedStringArray, edit: Dictionary) -> String:
	var replacements: Dictionary = edit["replacements"]
	var insertions: Dictionary = edit["insertions"]

	var out := PackedStringArray()
	for i in lines.size():
		if insertions.has(i):
			out.append_array(insertions[i])
		out.append(replacements.get(i, lines[i]))

	return "\n".join(out)


static func _value(entity: Dictionary, key: String) -> String:
	return String(entity["props"].get(key, ""))
