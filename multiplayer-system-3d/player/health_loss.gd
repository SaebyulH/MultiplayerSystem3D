extends Label3D

@export var attribute_component: AttributeComponent

var _last_health := 0.0
var _last_change := 0.0
var _last_time := 0.0

const HIDE_TIME := 2.0


func _ready() -> void:
	if attribute_component == null:
		return

	_last_health = attribute_component.health


func _process(_delta: float) -> void:
	if attribute_component == null:
		return

	var current := attribute_component.health

	# detect change (works in multiplayer because health is replicated)
	if not is_equal_approx(current, _last_health):
		_last_change = current - _last_health
		_last_time = Time.get_ticks_msec() / 1000.0
		_last_health = current

	# hide after timeout
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_time > HIDE_TIME:
		text = ""
		return

	# display
	if _last_change < 0:
		modulate = Color(0.914, 0.0, 0.0, 1.0)
		text = "-%d" % int(abs(_last_change))
	elif _last_change > 0:
		modulate = Color(0.472, 0.914, 0.0, 1.0)
		text = "+%d" % int(_last_change)
	else:
		text = ""
