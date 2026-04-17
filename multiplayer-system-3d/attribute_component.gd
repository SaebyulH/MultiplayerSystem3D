extends Node
class_name AttributeComponent

signal health_changed
signal no_health
var last_attacker = "NONE"

@export var starting_health = 100

@export var health: int = 100:
	set(value):
		health = value
		health_changed.emit()
		if health <= 0:
			no_health.emit()

func reset_health():
	health = starting_health
