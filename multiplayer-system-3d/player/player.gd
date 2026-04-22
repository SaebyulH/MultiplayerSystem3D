extends CharacterBody3D
class_name Player

var needs_respawn := false
var respawn_position := Vector3.ZERO

# In Player.gd
var knockback_velocity := Vector3.ZERO
@export var knockback_decay: float = 50.0  # how fast it fades per second

var speed = 5.0
const JUMP_VELOCITY = 5.0

var queue_velocity := Vector3(0.0, 0.0, 0.0)
#var queue_global_position := Vector3(0.0, 0.0, 0.0)
#var queue_global_position_applied := true

@export var player_input: PlayerInput
@export var rollback_sync: RollbackSynchronizer
@export var attribute_component: AttributeComponent
@onready var camera := %Camera3D
#@export var head :Node3D
@export var body :Node3D


@export var weapon_controller: WeaponController
@onready var collider: CollisionShape3D = $CollisionShape3D
@onready var mesh: MeshInstance3D = $MeshInstance3D

var is_crouching: bool = false

@export var crouch_height: float = 1.0
@export var stand_height: float = 2.0

@export var crouch_speed_multiplier: float = 0.5


var spawn_manager: SpawnManager

var pitch := 0.0

#@onready var leaderboard: LeaderboardComponent = get_node("/root/Main/World1/LeaderboardComponent")




func _enter_tree() -> void:
	#The Player Input node is controlled by the LOCAL
	player_input.set_multiplayer_authority(str(name).to_int())
	body.set_multiplayer_authority(str(name).to_int())
	#set_multiplayer_authority(str(name).to_int())
	
	
	#
	#%Name

func _ready() -> void:
	add_to_group("players")

	#input_synchronizer.set_visibility_for(1, true)
	attribute_component.health_changed.connect(_health_changed)

	# Only the peer who OWNS this player activates their camera
	var my_id := multiplayer.get_unique_id()
	var player_id := name.to_int()

	if my_id == player_id:
		camera.make_current()
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		camera.current = false
		camera.visible = false

	attribute_component.no_health.connect(_no_health)
		
	rollback_sync.process_settings()
		
func _health_changed():
	pass

func reset():
	attribute_component.reset()
	var last_weapon = weapon_controller.current_weapon_index
	weapon_controller.reset()
	weapon_controller.current_weapon_index = last_weapon

	needs_respawn = true
	for sibling in get_parent().get_children():
		if sibling is Map:
			respawn_position = sibling.get_random_spawn_location()
			break
	print("KFAJKFLLAJDLFKJADKL")
	
#executed only by authority anyway
func _no_health():
	print(name + " KILLED BY " + attribute_component.last_attacker)
	#Leaderboard.request_add_death(name)
	#Leaderboard.request_add_kill(attribute_component.last_attacker)
	#spawn_manager.respawn_player(name)
	reset()

func _rollback_tick(delta, tick, is_fresh):
	if needs_respawn:
		global_position = respawn_position
		velocity = Vector3.ZERO
		needs_respawn = false
	_apply_movement_from_input(delta)


func _physics_process(delta: float) -> void:
	if not get_tree().get_multiplayer().has_multiplayer_peer():
		return
	
	_apply_movement_from_input(delta)
	## Apply aim for all instances
	#rotation.y = player_input.body_rotation_y
	#head.rotation.x = player_input.head_rotation_x
	#sync_rotation.rpc(head.rotation.x, rotation.y)
	
	#
	#if is_multiplayer_authority():
#
		#move_and_slide()
func _force_update_is_on_floor():
	var old_velocity = velocity
	velocity = Vector3.ZERO
	move_and_slide()
	velocity = old_velocity


func apply_knockback(force: Vector3) -> void:
	if force.length() < 0.01:
		return
	knockback_velocity += force

func _apply_movement_from_input(delta):
	_force_update_is_on_floor()

	if not is_on_floor():
		velocity += get_gravity() * delta
	elif player_input.jump_input and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := player_input.input_dir
	var cam_basis: Basis = camera.global_transform.basis
	var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var direction := (forward * input_dir.y + right * input_dir.x).normalized()

	var calc_speed : float = speed * weapon_controller.weapons[weapon_controller.current_weapon_index].player_speed_multiplier
	if is_crouching:
		calc_speed *= crouch_speed_multiplier

	if direction:
		velocity.x = direction.x * calc_speed
		velocity.z = direction.z * calc_speed
	else:
		velocity.x = move_toward(velocity.x, 0, calc_speed)
		velocity.z = move_toward(velocity.z, 0, calc_speed)

	# Decay and apply knockback separately
	velocity *= NetworkTime.physics_factor
	velocity += knockback_velocity  # moved to here, not scaled
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	# decay after move
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)




#func set_player_position(vector: Vector3):
	#queue_global_position = vector
	#queue_global_position_applied = false



#func apply_knockback(force: Vector3) -> void:
	## Optional: ignore tiny forces
	#if force.length() < 0.01:
		#return
	#
	## Apply knockback
	#queue_velocity += force
	#
	#print("APPLIED KNOCKBACK" + str(force.length()))

func change_health(health: float, changer: String):
	attribute_component.apply_health_delta(health, changer, self.name)
	#Leaderboard.request_add_death(changer)
