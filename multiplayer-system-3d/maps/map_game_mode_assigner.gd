@tool
extends Node
## One-shot tool that detects each map's game mode from its GameModeComponent and
## writes it into the map's MapData .tres file.
##
## This is the lightweight companion to map_thumbnail_generator.gd: it only fixes
## the `game_mode` field (no rendering), so re-run it whenever you add/change a
## map or the mode grouping in the host menu looks wrong.
##
## HOW TO USE:
##   1. Open this scene (maps/map_game_mode_assigner.tscn).
##   2. Press F6 (Run Current Scene) — modes are assigned, then the scene
##      auto-quits after 0.5 seconds.

const MAP_DATA_DIR := "res://maps/map_data"


var _started := false
var _files: Array[String] = []
var _index := 0
var _updated := 0
var _done := false


func _ready() -> void:
	if _started:
		return
	if Engine.is_editor_hint():
		print("Map Game Mode Assigner attached. Press F6 to run.")
		return

	_started = true
	print("──────────────────────────────────────────")
	print("Map Game Mode Assigner")
	print("──────────────────────────────────────────")

	_find_tres_files(MAP_DATA_DIR, _files)
	_files.sort()
	print("Found %d MapData .tres files." % _files.size())

	if _files.is_empty():
		print("Nothing to do.")
		get_tree().quit()
		return

	_process_next()


func _find_tres_files(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if not d:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.ends_with(".tres"):
			out.append(dir + "/" + f)
		f = d.get_next()
	d.list_dir_end()


func _process_next() -> void:
	if _done:
		return

	if _index >= _files.size():
		_finish()
		return

	var path := _files[_index]
	_index += 1

	var data := load(path) as MapData
	if not data:
		print("  SKIP %s (not a MapData)" % path)
		_process_next.call_deferred()
		return

	if data.map_scene == null:
		print("  SKIP %s (no map_scene)" % path)
		_process_next.call_deferred()
		return

	# Instantiate without adding to the tree, so _enter_tree/_ready never run —
	# the exported game_mode is available right after instantiate().
	var map := data.map_scene.instantiate()
	var gmc := map.get_node_or_null("GameModeComponent") as GameModeComponent
	var mode := int(gmc.game_mode) if gmc else -1
	map.free()

	if mode < 0:
		print("  SKIP %s (no GameModeComponent)" % data.display_name)
		_process_next.call_deferred()
		return

	if data.game_mode == mode:
		print("  %s — already %s" % [data.display_name, _mode_name(mode)])
		_process_next.call_deferred()
		return

	data.game_mode = mode
	if ResourceSaver.save(data, path) != OK:
		print("  FAILED to save %s" % path)
		_process_next.call_deferred()
		return

	_updated += 1
	print("  %s → %s" % [data.display_name, _mode_name(mode)])
	_process_next.call_deferred()


func _mode_name(mode: int) -> String:
	match mode:
		GameModeComponent.GameMode.ESCORT: return "ESCORT"
		GameModeComponent.GameMode.DOMINATION: return "DOMINATION"
		GameModeComponent.GameMode.KOTH: return "KOTH"
		GameModeComponent.GameMode.HYBRID: return "HYBRID"
		GameModeComponent.GameMode.CONTROL: return "CONTROL"
		GameModeComponent.GameMode.DEATHMATCH: return "DEATHMATCH"
		_: return "UNKNOWN"


func _finish() -> void:
	if _done:
		return

	_done = true

	print("──────────────────────────────────────────")
	print("Done — %d MapData file(s) updated." % _updated)
	print("──────────────────────────────────────────")

	get_tree().create_timer(0.5).timeout.connect(
		func(): get_tree().quit()
	)
