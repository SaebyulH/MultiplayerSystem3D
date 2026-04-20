extends Node
class_name AttributeComponent

signal health_changed
signal no_health
var last_attacker = "NONE"

var killstreak := 0
@export var passive_heal_per_sec: float = 1.0
var _heal_timer: float = 0.0

@export var starting_health = 100.0

@export var health: float = 100.0:
	set(value):
		health = value
		health_changed.emit()
		if health <= 0:
			no_health.emit()

func reset_health():
	health = starting_health

func reset():
	reset_health()
	last_attacker = "NONE"

func apply_health_delta(delta: float, changer: String, changee: String):
	var temp_health = health
	temp_health += delta
	#health += delta
	print("player " + changer + " changed health of player " + changee + " health by " + str(delta))
	
	# damage
	if delta < 0:
		if changee == changer:
			Leaderboard.request_add_self_damage(changer, delta)
		else:
			Leaderboard.request_add_damage(changer, delta)	
	else:
		if changee == changer:
			Leaderboard.request_add_self_heal(changer, delta)
		else:
			Leaderboard.request_add_heal_other(changer, delta)
			
	if temp_health <= 0.0:
		Leaderboard.request_add_kill(changer)
		Leaderboard.request_add_death(changee)
	
	health = temp_health
	
func _process(delta: float) -> void:
	# don’t heal if dead or already full
	if health <= 0.0 or health >= starting_health:
		return
	
	_heal_timer += delta
	
	if _heal_timer >= 1.0:
		_heal_timer -= 1.0
		apply_health_delta(passive_heal_per_sec, get_parent().name, get_parent().name)
