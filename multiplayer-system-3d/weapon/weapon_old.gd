#extends Node3D
#
#
#
#@export var projectile: PackedScene
#@export var projectile_spawn_parent: Node3D
#
#@export var _parent_player: Player
#@onready var recoil = %CameraRecoil
## Called when the node enters the scene tree for the first time.
#func _ready() -> void:
	#player_input.primary_fire.connect(_primary_fire)
#
#func _primary_fire():
	#_spawn_projectile.rpc_id(1)
	#recoil.recoilFire()
	#
	#
#@rpc("any_peer", "call_local")
#func _spawn_projectile():
	#if is_multiplayer_authority():
		#var projectile_scene = projectile.instantiate() as Node3D
#
		## Spawn at player transform
		#projectile_scene.global_transform = _parent_player.global_transform
#
		## Identify shooter
		#projectile_scene.shooter_name = _parent_player.name
#
		## Forward direction in Godot is usually -Z
		#var forward_dir: Vector3 = global_transform.basis.z
#
		## Set velocity (adjust speed as needed)
		#var SPEED := 1000
		#projectile_scene.velocity = -forward_dir * SPEED
#
		#projectile_spawn_parent.add_child(projectile_scene, true)
