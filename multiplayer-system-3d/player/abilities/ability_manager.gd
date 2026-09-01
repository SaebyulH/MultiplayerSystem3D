class_name AbilityManager
extends Node

## Holds the player's equipped abilities, tracks per-ability cooldowns, and
## translates input (ability keys 1-4, plus fire buttons for EQUIP-cast abilities)
## into server-side ability activations.
##
## Abilities are populated from the player's Character resource (see
## Player.set_character).  Only the owning client sends input; the server runs the
## ability's activate*() hooks authoritatively.

@export var abilities: Array[Ability] = []

var _parent_player: Player
var _cooldowns: Array[float] = []

## Index of the currently-equipped (EQUIP-cast) ability, or -1 when none.
var equipped_index: int = -1

func _ready() -> void:
	_parent_player = get_parent() as Player
	_resize_cooldowns()
	print("[Ability] manager ready, abilities=", abilities.size())

func _resize_cooldowns() -> void:
	_cooldowns.resize(abilities.size())
	for i in _cooldowns.size():
		_cooldowns[i] = 0.0

## Replace the ability list (called when a character is applied).  Clears
## cooldowns and any equipped ability.
func set_abilities(new_abilities: Array[Ability]) -> void:
	abilities = new_abilities
	_resize_cooldowns()
	equipped_index = -1
	var names: Array[String] = []
	for a in abilities:
		names.append(a.ability_name if a else "<null>")
	print("[Ability] set_abilities: ", names)

func get_abilities() -> Array[Ability]:
	return abilities

func get_cooldown_remaining(index: int) -> float:
	if index < 0 or index >= _cooldowns.size():
		return 0.0
	return _cooldowns[index]

func is_equipped() -> bool:
	return equipped_index >= 0

func _process(delta: float) -> void:
	for i in _cooldowns.size():
		if _cooldowns[i] > 0.0:
			_cooldowns[i] = maxf(_cooldowns[i] - delta, 0.0)

	if not _is_owning_client():
		return
	if PlayerInput.ui_open:
		return
	# While a shoulder charge is active, no other ability can be cast.
	if _parent_player.is_charging():
		return

	# Ability keys 1-4.
	for i in 4:
		if Input.is_action_just_pressed("ability_%d" % (i + 1)):
			print("[Ability] key pressed: ability_", i + 1)
			_on_ability_key(i)
			return

	# EQUIP-cast: the equipped ability's cast is triggered by a fire button.
	if equipped_index >= 0:
		if Input.is_action_just_pressed("primary_fire"):
			_cast_equipped(0)
		elif Input.is_action_just_pressed("secondary_fire"):
			_cast_equipped(1)
		elif Input.is_action_just_pressed("tertiary_fire"):
			_cast_equipped(2)

## True when this node belongs to the local peer's own (non-bot) player.
func _is_owning_client() -> bool:
	if _parent_player == null or _parent_player.is_bot:
		return false
	var my_id: int = multiplayer.get_unique_id()
	var owner_id: int = _parent_player.name.to_int()
	return my_id == owner_id

func _on_ability_key(index: int) -> void:
	if index < 0 or index >= abilities.size():
		print("[Ability] key ", index + 1, " out of range (size=", abilities.size(), ")")
		return
	var ability: Ability = abilities[index]
	if ability == null:
		print("[Ability] ability ", index, " is null")
		return
	print("[Ability] on_key ", index, " -> ", ability.ability_name, " cast_type=", ability.cast_type)
	if ability.cast_type == Ability.CastType.EQUIP:
		# Toggle: press the same key again to unequip.
		equipped_index = -1 if equipped_index == index else index
		return
	_request_cast(index, 0)

func _cast_equipped(mode: int) -> void:
	if equipped_index < 0:
		return
	if _cooldowns[equipped_index] > 0.0:
		return
	var index: int = equipped_index
	_request_cast(index, mode)
	# Unequip after this frame's physics so the fire press that cast the ability
	# doesn't also fire the weapon (WeaponController suppresses while equipped).
	_unequip.call_deferred()

func _unequip() -> void:
	equipped_index = -1

func _request_cast(index: int, mode: int) -> void:
	if index < 0 or index >= abilities.size():
		return
	if _cooldowns[index] > 0.0:
		return
	var ability: Ability = abilities[index]
	if ability == null:
		return
	print("[Ability] request_cast index=", index, " mode=", mode)
	if ability.cast_mode == Ability.CastMode.CLIENT:
		# Deterministic effect (movement/teleport): run the hook locally so it can
		# queue rollback input.  Cooldown is tracked optimistically on the client.
		_cooldowns[index] = ability.cooldown
		_run_ability(index, mode)
	elif multiplayer.is_server():
		# Server sets its own cooldown authoritatively in _cast_ability.
		_cast_ability(index, mode)
	else:
		# Optimistic local cooldown for responsive HUD / spam prevention.
		_cooldowns[index] = ability.cooldown
		_cast_ability.rpc_id(1, index, mode)

## Dispatch the ability's effect hook for [param mode].
func _run_ability(index: int, mode: int) -> void:
	var ability: Ability = abilities[index]
	match mode:
		0:
			if ability.cast_type == Ability.CastType.EQUIP:
				ability.activate_primary(_parent_player)
			else:
				ability.activate(_parent_player)
		1:
			ability.activate_secondary(_parent_player)
		2:
			ability.activate_tertiary(_parent_player)

@rpc("any_peer", "reliable")
func _cast_ability(index: int, mode: int) -> void:
	if not multiplayer.is_server():
		return
	if index < 0 or index >= abilities.size():
		return
	var ability: Ability = abilities[index]
	if ability == null:
		return
	if _cooldowns[index] > 0.0:
		return
	_cooldowns[index] = ability.cooldown
	print("[Ability] server casting ", ability.ability_name, " mode=", mode)
	_run_ability(index, mode)
