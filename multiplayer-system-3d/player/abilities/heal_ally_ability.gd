class_name HealAllyAbility
extends TargetedAbility

## Heals the locked **ally** targets for [member heal_amount] health, spread over
## [member heal_duration] seconds.
##
## Ally-only via `target_team = ALLIES`, so the crosshair targeting never locks
## onto an enemy.  In FFA there are no teammates at all, so the ability simply
## finds no valid targets and cannot be cast (and does not burn its cooldown) —
## that falls out of TargetedAbility.is_valid_target, not of a special case here.
##
## Deliberately no `blocks_actions`: the target is someone else, and freezing a
## teammate for the duration of their heal would be a griefing tool.  This is the
## one place the ally heal differs from HealAbility, whose self-channel does lock
## the caster out.

## Total health restored across the whole duration.
@export var heal_amount: float = 100.0

## Seconds the heal is spread across.
@export var heal_duration: float = 8.0

## Seconds between heal ticks.
@export var heal_tick_interval: float = 0.5


func _init() -> void:
	# This ability is ally-targeted by construction.  Set here as well as in the
	# .tres so a code-built instance cannot accidentally default to ENEMIES.
	target_team = TargetTeam.ALLIES


func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	for target in targets:
		if not is_instance_valid(target) or target.status_effect_manager == null:
			continue
		# Built per target, mirroring HealAbility: total/duration/tick are
		# per-ability values, and a Resource instance shared between targets would
		# let one target's heal rewrite another's.
		var effect := HealOverTimeEffect.new()
		effect.total_heal = heal_amount
		effect.base_duration = maxf(heal_duration, 0.0)
		effect.tick_interval = maxf(heal_tick_interval, 0.0)
		# Credited to the caster, not the target: apply_health_delta routes
		# changee != changer into Leaderboard.request_add_heal_other, which is
		# what should show up on the medic's scoreboard line.
		target.status_effect_manager.apply_effect(effect, player.name)
