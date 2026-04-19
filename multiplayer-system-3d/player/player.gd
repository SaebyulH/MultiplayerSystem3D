extends CharacterBody3D
class_name Player


const SPEED = 5.0
const JUMP_VELOCITY = 5.0


@export var player_input: PlayerInput
@export var input_synchronizer: MultiplayerSynchronizer
@export var attribute_component: AttributeComponent
@onready var camera := %Camera3D
#@export var head :Node3D
@export var body :Node3D


@onready var collider: CollisionShape3D = $CollisionShape3D
@onready var mesh: MeshInstance3D = $MeshInstance3D

var is_crouching: bool = false

@export var crouch_height: float = 1.0
@export var stand_height: float = 2.0

@export var crouch_speed_multiplier: float = 0.5


var spawn_manager: SpawnManager

var pitch := 0.0

@onready var leaderboard = get_node("/root/Main/World1/LeaderboardComponent")

func _enter_tree() -> void:
	#The Player Input node is controlled by the LOCAL
	player_input.set_multiplayer_authority(str(name).to_int())
	body.set_multiplayer_authority(str(name).to_int())
	
	
	%Name.text = ("Host" if (name.to_int() == 1) else "Client") + ", NetID: " + str(name)

func _ready() -> void:
	input_synchronizer.set_visibility_for(1, true)
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

	if is_multiplayer_authority():
		attribute_component.no_health.connect(_no_health)
		
func _health_changed():
	print(str(name) + ": Health Changed!")

#executed only by authority anyway
func _no_health():
	
	attribute_component.reset_health()
	print(name + " KILLED BY " + attribute_component.last_attacker)
	leaderboard.request_add_death(name)
	leaderboard.request_add_kill(attribute_component.last_attacker)
	spawn_manager.respawn_player(name)

func _physics_process(delta: float) -> void:
	if not get_tree().get_multiplayer().has_multiplayer_peer():
		return

	## Apply aim for all instances
	#rotation.y = player_input.body_rotation_y
	#head.rotation.x = player_input.head_rotation_x
	#sync_rotation.rpc(head.rotation.x, rotation.y)
	
	
	if is_multiplayer_authority():
		# --- UPDATE CROUCH STATE (FIX) ---
		#is_crouching = player_input.crouch
		#_apply_crouch()

		if not is_on_floor():
			velocity += get_gravity() * delta

		if player_input.jump_input and is_on_floor():
			velocity.y = JUMP_VELOCITY

		var input_dir := player_input.input_dir
		var cam_basis: Basis = camera.global_transform.basis
		var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
		var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
		var direction := (forward * input_dir.y + right * input_dir.x).normalized()

		var speed := SPEED
		if is_crouching:
			speed *= crouch_speed_multiplier

		if direction:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
		else:
			velocity.x = move_toward(velocity.x, 0, speed)
			velocity.z = move_toward(velocity.z, 0, speed)

		move_and_slide()



#@rpc("any_peer", "call_remote")
#func sync_rotation(head_x_rotation: float, body_y_rotation: float, player_name: String):
	#print("Recieved Head Rotation!")
	#if name == player_name:
		#print("Applying Head Rotation from " + player_name + "To other instances")
		#
		#rotation.y = body_y_rotation
		#head.rotation.x = head_x_rotation
#


#@rpc("any_peer", "call_remote")
#func sync_crouch(head_x_rotation: float, body_y_rotation: float, player_name: String):
	#print("Recieved Head Rotation from " + player_name)
	#if name == player_name:
		#
		#rotation.y = body_y_rotation
		#head.rotation.x = head_x_rotation


#func _apply_crouch() -> void:
	#var shape := $CollisionShape3D.shape as CapsuleShape3D
	#if shape == null:
		#return
#
	#var target_height = crouch_height if is_crouching else stand_height
#
	## capsule height is cylinder only
	#var target_cylinder = target_height - (shape.radius * 2.0)
#
	#shape.height = lerp(shape.height, target_cylinder, 10.0 * get_process_delta_time())
#
	## IMPORTANT: do NOT scale collision shape
#
	## Visuals only (safe)
	#var scale_factor := crouch_height / stand_height if is_crouching else 1.0
	#$MeshInstance3D.scale = Vector3(1, scale_factor, 1)
#
	## Camera / head should NOT be world-scaled either
	#head.position.y = (target_height * 0.9)
