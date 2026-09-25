extends Node
class_name AttributeComponent

signal health_changed
signal no_health

var last_attacker = "NONE"
## Direction of the last damaging hit (away from the attacker), used to knock the
## death ragdoll backward.  Overwritten on every hit, so it holds the killing blow.
var last_hit_direction: Vector3 = Vector3.ZERO
var killstreak := 0

## Last *enemy* who damaged this player, credited for environmental kills
## (fall damage, hazards).  Expires after ENEMY_ATTACKER_EXPIRY seconds.
var last_enemy_attacker = "NONE"
var _enemy_attacker_expiry: Timer

@export var passive_heal_per_sec: float = 10.0

var _time_since_last_damage: float = 0.0
## Accumulated self-heal waiting to be reported (throttled to avoid an RPC +
## scores_changed emit every frame while regenerating).
var _pending_self_heal: float = 0.0
var _regen_stat_timer: Timer
const HEAL_DELAY := 5.0
const ENEMY_ATTACKER_EXPIRY := 30.0
const REGEN_STAT_INTERVAL := 0.5

# Declared before `starting_health` on purpose: that variable's setter calls
# recompute_max_health(), so everything it reads must already be initialized.

## Active max-health multipliers, keyed by the contributing effect's id.
##
## A *registry* rather than a single value, so overlapping effects compose
## instead of overwriting: a shrink (0.25) plus an enlarge (2.0) yields 0.5,
## and removing either one leaves the other exactly as it was.  Server-side
## only — effects never run on a client (see [method apply_synced_max_health_mult]).
var _max_health_mults: Dictionary = {}

## Registry key used by [method apply_synced_max_health_mult].  Clients have no
## real per-effect registry, so the mirrored product lives under this one.
const CLIENT_MIRROR_KEY := "__synced"

## Product of [member _max_health_mults].  1.0 = unbuffed.  This is the value
## that peers mirror, rather than an absolute, because `starting_health` is
## already identical on every peer — so the two can never drift apart.
var max_health_mult: float = 1.0

## The LIVE maximum health.  DERIVED — never assign it; write
## [member starting_health] or the multiplier registry and let
## [method recompute_max_health] recompute it.
var max_health: float = 100.0

## The character's BASE max health.  Set once per life from
## `Character.health_mult` (see `Player.set_character`); nothing else should
## write it.  The live cap is [member max_health], which is this value times
## every active [member _max_health_mults] entry.
##
## The setter recomputes, so callers can write the base directly without
## remembering to refresh anything.
@export var starting_health := 100.0:
	set(value):
		starting_health = value
		recompute_max_health()

@export var health: float = 100.0:
	set(value):
		health = value
		health_changed.emit()
		if health <= 0.0:
			no_health.emit()


## Register (or replace) the multiplier contributed by [param key].  Idempotent
## for a given key, so an effect re-applied over its own id cannot double up.
func add_max_health_multiplier(key: String, mult: float) -> void:
	if key.is_empty():
		return
	_max_health_mults[key] = mult
	recompute_max_health()


## Drop the multiplier contributed by [param key].  Removing an unknown key is a
## no-op, which makes a teardown that runs twice harmless.
func remove_max_health_multiplier(key: String) -> void:
	if _max_health_mults.erase(key):
		recompute_max_health()


## Client-side mirror of the server's already-multiplied value.  Clients hold no
## registry — `StatusEffectManager.apply_effect` is server-only, so an effect's
## `_on_apply`/`_on_remove` never run on one — so this is the whole registry here.
func apply_synced_max_health_mult(mult: float) -> void:
	_max_health_mults.clear()
	if not is_equal_approx(mult, 1.0):
		_max_health_mults[CLIENT_MIRROR_KEY] = mult
	recompute_max_health()


func recompute_max_health() -> void:
	var product := 1.0
	for key in _max_health_mults:
		product *= float(_max_health_mults[key])
	max_health_mult = product

	var old_max := max_health
	max_health = starting_health * product

	# Preserve the health *ratio* across the change, so the bar never jumps:
	#   100/100 --shrink 0.5--> 50/50 --25 dmg--> 25/50 --expire--> 50/100
	# Only writes when the value actually moves, and never while the player is
	# dead — `health` is a setter that emits `no_health` on *every* assignment
	# landing at <= 0, not on a transition into death, so writing there would
	# re-enter the whole death path (known-issues #31/#32).
	if health <= 0.0:
		return
	var target := health
	if old_max > 0.0:
		target = health * (max_health / old_max)
	target = clampf(target, 0.0, max_health)
	if not is_equal_approx(target, health):
		health = target


func reset_health():
	health = max_health


func _ready() -> void:
	# Establish max_health from the base even if nothing has written
	# starting_health yet (the declaration initializer does not route through the
	# setter, so this is the one guaranteed recompute per life).
	recompute_max_health()

	_enemy_attacker_expiry = Timer.new()
	_enemy_attacker_expiry.name = "EnemyAttackerExpiryTimer"
	_enemy_attacker_expiry.wait_time = ENEMY_ATTACKER_EXPIRY
	_enemy_attacker_expiry.one_shot = true
	_enemy_attacker_expiry.timeout.connect(_on_enemy_attacker_expired)
	add_child(_enemy_attacker_expiry)

	_regen_stat_timer = Timer.new()
	_regen_stat_timer.name = "RegenStatTimer"
	_regen_stat_timer.wait_time = REGEN_STAT_INTERVAL
	_regen_stat_timer.one_shot = true
	_regen_stat_timer.timeout.connect(_flush_regen_stat)
	add_child(_regen_stat_timer)


func _on_enemy_attacker_expired() -> void:
	last_enemy_attacker = "NONE"


## Report accumulated self-heal to the leaderboard.  Called on a throttle timer
## so regenerating players don't emit an RPC + scores_changed every frame.
func _flush_regen_stat() -> void:
	if _pending_self_heal <= 0.0:
		return
	Leaderboard.request_add_self_heal(get_parent().name, _pending_self_heal)
	_pending_self_heal = 0.0


func apply_health_delta(delta: float, changer: String, changee: String, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false):

	var old_health := health
	var new_health :float = clamp(old_health + delta, 0.0, max_health)
	var applied_delta := new_health - old_health

	if is_zero_approx(applied_delta):
		return

	pass  # health change print removed



	var changer_node = GameManager.find_player(changer)
	if applied_delta < 0:
		_time_since_last_damage = 0.0

		if changee == changer:
			Leaderboard.request_add_self_damage(changer, applied_delta)
		else:
			Leaderboard.request_add_damage(changer, applied_delta)
			if not changer_node.is_bot:
				if is_headshot:
					changer_node.weapon_controller.play_crit_sound.rpc_id(changer.to_int())
				else:
					changer_node.weapon_controller.play_hit_sound.rpc_id(changer.to_int())
				changer_node.damage_number_manager._receive_damage_number.rpc_id(changer.to_int(), changee, applied_delta, is_headshot, falloff_mult, is_backshot)
		last_attacker = changer
		if changer_node != null and changer_node != get_parent():
			last_hit_direction = ((get_parent() as Node3D).global_position - changer_node.global_position).normalized()
		if _is_enemy_attacker(changer):
			last_enemy_attacker = changer
			if _enemy_attacker_expiry:
				_enemy_attacker_expiry.start()
	else:
		if changee == changer:
			Leaderboard.request_add_self_heal(changer, applied_delta)
		else:
			Leaderboard.request_add_heal_other(changer, applied_delta)
			if not changer_node.is_bot:
				changer_node.weapon_controller.play_hit_heal_sound.rpc_id(changer.to_int())
				changer_node.damage_number_manager._receive_damage_number.rpc_id(changer.to_int(), changee, applied_delta)


	if old_health > 0.0 and new_health <= 0.0:
		if changee != changer:
			# Resolve weapon info for the kill feed.
			var weapon_name: String = ""
			var killfeed_icon_path: String = ""
			if changer_node:
				var wc: WeaponController = changer_node.weapon_controller
				if wc:
					var weapons: Array[Weapon] = wc.get_weapons()
					if not weapons.is_empty():
						var idx: int = wc.current_weapon_index
						if idx >= 0 and idx < weapons.size():
							weapon_name = weapons[idx].display_name
							# Pre-rendered kill-feed icon (generated by
							# weapon/killfeed_icon_generator.gd).  Falls
							# back to text-only if no icon is assigned.
							if weapons[idx].killfeed_icon:
								killfeed_icon_path = weapons[idx].killfeed_icon.resource_path

			Leaderboard.request_add_kill(changer, changee, weapon_name, killfeed_icon_path, is_headshot, is_backshot)
			Leaderboard.request_add_death(changee)
			# Heal on kill: restore HP to the killer based on their character.
			var killer: Player = GameManager.find_player(changer)
			if killer and killer._character:
				var hok: float = killer._character.heal_on_kill
				if hok > 0.0:
					killer.change_health(hok, changer)

	if abs(applied_delta) > 0.0001:
		health = new_health


## True when [param changer] is on an opposing team (or everyone, in FFA).
func _is_enemy_attacker(changer: String) -> bool:
	if changer == get_parent().name:
		return false
	var changer_p: Player = GameManager.find_player(changer)
	var self_p: Player = get_parent() as Player
	if changer_p == null or self_p == null:
		return false
	if self_p.team == Player.Team.FFA:
		return true
	return changer_p.team != self_p.team


## Apply damage from the environment (fall, hazards, etc.).  Credits the last
## enemy who damaged this player (if not expired) for the kill.
func apply_environmental_damage(damage: float) -> void:
	if damage <= 0.0:
		return
	var changer: String = get_parent().name
	if last_enemy_attacker != "NONE" and GameManager.find_player(last_enemy_attacker) != null:
		changer = last_enemy_attacker
	apply_health_delta(-damage, changer, get_parent().name)


func reset():
	# Drop every max-health multiplier first, so `reset_health()` fills to the
	# character's real base and not a buffed/shrunk cap.  Normally
	# clear_all_effects() has already removed the contributing effects, but a
	# teardown that was ever missed must not leak into the next life.
	_max_health_mults.clear()
	recompute_max_health()
	reset_health()
	last_attacker = "NONE"
	last_hit_direction = Vector3.ZERO
	last_enemy_attacker = "NONE"
	if _enemy_attacker_expiry:
		_enemy_attacker_expiry.stop()
	_time_since_last_damage = 0.0
	_pending_self_heal = 0.0
	if _regen_stat_timer:
		_regen_stat_timer.stop()

func _process(delta: float) -> void:
	# Health is server-authoritative; clients mirror it via the
	# MultiplayerSynchronizer. Running regen on every peer duplicated the
	# find_player scan, sent an RPC every frame, and (for negative regen)
	# duplicated death/score bookkeeping.
	if not multiplayer.is_server():
		return

	# Character regen overrides base values when set (non-null character).
	var heal_rate: float = passive_heal_per_sec
	var heal_delay: float = HEAL_DELAY
	var p: Player = get_parent() as Player
	if p and p._character:
		heal_rate = p._character.regen_per_sec
		heal_delay = p._character.regen_delay

	if heal_rate < 0.0:
		# Negative regen = damage over time.  Applied directly, bypasses the
		# heal-delay gate and can kill the player (setter emits no_health).
		health = health + heal_rate * delta
		return

	_time_since_last_damage += delta
	if health <= 0.0 or health >= max_health:
		return
	if _time_since_last_damage < heal_delay:
		return

	# Apply the heal directly (no find_player / per-frame RPC) and accumulate
	# the self-heal stat, reporting it on a throttle timer instead of every frame.
	var old_health := health
	health = clamp(old_health + heal_rate * delta, 0.0, max_health)
	_pending_self_heal += health - old_health
	if _regen_stat_timer.is_stopped():
		_regen_stat_timer.start()
