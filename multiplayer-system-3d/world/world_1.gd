extends Node3D

@export var player_scene: PackedScene

#@export var player_ui: Control

#@export var leaderboard_component: LeaderboardComponent
@export var spawn_parent: Node3D
#var map_path

#func hide_ui():
	#$GameMenu.hide()
	##Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
#
#func show_ui():
	#$GameMenu.show()
	#Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	

	


func load_map(map_path: String):
	if NetworkManager.is_hosting_game:

		
		var map = load(map_path).instantiate()
		map.name = "Map"
		for child in spawn_parent.get_children():
			child.queue_free()
		spawn_parent.add_child(map)

		print("MAP ADDED" + map_path)
		
		var spawn_manager_scene = load("res://world/spawn_manager.tscn")
		var spawn_manager = spawn_manager_scene.instantiate()
		spawn_manager.player_scene = player_scene
		spawn_manager.spawn_locations = map.spawn_locations
		spawn_manager.despawn_point = map.despawn_point
		add_child(spawn_manager)
