@tool
extends Node
## One-shot tool that pre-renders every gameplay map's overview camera into a
## PNG thumbnail and writes a MapData resource pointing at the map.
##
## Each map already ships a root Camera3D framed on the map, plus its own
## WorldEnvironment (sky) and DirectionalLight3D — so we just instantiate the
## map into a SubViewport with its own World3D and capture the camera's view.
## No lighting or framing math is required.
##
## HOW TO USE:
##   1. Open this scene (maps/map_thumbnail_generator.tscn).
##   2. Press F6 (Run Current Scene) — thumbnails are generated, then the scene
##      auto-quits after 0.5 seconds.
##
## Re-run whenever you add or change a map.

const MAP_DATA_DIR := "res://maps/map_data"
const THUMBNAIL_DIR := "res://map_thumbnails"
const THUMBNAIL_WIDTH := 512
const THUMBNAIL_HEIGHT := 288


var _started := false
var _map_entries: Array[Dictionary] = []
var _map_index := 0
var _generated := 0
var _done := false


func _ready() -> void:
	if _started:
		return
	if Engine.is_editor_hint():
		print("Map Thumbnail Generator attached. Press F6 to run.")
		return

	_started = true
	print("──────────────────────────────────────────")
	print("Map Thumbnail Generator — %dx%d thumbnails" % [THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT])
	print("──────────────────────────────────────────")

	if DirAccess.make_dir_recursive_absolute(THUMBNAIL_DIR) != OK:
		printerr("Failed to create: ", THUMBNAIL_DIR)
		get_tree().quit(1)
		return
	if DirAccess.make_dir_recursive_absolute(MAP_DATA_DIR) != OK:
		printerr("Failed to create: ", MAP_DATA_DIR)
		get_tree().quit(1)
		return

	_map_entries = ConnectionUtils.scan_maps()
	print("Found %d maps." % _map_entries.size())

	if _map_entries.is_empty():
		print("Nothing to do.")
		get_tree().quit()
		return

	_process_next()


func _process_next() -> void:
	if _done:
		return

	if _map_index >= _map_entries.size():
		_finish()
		return

	var entry := _map_entries[_map_index]
	_map_index += 1

	var display_name: String = entry["display_name"]
	var map_path: String = entry["path"]

	var map_scene := load(map_path) as PackedScene
	if not map_scene:
		print("  SKIP %s (could not load scene)" % map_path)
		_process_next.call_deferred()
		return

	print("  %s  →  %s …" % [display_name, map_path])

	var built := _build_viewport(map_scene)
	var vp: SubViewport = built["vp"]
	var game_mode: int = built["game_mode"]
	if game_mode < 0:
		print("    SKIP (no GameModeComponent)")
		vp.queue_free()
		_process_next.call_deferred()
		return
	add_child(vp)

	_capture_deferred.call_deferred(vp, display_name, map_scene, game_mode)


func _build_viewport(map_scene: PackedScene) -> Dictionary:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.handle_input_locally = false
	vp.size = Vector2i(THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	# The map renders its own sky + lighting via its WorldEnvironment and
	# DirectionalLight3D children.  Leave processing enabled so CSG greybox
	# geometry builds before we capture.
	var map := map_scene.instantiate()
	vp.add_child(map)

	var game_mode := -1
	var gmc := map.get_node_or_null("GameModeComponent") as GameModeComponent
	if gmc:
		game_mode = int(gmc.game_mode)

	var cam := map.get_node_or_null("Camera3D") as Camera3D
	if cam:
		cam.current = true
	else:
		print("    WARNING: no root Camera3D found — render will be empty")

	return { "vp": vp, "game_mode": game_mode }


func _capture_deferred(vp: SubViewport, display_name: String, map_scene: PackedScene, game_mode: int) -> void:
	# The SubViewport's first UPDATE_ONCE render can fire before the map's CSG
	# greybox finishes its deferred build, yielding an empty frame.  Wait for the
	# CSG to build, then force one more render before reading the texture.
	await get_tree().process_frame
	await get_tree().process_frame
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame

	var tex := vp.get_texture()

	if not tex:
		print("    FAILED (no texture — viewport may be empty)")
		_cleanup_and_next(vp)
		return

	var img := tex.get_image()

	if not img:
		print("    FAILED (get_image returned null)")
		_cleanup_and_next(vp)
		return

	remove_child(vp)
	vp.queue_free()

	var thumbnail_path := THUMBNAIL_DIR + "/" + display_name + ".png"
	var map_data_path := MAP_DATA_DIR + "/" + display_name + ".tres"

	if img.save_png(thumbnail_path) != OK:
		print("    FAILED (save PNG to %s)" % thumbnail_path)
		_process_next.call_deferred()
		return

	# Build an ImageTexture directly from the image we already have in memory,
	# then claim the PNG path via take_over_path().  This avoids a
	# save-then-reload round-trip that fails on Windows when ResourceLoader
	# tries to open the file before the OS has flushed it.
	var image_tex := ImageTexture.create_from_image(img)
	image_tex.take_over_path(thumbnail_path)

	var map_data := MapData.new()
	map_data.display_name = display_name
	map_data.game_mode = game_mode
	# Store the path, not the scene: see maps/map_data.gd.  This tool has already
	# paid to load the scene deliberately, so taking its path is free.
	map_data.map_scene_path = map_scene.resource_path
	map_data.map_image = image_tex

	if ResourceSaver.save(map_data, map_data_path) != OK:
		print("    FAILED (save MapData to %s)" % map_data_path)
		_process_next.call_deferred()
		return

	_generated += 1
	print("    OK")

	_process_next.call_deferred()


func _cleanup_and_next(vp: SubViewport) -> void:
	remove_child(vp)
	vp.queue_free()
	_process_next.call_deferred()


func _finish() -> void:
	if _done:
		return

	_done = true

	print("──────────────────────────────────────────")
	print("Done — %d thumbnails written to %s/ and %s/" % [_generated, THUMBNAIL_DIR, MAP_DATA_DIR])
	print("──────────────────────────────────────────")

	get_tree().create_timer(0.5).timeout.connect(
		func(): get_tree().quit()
	)
