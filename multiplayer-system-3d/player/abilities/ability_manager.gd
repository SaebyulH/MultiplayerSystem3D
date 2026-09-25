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

var _parent_player: Player
## Absolute `Time.get_ticks_msec()` deadlines: the instant gate 2 opens.
var _cooldowns: Array[float] = []
## Charge pool per slot, as of [member _charge_stamp_ms].  Fractional — see the
## class doc.  Named `bank` rather than `charges` to keep it unambiguous against
## Player.is_charging()/charge_time (the shoulder charge) and
## WeaponController._charge_time (the bow draw).
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
	if _cooldowns[index] > float(now):
		return false
	if _bank_at(index, now) < 1.0:
		return false
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
	var full := _max_meter_of(index)
	if full <= 0.0:
		return 0.0
	return clampf(_meter_at(index, Time.get_ticks_msec()) / full, 0.0, 1.0)

## Whether slot [param index]'s meter is currently running.  Drives the HUD's
## "in use" colour and the disc's bright state.
func is_meter_active(index: int) -> bool:
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
	# Only abilities that opt in can be used while dead (despawned).
	if not _parent_player.spawned and not ability.can_be_used_while_dead:
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
	if _is_on_cooldown(equipped_index):
		return
	var index: int = equipped_index
	if not _request_cast(index, mode):
		return
	# Unequip after this frame's physics so the fire press that cast the ability
	# doesn't also fire the weapon (WeaponController suppresses while equipped).
	_unequip.call_deferred()

func _unequip() -> void:
	equipped_index = -1

func _request_cast(index: int, mode: int) -> bool:
	if index < 0 or index >= abilities.size():
		return false
	if _is_on_cooldown(index):
		return false
	var ability: Ability = abilities[index]
	if ability == null:
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
	if index < 0 or index >= abilities.size():
		return
	var ability: Ability = abilities[index]
	if ability == null:
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
