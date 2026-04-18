extends CharacterBody3D
class_name Player


const SPEED = 5.0
const JUMP_VELOCITY = 5.0


@export var player_input: PlayerInput
@export var input_synchronizer: MultiplayerSynchronizer
@export var attribute_component: AttributeComponent
@onready var camera := %Camera3D
@onready var head := %Head

var spawn_manager: SpawnManager

var pitch := 0.0

@onready var leaderboard = get_node("/root/Main/World1/LeaderboardComponent")

func _enter_tree() -> void:
	#The Player Input node is controlled by the LOCAL
	player_input.set_multiplayer_authority(str(name).to_int())
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

	# Apply aim for all instances — server drives physics, client sees it locally too
	rotation.y = player_input.body_rotation_y
	head.rotation.x = player_input.head_rotation_x

	if is_multiplayer_authority():
		if not is_on_floor():
			velocity += get_gravity() * delta
		if player_input.jump_input and is_on_floor():
			velocity.y = JUMP_VELOCITY
		var input_dir := player_input.input_dir
		var cam_basis: Basis = camera.global_transform.basis
		var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
		var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
		var direction := (forward * input_dir.y + right * input_dir.x).normalized()
		if direction:
			velocity.x = direction.x * SPEED
			velocity.z = direction.z * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)
			velocity.z = move_toward(velocity.z, 0, SPEED)
		move_and_slide()
		

	
