extends SimpleProjectile

var _initial_speed: float = 0.0


func _ready() -> void:
	super()
	_initial_speed = linear_velocity.length()


func _on_weapon_signal(target: Vector3, player_transform: Vector3) -> void:
	if not is_multiplayer_authority():
		return

	# Unstick if embedded in a surface so the arrow can fly again.
	if _stuck_to != null:
		_stuck_to = null
		freeze = false
		sleeping = false

	# Redirect the arrow toward the target position using the original speed.
	var dir := (target - global_position).normalized()
	if dir.length_squared() > 0.01:
		linear_velocity = dir * _initial_speed
		sleeping = false
