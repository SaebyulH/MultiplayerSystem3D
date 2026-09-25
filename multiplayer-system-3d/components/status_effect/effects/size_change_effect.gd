extends StatusEffect
class_name SizeChangeEffect

## Scales the player (the whole root node — model, collider, hurtboxes and weapon)
## and their max health by [member size_mult] / [member health_mult] for the
## effect's duration.  On expiry both revert.
##
## Enlarging and shrinking are the same path — [member size_mult] above 1.0 grows,
## below 1.0 shrinks.  See `defaults/status_effects/size_change.tres` (2.0, the
## old Rampage) and `shrink.tres` (0.5, the debuff) for the two authored ends.
##
## **This effect never touches health.**  It registers two multipliers —
## `Player.add_size_multiplier()` and
## `AttributeComponent.add_max_health_multiplier()` — and those systems derive
## the scale and the max health from them.  That is deliberate and load-bearing:
## the previous version captured `attribute_component.starting_health` as a
## "base" and wrote the scaled value back into it, which corrupted max health
## *permanently* whenever a second size effect replaced the first without the
## first's teardown running (known-issues #36).  With no captured state there is
## nothing to lose, so that class of bug is impossible rather than unlikely.
##
## Multipliers compose: shrunk to 0.25 and then grown by 2.0 leaves the player at
## 0.5 scale and 0.5x max health.  Which requires [member StatusEffect.effect_id]
## to differ between the enlarge and shrink variants — `StatusEffectManager` keeps
## at most one instance per id, so two effects sharing an id would replace each
## other instead of stacking.
##
## [member StatusEffect.is_negative] is authored per-.tres rather than fixed here,
## for the same bidirectionality reason: `size_change.tres` is a buff and
## `shrink.tres` is a debuff (cleansable, and refreshes on re-cast).

## Multiplier applied to the player's scale.  < 1.0 shrinks, > 1.0 grows.
@export_range(0.05, 10.0) var size_mult: float = 2.0

## Multiplier applied to max health.  Exactly 1.0 leaves health alone entirely.
@export_range(0.05, 10.0) var health_mult: float = 2.0


func _init() -> void:
	effect_id = "enlarge"
	display_name = "Enlarged"
	base_duration = 10.0
	tick_interval = 0.0
	is_negative = false
	# Every application is its own instance, so two shrinks compound (0.25 x
	# 0.25) rather than one merely lasting longer — the multipliers registered
	# here are keyed by the (per-application) effect_id.  A .tres can still opt
	# out by setting `stacks = false`.
	stacks = true


func _on_apply(player: Player, _applier: String, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	player.add_size_multiplier(effect_id, size_mult)
	if player.attribute_component:
		player.attribute_component.add_max_health_multiplier(effect_id, health_mult)
	_broadcast(player)


func _on_remove(player: Player, _state: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	# Idempotent by construction: both removals are keyed, so a teardown that
	# runs twice — or runs for an effect that was never applied — is harmless.
	player.remove_size_multiplier(effect_id)
	if player.attribute_component:
		player.attribute_component.remove_max_health_multiplier(effect_id)
	_broadcast(player)


## Push the re-derived products to every peer.  The effect runs server-side only,
## and neither the scale nor the max health is replicated by a synchronizer, so
## this one-shot RPC is what keeps clients in step.  Late joiners get the same
## two values through `Player.rpc_sync_full_state` instead.
func _broadcast(player: Player) -> void:
	var health_mult_actual := 1.0
	if player.attribute_component:
		health_mult_actual = player.attribute_component.max_health_mult
	player._rpc_size_change.rpc(player._size_scale, health_mult_actual)
