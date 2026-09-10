extends Node
class_name MainMenuMode

## Inert lobby mode for the 3D main-menu world.
##
## The lobby is a "map" that players can move/shoot/select characters in, but
## there is no objective, no round timer, and no win condition.  This node
## exists only so GameModeComponent has a mode object to dispatch to; it holds
## no state and syncs nothing (EscortMode-shaped).

func tick(_delta: float) -> void:
	pass

func reset() -> void:
	pass
