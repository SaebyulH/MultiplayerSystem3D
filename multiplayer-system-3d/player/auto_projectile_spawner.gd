@tool
extends MultiplayerSpawner

## Rebuilds this spawner's `_spawnable_scenes` from res://weapon/projectiles/scenes/.
##
## Lives on the world's `ProjectilesParent/ProjectileSpawner` in world1.tscn — the
## one spawner that replicates projectiles (see docs/02-netcode.md §6).
##
## [b]The list is shared state.[/b]  MultiplayerSpawner does not send a scene over
## the wire — it sends a reference into `_spawnable_scenes`, and every peer resolves
## it against its own copy.  The array therefore has to be identical on every peer
## and has to stay small and stable.  An array that grows or reorders between peers
## makes one peer instantiate a different scene than the one that was fired, which
## reads as a missing model rather than as a lookup bug.
##
## This setter therefore [b]rebuilds from scratch[/b], deduped and in a sorted
## order, instead of appending.  The previous append-only version left player.tscn
## with 96 entries for 17 scenes (see docs/05-known-issues.md #28).
##
## Note it can only ever register scenes that exist [b]as files[/b] — resolution
## matches the spawned node's `scene_file_path` against each entry's path.  A
## scene packed inline as a `SubResource` has no path and can never be replicated;
## see #28.  Keep every projectile in `weapon/projectiles/scenes/*.tscn` real.
@export var scan_projectiles: bool:
	set(value):
		if value:
			_scan_and_register()
			scan_projectiles = false

const PROJECTILE_DIR := "res://weapon/projectiles/scenes/"


func _scan_and_register() -> void:
	var dir := DirAccess.open(PROJECTILE_DIR)
	if dir == null:
		push_error("Failed to open directory: " + PROJECTILE_DIR)
		return

	# Collect first, then rebuild.  Clearing before a failed scan would leave the
	# spawner with no spawnable scenes at all, which breaks every projectile.
	var found: Array[String] = []
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir() and file.ends_with(".tscn"):
			found.append(PROJECTILE_DIR + file)
		file = dir.get_next()
	dir.list_dir_end()

	# DirAccess order is filesystem-dependent, and the index IS the wire format —
	# so sort, to keep the generated array reproducible anywhere.
	found.sort()

	clear_spawnable_scenes()
	for path in found:
		add_spawnable_scene(path)

	if Engine.is_editor_hint():
		notify_property_list_changed()
		print("ProjectileSpawner: %d spawnable scene(s) registered" % get_spawnable_scene_count())
