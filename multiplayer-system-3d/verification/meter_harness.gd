extends Node

## Throwaway verification harness for the metered-ability feature
## (MeteredAbility + AbilityManager's meter pool).
##
##   "C:/tools/godot/godot_console.exe" --path . res://verification/meter_harness.tscn
##
## Exit code is the number of failed checks.  Builds a real Player, so
## AbilityManager._parent_player is set and the toggle hooks actually run, then
## swaps in a stub MeteredAbility that records its transitions instead of touching
## status effects — StatusEffectManager.apply_effect() is a silent no-op off-server,
## so driving the real NoclipAbility here would make every assertion vacuous.
## NoclipEffect's own plumbing is unchanged by this feature and is not what this
## harness is for; the pool arithmetic is.
##
## Delete after use.

var _checks: int = 0
var _fails: int = 0


## Records on/off transitions instead of applying an effect.
class StubMeteredAbility extends MeteredAbility:
	var on_count: int = 0
	var off_count: int = 0
	func activate(_player: Player) -> void:
		on_count += 1
	func deactivate(_player: Player) -> void:
		off_count += 1


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("PASS  ", label)
	else:
		_fails += 1
		print("FAIL  ", label, "   ", detail)


func _near(label: String, got: float, want: float, eps: float = 0.01) -> void:
	_check(label, absf(got - want) <= eps, "got %f want %f" % [got, want])


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var player: Player = await _make_player()
	if player == null:
		print("SUMMARY: could not build a Player — aborting")
		get_tree().quit(1)
		return

	var stub := StubMeteredAbility.new()
	stub.ability_name = "TestMeter"
	# Pinned rather than inherited: tuning noclip must never silently invalidate
	# the arithmetic asserted here.
	stub.max_meter = 5.0
	stub.recharge_seconds = 7.0
	stub.min_activate_meter = 1.0

	var am: AbilityManager = player.ability_manager
	var arr: Array[Ability] = [stub]
	am.set_abilities(arr)

	_test_forced_settings(stub)
	_test_starts_full(am)
	_test_drain_and_refill(am)
	_test_clamping(am)
	_test_readiness(am)
	_test_toggle_transitions(am, stub)
	_test_auto_off(am, stub)
	_test_reset_meter(am, stub)
	_test_flicker_threshold(stub)
	_test_degenerate_config()
	await _test_noclip_end_to_end()

	print("SUMMARY: %d/%d passed" % [_checks - _fails, _checks])
	get_tree().quit(_fails)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

## Move the meter's timestamp back by [param seconds].  Every read derives from
## `Time.get_ticks_msec()` against that stamp, so shifting it *is* the elapsed
## time — and it keeps the whole harness free of real sleeps.
func _age(am: AbilityManager, seconds: float) -> void:
	am._meter_stamp_ms[0] -= seconds * 1000.0


## Pretend the charge pool and the toggle delay have both fully recovered, so a
## readiness assertion isolates the *meter* gate from the two gates that already
## existed.  All three together is checked separately in _test_toggle_transitions.
func _open_other_gates(am: AbilityManager) -> void:
	am._cooldowns[0] = 0.0
	am._charge_bank[0] = 1.0
	am._charge_stamp_ms[0] = float(Time.get_ticks_msec())


# --------------------------------------------------------------------------
# 1. The resource
# --------------------------------------------------------------------------
func _test_forced_settings(stub: MeteredAbility) -> void:
	# _init() pins all four; each other value is silently broken (see the class doc).
	_check("metered.cast_type == INSTANT", stub.cast_type == Ability.CastType.INSTANT)
	_check("metered.cast_mode == SERVER", stub.cast_mode == Ability.CastMode.SERVER)
	_check("metered.max_charges == 1", stub.max_charges == 1)
	_near("metered.cooldown is the 1 s toggle delay", stub.cooldown, 1.0)
	_check("metered is not 'charged' (no charge bars)", not stub.is_charged())


# --------------------------------------------------------------------------
# 2. Fresh state
# --------------------------------------------------------------------------
func _test_starts_full(am: AbilityManager) -> void:
	_near("a fresh meter is full", am.get_meter_fraction(0), 1.0)
	_check("a fresh meter is not running", not am.is_meter_active(0))
	_check("a fresh meter is castable", am.is_ability_ready(0))


# --------------------------------------------------------------------------
# 3. Rates
# --------------------------------------------------------------------------
func _test_drain_and_refill(am: AbilityManager) -> void:
	am._set_meter(0, am.get_abilities()[0], true)
	_check("turning on starts the meter", am.is_meter_active(0))

	_age(am, 2.0)
	_near("2 s of use costs 2 of 5", am.get_meter_fraction(0), 0.6)

	am._set_meter(0, am.get_abilities()[0], false)
	_check("turning off stops the meter", not am.is_meter_active(0))

	_age(am, 1.4)
	# 2 s used leaves 3 s of meter; at 5/7 s of meter per second, 1.4 s of refill
	# returns exactly 1 s — so this is short of full and the rate is the thing
	# under test rather than saturating at the cap.
	_near("refill runs at max_meter / recharge_seconds", am.get_meter_fraction(0), 0.8)

	_age(am, 3.0)
	_near("empty -> full takes recharge_seconds", am.get_meter_fraction(0), 1.0)


func _test_clamping(am: AbilityManager) -> void:
	am._set_meter(0, am.get_abilities()[0], true)
	_age(am, 99.0)
	_near("draining past empty clamps at 0", am.get_meter_fraction(0), 0.0)

	am._set_meter(0, am.get_abilities()[0], false)
	_age(am, 99.0)
	_near("refilling past full clamps at max", am.get_meter_fraction(0), 1.0)

	# A long gap must cost the same as a short one — the read is one
	# multiply-and-clamp, never a step loop.
	var t0 := Time.get_ticks_msec()
	am.get_meter_fraction(0)
	_check("an hour-long gap still reads in < 1 ms", Time.get_ticks_msec() - t0 < 1)


# --------------------------------------------------------------------------
# 4. The readiness gate
# --------------------------------------------------------------------------
func _test_readiness(am: AbilityManager) -> void:
	_open_other_gates(am)

	# Empty and running: this press turns it OFF, so it must stay castable.
	am._set_meter(0, am.get_abilities()[0], true)
	_age(am, 99.0)
	_near("an exhausted running meter reads empty", am.get_meter_fraction(0), 0.0)
	_check("an exhausted RUNNING meter is still castable (off is never gated)",
		am.is_ability_ready(0))
	am._set_meter(0, am.get_abilities()[0], false)

	# Empty and idle: this press would turn it ON, so it must be refused.
	_check("an exhausted idle meter is NOT castable", not am.is_ability_ready(0))
	# Tolerant on purpose: the pool refills in real time between these two reads,
	# so an exact 0.0 here would be asserting on the harness's own frame timing.
	_check("...and the pie is not 'complete'", am.get_cast_progress(0) < 0.2,
		"got %f" % am.get_cast_progress(0))

	# The gate opens at min_activate_meter, not at some fraction of full.
	_age(am, 1.4)
	_check("min_activate_meter of meter opens the gate", am.is_ability_ready(0))
	_near("...and the pie reads complete", am.get_cast_progress(0), 1.0)

	# Half-way there: still shut, and the pie is partial rather than complete.
	am._set_meter(0, am.get_abilities()[0], true)
	_age(am, 99.0)
	am._set_meter(0, am.get_abilities()[0], false)
	_age(am, 0.7)
	# eps is loose for the same reason as above — real frames elapse mid-test.
	_near("half of min_activate_meter is half the gate", am.get_cast_progress(0), 0.5, 0.05)
	_check("...and it is not castable yet", not am.is_ability_ready(0))
	_age(am, 1.0)


# --------------------------------------------------------------------------
# 5. The toggle
# --------------------------------------------------------------------------
func _test_toggle_transitions(am: AbilityManager, stub: StubMeteredAbility) -> void:
	# The earlier tests drove this same stub through _set_meter, so start from a
	# known count rather than assuming a fresh one.
	stub.on_count = 0
	stub.off_count = 0
	var arr: Array[Ability] = [stub]
	am.set_abilities(arr)
	_open_other_gates(am)

	_check("no transitions on a fresh slot", stub.on_count == 0 and stub.off_count == 0)

	am._set_meter(0, stub, true)
	_check("turning on calls activate() once", stub.on_count == 1 and stub.off_count == 0)

	# Idempotence is what makes a redundant press harmless across peers.
	am._set_meter(0, stub, true)
	_check("asking for the state it is already in is a no-op",
		stub.on_count == 1 and stub.off_count == 0)

	am._set_meter(0, stub, false)
	_check("turning off calls deactivate() once", stub.on_count == 1 and stub.off_count == 1)

	am._set_meter(0, stub, false)
	_check("...and asking to turn off twice is also a no-op", stub.off_count == 1)

	# A cast spends the charge and opens the 1 s toggle delay, so a second press
	# in the same instant is refused by the pre-existing gate.
	am.set_abilities(arr)
	_open_other_gates(am)
	am._request_cast(0, 0)
	_check("a cast turns the meter on", am.is_meter_active(0))
	_check("...and closes the 1 s toggle delay behind it", not am.is_ability_ready(0))
	# Age the charge pool and the deadline together: a real second passing closes
	# both gates, and they are what make the delay 1 s.
	_age(am, 1.0)
	am._charge_stamp_ms[0] -= 1000.0
	am._cooldowns[0] -= 1000.0
	_check("...which reopens after a second", am.is_ability_ready(0))

	# off -> on -> off must end idle, whichever order the presses arrived in.
	am._set_meter(0, stub, false)
	_check("the slot ends idle", not am.is_meter_active(0))


# --------------------------------------------------------------------------
# 6. Exhaustion
# --------------------------------------------------------------------------
func _test_auto_off(am: AbilityManager, stub: StubMeteredAbility) -> void:
	var arr: Array[Ability] = [stub]
	am.set_abilities(arr)
	_check("the exhaustion tick is disarmed while nothing is running",
		not am.is_physics_processing())

	# Run the pool down to half a second, then turn it on.
	am._set_meter(0, stub, true)
	_age(am, 4.5)
	am._set_meter(0, stub, false)
	_check("...still disarmed while idle", not am.is_physics_processing())

	var before := stub.off_count
	am._set_meter(0, stub, true)
	_check("running a meter arms the exhaustion tick", am.is_physics_processing())

	am._physics_process(0.0)
	_check("a meter with time left does not auto-off", am.is_meter_active(0))

	_age(am, 0.6)
	am._physics_process(0.0)
	_check("an exhausted meter turns itself off", not am.is_meter_active(0))
	_check("...through deactivate(), once", stub.off_count == before + 1)
	_check("...and the tick disarms again", not am.is_physics_processing())
	_near("...leaving the pool empty, refilling", am.get_meter_fraction(0), 0.0)

	# The auto-off must not have spent a charge or reopened the toggle delay —
	# it is not a cast.
	_check("auto-off does not reopen the toggle delay", am._cooldowns[0] <= float(Time.get_ticks_msec()))


# --------------------------------------------------------------------------
# 7. Resets
# --------------------------------------------------------------------------
func _test_reset_meter(am: AbilityManager, stub: StubMeteredAbility) -> void:
	var arr: Array[Ability] = [stub]
	am.set_abilities(arr)
	am._set_meter(0, stub, true)
	_age(am, 3.0)

	am.reset_meters()
	_check("reset stops the meter", not am.is_meter_active(0))
	_near("reset refills the meter", am.get_meter_fraction(0), 1.0)
	_check("reset disarms the exhaustion tick", not am.is_physics_processing())

	# Replacing the loadout mid-flight must also stop it, not just clear the flag
	# — otherwise the ability's effect outlives the ability that can cancel it.
	am._set_meter(0, stub, true)
	var before := stub.off_count
	am.set_abilities(arr)
	_check("set_abilities() stops a running meter through deactivate()",
		stub.off_count == before + 1 and not am.is_meter_active(0))
	_near("...and hands back a full pool", am.get_meter_fraction(0), 1.0)


# --------------------------------------------------------------------------
# 8. The tuning trap
# --------------------------------------------------------------------------
func _test_flicker_threshold(stub: MeteredAbility) -> void:
	# A player tapping at the boundary settles where `meter = rate * (1 - meter)`
	# with `rate = max_meter / recharge_seconds`.  Below that fixed point the
	# ability can be flickered on and off forever at the same average uptime as
	# one long burst, which is strictly better for dodging fire.
	var rate: float = stub.max_meter / stub.recharge_seconds
	var attractor: float = rate / (1.0 + rate)
	_check("min_activate_meter is above the flicker attractor (%.2f s)" % attractor,
		stub.min_activate_meter > attractor,
		"min=%f attractor=%f" % [stub.min_activate_meter, attractor])
	_check("...and leaves usable meter above it",
		stub.min_activate_meter < stub.max_meter)


# --------------------------------------------------------------------------
# 9. Degenerate authored values must not divide by zero or read stale state
# --------------------------------------------------------------------------
func _test_degenerate_config() -> void:
	var bad := StubMeteredAbility.new()
	bad.max_meter = 0.0
	bad.recharge_seconds = 0.0
	bad.min_activate_meter = 0.0
	var arr: Array[Ability] = [bad]
	var am := AbilityManager.new()
	add_child(am)
	am.set_abilities(arr)

	_near("max_meter == 0 reads 0, not NaN", am.get_meter_fraction(0), 0.0)
	_check("max_meter == 0 is never ready (no free cast)", not am.is_ability_ready(0))
	var f := am.get_cast_progress(0)
	_check("a degenerate meter does not produce NaN in the pie", f == f and f >= 0.0 and f <= 1.0,
		"got %f" % f)

	var plain: Ability = Ability.new()
	var arr2: Array[Ability] = [plain]
	am.set_abilities(arr2)
	_near("a non-metered slot reports no meter", am.get_meter_fraction(0), 0.0)
	_check("...and is not 'running'", not am.is_meter_active(0))
	_check("...and draws no meter bar geometry",
		AbilityCircle.new().meter_bar_geometry(Vector2(32, 32), 30) == Vector4.ZERO)

	_test_meter_bar_geometry()


## The bar is drawn, not laid out by a container, so a sign error here is
## invisible in gameplay and only shows up as a bar half off the widget.  Same
## reason charge_bar_geometry is split out, and the same assertion the charge
## bars get: it fits at both disc diameters.
func _test_meter_bar_geometry() -> void:
	for d in [AbilityCircle.BASE_DIAMETER, AbilityCircle.ACTIVE_DIAMETER]:
		# Explicit types, not := — an untyped array literal is a Variant source
		# (CLAUDE.md), and inferring from it is the "Cannot infer the type" trap.
		var diameter: float = d
		var circle := AbilityCircle.new()
		circle.set_meter(1.0, false, true)
		var radius: float = diameter * 0.5 - 2.0
		var geom: Vector4 = circle.meter_bar_geometry(Vector2(diameter, diameter) * 0.5, radius)
		var fits: bool = geom.z > 0.0 and geom.x >= 0.0 and geom.y >= 0.0 \
			and geom.x + geom.z <= diameter and geom.y + geom.w <= diameter
		_check("meter bar fits inside a %.0f px disc" % diameter, fits, "geom=%s" % geom)

	# A bar that still refills is drawn as a partial fill; one with nothing left
	# draws only the track, which is why `enabled` has to be a separate flag.
	var circle := AbilityCircle.new()
	circle.set_meter(1.0, false, true)
	_check("meter bar is enabled only when asked", circle.meter_bar_geometry(Vector2(32, 32), 30).z > 0.0)
	circle.set_meter(0.0, false, false)
	_check("...and disabled draws nothing",
		circle.meter_bar_geometry(Vector2(32, 32), 30) == Vector4.ZERO)


# --------------------------------------------------------------------------
# 10. The real NoclipAbility, against a real (local, loopback) server peer
# --------------------------------------------------------------------------
## The stub above proves the machinery; this proves the wiring the feature
## actually ships — that a metered cast reaches NoclipEffect, and that exhaustion
## takes it away again and arms the exit pulse.  StatusEffectManager refuses to
## apply anything off-server, so this needs a real server peer or every assertion
## here would be vacuous.
func _test_noclip_end_to_end() -> void:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(47999, 1) != OK:
		_check("could not open a loopback server peer", false)
		return
	get_tree().get_multiplayer().multiplayer_peer = peer

	var player: Player = await _make_player()
	var noclip: MeteredAbility = load("res://player/abilities/noclip.tres")
	_check("noclip.tres is a MeteredAbility", noclip is MeteredAbility)
	_near("noclip has 5 s of meter", noclip.max_meter, 5.0)
	_near("noclip takes 7 s to recharge", noclip.recharge_seconds, 7.0)
	_near("noclip's toggle delay is 1 s", noclip.cooldown, 1.0)

	var am: AbilityManager = player.ability_manager
	var arr: Array[Ability] = [noclip]
	am.set_abilities(arr)

	_check("noclip starts off", not player.status_effect_manager.has_effect("noclip"))
	am._request_cast(0, 0)
	_check("a metered cast applies NoclipEffect", player.status_effect_manager.has_effect("noclip"))
	_check("...and starts the meter", am.is_meter_active(0))

	# Run the pool dry and let the exhaustion tick end it, exactly as it would in
	# a live game — this is the path that replaced the manual re-cast.
	am._meter_stamp_ms[0] -= 6000.0
	am._physics_process(0.0)
	_check("exhaustion removes NoclipEffect", not player.status_effect_manager.has_effect("noclip"))
	_check("...and stops the meter", not am.is_meter_active(0))
	# NoclipEffect._on_remove starts the 999-damage pulsee, so burning the last of
	# the bar is still lethal — the behaviour the user asked for.
	_check("...and arms the 999-damage exit pulse", player._noclip_exit_time > 0.0)

	# And the toggle path, once the delay and the pool are back.
	am._cooldowns[0] = 0.0
	am._charge_bank[0] = 1.0
	am._charge_stamp_ms[0] = float(Time.get_ticks_msec())
	am._meter_stamp_ms[0] -= 99_000.0
	_check("noclip is castable again once refilled", am.is_ability_ready(0))
	am._request_cast(0, 0)
	_check("...and turns back on", player.status_effect_manager.has_effect("noclip"))

	am._set_meter(0, noclip, false)
	_check("a manual off removes it too", not player.status_effect_manager.has_effect("noclip"))

	# respawn path
	am._request_cast(0, 0)
	am.reset_meters()
	_check("reset_meters() clears a running noclip on respawn",
		not am.is_meter_active(0))
	_near("...and hands back a full bar", am.get_meter_fraction(0), 1.0)


func _make_player() -> Player:
	var world := Node3D.new()
	world.name = "HarnessWorld"
	add_child(world)
	GameManager.spawn_parent = world

	var scene: PackedScene = load("res://player/player.tscn")
	var player: Player = scene.instantiate()
	# Set before add_child: Player._enter_tree wires per-child authority off is_bot.
	player.is_bot = true
	player.name = "1"
	world.add_child(player)
	await get_tree().process_frame
	player.spawned = true
	return player
