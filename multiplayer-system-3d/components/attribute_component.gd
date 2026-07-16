extends Node
class_name AttributeComponent

signal health_changed
signal no_health

var last_attacker = "NONE"
var killstreak := 0

@export var passive_heal_per_sec: float = 10.0
var _heal_timer: float = 0.0

var _time_since_last_damage: float = 0.0
const HEAL_DELAY := 5.0

@export var starting_health := 100.0

@export var health: float = 100.0:
	set(value):
		health = value
		health_changed.emit()
		if health <= 0.0:
			no_health.emit()


func reset_health():
	health = starting_health


func apply_health_delta(delta: float, changer: String, changee: String):

	var old_health := health
	var new_health :float = clamp(old_health + delta, 0.0, starting_health)
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
				changer_node.weapon_controller.play_hit_sound.rpc_id(changer.to_int())
		last_attacker = changer
	else:
		if changee == changer:
			Leaderboard.request_add_self_heal(changer, applied_delta)
		else:
			Leaderboard.request_add_heal_other(changer, applied_delta)
			if not changer_node.is_bot:
				changer_node.weapon_controller.play_hit_heal_sound.rpc_id(changer.to_int())
			

	if old_health > 0.0 and new_health <= 0.0:
		if changee != changer:
			Leaderboard.request_add_kill(changer)
			Leaderboard.request_add_death(changee)
			# Heal on kill: restore HP to the killer based on their character.
			var killer: Player = GameManager.find_player(changer)
			if killer and killer._character:
				var hok: float = killer._character.heal_on_kill
				if hok > 0.0:
					killer.change_health(hok, changer)
	
	if abs(applied_delta) > 0.0001:
		health = new_health


func reset():
	reset_health()
	last_attacker = "NONE"
	_time_since_last_damage = 0.0
	_heal_timer = 0.0  # ← add this

func _process(delta: float) -> void:
	# Read character-specific regen values.
	var char_reg: float = 0.0
	var char_delay: float = 0.0
	var p: Player = get_parent() as Player
	if p and p._character:
		char_reg = p._character.regen_per_sec
		char_delay = p._character.regen_delay
	var heal_rate: float = passive_heal_per_sec + char_reg
	var heal_delay: float = max(HEAL_DELAY + char_delay, 0.0)

	_time_since_last_damage += delta
	if health <= 0.0 or health >= starting_health:
		_heal_timer = 0.0
		return
	if _time_since_last_damage < heal_delay:
		return
	apply_health_delta(heal_rate * delta, get_parent().name, get_parent().name)
