class_name AbilityManager
extends Node

## Holds the player's equipped abilities, tracks per-ability cooldowns (and the
## charge pool for a *charged* ability, see Ability.max_charges), and translates
## input (ability keys 1-4, plus fire buttons for EQUIP-cast abilities) into
## server-side ability activations.
##
## Abilities are populated from the player's Character resource (see
## Player.set_character).  Only the owning client sends input; the server runs the
## ability's activate*() hooks authoritatively.
##
## ## The gates
##
## An ordinary ability is castable when BOTH are open:
##
##   1. the charge pool holds at least one charge, and
##   2. [member _cooldowns] has elapsed — the *inter-cast interval* for a charged
##      ability (Ability.charge_interval), or the plain cooldown for a 1-charge
##      one, which is exactly what this always was.
##
## A metered ability adds a third (see below).
##
## A charged ability's pool is a **continuous fractional counter**, the same shape
## as Player.stamina: the integer part is banked charges, the fraction is progress
## toward the next one.  It refills at `1 / cooldown` per second up to
## `max_charges`, and a cast spends exactly 1.
##
## ## A metered ability is a third shape (MeteredAbility)
##
## A [MeteredAbility] drains a meter while it is running and refills it while it
## is not.  The meter is a pool of **seconds of use** held in [member _meter],
## derived lazily exactly like the charge pool, plus an on/off flag
## ([member _meter_active]).  It is a toggle, so `cooldown` is a *toggle delay*
## and the ability turns itself off when the pool empties — see
## [method _physics_process].
##
## ## No per-frame work, and nothing on the wire
##
## The pools are derived lazily from [member _charge_stamp_ms] and
## [member _meter_stamp_ms] with a single multiply (see _bank_at / _meter_at), so
## a peer that never reads one pays nothing and an hour-long gap costs the same as
## a frame.  There is deliberately no _process; the one _physics_process callback
## exists only for meter exhaustion and is **disabled unless a meter is actually
## running** (see _refresh_meter_tick), so a player using no metered ability still
## pays nothing per frame.
##
## Like the cooldowns beside them, both pools are **local per peer and never
## networked** — the owning client's copy is optimistic and the server's is
## authoritative, which is the model every ability already used.

@export var abilities: Array[Ability] = []

## Dev-menu "no ability cooldowns".  Per-peer like the pools below: the owning
## client's copy makes the HUD and the input gate agree, and the server's copy
## is the _cast_ability backstop.  Deliberately not broadcast to third parties,
## which never evaluate another player's casts.
var dev_no_cooldowns := false

## Dev-menu "infinite ability meters": a running meter does not drain.  Kept
## separate from [member dev_no_cooldowns], which deliberately does NOT bypass
## the meter gate (see is_ability_ready) — this is the knob that does.
## Per-peer in the same way as the cooldowns.
var dev_no_meter_drain := false

var _parent_player: Player
## Absolute `Time.get_ticks_msec()` deadlines: the instant gate 2 opens.
var _cooldowns: Array[float] = []
## Charge pool per slot, as of [member _charge_stamp_ms].  Fractional — see the
## class doc.  Named `bank` rather than `charges` to keep it unambiguous against
## Player.is_charging()/charge_time (the shoulder charge) and
## WeaponController._charge_time (the bow draw).
## Per-player cast RPC rate limit (cooldowns still gate the effect).
var _cast_window_ms: int = 0
var _cast_count: int = 0

var _charge_bank: Array[float] = []
## The `Time.get_ticks_msec()` at which [member _charge_bank] was last true.
var _charge_stamp_ms: Array[float] = []
## Meter pool per slot, in **seconds of use**, as of [member _meter_stamp_ms].
## Only meaningful for a [MeteredAbility]; see _meter_at.
var _meter: Array[float] = []
## The `Time.get_ticks_msec()` at which [member _meter] was last true.
var _meter_stamp_ms: Array[float] = []
## Whether each slot's meter is currently **draining** (true) or refilling.
## This is the toggle state, and the only thing that decides the direction
## _meter_at integrates in.
var _meter_active: Array[bool] = []

## Index of the currently-equipped (EQUIP-cast) ability, or -1 when none.
var equipped_index: int = -1

## Equip-charge state (see Ability.equip_charge_duration).  The slot being
## armed, or -1; the wall-clock instant the owner began arming; and a serial
## that invalidates a stale siren-stop timer after a cancel/re-arm.
##
## Only the owner's and the server's copies hold this — a third-party peer hears
## the siren but has no charge state (05-known-issues.md #162).  The server's
## copy is what validates the cast; the owner's copy is the responsive gate.
var _equip_charge_slot: int = -1
var _equip_charge_start_ms: int = 0
var _equip_siren_serial: int = 0
## Slot whose siren is playing on this peer, or -1.  Makes a repeated start
## (owner's local start + the server's broadcast) idempotent.
var _equip_siren_slot: int = -1
var _equip_siren: AudioStreamPlayer = null
## True once the bomb has been dropped and the siren belongs to a projectile in
## flight.  Owner and server only: it keeps a death/respawn from stopping the
## alarm before the nuke detonates.  The explosion RPC stops the siren on every
## peer, including the third-party copies that never held this flag.
var _equip_siren_bomb_in_flight: bool = false
## Replicated-on-every-peer pose flag: true from arm start until the drop or the
## cancel.  Visual only — it hides the weapon model and drops HoldBlend to 0.0
## (the Blast Charges presentation), never holsters, because the drop itself goes
## through WeaponController.fire_weapon_fire(), which checks `_is_ready()`.
var _equip_pose_active: bool = false

## The server accepts a cast this many seconds before its own copy of the
## charge clock completes, absorbing tick-timer jitter.  Both the arm request
## and the cast cross the same link, so the two clocks normally line up.
const EQUIP_SERVER_TOLERANCE := 0.15
## Safety net only: if no explosion report ever arrives (the shot was refused,
## the shooter disconnected, a reliable packet was lost), the siren still ends.
## The nuke normally detonates long before this.
const EQUIP_SIREN_MAX_SECONDS := 60.0

func _ready() -> void:
	_parent_player = get_parent() as Player
	_resize_state()
	print("[Ability] manager ready, abilities=", abilities.size())

## (Re)build the per-slot state to match [member abilities].  Every slot starts
## **full** — that is the "you start off with all charges" contract, and it is
## what makes a character change hand you a fresh loadout.
func _resize_state() -> void:
	# Stop anything still running *before* the arrays are rebuilt.  Clearing the
	# flag alone would strand the ability's effect — for noclip, a player left
	# flying through walls with no ability left to cancel it — so the transition
	# has to go through the ability's own hook.
	for i in _meter_active.size():
		if _meter_active[i]:
			_set_meter(i, _ability_at(i), false)
	# A character change invalidates any armed EQUIP ability on this peer.  A
	# dropped bomb's siren is left alone (it ends at detonation), and a
	# third-party copy never owns the stop — the server broadcasts it.
	if _equip_siren_bomb_in_flight \
			or (not _is_owning_client() and not multiplayer.is_server()):
		_clear_equip_charge_local()
	else:
		_end_equip_charge_local()
	# A character change invalidates the arming pose on every peer.  A dropped
	# bomb is unaffected (its pose ended at the drop; only the siren continues).
	_equip_pose_active = false
	var n: int = abilities.size()
	_cooldowns.resize(n)
	_charge_bank.resize(n)
	_charge_stamp_ms.resize(n)
	_meter.resize(n)
	_meter_stamp_ms.resize(n)
	_meter_active.resize(n)
	for i in n:
		_cooldowns[i] = 0.0
		_charge_stamp_ms[i] = 0.0
		_charge_bank[i] = float(_max_charges_of(i))
		_meter_stamp_ms[i] = 0.0
		_meter_active[i] = false
		_meter[i] = _max_meter_of(i)
	_refresh_meter_tick()


## Refill every meter and stop anything still running, without touching the
## cooldowns.  Called on respawn: Player.rpc_reset() does not re-apply the
## character, so _resize_state() would not otherwise run, and dying mid-noclip
## leaves the flag set with clear_all_effects() having already removed the effect
## underneath it.
func reset_meters() -> void:
	for i in _meter_active.size():
		if _meter_active[i]:
			_set_meter(i, _ability_at(i), false)
	for i in _meter.size():
		_meter[i] = _max_meter_of(i)
		_meter_stamp_ms[i] = 0.0
	_refresh_meter_tick()

## Replace the ability list (called when a character is applied).  Refills every
## charge pool and clears any equipped ability.
func set_abilities(new_abilities: Array[Ability]) -> void:
	abilities = new_abilities
	_resize_state()
	equipped_index = -1
	var names: Array[String] = []
	for a in abilities:
		names.append(a.ability_name if a else "<null>")
	print("[Ability] set_abilities: ", names)

func get_abilities() -> Array[Ability]:
	return abilities

## The ability in slot [param index], or null.  Bounds-checks **both** arrays:
## `abilities` is `@export` and can be reassigned without a _resize_state(), so a
## slot can be valid in one and not the other.
func _ability_at(index: int) -> Ability:
	if index < 0 or index >= abilities.size() or index >= _charge_bank.size():
		return null
	return abilities[index]

## Pool size for slot [param index], never below 1 (a negative or zero
## max_charges would otherwise make the pool nonsensical rather than just small).
func _max_charges_of(index: int) -> int:
	if index < 0 or index >= abilities.size():
		return 1
	var ability: Ability = abilities[index]
	return maxi(ability.max_charges, 1) if ability else 1


## The [MeteredAbility] in slot [param index], or null when the slot is empty or
## holds something else.  Bounds-checks [member _meter] as well as the ability
## list, for the reason _ability_at documents: `abilities` is `@export` and can be
## reassigned without a _resize_state(), so a slot can be valid in one array and
## not the other.
func _metered_at(index: int) -> MeteredAbility:
	if index < 0 or index >= _meter.size():
		return null
	return _ability_at(index) as MeteredAbility


## Full meter, in seconds, for slot [param index]; 0.0 for anything that is not a
## metered ability, which is also what _meter_at hands back for it.
func _max_meter_of(index: int) -> float:
	var metered := _metered_at(index)
	return maxf(metered.max_meter, 0.0) if metered != null else 0.0


## Refill rate in **seconds of meter per second**, or 0.0 when the authored
## recharge is degenerate (a non-positive or absent value would otherwise divide
## by zero).
func _meter_refill_rate(metered: MeteredAbility) -> float:
	if metered == null or metered.recharge_seconds <= 0.0:
		return 0.0
	return maxf(metered.max_meter, 0.0) / metered.recharge_seconds

## Charge pool for slot [param index] as of [param now] — a **pure read**, clamped
## to the pool size.
##
## The refill is one multiply-and-clamp and is NEVER a step loop: Ability.cooldown
## may legally be 0.0 — nothing shipped authors it, but it is a legal value and a
## loop would spin forever on it.  Because the result is clamped, reading after an
## hour away costs the same as reading after a millisecond.
func _bank_at(index: int, now: int) -> float:
	var ability := _ability_at(index)
	if ability == null:
		return 0.0
	var max_c := float(maxi(ability.max_charges, 1))
	var bank := _charge_bank[index]
	if bank >= max_c or ability.cooldown <= 0.0:
		return max_c  # full, or a cooldown of zero means instant regen
	var elapsed := float(now) - _charge_stamp_ms[index]
	if elapsed <= 0.0:
		return bank
	return minf(bank + elapsed / (ability.cooldown * 1000.0), max_c)


## Meter remaining for slot [param index] as of [param now], in **seconds** — a
## full pool is MeteredAbility.max_meter and an empty one is 0.0.  Returns 0.0 for
## a slot that is not a metered ability.
##
## The direct analogue of _bank_at, for the same reasons: one multiply-and-clamp
## against [member _meter_stamp_ms], an early-out at each end before any
## arithmetic, and never a step loop.  The only difference is that it integrates
## in **both** directions — an active meter drains at 1 s of meter per second, an
## inactive one refills at `max_meter / recharge_seconds`.
func _meter_at(index: int, now: int) -> float:
	var metered := _metered_at(index)
	if metered == null:
		return 0.0
	var full: float = maxf(metered.max_meter, 0.0)
	if full <= 0.0:
		return 0.0
	var meter: float = _meter[index]
	var draining: bool = _meter_active[index]
	# Dev-menu override: a running pool reads full and therefore never exhausts
	# (the _physics_process auto-off and the HUD both read this function).
	if draining and dev_no_meter_drain:
		return full
	var rate := 0.0
	if not draining:
		if meter >= full:
			return full                      # already full
		rate = _meter_refill_rate(metered)
		if rate <= 0.0:
			return full                      # degenerate recharge: treat as instant
	var elapsed := float(now) - _meter_stamp_ms[index]
	if elapsed <= 0.0:
		return meter
	if draining:
		return maxf(meter - elapsed / 1000.0, 0.0)
	return minf(meter + rate * elapsed / 1000.0, full)


## Toggle the dev-menu override.  Materialise every pool and re-stamp it BEFORE
## flipping the flag: turning the override OFF must not leave a stale `_meter`
## from when it was switched on, or the whole frozen interval would be applied
## at once and the pool would jump to empty.
func set_dev_no_meter_drain(on: bool) -> void:
	var now := Time.get_ticks_msec()
	for i in _meter_active.size():
		_meter[i] = _meter_at(i, now)
		_meter_stamp_ms[i] = float(now)
	dev_no_meter_drain = on


## Seconds until the meter gate opens — i.e. until the pool holds
## MeteredAbility.min_activate_meter again.  0.0 when it is open now, which
## includes the case where the ability is already running (that press turns it
## off, and an off-press is never gated by the meter).
func _meter_gate_wait(index: int, now: int) -> float:
	var metered := _metered_at(index)
	if metered == null or _meter_active[index]:
		return 0.0
	var need: float = maxf(metered.min_activate_meter, 0.0)
	if need <= 0.0:
		return 0.0
	var rate := _meter_refill_rate(metered)
	if rate <= 0.0:
		return 0.0
	return maxf(need - _meter_at(index, now), 0.0) / rate


## 0..1 progress of the **meter** gate: 1.0 when the pool is irrelevant to this
## press (not metered, already running, or holding at least min_activate_meter),
## otherwise the fill toward that minimum — so the bar and the pie visibly fill
## before the ability becomes castable again.
##
## This is the single answer to "is the meter the bottleneck": is_ability_ready,
## get_cast_progress and get_cooldown_remaining all read it, so the HUD cannot
## disagree with the cast path about what "ready" means — the same rule that keeps
## get_cast_progress in the manager rather than in the HUD.
func _meter_gate_fraction(index: int, now: int) -> float:
	var metered := _metered_at(index)
	if metered == null or _meter_active[index]:
		return 1.0
	# A pool that can never hold anything makes the ability unusable rather than
	# free: without this the gate is vacuously open and every press would burn a
	# charge and the 1 s delay for a zero-length activation.
	if metered.max_meter <= 0.0:
		return 0.0
	# min_activate_meter of 0 means "the pool is not a gate" — a legal way to
	# author a metered ability you can always switch on while it has any meter.
	var need: float = maxf(metered.min_activate_meter, 0.0)
	if need <= 0.0:
		return 1.0
	return clampf(_meter_at(index, now) / need, 0.0, 1.0)


## Turn a metered ability on or off.  **The only writer of [member _meter_active]
## apart from the array reset** — the same "one function" rule _begin_ability_gate
## follows, because a cast, an auto-off and a reset must all materialise the pool
## and re-stamp the clock identically or the pool drifts.
##
## Idempotent: a request for the state the slot is already in does nothing.  That
## is what makes a redundant press harmless — the direction rides along with the
## cast (see _request_cast), so two peers whose views differ by half an RTT cannot
## flip each other the wrong way.
##
## Deliberately does NOT go through _begin_ability_gate, and deliberately checks no
## guard: the meter running out has to end the ability even while the player is
## stunned or despawned, and an auto-off is not a cast — it must not spend a
## charge or reopen the 1 s toggle delay.  The cast path calls *both*, in order.
func _set_meter(index: int, ability: Ability, want_on: bool) -> void:
	var metered := ability as MeteredAbility
	if metered == null or _parent_player == null:
		return
	if index < 0 or index >= _meter_active.size():
		return
	if _meter_active[index] == want_on:
		return                              # already there — a redundant press
	var now := Time.get_ticks_msec()
	# Materialise the pool as of *now* before flipping, then re-stamp: the clock
	# restarts from the transition rather than from whenever it was last read
	# (same as _begin_ability_gate).
	_meter[index] = _meter_at(index, now)
	_meter_stamp_ms[index] = float(now)
	_meter_active[index] = want_on
	_refresh_meter_tick()
	print("[Ability] meter ", "on" if want_on else "off", " slot=", index, " at=", _meter[index])
	if want_on:
		metered.activate(_parent_player)
	else:
		metered.deactivate(_parent_player)


## Arm the exhaustion check iff some slot's meter is running.  Every writer of
## [member _meter_active] must finish with this — including the ones that clear
## the whole array — or the callback stays armed for the rest of the session.
func _refresh_meter_tick() -> void:
	var any_active := false
	for active in _meter_active:
		if active:
			any_active = true
			break
	set_physics_process(any_active)


## Meter exhaustion.  Runs only while a meter is active (_refresh_meter_tick), so
## this costs nothing at all for the overwhelming majority of abilities, which are
## not metered.
##
## This deliberately bypasses every guard in _cast_ability: an auto-off is a
## consequence of elapsed time, not a player action.  Routing it through them would
## let a player whose meter empties while stunned keep noclip forever — the
## off-press is blocked by the same guards in _input, so nothing could ever end it.
func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for i in _meter_active.size():
		if not _meter_active[i]:
			continue
		if _meter_at(i, now) > 0.0:
			continue
		_set_meter(i, _ability_at(i), false)


## True when [param index] can be cast right now: a charge is in hand, the instant
## gate has elapsed, and — for a metered ability that is not already running — the
## meter holds at least MeteredAbility.min_activate_meter.  Every gate is checked
## unconditionally, so a 1-charge ability (whose pool reaches 1 at exactly its
## cooldown deadline) is gated by the same code path it always was.
func is_ability_ready(index: int) -> bool:
	var ability := _ability_at(index)
	if ability == null:
		return false
	var now := Time.get_ticks_msec()
	if not dev_no_cooldowns:
		if _cooldowns[index] > float(now):
			return false
		if _bank_at(index, now) < 1.0:
			return false
	# The meter gate is deliberately NOT bypassed: "no cooldowns" must not let a
	# metered ability (noclip) start on an empty meter.
	return _meter_gate_fraction(index, now) >= 1.0

## The charge pool, `0..max_charges`.  Drives the HUD's charge bars: bar `i` is
## full at `>= i + 1` and partially filled in between — the stamina-bar read.
func get_charge_bank_fraction(index: int) -> float:
	if _ability_at(index) == null:
		return 0.0
	return _bank_at(index, Time.get_ticks_msec())

## The meter pool, 0..1, for the HUD's meter bar.  0.0 for a slot that is not a
## [MeteredAbility] — callers gate on the ability type themselves, so this is only
## ever drawn for a slot that has one.
func get_meter_fraction(index: int) -> float:
	# A passive metered ability's pool is rollback state on the Player, not this
	# per-peer clock — the movement sim reads it every predicting peer.  Delegate
	# so the HUD cannot show a different pool than the one gating air control.
	if _ability_at(index) is AirControlAbility and _parent_player != null:
		return _parent_player.get_air_control_meter_fraction()
	var full := _max_meter_of(index)
	if full <= 0.0:
		return 0.0
	return clampf(_meter_at(index, Time.get_ticks_msec()) / full, 0.0, 1.0)

## Whether slot [param index]'s meter is currently running.  Drives the HUD's
## "in use" colour and the disc's bright state.
func is_meter_active(index: int) -> bool:
	# Same delegation as get_meter_fraction: the air-control meter is draining
	# exactly while the rollback sim counted an actual strafe last tick (not
	# merely airborne input — see Player._air_strafe_factor).
	if _ability_at(index) is AirControlAbility:
		return _parent_player != null and _parent_player.is_air_control_draining()
	if index < 0 or index >= _meter_active.size():
		return false
	return _meter_active[index]

## 0..1 progress toward the *next* whole charge; 1.0 when the pool is full or the
## cooldown is zero.  This is gate 1's progress, i.e. the pie when no charge is
## in hand.
func get_recharge_fraction(index: int) -> float:
	var ability := _ability_at(index)
	if ability == null:
		return 0.0
	if ability.cooldown <= 0.0:
		return 1.0
	var bank := _bank_at(index, Time.get_ticks_msec())
	if bank >= float(maxi(ability.max_charges, 1)):
		return 1.0
	return clampf(bank - floorf(bank), 0.0, 1.0)

## 0..1 progress through gate 2 — the inter-cast interval for a charged ability,
## or the plain cooldown for a 1-charge one (which is exactly the fraction the HUD
## has always drawn).
func get_cast_interval_fraction(index: int) -> float:
	var ability := _ability_at(index)
	if ability == null:
		return 0.0
	var total: float = ability.charge_interval if ability.max_charges > 1 else ability.cooldown
	if total <= 0.0:
		return 1.0
	var remaining := maxf(_cooldowns[index] - float(Time.get_ticks_msec()), 0.0) / 1000.0
	return clampf(1.0 - remaining / total, 0.0, 1.0)

## 0..1 progress toward being castable, i.e. **whichever gate is currently the
## bottleneck**: with a charge in hand the interval is what you are waiting on,
## without one it is the recharge.  1.0 when the ability is ready now.
##
## The selector lives here, not in the HUD, so the pie and the targeted-ability
## preview gate cannot disagree about what "ready" means.
##
## A metered ability adds a third bottleneck (the pool), checked between the two
## above: with the charge pool full and the toggle delay elapsed but the meter
## still refilling, reporting 1.0 here would draw a **complete pie on a dimmed
## circle** — the ready visual for an ability that cannot be cast.
func get_cast_progress(index: int) -> float:
	var ability := _ability_at(index)
	if ability == null:
		return 0.0
	if dev_no_cooldowns:
		# Ready unless the meter is the bottleneck, so the HUD pie matches what
		# is_ability_ready() would answer.
		var gate := _meter_gate_fraction(index, Time.get_ticks_msec())
		return 1.0 if gate >= 1.0 else gate
	var now := Time.get_ticks_msec()
	if _bank_at(index, now) < 1.0:
		return get_recharge_fraction(index)
	var meter_gate := _meter_gate_fraction(index, now)
	if meter_gate < 1.0:
		return meter_gate
	if _cooldowns[index] <= float(now):
		return 1.0
	return get_cast_interval_fraction(index)

## Seconds until [param index] can be cast again; 0.0 when it is ready now.
## Reports whichever gate is the bottleneck, so for a 1-charge ability it is the
## plain cooldown it always was.
func get_cooldown_remaining(index: int) -> float:
	var ability := _ability_at(index)
	if ability == null:
		return 0.0
	if dev_no_cooldowns:
		return 0.0
	var now := Time.get_ticks_msec()
	# Single charge: gate 2 *is* the charge pool, so report it directly rather
	# than taking a max of two values that are only ever equal.
	var wait: float
	if ability.max_charges <= 1:
		wait = maxf(_cooldowns[index] - float(now), 0.0) / 1000.0
	else:
		wait = maxf(_cooldowns[index] - float(now), 0.0) / 1000.0
		var bank := _bank_at(index, now)
		if bank < 1.0:
			wait = maxf(wait, (1.0 - bank) * maxf(ability.cooldown, 0.0))
	# The meter is a third gate, and one that can outlast both of the above.
	return maxf(wait, _meter_gate_wait(index, now))

func is_equipped() -> bool:
	return equipped_index >= 0

func _input(event: InputEvent) -> void:
	if not _is_owning_client():
		return
	if PlayerInput.ui_open:
		return
	# While a shoulder charge or bashdown is active, no other ability can be cast.
	if _parent_player.is_charging() or _parent_player.is_bashing():
		return
	# A channel (StatusEffect.blocks_actions, e.g. a heal-over-time) locks
	# abilities out for its duration too.
	if _is_action_blocked():
		return

	# Ability keys 1-4.
	for i in 4:
		if event.is_action_pressed("ability_%d" % (i + 1)):
			print("[Ability] key pressed: ability_", i + 1)
			_on_ability_key(i)
			return

	# EQUIP-cast: the equipped ability's cast is triggered by a fire button.
	if equipped_index >= 0:
		if event.is_action_pressed("primary_fire"):
			_cast_equipped(0)
		elif event.is_action_pressed("secondary_fire"):
			_cast_equipped(1)
		elif event.is_action_pressed("tertiary_fire"):
			_cast_equipped(2)


## Spend one charge and open gate 2.  Deliberately ONE function rather than a
## separate "start the cooldown" and "spend a charge" pair: every cast path — the
## client-deterministic one, the client-optimistic one, and both server branches —
## has to do both, and splitting them is how one path quietly drifts into spending
## without gating, or gating without spending.
func _begin_ability_gate(index: int, ability: Ability) -> void:
	# Dev-menu no-cooldowns: spend nothing and open no deadline.  is_ability_ready
	# ignores both gates anyway; skipping the write keeps the pools intact so the
	# HUD does not visibly drain while the hack is on.
	if dev_no_cooldowns:
		return
	var now := Time.get_ticks_msec()
	# Materialise the pool as of *now* before touching it, then re-stamp: the
	# clock restarts from the cast rather than from whenever the pool was last
	# read (see _bank_at).
	_charge_bank[index] = _bank_at(index, now)
	_charge_stamp_ms[index] = float(now)
	_charge_bank[index] = maxf(_charge_bank[index] - 1.0, 0.0)
	if ability.max_charges > 1:
		_cooldowns[index] = float(now) + ability.charge_interval * 1000.0
	else:
		_cooldowns[index] = float(now) + ability.cooldown * 1000.0


func _is_on_cooldown(index: int) -> bool:
	return not is_ability_ready(index)

## True while a channel is locking the player's input out.  Reads the effect
## mirror, so it answers the same on the server and on the owning client.
func _is_action_blocked() -> bool:
	var sem: StatusEffectManager = _parent_player.status_effect_manager if _parent_player else null
	return sem != null and sem.is_action_blocked()


## True when this node belongs to the local peer's own (non-bot) player.
func _is_owning_client() -> bool:
	if _parent_player == null or _parent_player.is_bot:
		return false
	return _parent_player.is_owned_by_local_peer()

func _on_ability_key(index: int) -> void:
	if index < 0 or index >= abilities.size():
		print("[Ability] key ", index + 1, " out of range (size=", abilities.size(), ")")
		return
	var ability: Ability = abilities[index]
	if ability == null:
		print("[Ability] ability ", index, " is null")
		return
	# Passive abilities (air control) are driven by the simulation, not a key.
	if not ability.is_castable():
		return
	# Only abilities that opt in can be used while dead (despawned).
	if not _parent_player.spawned and not ability.can_be_used_while_dead:
		return
	print("[Ability] on_key ", index, " -> ", ability.ability_name, " cast_type=", ability.cast_type)
	if ability.cast_type == Ability.CastType.EQUIP:
		# Toggle: press the same key again to unequip (also cancels an equip
		# charge and stops its siren).
		if equipped_index == index:
			_cancel_equip(index)
			equipped_index = -1
			return
		# An armed ability with a charge must not start while its cooldown is
		# closed: the siren would play for a bomb that mouse1 then refuses.
		if ability.equip_charge_duration() > 0.0 and _is_on_cooldown(index):
			return
		if equipped_index >= 0:
			_cancel_equip(equipped_index)
		equipped_index = index
		_begin_equip_charge(index)
		return
	_request_cast(index, 0)

func _cast_equipped(mode: int) -> void:
	if equipped_index < 0:
		return
	var ability := _ability_at(equipped_index)
	if ability == null:
		return
	# An equip-charge ability is cast by the primary button only (LMB).  The
	# secondary/tertiary hooks are empty on every current user, and spending the
	# charge on a no-op would burn the cooldown without dropping the bomb.
	if mode != 0 and ability.equip_charge_duration() > 0.0:
		return
	if _is_on_cooldown(equipped_index):
		return
	# The fire button is inert until the equip charge has finished.  Refusing
	# here (rather than sending and letting the server reject) keeps the player
	# equipped, so the same mouse1 works the moment the charge completes.
	if not _equip_charge_ready(equipped_index):
		return
	var index: int = equipped_index
	if not _request_cast(index, mode):
		return
	# The bomb is on its way: clear the charge but KEEP the siren running.  It
	# stops when the nuke reports its explosion, not when it is dropped.
	_consume_equip_charge_local()
	# Unequip after this frame's physics so the fire press that cast the ability
	# doesn't also fire the weapon (WeaponController suppresses while equipped).
	_unequip.call_deferred()

func _unequip() -> void:
	equipped_index = -1


#region Equip charge (Davy Crockett)

## Start the arming window for [param index] on the owner's copy and tell the
## server, which validates its own clock and broadcasts the siren.  A no-op for
## an EQUIP ability with no charge (0 s).
func _begin_equip_charge(index: int) -> void:
	var ability := _ability_at(index)
	if ability == null or ability.equip_charge_duration() <= 0.0:
		return
	_equip_charge_slot = index
	_equip_charge_start_ms = Time.get_ticks_msec()
	_equip_siren_bomb_in_flight = false
	_equip_pose_active = true
	_start_equip_siren(index, ability)
	if multiplayer.is_server():
		_server_equip_charge(index, true)
	else:
		_request_equip_charge.rpc_id(1, index, true)


## Cancel an armed ability.  Stops the owner's siren immediately and tells the
## server so every other peer stops theirs.
func _cancel_equip(index: int) -> void:
	var ability := _ability_at(index)
	var had_charge := ability != null and ability.equip_charge_duration() > 0.0
	_end_equip_charge_local()
	if not had_charge:
		return
	if multiplayer.is_server():
		_server_equip_charge(index, false)
	else:
		_request_equip_charge.rpc_id(1, index, false)


## Drop any armed EQUIP ability.  Called from death/despawn on every peer.
##
## An **un-dropped** arming charge is cancelled and its siren stopped here.  A
## bomb already in flight keeps its siren until detonation: neither death nor a
## respawn silences it, and a third-party copy never owns the stop (the server
## broadcast at the explosion does).
func cancel_equip() -> void:
	var index := _equip_charge_slot
	var ability: Ability = _ability_at(index) if index >= 0 else null
	var had_charge := ability != null and ability.equip_charge_duration() > 0.0
	equipped_index = -1
	if _equip_siren_bomb_in_flight:
		_clear_equip_charge_local()
		return
	if not _is_owning_client() and not multiplayer.is_server():
		_clear_equip_charge_local()
		return
	_end_equip_charge_local()
	if not had_charge:
		return
	if multiplayer.is_server():
		_server_equip_charge(index, false)
	else:
		_request_equip_charge.rpc_id(1, index, false)


## True when the fire button may cast [param index].  An ability with no charge
## is always ready; an armed one is ready after its authored duration.
func _equip_charge_ready(index: int) -> bool:
	var ability := _ability_at(index)
	if ability == null:
		return false
	var duration := ability.equip_charge_duration()
	if duration <= 0.0:
		return true
	if _equip_charge_slot != index:
		return false
	var elapsed := float(Time.get_ticks_msec() - _equip_charge_start_ms) / 1000.0
	return elapsed >= duration


## `{ability, remaining, duration}` while an equip charge is still filling, or
## an empty dictionary.  Player merges this into the HUD's active-ability
## readout so the icon and its draining ring show the arming window.
func get_equip_charge_state() -> Dictionary:
	if _equip_charge_slot < 0:
		return {}
	var ability := _ability_at(_equip_charge_slot)
	if ability == null:
		return {}
	var duration := ability.equip_charge_duration()
	if duration <= 0.0:
		return {}
	var elapsed := maxf(
		float(Time.get_ticks_msec() - _equip_charge_start_ms) / 1000.0, 0.0)
	var remaining := duration - elapsed
	if remaining <= 0.0:
		return {}
	return {"ability": ability, "remaining": remaining, "duration": duration}


## Clear the local arming window without touching the siren.  Used when the
## bomb has been dropped (the siren now belongs to the projectile in flight) and
## on third-party copies, which never own the siren's stop.
func _clear_equip_charge_local() -> void:
	_equip_charge_slot = -1
	_equip_charge_start_ms = 0


## The bomb was dropped: clear the charge and mark the running siren as
## belonging to the projectile, so death/respawn leaves it alone until it
## reports an explosion.
func _consume_equip_charge_local() -> void:
	_clear_equip_charge_local()
	_equip_siren_bomb_in_flight = true
	_equip_pose_active = false


## Clear the local arming window and stop this peer's siren.  Does not touch
## the server's copy (the server calls this for itself and broadcasts the stop).
func _end_equip_charge_local() -> void:
	_clear_equip_charge_local()
	_equip_siren_bomb_in_flight = false
	_equip_pose_active = false
	_stop_equip_siren()


## True from arm start until the drop/cancel.  Player ORs this into its
## is_ability_pose_active() so every peer hides the weapon model and drops
## HoldBlend to 0.0 for the whole arming window (Blast Charges's presentation).
func is_equip_pose_active() -> bool:
	return _equip_pose_active


## Server-side authority for the arming window: opens it, validates a cast
## against its own clock, and broadcasts the siren edges to every peer.
func _server_equip_charge(index: int, on: bool) -> void:
	if not multiplayer.is_server():
		return
	var ability := _ability_at(index)
	if ability == null or ability.cast_type != Ability.CastType.EQUIP:
		return
	if ability.equip_charge_duration() <= 0.0:
		return
	if on:
		if _parent_player == null or not _parent_player.spawned:
			return
		# No cooldown gate here: the owner already gates the key locally, and a
		# server/client clock difference of a few ms must not leave the owner
		# armed with a siren while the server refused.  The cast backstop still
		# enforces the cooldown, and the 5 s charge cannot skip it.
		_equip_charge_slot = index
		_equip_charge_start_ms = Time.get_ticks_msec()
		_rpc_equip_siren.rpc(index, true)
		_rpc_equip_pose.rpc(true)
	elif _equip_charge_slot == index:
		_clear_equip_charge_local()
		_equip_siren_bomb_in_flight = false
		_rpc_equip_siren.rpc(index, false)
		_rpc_equip_pose.rpc(false)


## Server-side twin of _consume_equip_charge_local(): the drop succeeded, so
## clear the arming window but leave the siren running for the projectile.
func _server_consume_equip_charge(index: int) -> void:
	if _equip_charge_slot != index:
		return
	_consume_equip_charge_local()
	_rpc_equip_pose.rpc(false)


## Owner -> server.  The owning peer is the only sender allowed to arm its own
## ability; `index` resolves against this player's ability list on the server.
@rpc("any_peer", "call_remote", "reliable")
func _request_equip_charge(index: int, on: bool) -> void:
	if not multiplayer.is_server():
		return
	if _parent_player == null or not _parent_player.is_rpc_sender_allowed(
			multiplayer.get_remote_sender_id()):
		return
	_server_equip_charge(index, on)


## Server -> every peer.  Starts/stops the global siren; the charge state stays
## owner+server only (see the fields at the top).
@rpc("authority", "call_local", "reliable")
func _rpc_equip_siren(index: int, on: bool) -> void:
	if on:
		var ability := _ability_at(index)
		if ability != null:
			_start_equip_siren(index, ability)
	else:
		_equip_siren_bomb_in_flight = false
		_stop_equip_siren()


## Server -> every peer.  The arming pose is visual only (see
## _equip_pose_active): every peer hides the shooter's weapon model and ramps
## HoldBlend to 0.0, exactly like a weapon-fire burst, and restores it at drop.
@rpc("authority", "call_local", "reliable")
func _rpc_equip_pose(on: bool) -> void:
	_equip_pose_active = on


## Server -> every peer, sent by the nuke projectile when it detonates.  The
## siren runs from arming through flight, so this is its normal end: it does not
## care whether the siren still had an arming charge behind it.
@rpc("authority", "call_local", "reliable")
func stop_equip_siren_on_explosion() -> void:
	_equip_siren_bomb_in_flight = false
	_stop_equip_siren()


## Non-positional, so every peer hears it regardless of distance.  Duplicated
## per peer with looping enabled; a start on this peer while the same slot's
## siren is already playing is ignored, which is how the owner's immediate
## local start and the server's broadcast coexist.
func _start_equip_siren(index: int, ability: Ability) -> void:
	var stream := ability.equip_charge_siren()
	if stream == null or ability.equip_charge_duration() <= 0.0 \
			or not is_inside_tree():
		return
	if _equip_siren_slot == index and is_instance_valid(_equip_siren) \
			and _equip_siren.playing:
		return
	_kill_equip_siren()
	var looped: AudioStream = stream.duplicate()
	if looped is AudioStreamWAV:
		(looped as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	else:
		looped.set("loop", true)
	_equip_siren = AudioStreamPlayer.new()
	_equip_siren.stream = looped
	_equip_siren.volume_db = ability.equip_charge_siren_volume_db()
	_equip_siren_slot = index
	add_child(_equip_siren)
	_equip_siren.play()
	# The siren runs until the nuke reports its explosion (or a cancel stops it).
	# This timer is a safety net only, so a refused shot, a disconnect or a lost
	# reliable packet cannot leave it looping forever.
	_equip_siren_serial += 1
	var serial := _equip_siren_serial
	get_tree().create_timer(EQUIP_SIREN_MAX_SECONDS).timeout.connect(
		_on_equip_siren_timeout.bind(serial))


func _on_equip_siren_timeout(serial: int) -> void:
	if serial != _equip_siren_serial:
		return
	_equip_siren_bomb_in_flight = false
	_kill_equip_siren()


func _stop_equip_siren() -> void:
	_equip_siren_serial += 1
	_kill_equip_siren()


func _kill_equip_siren() -> void:
	if is_instance_valid(_equip_siren):
		_equip_siren.stop()
		_equip_siren.queue_free()
	_equip_siren = null
	_equip_siren_slot = -1

#endregion


func _request_cast(index: int, mode: int) -> bool:
	if index < 0 or index >= abilities.size():
		return false
	if _is_on_cooldown(index):
		return false
	var ability: Ability = abilities[index]
	if ability == null:
		return false
	# Passive abilities are never cast; their effect lives in the movement sim.
	if not ability.is_castable():
		return false
	# Only abilities that opt in can be used while dead (despawned).
	if not _parent_player.spawned and not ability.can_be_used_while_dead:
		return false
	print("[Ability] request_cast index=", index, " mode=", mode)
	# Targeted abilities auto-select visible enemies nearest the crosshair; the
	# chosen target names ride along with the cast so the server can validate.
	# With no valid candidates the cast is skipped and nothing is consumed.
	var target_names: Array = []
	if ability is TargetedAbility:
		target_names = _compute_target_names(ability)
		if target_names.is_empty():
			return false
	# A metered ability is a toggle, so the press means "turn it on" or "turn it
	# off" and which one is decided *here*, from the pool.  It rides along with the
	# cast so the server applies the same direction rather than re-deriving it from
	# its own flag: without that, half an RTT of disagreement turns one rejected
	# press into an inversion — the client believing it is on while the server has
	# stayed off, so the player's next press (meaning "off") switches noclip *on*.
	# Ignored by every other ability.
	var want_on: bool = ability is MeteredAbility and not is_meter_active(index)
	if ability.cast_mode == Ability.CastMode.CLIENT:
		# Deterministic effect (movement/teleport): run the hook locally so it can
		# queue rollback input.  Cooldown is tracked optimistically on the client.
		_begin_ability_gate(index, ability)
		_run_ability(index, mode, want_on)
	elif multiplayer.is_server():
		# Server sets its own cooldown authoritatively in _cast_ability.
		_cast_ability(index, mode, target_names, want_on)
	else:
		# Optimistic local cooldown for responsive HUD / spam prevention.
		_begin_ability_gate(index, ability)
		# ... and an optimistic local meter, for the same reason.  _run_ability
		# never runs on this peer for a SERVER-mode ability, so without this the
		# owner's bar would sit full until the effect replicated back.
		if ability is MeteredAbility:
			_set_meter(index, ability, want_on)
		# Timed self-buffs and action poses replicate their state to this peer,
		# but a weapon-fire burst runs only on the server.  Start the HUD window
		# locally so its icon+ring appears on the shot that started the cast.
		if ability is WeaponFireAbility and _parent_player != null \
				and _parent_player.weapon_controller != null:
			var burst := (ability as WeaponFireAbility).burst_duration()
			if burst > 0.0:
				_parent_player.weapon_controller.start_ability_visual(
					ability.ability_name, burst)
		_cast_ability.rpc_id(1, index, mode, target_names, want_on)
	return true

## Dispatch the ability's effect hook for [param mode].  [param want_on] is the
## direction of a metered toggle (see _request_cast) and is ignored by everything
## else.
func _run_ability(index: int, mode: int, want_on: bool = false) -> void:
	var ability: Ability = abilities[index]
	# Checked ahead of the mode switch: a metered ability is a toggle, so every
	# mode means the same on/off transition rather than an activate_*( ) hook —
	# and falling through to those would spend the charge without ever flipping
	# the meter.
	if ability is MeteredAbility:
		_set_meter(index, ability, want_on)
		return
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
func _cast_ability(index: int, mode: int, target_names: Array = [], want_on: bool = false) -> void:
	if not multiplayer.is_server():
		return
	if _parent_player == null or not _parent_player.is_rpc_sender_allowed(
			multiplayer.get_remote_sender_id()):
		return
	var _now := Time.get_ticks_msec()
	if _now - _cast_window_ms > 1000:
		_cast_window_ms = _now
		_cast_count = 0
	_cast_count += 1
	if _cast_count > 60:
		return
	if index < 0 or index >= abilities.size():
		return
	var ability: Ability = abilities[index]
	if ability == null:
		return
	# Server backstop for passive abilities: there is nothing to cast.
	if not ability.is_castable():
		return
	# Server backstop: reject casts while despawned unless the ability opts in.
	if not _parent_player.spawned and not ability.can_be_used_while_dead:
		return
	# Server backstop for the channel lock — the client gate in _input is what
	# makes the HUD feel right, this is what actually enforces it.
	if _is_action_blocked():
		return
	if _is_on_cooldown(index):
		return
	# Equip-charge backstop: the server validates the arming window from its own
	# clock, so a client cannot skip the siren by sending the cast early.  Both
	# the arm request and the cast cross the same link, so the tolerance only
	# absorbs tick-timer jitter.
	var equip_duration := ability.equip_charge_duration()
	if equip_duration > 0.0:
		if _equip_charge_slot != index:
			return
		var armed_for := float(_now - _equip_charge_start_ms) / 1000.0
		if armed_for + EQUIP_SERVER_TOLERANCE < equip_duration:
			return
		_server_consume_equip_charge(index)
	print("[Ability] server casting ", ability.ability_name, " mode=", mode)
	if ability is MeteredAbility:
		# Checked before the targeted branch on purpose.  A metered ability is a
		# toggle, so if it also derived from TargetedAbility it would otherwise
		# fall into the branch below, spend the charge on _begin_ability_gate and
		# then apply to targets without ever flipping the meter — leaving it
		# reading full and ready forever with nothing running.
		_begin_ability_gate(index, ability)
		_set_meter(index, ability, want_on)
	elif ability is TargetedAbility:
		var targets := _resolve_targets(ability, target_names)
		if targets.is_empty():
			return  # no valid targets — don't consume the cooldown
		_begin_ability_gate(index, ability)
		ability.apply_to_targets(_parent_player, targets)
	else:
		_begin_ability_gate(index, ability)
		_run_ability(index, mode, want_on)


## Auto-select the locked targets for a targeted ability and return their names.
## Runs on the casting peer (a client, or the host server) where the camera is live.
func _compute_target_names(ability: TargetedAbility) -> Array[String]:
	var names: Array[String] = []
	if _parent_player == null:
		return names
	var candidates := ability.find_candidates(_parent_player)
	var limit := mini(candidates.size(), ability.max_targets)
	for i in limit:
		names.append(candidates[i].name)
	return names


## Resolve and validate target names on the server (team, spawned, in range, LOS).
## The team check is the ability's own (`is_valid_target`), not a hardcoded
## enemy test — otherwise an ally-targeted ability would be previewed correctly
## and then rejected here.
func _resolve_targets(ability: TargetedAbility, names: Array) -> Array[Player]:
	var targets: Array[Player] = []
	for n in names:
		var p: Player = GameManager.find_player(n)
		if p == null or not p.spawned or p == _parent_player:
			continue
		if not ability.is_valid_target(_parent_player, p):
			continue
		if _parent_player.global_position.distance_to(p.global_position) > ability.max_range:
			continue
		if not _parent_player.has_line_of_sight_to(p):
			continue
		targets.append(p)
	return targets
