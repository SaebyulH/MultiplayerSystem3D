extends Node

## Verification harness for FlyGirl's passive Air Control meter.
##
##   "C:/tools/godot/godot_console.exe" --path . res://verification/air_control_harness.tscn
##
## Exit code is the number of failed checks.  Drives the real Player /
## AbilityManager / Character resources directly (no ENet peer).  Delete after use.

var _checks: int = 0
var _fails: int = 0

func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("PASS  ", label)
	else:
		_fails += 1
		print("FAIL  ", label, "   ", detail)


func _eq(label: String, got, want) -> void:
	var ok: bool
	if (got is float or got is int) and (want is float or want is int):
		ok = is_equal_approx(float(got), float(want))
	else:
		ok = got == want
	_check(label, ok, "got %s want %s" % [got, want])


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var char: Character = load("res://player/characters/breacher.tres")
	var air: AirControlAbility = char.abilities[0] as AirControlAbility
	var carpet: WeaponFireAbility = char.abilities[1] as WeaponFireAbility

	_test_resources(char, air, carpet)

	var player: Player = await _make_player()
	if player == null:
		print("SUMMARY: could not build a Player — aborting")
		get_tree().quit(1)
		return
	_test_player(player, air)

	print("SUMMARY: %d/%d passed" % [_checks - _fails, _checks])
	get_tree().quit(_fails)


func _test_resources(char: Character, air: AirControlAbility, carpet: WeaponFireAbility) -> void:
	_check("FlyGirl slot 1 is AirControlAbility", air != null, str(char.abilities[0]))
	_check("FlyGirl slot 2 is WeaponFireAbility (Blast Charges)", carpet != null,
		str(char.abilities[1]))
	if air != null:
		_eq("air control is passive (not castable)", air.is_castable(), false)
		_eq("air max_meter", air.max_meter, 3.0)
		_eq("air recharge_seconds", air.recharge_seconds, 9.0)
		_eq("depleted air accel mult is Juggernaut's", air.depleted_air_accel_mult, 0.5)
		_eq("depleted air cap mult is Juggernaut's", air.depleted_air_speed_cap_mult, 0.5)
	if carpet != null:
		_eq("Blast Charges max_charges", carpet.max_charges, 2)
		_eq("Blast Charges damage_multiplier", carpet.damage_multiplier, 0.1)


func _test_player(player: Player, air: AirControlAbility) -> void:
	_eq("meter starts full", player.get_air_control_meter_fraction(), 1.0)
	_eq("HUD fraction delegates to the rollback meter",
		player.ability_manager.get_meter_fraction(0), 1.0)

	# Drain is proportional to misalignment: travelling forward and holding a
	# perpendicular direction is a full strafe (1 s of meter per second)...
	player.velocity = Vector3(0.0, 0.0, -4.0)
	player._update_air_control_meter(1.0, false, Vector3.RIGHT)
	_eq("perpendicular strafe drains 1 s per second", player.air_control_meter, 2.0)
	# ...holding W while looking forward is aligned, so it does not drain (and
	# recharges instead)...
	player._update_air_control_meter(1.0, false, Vector3(0.0, 0.0, -1.0))
	_eq("aligned forward input does not drain", player.air_control_meter, 2.0 + 3.0 / 9.0)
	# ...a 45° diagonal drains the sine of the angle (1 - cos 45°)...
	player.air_control_meter = 3.0
	player._update_air_control_meter(1.0, false, Vector3(1.0, 0.0, -1.0).normalized())
	_eq("diagonal strafe drains in proportion",
		player.air_control_meter, 3.0 - (1.0 - sqrt(0.5)))
	# ...and below the travel-direction threshold nothing counts as a strafe.
	player.air_control_meter = 2.0
	player.velocity = Vector3(0.0, 0.0, -0.3)
	player._update_air_control_meter(1.0, false, Vector3.RIGHT)
	_eq("low horizontal speed does not drain", player.air_control_meter, 2.0 + 3.0 / 9.0)

	# Refill while grounded / airborne with no input at full/9.
	player.air_control_meter = 0.0
	player._update_air_control_meter(1.0, true, Vector3.RIGHT)
	_eq("grounded refills at max_meter/recharge_seconds",
		player.air_control_meter, 3.0 / 9.0)
	player.air_control_meter = 0.0
	player._update_air_control_meter(1.0, false, Vector3.ZERO)
	_eq("airborne with no input refills", player.air_control_meter, 3.0 / 9.0)

	# Empty pool clamps at 0 and cannot drain further.
	player.air_control_meter = 0.0
	player.velocity = Vector3(0.0, 0.0, -4.0)
	player._update_air_control_meter(1.0, false, Vector3.RIGHT)
	_eq("empty pool clamps at 0", player.air_control_meter, 0.0)

	# Air acceleration: full pool uses FlyGirl's 2.0/2.0, empty uses 0.5/0.5.
	var full_accel := _air_step(player, air.max_meter)
	var empty_accel := _air_step(player, 0.0)
	_check("full meter gives more air control than empty", full_accel > empty_accel * 2.5,
		"full=%s empty=%s" % [full_accel, empty_accel])
	# The step is capped by the wish speed itself, so the depleted cap (1.5 × 0.5)
	# is what the velocity lands on, not the raw accel*speed*delta product.
	_eq("empty air velocity matches Juggernaut mults", empty_accel, 1.5 * 0.5)

	# HUD "in use" colour tracks an actual strafe, not merely airborne input.
	player.velocity = Vector3(0.0, 0.0, -4.0)
	player._update_air_control_meter(0.1, false, Vector3.RIGHT)
	_eq("draining flag true while strafing",
		player.ability_manager.is_meter_active(0), true)
	player._update_air_control_meter(0.1, false, Vector3(0.0, 0.0, -1.0))
	_eq("draining flag false when aligned forward",
		player.ability_manager.is_meter_active(0), false)

	# Passive abilities refuse every cast path.
	_eq("cast request refused for a passive ability",
		player.ability_manager._request_cast(0, 0), false)


func _air_step(player: Player, meter: float) -> float:
	player.air_control_meter = meter
	player.velocity = Vector3.ZERO
	player._air_accelerate(Vector3(0, 0, -1), 10.0, 0.1)
	return Vector3(player.velocity.x, 0.0, player.velocity.z).length()


func _make_player() -> Player:
	var world := Node3D.new()
	world.name = "HarnessWorld"
	add_child(world)
	var projectiles := Node3D.new()
	projectiles.name = "ProjectilesParent"
	world.add_child(projectiles)
	GameManager.projectile_parent = projectiles
	GameManager.spawn_parent = world

	var scene: PackedScene = load("res://player/player.tscn")
	var player: Player = scene.instantiate()
	player.is_bot = true
	player.name = "1"
	world.add_child(player)
	await get_tree().process_frame
	player.spawned = true
	player.set_character(load("res://player/characters/breacher.tres"))
	await get_tree().process_frame
	return player
