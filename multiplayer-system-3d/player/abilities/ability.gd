class_name Ability
extends Resource

## Base class for all abilities.  A concrete ability is a .tres resource whose
## script is a subclass of Ability (see heal_ability.gd, weapon_fire_ability.gd,
## shoulder_charge_ability.gd).  Each ability holds a name, description, cooldown, and a
## cast type.  The actual effect lives in the subclass's activate*() hooks, which
## run on the server; the owning client sends input via the AbilityManager.

enum CastType {
	INSTANT,  ## executes immediately when its ability key (1-4) is pressed
	EQUIP,    ## "equips" the ability; a fire button (mouse1/2/3) then casts it
}

## How the ability's effect is applied.
##   SERVER — activate*() runs on the server and its effect is replicated
##            (heals, damage, spawning, etc.).
##   CLIENT — activate*() runs on the owning client and drives the rollback
##            simulation through deterministic input (movement, teleport, etc.).
##            These effects must NOT touch rollback-simulated state via RPC.
enum CastMode {
	SERVER,
	CLIENT,
}

@export var ability_name: String = "Ability"
@export_multiline var description: String = ""
@export var cast_type: CastType = CastType.INSTANT
@export var cast_mode: CastMode = CastMode.SERVER
@export var cooldown: float = 0.1

## INSTANT cast — called the moment the ability key is pressed.
func activate(player: Player) -> void:
	pass

## EQUIP cast — one of these is called when the player presses a fire button.
## primary = mouse1, secondary = mouse2, tertiary = mouse3.
func activate_primary(player: Player) -> void:
	pass

func activate_secondary(player: Player) -> void:
	pass

func activate_tertiary(player: Player) -> void:
	pass
