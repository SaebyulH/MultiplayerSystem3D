@tool
extends Resource
class_name Weapon

## The name shown in UI and inventory systems.
@export var display_name: String = "Default Weapon"

@export_group("Universal Combat")
## If true, mag_size and reload properties are ignored.
@export var has_infinite_ammo: bool = false:
	set(value):
		has_infinite_ammo = value
		notify_property_list_changed()
		emit_changed()
## Maximum number of rounds in one magazine.
@export var mag_size: int = 6
## Current rounds remaining in the magazine.
@export var mag_current: int = 6
## If true, reloads one round at a time instead of the whole magazine at once.
@export var reload_individually: bool = false
## Time in seconds to complete a full reload (or one round if reload_individually is true).
@export var reload_time: float = 1.0
## If true, this weapon continues reloading even when not in the active slot.
@export var reload_in_background: bool = false
## If true, automatically switch to the next weapon that can shoot when this
## weapon's magazine is empty (priority: primary → secondary → melee).
@export var auto_switch_when_empty: bool = false
## Multiplier applied to the player's movement speed while this weapon is equipped.
@export var player_speed_multiplier: float = 1.0


@export_group("Switching")
## Time in seconds to pull this weapon out when it becomes the active weapon.
## The weapon cannot be used while it is being pulled out.
@export var pullout_time: float = 0.8
## Time in seconds to put this weapon away when it is deselected.  The weapon
## cannot be used while it is being put away.
@export var put_away_time: float = 0.1

func reset():
	mag_current = mag_size


@export_group("Fire")
@export var weapon_fires: Array[WeaponFire] = []

@export_group("Spread")
## Minimum spread in degrees — always applied, even on the first shot.
@export var min_spread: float = 0.0
## Extra minimum spread (degrees) applied only when firing unscoped (not ADS).
## 0.0 = no penalty.  Added on top of min_spread.
@export var unscoped_spread: float = 0.0
## Degrees of spread added per shot.
@export var spread_per_shot: float = 0.0
## Maximum accumulated spread in degrees (cone half-angle).
@export var max_spread: float = 30.0
## Degrees per second the spread decays when not firing.
@export var spread_decay: float = 20.0


@export_group("Visuals")
## The 3D model scene to spawn and attach to the weapon holder.
@export var weapon_model: PackedScene
## Positional offset of the weapon model relative to the weapon holder.
@export var weapon_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
## Rotation of the weapon model in degrees, converted to radians internally.
@export_custom(PROPERTY_HINT_RANGE, "-360,360,0.1,radians")
var weapon_rotation: Vector3 = Vector3.ZERO
## Scale of the weapon model.
@export var weapon_scale: Vector3 = Vector3(1.0, 1.0, 1.0)

@export_group("Kill Feed")
## Pre-rendered icon shown in the kill feed.  Generate with the
## weapon/killfeed_icon_generator.gd editor script (File > Run in the
## Script Editor while this project is open).
@export var killfeed_icon: Texture2D

@export_group("Sound")
# Sound played when a reload begins.
@export var reload_sound: AudioStream = load("res://assets/sounds/reload.mp3")

func _validate_property(property: Dictionary) -> void:
	# Grey out ammo/reload props when infinite ammo is on
	if property.name in ["mag_size", "mag_current", "reload_individually", "reload_time"]:
		if has_infinite_ammo:
			property.usage |= PROPERTY_USAGE_READ_ONLY
	# Auto-switch only makes sense with background reload (otherwise you
	# switch away and never get the ammo back).
	if property.name == "auto_switch_when_empty":
		if not reload_in_background:
			property.usage |= PROPERTY_USAGE_READ_ONLY
