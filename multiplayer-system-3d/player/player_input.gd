class_name PlayerInput extends Node

# ---------------------------------------------------------------------------
# Architecture notes
# ---------------------------------------------------------------------------
# primary/secondary/tertiary_fire_held must NOT be in RollbackSynchronizer's
# input_properties. Netfox stomps them on re-simulation ticks before
# WeaponController can consume them.
#
# Fire state is managed here and polled directly by WeaponController in
# _physics_process — outside the rollback tick entirely.
# Movement / jump / crouch stay in input_properties for deterministic replay.
# ---------------------------------------------------------------------------

# Rolled back by netfox
var input_dir: Vector2 = Vector2.ZERO
var jump_input: bool   = false
var crouch: bool       = false

# Not rolled back — polled each physics frame by WeaponController
var primary_fire_held: bool   = false
var secondary_fire_held: bool = false
var tertiary_fire_held: bool  = false

signal previous_weapon
signal next_weapon
signal reload

static var ui_open: bool = false

const FIRE_ACTIONS: Array[String] = ["primary_fire", "secondary_fire", "tertiary_fire"]

func _ready() -> void:
	NetworkTime.before_tick_loop.connect(_gather)

func _gather() -> void:
	
	if not is_inside_tree() or not is_multiplayer_authority():
		return
		
	if get_parent().is_bot:
		return
	if ui_open:
		input_dir  = Vector2.ZERO
		jump_input = false
		return
	input_dir  = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	jump_input = Input.is_action_pressed("ui_accept")
	crouch     = Input.is_action_pressed("crouch")

func _input(event: InputEvent) -> void:
	if get_parent().is_bot:
		return
	if not is_multiplayer_authority():
		return

	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		if event.is_action_pressed("ui_cancel"):
			return
		# Capture mouse on first click — don't fire through it
		for action in FIRE_ACTIONS:
			if Input.is_action_just_pressed(action):
				if not ui_open:
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				return
		return

	primary_fire_held   = Input.is_action_pressed("primary_fire")
	secondary_fire_held = Input.is_action_pressed("secondary_fire")
	tertiary_fire_held  = Input.is_action_pressed("tertiary_fire")

	if Input.is_action_just_pressed("previous_weapon"):
		previous_weapon.emit()
	if Input.is_action_just_pressed("next_weapon"):
		next_weapon.emit()
	if Input.is_action_just_pressed("reload"):
		reload.emit()
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		primary_fire_held   = false
		secondary_fire_held = false
		tertiary_fire_held  = false
