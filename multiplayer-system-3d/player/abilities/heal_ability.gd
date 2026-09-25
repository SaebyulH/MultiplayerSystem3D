class_name HealAbility
extends Ability

## Heals the caster for [member heal_amount] health — either in one instant, or
## spread across [member heal_duration] seconds.
##
## The over-time mode is a per-cast [HealOverTimeEffect] on the player's
## server-authoritative StatusEffectManager, not a local timer: the channel then
## replicates to clients (HUD countdown included), is torn down automatically on
## death/respawn, and can lock the caster's input out via [member blocks_actions].
##
## activate() runs on the server only (Ability.CastMode.SERVER), which is what
## the effect manager requires.

@export var heal_amount: float = 40.0

@export_group("Heal Over Time")
## When false, [member heal_amount] is applied in a single instant and the
## options below are ignored.
@export var heal_over_time: bool = false
## Seconds the heal is spread across.
@export var heal_duration: float = 5.0
## Seconds between heal ticks.  Smaller is smoother but costs one
## apply_health_delta + leaderboard credit per tick.
@export var heal_tick_interval: float = 0.5
## When true, the caster cannot move, jump, crouch, dash, fire, or cast
## abilities until the heal finishes.  Only meaningful with
## [member heal_over_time].
@export var block_actions_during_heal: bool = false


func activate(player: Player) -> void:
	if not heal_over_time or player.status_effect_manager == null:
		# No manager means no effect would ever tick — pay out instantly rather
		# than silently healing nothing.
		player.change_health(heal_amount, player.name)
		return

	# Built per cast rather than authored as a .tres: duration, tick rate, and
	# the input lock are per-ability values, and a Resource instance is shared by
	# every player of the class (see CLAUDE.md — duplicate mutable per-instance
	# state).
	var effect := HealOverTimeEffect.new()
	effect.total_heal = heal_amount
	effect.base_duration = maxf(heal_duration, 0.0)
	effect.tick_interval = maxf(heal_tick_interval, 0.0)
	effect.blocks_actions = block_actions_during_heal
	player.status_effect_manager.apply_effect(effect, player.name)
