extends CharacterBody3D
class_name Player


const SPEED = 5.0
const JUMP_VELOCITY = 4.5

const MAX_HEALTH = 100
var health: int = MAX_HEALTH:
	set(value):
		health = value
		print("Health changed to: ", health)
		# You can call a function or emit a signal here
		_on_health_changed()

@export var player_input: PlayerInput
@export var input_synchronizer: MultiplayerSynchronizer

func _enter_tree() -> void:
	#The Player Input node is controlled by the LOCAL
	player_input.set_multiplayer_authority(str(name).to_int())
	$Name.text = ("Host" if (name.to_int() == 1) else "Client") + " Network ID: " + str(name)
	$Name2.text = str(health)

	
func _ready() -> void:
	input_synchronizer.set_visibility_for(1, true)

func _on_health_changed():
	$Name2.text = str(health)

func change_health(delta: int ):
	health += delta
	if health > MAX_HEALTH:
		health = MAX_HEALTH
	if health < 0:
		health = 0
		
		
func _physics_process(delta: float) -> void:
	#Only server moves it. It is synced via the syncher
	if get_tree().get_multiplayer().has_multiplayer_peer() and is_multiplayer_authority():

		# Add the gravity.
		if not is_on_floor():
			velocity += get_gravity() * delta

		# Handle jump.
		if player_input.jump_input and is_on_floor():
			velocity.y = JUMP_VELOCITY
		
		
		
		
		# Input
		var input_dir := player_input.input_dir
		var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
		if direction:
			velocity.x = direction.x * SPEED
			velocity.z = direction.z * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)
			velocity.z = move_toward(velocity.z, 0, SPEED)

		move_and_slide()
