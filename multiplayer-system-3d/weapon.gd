extends Node

@export var player_input: PlayerInput
@export var projectile: PackedScene
@export var projectile_spawn_parent: Node3D

@onready var _parent_player = get_parent()
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	player_input.primary_fire.connect(_primary_fire)

func _primary_fire():
	_spawn_projectile.rpc_id(1)
	
@rpc("any_peer", "call_local")
func _spawn_projectile():
	if is_multiplayer_authority():
		var projectile_scene = projectile.instantiate() as Node3D
		projectile_scene.global_transform = _parent_player.global_transform
		projectile_scene.shooter_name = _parent_player.name
		projectile_spawn_parent.add_child(projectile_scene, true)
