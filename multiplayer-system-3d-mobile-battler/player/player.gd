extends CharacterBody3D
class_name Player


@export var acceleration: float = 40.0
@export var friction: float = 18.0
@export var air_acceleration: float = 40.0
@export var air_friction: float = 4.0
@export var tick_interpolator: TickInterpolator

@export var respawn_time: float = 1.5
var respawn_timer: float = 0.0
var _pending_spawn_position: Vector3 = Vector3.ZERO
var _has_pending_spawn: bool = false

var is_bot: bool = false  # set by SpawnManager before add_child

# In your player script
var entity_id: String :
	get:
		return name   # for players, entity_id == name == str(network_id)
	set(value):
		name = value  # bots set this explicitly before add_child


var ads: bool = false

enum Team {SPI, SCI, FFA} #If set to FFA, you can damage anyone
const FRIENDLY_FIRE_MULTIPLIER = 0.0

signal team_changed()


var skins: Array[MeshInstance3D] = []

const TEAM_COLORS: Dictionary = {
	Team.SCI: Color.WHITE,
	Team.SPI: Color.BLACK,
}

var team: Team = Team.SPI:
	set(value):
		team = value
		if is_inside_tree():
			var color: Color = TEAM_COLORS.get(value, Color.PURPLE)
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			for skin in skins:
				if skin == null:
					continue
				skin.set_surface_override_material(0, mat)
		team_changed.emit()
			
			
func get_gmc_team() -> Player.Team:
	match team:
		Team.SPI: return Player.Team.SPI
		Team.SCI: return Player.Team.SCI
		_: return Player.Team.FFA

#var despawned := true


#var needs_respawn := false
#var respawn_position := Vector3.ZERO

# In Player.gd
var knockback_velocity := Vector3.ZERO
#@export var knockback_decay: float = 100.0  # how fast it fades per second

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
	if is_bot:
		player_input.set_multiplayer_authority(1)
		body.set_multiplayer_authority(1)
		# Cover the synchronizer explicitly
		#if has_node("MultiplayerSynchronizer"):
			#$MultiplayerSynchronizer.set_multiplayer_authority(1)
	else:
		var id := str(name).to_int()
		set_multiplayer_authority(1)
		player_input.set_multiplayer_authority(id)
		body.set_multiplayer_authority(id)
		#if has_node("MultiplayerSynchronizer"):
			#$MultiplayerSynchronizer.set_multiplayer_authority(id)
			
			
func _ready() -> void:
	skins = [
		$Body/Recoil/Head/WeaponParent/RightArm,
		$Body/Recoil/Head/WeaponParent/RightForearm,
		$Body/Recoil/Head/WeaponParent/LeftForearm,
		$Body/Recoil/Head/WeaponParent/LeftArm,
		$Body/Recoil/Head/Helmet,
		$Body/Torso,
		$Body/LeftLeg,
		$Body/RighLeg,
	]
	team = team
	
	
	
	
	add_to_group("players")
	attribute_component.health_changed.connect(_health_changed)
	attribute_component.no_health.connect(no_health)
	rollback_sync.process_settings()
	despawn()
	## Initial spawn
	#if multiplayer.is_server():
		#for node in GameManager.spawn_parent.get_children():
			#if node is Map:
				#rpc_reset.rpc(node.get_random_spawn_location(team))
				#break
		
func _health_changed():
	pass

func _get_spawn_position() -> Vector3:
	for node in GameManager.spawn_parent.get_children():
		if node is Map:
			return node.get_random_spawn_location(team)
	return Vector3.ZERO



#func reset() -> void:
	#attribute_component.reset()
	#weapon_controller.reset()
	#if multiplayer.is_server():
		#rpc_reset.rpc(_get_spawn_position())
	#print("PLAYER RESET!!!!")

@rpc("any_peer", "call_local")
func rpc_reset(pos: Vector3) -> void:
	despawn()
	respawn_timer = respawn_time
	_pending_spawn_position = pos
	_has_pending_spawn = true
	velocity = Vector3.ZERO
	knockback_velocity = Vector3.ZERO
	
	
func no_health() -> void:
	print(name + " KILLED BY " + attribute_component.last_attacker)
	attribute_component.reset()
	weapon_controller.reset()
	
	if multiplayer.is_server():
		rpc_reset.rpc(_get_spawn_position())

@rpc("call_local")
func _sync_head():
	$HeadHurtbox.global_rotation = %Head.global_rotation
	$BodyHurtbox.global_rotation = $Body.global_rotation


var spawned := false

func despawn():
	hide()
	spawned = false
	global_position = GameManager.get_despawn_position()
	$Body/PlayerUI.hide()
	camera.current = false
	camera.visible = false	

func spawn():
	show()
	spawned = true
	$Body/PlayerUI.show()
	if not is_bot:
		var my_id := multiplayer.get_unique_id()
		var player_id := name.to_int()
		if my_id == player_id:
			camera.make_current()
			$BodyHurtbox/MeshInstance3D2.hide()
			$BodyHurtbox/CollisionShape3D.hide()
		else:
			camera.current = false
			camera.visible = false
	else:
		# bots never take camera, always hide their hurtbox mesh
		camera.current = false
		camera.visible = false



#if despawned:
		#global_position = GameManager.get_despawn_position()
		#$Body/PlayerUI.hide()
		#return
	#else:
		#$Body/PlayerUI.show()
		#var my_id := multiplayer.get_unique_id()
		#var player_id := name.to_int()
		#if my_id == player_id and not despawned:
			#camera.make_current()
			#$BodyHurtbox/MeshInstance3D2.hide()
			#$BodyHurtbox/CollisionShape3D.hide()
		#else:
			#camera.current = false
			#camera.visible = false	


var _debug_frames := 0

func _physics_process(delta: float) -> void:
	
	#if not spawned:
		#return
		#hide()
	#show()
	
	#if is_multiplayer_authority():
		#_sync_head.rpc()
		#
	#EVERYONE DOES THIS
	if respawn_timer > 0.0:
		
		respawn_timer -= delta
	else:
		if not spawned:
			spawn()
		
	if spawned and _debug_frames < 10:
		_debug_frames += 1
		print("[physics_process] frame=%d peer=%d pos=%s vel=%s" % [_debug_frames, multiplayer.get_unique_id(), global_position, velocity])
			
func _rollback_tick(delta, tick, is_fresh):

	if _has_pending_spawn:
		global_position = _pending_spawn_position
		velocity = Vector3.ZERO
		_has_pending_spawn = false
		tick_interpolator.teleport()
		return
		
	_apply_movement_from_input(delta)


#func _physics_process(delta: float) -> void:
	#if not get_tree().get_multiplayer().has_multiplayer_peer():
		#return
	
	#_apply_movement_from_input(delta)
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
	var on_floor := is_on_floor()

	if not on_floor:
		velocity += get_gravity() * delta
	elif player_input.jump_input:
		knockback_velocity = Vector3.ZERO
		velocity.y = JUMP_VELOCITY

	var input_dir := player_input.input_dir
	var cam_basis: Basis = camera.global_transform.basis
	var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var direction := (forward * input_dir.y + right * input_dir.x).normalized()

	var calc_speed: float = speed
	var weapons := weapon_controller.get_weapons()
	if not weapons.is_empty():
		calc_speed = speed * weapons[weapon_controller.current_weapon_index].player_speed_multiplier
	if is_crouching:
		calc_speed *= crouch_speed_multiplier

	var accel := acceleration if on_floor else air_acceleration
	var fric  := friction     if on_floor else air_friction

	if direction:
		# Accelerate toward target velocity
		var target_x := direction.x * calc_speed
		var target_z := direction.z * calc_speed
		velocity.x = move_toward(velocity.x, target_x, accel * delta)
		velocity.z = move_toward(velocity.z, target_z, accel * delta)
	else:
		# Decelerate to zero
		velocity.x = move_toward(velocity.x, 0.0, fric * delta)
		velocity.z = move_toward(velocity.z, 0.0, fric * delta)

	velocity *= NetworkTime.physics_factor
	velocity += knockback_velocity
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	
	var knockback_decay = velocity.length() ** 2 * 10
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)

	if ads:
		camera.fov = 20.0
		body.mouse_sens_x = 0.002 * 0.268
		body.mouse_sens_y = 0.002 * 0.268
		speed = 2.5
	else:
		camera.fov = 90.0
		body.mouse_sens_x = 0.002
		body.mouse_sens_y = 0.002
		speed = 5.0

#func _apply_movement_from_input(delta):
	#_force_update_is_on_floor()
#
	#if not is_on_floor():
		#velocity += get_gravity() * delta
	#elif player_input.jump_input and is_on_floor():
		#knockback_velocity = Vector3.ZERO
		#velocity.y = JUMP_VELOCITY
#
	#var input_dir := player_input.input_dir
	#var cam_basis: Basis = camera.global_transform.basis
	#var forward := Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	#var right   := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	#var direction := (forward * input_dir.y + right * input_dir.x).normalized()
	#
	#var calc_speed : float = 1.0
	#var weapons := weapon_controller.get_weapons()
	#if not weapons.is_empty():
		#calc_speed = speed * weapons[weapon_controller.current_weapon_index].player_speed_multiplier
	#if is_crouching:
		#calc_speed *= crouch_speed_multiplier
#
	#if direction:
		#velocity.x = direction.x * calc_speed
		#velocity.z = direction.z * calc_speed
	#else:
		#velocity.x = move_toward(velocity.x, 0, calc_speed)
		#velocity.z = move_toward(velocity.z, 0, calc_speed)
#
	## Decay and apply knockback separately
	#velocity *= NetworkTime.physics_factor
	#
	#velocity += knockback_velocity # moved to here, not scaled
	#
	#move_and_slide()
	#
	##velocity -= knockback_velocity
	#velocity /= NetworkTime.physics_factor
	## decay after move
	#knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)
#
	#if player_input.ads:
		#camera.fov = 20.0
		#body.mouse_sens_x = 0.002*0.268
		#body.mouse_sens_y = 0.002*0.268
		#speed = 2.5
	#else:
		#camera.fov = 90.0
		#body.mouse_sens_x = 0.002
		#body.mouse_sens_y = 0.002
		#speed = 5.0
	
	#print(knockback_velocity.length())
		


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
