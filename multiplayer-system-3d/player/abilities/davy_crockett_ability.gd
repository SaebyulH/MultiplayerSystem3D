class_name DavyCrockettAbility
extends WeaponFireAbility

## FlyGirl's equipped nuke.  The ability key arms the bomb; a global siren plays
## for [member arming_time]; once the charge finishes, mouse1 drops the nuke.
## Pressing the ability key again before the drop cancels it and stops the siren.
##
## The arming clock, the server-side validation and the siren are owned by
## AbilityManager.  This resource carries only authored data: an Ability is
## shared by every player holding it, so it must never hold per-player state.

## Seconds between arming and the drop becoming available.
@export var arming_time: float = 5.0
## Looping stream played to every peer for the whole arming window.
@export var siren: AudioStream
@export_range(-40.0, 12.0, 0.5) var siren_volume_db: float = -6.0


## EQUIP abilities cast through activate_primary(); the inherited
## WeaponFireAbility.activate() is the actual shot.
func activate_primary(player: Player) -> void:
	activate(player)


func equip_charge_duration() -> float:
	return maxf(arming_time, 0.0)


func equip_charge_siren() -> AudioStream:
	return siren


func equip_charge_siren_volume_db() -> float:
	return siren_volume_db
