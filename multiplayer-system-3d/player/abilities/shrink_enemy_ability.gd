class_name ShrinkEnemyAbility
extends TargetedAbility

## Shrinks the locked enemy targets to half size and half max health for
## [member shrink_duration] seconds.
##
## Targeted like BurnAbility: candidates are the visible enemies nearest the
## crosshair, auto-selected on the casting peer and re-validated server-side
## (enemy, spawned, in range, line of sight) before anything is applied.
##
## The effect is a SizeChangeEffect, so the target's health scales
## **proportionally** and reverts on expiry — the damage they take while shrunk
## is kept, in proportion:
##
##   100/100 --cast--> 50/50 --25 dmg--> 25/50 --expires--> 50/100
##
## i.e. a temporary nerf / burst window, not a permanent HP cut. Because it is a
## negative effect it is also stripped by a cleanse (InvincibleEffect) and a
## re-cast on the same target extends the duration rather than replacing it.

## The shrink to apply.  Defaults to `defaults/status_effects/shrink.tres`
## (size_mult 0.5 / health_mult 0.5).  Duplicated per target — see below.
@export var shrink_effect: SizeChangeEffect

## Seconds the shrink lasts.  Stamped onto the effect, so this is the single
## place to tune the duration for this ability.
@export var shrink_duration: float = 5.0


func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	for target in targets:
		if not is_instance_valid(target) or target.status_effect_manager == null:
			continue
		# Duplicated per target, and per cast: the .tres is a shared resource
		# (CLAUDE.md), so stamping a duration onto it directly would rewrite it
		# for every future caster and for any other target already shrunk.
		var effect: SizeChangeEffect = shrink_effect.duplicate(true) if shrink_effect else SizeChangeEffect.new()
		effect.base_duration = maxf(shrink_duration, 0.0)
		# Credited to the caster, matching BurnAbility.
		target.status_effect_manager.apply_effect(effect, player.name)
