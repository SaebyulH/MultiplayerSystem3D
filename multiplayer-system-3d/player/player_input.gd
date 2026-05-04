extends Node
class_name PlayerInput

# ---------------------------------------------------------------------------
# Architecture notes
# ---------------------------------------------------------------------------
# primary_fire_held / primary_fire_just_released must NOT be in the RollbackSynchronizer's
# input_properties. Netfox snapshots and restores those each tick, which
# means the values get stomped before WeaponController can consume them.
#
# Instead, fire state is managed here and consumed directly by
# WeaponController in _physics_process — outside the rollback tick entirely.
#
# Movement / jump / crouch remain in input_properties because they feed into
# _rollback_tick on Player and need deterministic replay.
# ---------------------------------------------------------------------------

# Rolled back by netfox — keep in input_properties
var input_dir: Vector2 = Vector2.ZERO
var jump_input: bool   = false
var crouch: bool       = false
var ads: bool = false

# NOT rolled back — consumed directly by WeaponController each physics frame.
# WeaponController clears primary_fire_just_released after reading it.
var primary_fire_held: bool          = false
var primary_fire_just_released: bool = false

var secondary_fire_held: bool          = false
var secondary_fire_just_released: bool = false




signal previous_weapon
signal next_weapon
signal reload
static var ui_open: bool = false

func _ready() -> void:
	NetworkTime.before_tick_loop.connect(_gather)


func _gather() -> void:
	if not is_inside_tree() or not is_multiplayer_authority():
		return
	input_dir  = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	jump_input = Input.is_action_pressed("ui_accept")
	crouch     = Input.is_action_pressed("crouch")
	#ads     = Input.is_action_pressed("ads")
	


func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return

	# Capture mouse on first click without firing through the click
	if Input.is_action_just_pressed("primary_fire"):
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			if not ui_open:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			primary_fire_held = false
			return
	
	# Capture mouse on first click without firing through the click
	if Input.is_action_just_pressed("secondary_fire"):
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			if not ui_open:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			secondary_fire_held = false
			return
	
	
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	# Update held state every input event so WeaponController always has
	# the current value when it polls in _physics_process
	primary_fire_held = Input.is_action_pressed("primary_fire")
	secondary_fire_held = Input.is_action_pressed("secondary_fire")
	

	# One-frame flag — WeaponController clears this after reading
	if Input.is_action_just_released("primary_fire"):
		primary_fire_just_released = true
	# One-frame flag — WeaponController clears this after reading
	if Input.is_action_just_released("secondary_fire"):
		secondary_fire_just_released = true
		
		
		
	if Input.is_action_just_pressed("previous_weapon"):
		previous_weapon.emit()
	if Input.is_action_just_pressed("next_weapon"):
		next_weapon.emit()
	if Input.is_action_just_pressed("reload"):
		reload.emit()

	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		primary_fire_held = false
