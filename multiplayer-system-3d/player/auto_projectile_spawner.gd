@tool
extends MultiplayerSpawner

@export var scan_projectiles: bool:
	set(value):
		if value:
			_scan_and_register()
			scan_projectiles = false

var _registered := {}

func _scan_and_register() -> void:
	var path := "res://weapon/projectiles/scenes/"
	var dir := DirAccess.open(path)
	
	if not dir:
		push_error("Failed to open directory: " + path)
		return

	dir.list_dir_begin()
	var file := dir.get_next()

	while file != "":
		if not dir.current_is_dir() and file.ends_with(".tscn"):
			var full_path := path + file
			
			if not _registered.has(full_path):
				add_spawnable_scene(full_path)
				_registered[full_path] = true
		
		file = dir.get_next()

	dir.list_dir_end()

	if Engine.is_editor_hint():
		notify_property_list_changed()
