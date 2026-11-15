extends RefCounted
class_name MatchManifest

## Build-time map manifest shared by the client, the dedicated server, and the
## export tooling.
##
## Maps are large static scenes (`maps/bind.tscn` is ~46 MB) and must never be
## replicated over ENet.  Every peer loads the map from its own build instead;
## the wire carries only the map path and this manifest's SHA-256 for that path.
## A mismatch is rejected in the handshake (`Protocol.ErrorCode.MAP_MISMATCH`)
## before anything is loaded.
##
## The manifest is generated from the *same build* that ships the maps.  Keep
## `convert_text_resources_to_binary` disabled in the dedicated-server export
## preset, or the exported `.tscn` bytes stop matching the source hashes.
##
## Usage:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/map_manifest.tscn
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/map_manifest.tscn -- --check

## Preloaded rather than referenced through `class_name` so a cold headless
## start cannot reach this script before the global class table is filled
## (see `docs/05-known-issues.md` #62).
const Protocol := preload("res://network/session_protocol.gd")

const SCHEMA_VERSION: int = 1

## Directories that contain assets served to clients.  Map scenes live directly
## in `res://maps`; their lobby metadata lives in `res://maps/map_data`.
const MAP_DIR: String = "res://maps"
const MAP_DATA_DIR: String = "res://maps/map_data"
const MAP_EXTENSIONS: Array[String] = ["tscn", "scn"]
const MAP_DATA_EXTENSIONS: Array[String] = ["tres"]


## The manifest the build ships.
static func load_manifest(path: String = Protocol.MAP_MANIFEST_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


## The manifest this build *would* produce.  Deterministic: keys are sorted and
## the SHA is over the canonical JSON of the entry table only.
static func build_manifest() -> Dictionary:
	var entries := build_entries()
	var canonical := JSON.stringify(entries, "", true)
	return {
		"schema": SCHEMA_VERSION,
		"protocol": Protocol.VERSION,
		"entries": entries,
		"manifest_sha": _sha256_text(canonical),
	}


static func build_entries() -> Dictionary:
	var entries := {}
	for path in _scan(MAP_DIR, MAP_EXTENSIONS):
		var hash := FileAccess.get_sha256(path)
		if hash.is_empty():
			push_error("MatchManifest: cannot hash %s" % path)
			continue
		entries[path] = hash
	for path in _scan(MAP_DATA_DIR, MAP_DATA_EXTENSIONS):
		var hash := FileAccess.get_sha256(path)
		if hash.is_empty():
			push_error("MatchManifest: cannot hash %s" % path)
			continue
		entries[path] = hash
	return entries


static func write_manifest(manifest: Dictionary, path: String = Protocol.MAP_MANIFEST_PATH) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(manifest, "  ", true) + "\n")
	file.close()
	return OK


## Hash the local file a map path resolves to, for handshake validation.
static func hash_map(map_path: String) -> String:
	return FileAccess.get_sha256(map_path)


## True when the local map matches what the server announced.  A missing map or
## a missing manifest entry is a mismatch, never an implicit pass.
static func verify_map(map_path: String, expected_hash: String) -> bool:
	if expected_hash.is_empty():
		return false
	return hash_map(map_path) == expected_hash


## Compare the shipped manifest against this build's files.  Returns a list of
## human-readable failures; empty means the build is consistent.
static func verify_shipped_manifest(path: String = Protocol.MAP_MANIFEST_PATH) -> Array[String]:
	var failures: Array[String] = []
	var shipped := load_manifest(path)
	if shipped.is_empty():
		failures.append("manifest missing or unreadable: %s" % path)
		return failures
	var built := build_manifest()
	var shipped_sha := str(shipped.get("manifest_sha", ""))
	if shipped_sha != str(built.get("manifest_sha", "")):
		failures.append("manifest SHA mismatch: shipped=%s built=%s" % [shipped_sha, built.get("manifest_sha", "")])
	var shipped_entries: Variant = shipped.get("entries", {})
	var built_entries: Dictionary = built.get("entries", {})
	if not shipped_entries is Dictionary:
		failures.append("manifest entries are not a dictionary")
		return failures
	var shipped_dict := shipped_entries as Dictionary
	for key in shipped_dict.keys():
		if not built_entries.has(key):
			failures.append("stale manifest entry: %s" % key)
		elif shipped_dict[key] != built_entries[key]:
			failures.append("hash mismatch: %s" % key)
	for key in built_entries.keys():
		if not shipped_dict.has(key):
			failures.append("unlisted build file: %s" % key)
	return failures


static func _scan(dir_path: String, extensions: Array[String]) -> Array[String]:
	var out: Array[String] = []
	var files := DirAccess.get_files_at(dir_path)
	for file_name in files:
		var ext := file_name.get_extension().to_lower()
		if extensions.has(ext):
			out.append(dir_path.path_join(file_name))
	out.sort()
	return out


static func _sha256_text(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()
