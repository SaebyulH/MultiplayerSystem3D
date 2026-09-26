@tool
extends Node
## One-shot tool that downsizes oversized textures under trenchbroom/textures/.
##
## Rewrites every image whose longest edge exceeds TARGET_SIZE down to TARGET_SIZE,
## copying the pristine original into backup/trenchbroom/textures/ first.  It never
## upscales and never stretches, so anything already at or below TARGET_SIZE —
## including the 64x64 TrenchBroom sentinels (clip/origin/skip/default_texture) and the
## non-square JPEGs — is skipped by construction rather than by a filename allowlist.
## Re-running it once everything is at size is a no-op.
##
## Images are overwritten **in place**: the uid that every .tres/.tscn references lives in
## the sidecar .import file, not in the image, so rewriting the image keeps every reference
## valid.  Godot reimports the changed sources afterwards.
##
## HOW TO USE:
##   1. Open this scene (tools/resize_textures.tscn).
##   2. Press F6 (Run Current Scene) — originals are backed up, oversized images are
##      rewritten, then the scene auto-quits.
##
## Re-run whenever a new texture pack lands under trenchbroom/textures/.

const SOURCE_ROOT := "res://trenchbroom/textures"
const BACKUP_ROOT := "res://backup/trenchbroom/textures"
const TARGET_SIZE := 2048

## Only these are walked.  Everything else in the tree is deliberately ignored: the packs
## ship .blend/.blend1, a .txt and .txt~ asset-catalog, palette.lmp, the .import sidecars,
## generated .tres materials, the source .zip archives, and one stray editor backup whose
## extension is "png~" — which does not equal "png" below, so it falls out for free.
const IMAGE_EXTS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "tga", "bmp"]


var _started := false
var _resized: int = 0
var _skipped: int = 0
var _ignored: int = 0
var _errors: int = 0


func _ready() -> void:
	if _started:
		return
	if Engine.is_editor_hint():
		print("Texture Resizer attached. Press F6 to run.")
		return

	_started = true
	print("──────────────────────────────────────────")
	print("Texture Resizer — longest edge > %dpx -> %dpx" % [TARGET_SIZE, TARGET_SIZE])
	print("──────────────────────────────────────────")

	for path in _collect_images(SOURCE_ROOT):
		_process_image(path)

	print("done: %d resized, %d skipped (<= %dpx), %d non-image ignored, %d errors"
		% [_resized, _skipped, TARGET_SIZE, _ignored, _errors])
	get_tree().quit(_errors)


func _collect_images(root: String) -> PackedStringArray:
	var found := PackedStringArray()
	_walk(root, found)
	found.sort()
	return found


func _walk(dir_path: String, found: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		_errors += 1
		print("ERROR  cannot open %s" % dir_path)
		return
	for file_name in dir.get_files():
		if IMAGE_EXTS.has(file_name.get_extension().to_lower()):
			found.append(dir_path.path_join(file_name))
		else:
			_ignored += 1
	for sub in dir.get_directories():
		_walk(dir_path.path_join(sub), found)


func _process_image(path: String) -> void:
	var img := _load_image(path)
	if img == null:
		_errors += 1
		print("ERROR  %s  (could not decode)" % _rel(path))
		return

	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) <= TARGET_SIZE:
		_skipped += 1
		return

	if not _can_save(path):
		_skipped += 1
		print("SKIP   %s  (no matching encoder for .%s)" % [_rel(path), path.get_extension()])
		return

	# Longest edge -> TARGET_SIZE, the other following proportionally, so a non-square
	# image is never distorted.  Equal edges land on exactly TARGET_SIZE square.
	var scale := float(TARGET_SIZE) / float(maxi(w, h))
	var new_w := maxi(1, roundi(w * scale))
	var new_h := maxi(1, roundi(h * scale))

	if not _backup(path):
		return

	img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
	var err := _save(img, path)
	if err != OK:
		_errors += 1
		print("ERROR  %s  (save failed: %d)" % [_rel(path), err])
		return

	print("RESIZE %s  %dx%d -> %dx%d" % [_rel(path), w, h, new_w, new_h])
	_resized += 1


## Decodes the raw source bytes directly, deliberately bypassing Godot's import system.
## `Image.load()` on a res:// path still works in a project-directory run but warns on every
## single file, and `load()` + `get_image()` would hand back the *imported* texture — lossy
## for the sources configured `compress/mode=2` + `vram_texture`.  The bytes on disk are
## what we want to re-encode.
func _load_image(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	var err := FAILED
	match path.get_extension().to_lower():
		"png":
			err = img.load_png_from_buffer(bytes)
		"jpg", "jpeg":
			err = img.load_jpg_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		"tga":
			err = img.load_tga_from_buffer(bytes)
		"bmp":
			err = img.load_bmp_from_buffer(bytes)
	return img if err == OK else null


## Copies the pristine original into BACKUP_ROOT, mirroring the source tree.  An existing
## backup is left alone rather than clobbered — the backup must keep holding the true
## pre-tool original even if this script is run again later.
func _backup(path: String) -> bool:
	var dest := BACKUP_ROOT.path_join(_rel(path))
	if FileAccess.file_exists(dest):
		print("   backup already present, kept: %s" % dest)
		return true

	var dest_abs := ProjectSettings.globalize_path(dest)
	var dir_err := DirAccess.make_dir_recursive_absolute(dest_abs.get_base_dir())
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		_errors += 1
		print("ERROR  cannot create %s (%d)" % [dest_abs.get_base_dir(), dir_err])
		return false

	var copy_err := DirAccess.copy_absolute(
		ProjectSettings.globalize_path(path), dest_abs)
	if copy_err != OK:
		_errors += 1
		print("ERROR  backup failed for %s (%d)" % [_rel(path), copy_err])
		return false

	print("   backup -> %s" % dest)
	return true


## Only re-encode into the container the file already has.  Writing PNG bytes into a .tga
## would leave the extension lying about the contents, so anything without a real encoder
## here is skipped instead.
func _can_save(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	return ext == "png" or ext == "jpg" or ext == "jpeg"


func _save(img: Image, path: String) -> Error:
	var dest := ProjectSettings.globalize_path(path)
	var ext := path.get_extension().to_lower()
	if ext == "png":
		return img.save_png(dest)
	return img.save_jpg(dest, 0.95)


func _rel(path: String) -> String:
	return path.trim_prefix(SOURCE_ROOT + "/")
