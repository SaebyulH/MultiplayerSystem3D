extends Node
class_name AttributeComponent

signal health_changed
signal no_health
var last_attacker = "NONE"

var killstreak := 0

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
