class_name SelfEffectAbility
extends Ability

## Applies a status effect to the caster.  The generic "buff yourself" ability —
## the effect lives in a .tres, so one script covers every self-applied effect
## and the ability resource is pure configuration.
##
## Server-cast (Ability.CastMode.SERVER): activate() runs on the server, which is
## what StatusEffectManager.apply_effect() requires.  The effect is then timed,
## replicated and torn down like any other status effect.
##
## Example: `player/abilities/size_change.tres` points at
## `defaults/status_effects/size_change.tres` (with `shrink.tres` as the
## shrink-direction twin).

## The effect to apply.  Duplicated per cast — see activate().
@export var effect: StatusEffect

## When false (the default) the effect keeps its own [member StatusEffect.base_duration],
## so the duration is authored once on the effect.  Set true to override it here,
## which is useful when two abilities share one effect at different lengths.
@export var override_duration: bool = false
@export var duration: float = 10.0


func activate(player: Player) -> void:
	if effect == null:
		push_warning("[SelfEffectAbility] %s has no effect assigned" % ability_name)
		return
	if player.status_effect_manager == null:
		return

	# Duplicated per cast: `effect` is a shared Resource loaded from disk, and the
	# manager keys its per-cast state off the instance (CLAUDE.md — duplicate
	# mutable per-instance state).  Without this, overriding base_duration below
	# would rewrite the .tres for every future caster.
	var inst: StatusEffect = effect.duplicate(true)
	if override_duration:
		inst.base_duration = maxf(duration, 0.0)
	player.status_effect_manager.apply_effect(inst, player.name)
