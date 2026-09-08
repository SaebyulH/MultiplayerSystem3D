class_name BashDownAbility
extends MovementAbility

## Instant-cast movement ability: a one-shot lunge in the look direction.  Hitting an
## enemy mid-air stops your momentum, pins them to you, and slams both to the ground.
## Missing just falls normally.

@export var lunge_speed: float = 20.0      # impulse magnitude along the look direction
@export var launch_up_speed: float = 6.0   # upward bias so a ground cast goes airborne
@export var lunge_duration: float = 0.5    # bump-detection window (seconds)
@export var slam_speed: float = 30.0       # downward speed while slamming
@export var grab_radius: float = 1.5       # enemy grab radius
@export var bump_damage: float = 20.0      # damage on the grab
@export var slam_damage: float = 30.0      # damage when the slam reaches the ground

func activate(player: Player) -> void:
	player.player_input.queued_bashdown_trigger_dir = player.camera_forward()
