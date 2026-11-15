extends Node
## Generates or verifies `res://maps/manifest.json`.
##
## HOW TO USE:
##   # Regenerate after adding/editing a map or MapData resource:
##   "C:/tools/godot/godot_console.exe" --path . --headless \
##       res://tools/map_manifest.tscn
##
##   # Verify the shipped manifest against the current build (CI / pre-export):
##   "C:/tools/godot/godot_console.exe" --path . --headless \
##       res://tools/map_manifest.tscn -- --check
##
## Exit code is the number of failures, so 0 means the manifest is consistent.
##
## Maps are static and large, so clients load them from their own build instead
## of receiving them from the server.  The manifest is what makes that safe: the
## handshake carries the expected SHA-256 for the map path, and a mismatch is
## rejected before anything is loaded.  See `network/match_manifest.gd`.

## Preloaded rather than referenced through `class_name`; a cold headless start
## reaches these scripts before the global class table is guaranteed to be filled
## (`docs/05-known-issues.md` #62).
const ManifestScript := preload("res://network/match_manifest.gd")
const Protocol := preload("res://network/session_protocol.gd")

const CHECK_FLAG := "--check"


func _ready() -> void:
	if CHECK_FLAG in OS.get_cmdline_user_args():
		_run_check()
	else:
		_run_write()


func _run_write() -> void:
	var manifest := ManifestScript.build_manifest()
	var err: Error = ManifestScript.write_manifest(manifest)
	if err != OK:
		push_error("MapManifest: write failed (%d)" % err)
		get_tree().quit(1)
		return
	var entries: Dictionary = manifest["entries"]
	print("MapManifest: wrote %s (%d entries, sha=%s)" % [
		Protocol.MAP_MANIFEST_PATH,
		entries.size(),
		manifest["manifest_sha"],
	])
	get_tree().quit(0)


func _run_check() -> void:
	var failures: Array[String] = ManifestScript.verify_shipped_manifest()
	if failures.is_empty():
		var manifest := ManifestScript.load_manifest()
		print("MapManifest: OK (%s)" % manifest.get("manifest_sha", "?"))
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("MapManifest: %s" % failure)
	get_tree().quit(failures.size())
