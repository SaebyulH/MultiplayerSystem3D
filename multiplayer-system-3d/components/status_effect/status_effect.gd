@tool
extends Resource
class_name StatusEffect

## ---------------------------------------------------------------------------
## StatusEffect — base resource for defining a status effect template.
##
## Subclass this and override _on_apply / _on_tick / _on_remove to create
## custom effects.  Create a .tres file with the subclass script assigned,
## then add it to any WeaponFire's status_effects array.
##
## Negative effects stack by extending duration — not by creating multiple
## instances of the same effect_id.
## ---------------------------------------------------------------------------

## Unique identifier used for stacking and lookup (e.g. "bleed", "burn").
@export var effect_id: String = ""

## Human-readable name shown in UI.
@export var display_name: String = ""

## If true, this effect is cleared by invincibility and stacks by duration.
@export var is_negative: bool = true

## Base duration in seconds applied when the effect is first added.
## Stacking extends the remaining time by this amount.
@export var base_duration: float = 4.0

## Interval in seconds between _on_tick calls.  0 = no automatic ticking.
@export var tick_interval: float = 0.0


# ------------------------------------------------------------------ virtuals
# Each receives the player, the name of whoever applied the effect, and a
# mutable Dictionary (state) that the manager persists per-instance so
# effects can store timing / phase data without polluting the resource.


## Called once when the effect is first applied (not on duration extension).
func _on_apply(_player: Player, _applier: String, _state: Dictionary) -> void:
	pass


## Called at tick_interval intervals while the effect is active.
## [param delta] is the actual time since the last tick (may differ slightly
## from tick_interval due to frame pacing).
func _on_tick(_player: Player, _applier: String, _state: Dictionary) -> void:
	pass


## Called when the effect expires naturally or is forcibly removed.
func _on_remove(_player: Player, _state: Dictionary) -> void:
	pass
