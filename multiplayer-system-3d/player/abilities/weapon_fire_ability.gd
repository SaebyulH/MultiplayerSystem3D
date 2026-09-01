class_name WeaponFireAbility
extends Ability

## Instant-cast ability that fires a standalone WeaponFire resource on demand.
## This is the reusable template for any "fire a weaponfire" ability — assign a
## WeaponFire resource (weapon/weapon_fire.gd) in the .tres.

@export var weapon_fire: WeaponFire
## If true (default), the player's normal weapon fire is suppressed while this
## ability's fire is ongoing (e.g. a burst that is still firing its shots).
@export var interrupt_shooting_weapon: bool = true

func activate(player: Player) -> void:
	player.weapon_controller.fire_weapon_fire(weapon_fire, interrupt_shooting_weapon, ability_name)
