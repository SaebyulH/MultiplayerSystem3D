class_name WeaponFireAbility
extends Ability

## Instant-cast ability that fires a standalone WeaponFire resource on demand.
## This is the reusable template for any "fire a weaponfire" ability — assign a
## WeaponFire resource (weapon/weapon_fire.gd) in the .tres.

@export var weapon_fire: WeaponFire
## If true (default), the player's normal weapon fire is suppressed while this
## ability's fire is ongoing (e.g. a burst that is still firing its shots).
@export var interrupt_shooting_weapon: bool = true
## Scales the fired shot's damage on top of the character's own damage amp.
## Applies **only** to this ability's shot — the normal weapon pipeline reads its
## own values, so a nerfed ability never changes the weapon it borrows art from.
## Carpet Bomb authors 0.1 (ten percent) this way.
@export var damage_multiplier: float = 1.0

func activate(player: Player) -> void:
	player.weapon_controller.fire_weapon_fire(
		weapon_fire, interrupt_shooting_weapon, ability_name, damage_multiplier)


## Visible duration of this ability's burst/volley in seconds, or 0 for a
## single-shot ability.  The server's WeaponController uses the same formula;
## the owning client uses it to start the HUD window optimistically, because
## CAST_MODE.SERVER abilities do not run activate() on the client.
func burst_duration() -> float:
	if weapon_fire == null \
			or weapon_fire.multishot_mode != WeaponFire.MultishotMode.BURST:
		return 0.0
	var shots := weapon_fire.multishot_data.size()
	if shots <= 1:
		return 0.0
	return maxf(float(shots - 1) * weapon_fire.burst_post_shoot_delay, 0.05)
