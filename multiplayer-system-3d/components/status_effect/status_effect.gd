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
@export var tick_interval: float = 0.5


# ----------------------------------------------------------- trigger condition
## Controls *when* this effect is applied, based on how the hit landed.
## Each condition is Any / Match / Negate; they combine with And or Or.
## Defaults (Any + Any + And) mean the effect always applies.

@export_group("Trigger Condition")
## Headshot requirement.  "Any" applies regardless of headshot state.
@export_enum("Any", "Headshot", "Non-Headshot") var headshot_condition: int = 0
## Backshot requirement.  "Any" applies regardless of backshot state.
@export_enum("Any", "Backshot", "Non-Backshot") var backshot_condition: int = 0
## How the two conditions combine.  "And" = both must match, "Or" = either may match.
@export_enum("And", "Or") var condition_combine: int = 0


## Whether this effect should be applied for a hit with the given properties.
func should_trigger(is_headshot: bool, is_backshot: bool) -> bool:
	var headshot_ok := _condition_matches(headshot_condition, is_headshot)
	var backshot_ok := _condition_matches(backshot_condition, is_backshot)
	if condition_combine == 0:  # And
		return headshot_ok and backshot_ok
	return headshot_ok or backshot_ok  # Or


## Resolve a single Any / Match / Negate condition against a bool value.
func _condition_matches(condition: int, value: bool) -> bool:
	match condition:
		1:  # Headshot / Backshot
			return value
		2:  # Non-Headshot / Non-Backshot
			return not value
		_:  # Any
			return true


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
