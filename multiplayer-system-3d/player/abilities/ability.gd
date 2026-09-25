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
## Seconds to regenerate ONE charge (see [member max_charges]).  With the default
## single charge this is simply the ability's cooldown, exactly as it always was.
@export var cooldown: float = 0.1
## If true, this ability can be cast while the player is dead (despawned, under
## the respawn timer).  Most abilities leave this false and are blocked by the
## AbilityManager while the player is dead.
@export var can_be_used_while_dead: bool = false

@export_group("Charges")
## How many charges (HUD bars) this ability can hold.  **1 — the default — is
## today's behaviour**: a single charge that regenerates over [member cooldown],
## which is what every existing ability does.  Set it above 1 to make the ability
## *charged*: it banks that many casts, each regenerating over [member cooldown],
## and the HUD draws one bar per charge above the ability circle.
##
## The whole charge model — including [member charge_interval] — is only engaged
## when this is greater than 1, so an ability that leaves it alone is unaffected.
@export var max_charges: int = 1:
	set(value):
		max_charges = value
		# charge_interval is hidden while this is <= 1, so the inspector has to be
		# told to re-run _validate_property (same reason as Weapon.charged).
		notify_property_list_changed()
## Minimum seconds between casts, even with charges in hand.  This is a second
## gate on top of the charge pool: with three charges in hand you still cannot
## fire three casts in the same instant.
##
## **Only consulted when [member max_charges] > 1.**  A single-charge ability's
## 1 charge is itself the gate, and [member cooldown] serves that role — which is
## why this is ignored there rather than defaulting into every ability in the game.
@export var charge_interval: float = 1.0


func _validate_property(property: Dictionary) -> void:
	# charge_interval does nothing without a multi-charge pool (see the exports
	# above), so hide it rather than leave a knob that silently does nothing.
	if property.name == "charge_interval" and not is_charged():
		property.usage = PROPERTY_USAGE_NO_EDITOR


## True when this ability runs on the charge pool rather than a plain cooldown.
func is_charged() -> bool:
	return max_charges > 1

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
