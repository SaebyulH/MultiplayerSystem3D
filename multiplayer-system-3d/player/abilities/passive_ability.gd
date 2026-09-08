class_name PassiveAbility
extends Ability

## A passive, description-only ability.  It occupies a slot in the character's
## ability list and shows up in the HUD and menus like any other ability, but has
## no castable effect — the inherited activate*() hooks are intentional no-ops.
##
## Use it to document baked-in traits that the Character stats already implement
## (special movement tech, passives, etc.), e.g. low gravity or extra air jumps,
## so they read as part of the kit without adding any gameplay logic.

func _init() -> void:
	cooldown = 0.0
