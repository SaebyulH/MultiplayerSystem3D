extends CharacterBody3D
class_name Player


var speed = 5.0
const JUMP_VELOCITY = 5.0


@export var player_input: PlayerInput
@export var input_synchronizer: MultiplayerSynchronizer
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

@onready var leaderboard = get_node("/root/Main/World1/LeaderboardComponent")




func _enter_tree() -> void:
	#The Player Input node is controlled by the LOCAL
	player_input.set_multiplayer_authority(str(name).to_int())
	body.set_multiplayer_authority(str(name).to_int())
	
	
	%Name.text = ("Host" if (name.to_int() == 1) else "Client") + ", NetID: " + str(name)

func _ready() -> void:
	add_to_group("players")

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

func reset():
	attribute_component.reset()
	weapon_controller.reset()

#executed only by authority anyway
func _no_health():
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

		var calc_speed : float = speed * weapon_controller.weapons[weapon_controller.current_weapon_index].player_speed_multiplier
		if is_crouching:
			calc_speed *= crouch_speed_multiplier

		if direction:
			velocity.x = direction.x * calc_speed
			velocity.z = direction.z * calc_speed
		else:
			velocity.x = move_toward(velocity.x, 0, calc_speed)
			velocity.z = move_toward(velocity.z, 0, calc_speed)

		move_and_slide()

func apply_knockback(force: Vector3) -> void:
	# Optional: ignore tiny forces
	if force.length() < 0.01:
		return
	
	# Apply knockback
	velocity += force

func change_health(health: float):
	attribute_component.health += health
