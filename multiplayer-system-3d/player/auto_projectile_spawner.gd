extends MultiplayerSpawner

func _ready() -> void:
	var dir = DirAccess.open("res://weapon/projectiles/scenes/")
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if file.ends_with(".tscn"):
				add_spawnable_scene("res://weapon/projectiles/scenes/" + file)
			file = dir.get_next()
