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
var dash_input: bool   = false

## One-shot shoulder-charge direction (world space) queued by abilities.
## ZERO = no trigger.  Input property: gathered here, broadcast, and consumed in
## _rollback_tick to start a charge.  Local staging is [member queued_charge_trigger_dir].
var charge_trigger_dir: Vector3 = Vector3.ZERO

## Local staging for the next gathered tick.  Abilities set this; _gather()
## copies it into [member charge_trigger_dir] and clears it.  Not rolled back.
var queued_charge_trigger_dir: Vector3 = Vector3.ZERO

# Not rolled back — polled each physics frame by WeaponController
var primary_fire_held: bool   = false
var secondary_fire_held: bool = false
var tertiary_fire_held: bool  = false

signal previous_weapon
signal next_weapon
signal reload
signal inspect

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
		dash_input = false
		charge_trigger_dir = Vector3.ZERO
		queued_charge_trigger_dir = Vector3.ZERO
		return
	# Stunned or pinned players cannot move, jump, crouch, dash, or cast.
	var status_manager := get_parent().status_effect_manager as StatusEffectManager
	if status_manager and (status_manager.is_stunned() or status_manager.is_pinned()):
		input_dir  = Vector2.ZERO
		jump_input = false
		crouch     = false
		dash_input = false
		charge_trigger_dir = Vector3.ZERO
		queued_charge_trigger_dir = Vector3.ZERO
		return
	input_dir  = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	jump_input = Input.is_action_pressed("ui_accept")
	crouch     = Input.is_action_pressed("crouch")
	dash_input = Input.is_action_pressed("dash")
	charge_trigger_dir = queued_charge_trigger_dir
	queued_charge_trigger_dir = Vector3.ZERO

func _input(event: InputEvent) -> void:
	if get_parent().is_bot:
		return
	if not is_multiplayer_authority():
		return

	# Stunned or pinned players cannot take any actions.
	var status_manager := get_parent().status_effect_manager as StatusEffectManager
	if status_manager and (status_manager.is_stunned() or status_manager.is_pinned()):
		primary_fire_held   = false
		secondary_fire_held = false
		tertiary_fire_held  = false
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
	if Input.is_action_just_pressed("inspect"):
		inspect.emit()
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		primary_fire_held   = false
		secondary_fire_held = false
		tertiary_fire_held  = false
