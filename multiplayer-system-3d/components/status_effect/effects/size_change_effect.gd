extends StatusEffect
class_name SizeChangeEffect

## Scales the player (the whole root node — model, collider, hurtboxes and weapon)
## and their max health by [member size_mult] / [member health_mult] for the
## effect's duration.  On expiry both revert.
##
## Enlarging and shrinking are the same path — [member size_mult] above 1.0 grows,
## below 1.0 shrinks.  There is no separate "shrink" effect; see
## `defaults/status_effects/size_change.tres` (2.0, the old Rampage) and
## `shrink.tres` (0.5) for the two authored ends of it.
##
## [member StatusEffect.is_negative] is authored per-.tres rather than fixed here,
## because this effect is bidirectional: `size_change.tres` is a buff and
## `shrink.tres` is a debuff (cleansable, and refreshes on re-cast).  Applied to
## enemies by ShrinkEnemyAbility.
##
## Set [member health_mult] to 1.0 for a pure size change: the health branch is
## then skipped entirely, which matters because the pre-generalization version
## ended in reset_health() — that would have made a size-only buff a free full heal.

## Multiplier applied to the player's scale.  < 1.0 shrinks, > 1.0 grows.
@export_range(0.05, 10.0) var size_mult: float = 2.0

## Multiplier applied to max health.  Exactly 1.0 leaves health alone entirely.
@export_range(0.05, 10.0) var health_mult: float = 2.0


func _init() -> void:
	effect_id = "size_change"
	display_name = "Size Change"
	base_duration = 10.0
	tick_interval = 0.0
	is_negative = false


func _on_apply(player: Player, _applier: String, state: Dictionary) -> void:
	if not is_instance_valid(player):
		return

	var ac: AttributeComponent = player.attribute_component
	# Captured so _on_remove can restore it.  `reset_health()` respawns to
	# `starting_health`, so leaving the scaled value behind would hand the next
	# life scaled HP.
	var base_max: float = ac.starting_health if ac else 100.0
	state["base_max_health"] = base_max
	var new_max: float = base_max * health_mult

	if ac and not is_equal_approx(health_mult, 1.0):
		ac.starting_health = new_max
		# Scaled **proportionally**, so the HP bar keeps its ratio across the
		# transition (enlarge 20/100 -> 40/200, shrink 100/100 -> 50/50).
		#
		# Never written while the player is dead: `AttributeComponent.health` is a
		# setter that emits `no_health` on *every* assignment landing at <= 0, not
		# on a transition into death, and that re-enters the whole death path
		# (Player.no_health -> clear_all_effects -> back here).  See known-issues
		# #31 for the stack overflow this shape of bug caused, and #32 for why the
		# guard is on the *value* rather than on a death flag.
		if ac.health > 0.0:
			ac.health = clampf(ac.health * health_mult, 0.0, new_max)

	player.set_size_scale(size_mult)
	player._rpc_size_change.rpc(size_mult, new_max)


func _on_remove(player: Player, state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	var base_max: float = state.get("base_max_health", 100.0)
	player.set_size_scale(1.0)
	var ac: AttributeComponent = player.attribute_component
	if ac:
		# Always restore the max, even for a dead player — see the note in
		# _on_apply.  Skipping it would leave the next life at scaled HP.
		ac.starting_health = base_max
		# Undo the proportional scaling, so a shrink that expires does not leave the
		# player permanently low.  This is what makes the round trip exact: shrink
		# 100/100 -> 50/50 restores to 100/100, and a player damaged *during* the
		# effect keeps the same HP ratio either side of it.
		#
		# `is_equal_approx` keeps the pure size-change case (health_mult 1.0) out of
		# here, and the `> 0.0` guard covers the common case of dying mid-effect,
		# where health is already 0 and any write would re-enter the death path.
		if ac.health > 0.0 and health_mult > 0.0 and not is_equal_approx(health_mult, 1.0):
			# Clamped to the restored cap, so this can only ever move health *down*
			# to the real max, never above it.
			ac.health = clampf(ac.health / health_mult, 0.0, base_max)
	player._rpc_size_change.rpc(1.0, base_max)
