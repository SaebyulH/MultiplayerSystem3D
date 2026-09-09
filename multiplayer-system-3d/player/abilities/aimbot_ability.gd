class_name AimbotAbility
extends Ability

## Grants the "aimbot" status effect for [member duration] seconds.  While active,
## the caster's head continuously rotates toward the nearest enemy head within
## [member max_angle_deg] of the crosshair (see Player._update_aimbot).  The effect
## is purely client-side aim assistance; the head rotation is replicated to the
## server so authoritative shots follow the tracked aim.

@export var duration: float = 8.0
@export var max_angle_deg: float = 8.0

func activate(player: Player) -> void:
	if not player.status_effect_manager:
		return
	var effect := AimbotEffect.new()
	effect.base_duration = duration
	player.status_effect_manager.apply_effect(effect, player.name)
