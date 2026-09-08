class_name TeleportAbility
extends MovementAbility

## Instant-cast CLIENT movement ability: blink [member teleport_distance] metres
## along the camera's aim direction.  activate() only stages the direction on
## PlayerInput; Player._rollback_tick consumes it and applies a deterministic
## position jump (with tick_interpolator.teleport()) so every peer agrees.

@export var teleport_distance: float = 3.0

func activate(player: Player) -> void:
	player.player_input.queued_teleport_trigger_dir = player.camera_forward()
