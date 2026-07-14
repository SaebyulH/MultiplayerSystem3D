@tool
extends Resource
class_name WeaponFire
#
### The name shown in UI and inventory systems.
#@export var display_name: String = "Default Weapon"

@export_group("Universal Combat")

enum ActionType {SHOOT, ADS, SHIELD}

@export var action_type: ActionType = ActionType.SHOOT:
	set(value):
		action_type = value
		notify_property_list_changed()



## If true, the weapon fires repeatedly while the trigger is held.
@export var automatic: bool = false
## Delay in seconds before the shot is fired after pulling the trigger.
@export var pre_shoot_delay: float = 0.0
## Minimum time in seconds between shots.
@export var post_shoot_delay: float = 0.5




## Ammo consumed to shoot this type
@export var ammo_cost: int = 1

## If true, mag_size and reload properties are ignored.
#@export var has_infinite_ammo: bool = false:
	#set(value):
		#has_infinite_ammo = value
		#notify_property_list_changed()
		#emit_changed()
### Maximum number of rounds in one magazine.
#@export var mag_size: int = 6
### Current rounds remaining in the magazine.
#@export var mag_current: int = 6
### If true, reloads one round at a time instead of the whole magazine at once.
#@export var reload_individually: bool = false
### Time in seconds to complete a full reload (or one round if reload_individually is true).
#@export var reload_time: float = 1.0
### Recoil behaviour data for this weapon.
@export var recoil_data: RecoilData = RecoilData.new()


##recoil knockback, moving the player physically
@export var recoil_knockback: Vector3 = Vector3.ZERO
## Multiplier applied to the player's movement speed while this weapon is equipped.
#@export var player_speed_multiplier: float = 1.0

#func reset():
	#mag_current = mag_size




@export_group("Bullet")
enum BulletType {HITSCAN, PROJECTILE}
## Whether the weapon uses instant hitscan or a physical projectile scene.
@export var bullet_type: BulletType:
	set(value):
		bullet_type = value
		notify_property_list_changed()
		emit_changed()
## Damage dealt per hitscan hit. Only used when bullet_type is HITSCAN.
@export var hitscan_damage: float = 10.0
## Maximum range of the hitscan ray in units. Only used when bullet_type is HITSCAN.
@export var hitscan_range: float = 1000000000.0
@export var headshot_multiplier: float = 1.0

## enables damage falloff from the start to end position
@export var has_damage_falloff: bool = false:
	set(value):
		has_damage_falloff = value

		notify_property_list_changed()
		emit_changed()
		

@export var falloff_start: float = 10.0
@export var falloff_end: float = 30.0
## By default a linear falloff
@export var falloff_curve: CurveTexture = preload("res://defaults/default_damage_falloff_curve.tres")

## The projectile scene to spawn on fire. Damage is configured inside the scene. Only used when bullet_type is PROJECTILE.
@export var projectile_scene: PackedScene
## Each Vector3 defines the direction of one bullet fired per shot, enabling spread or multishot patterns.
@export var multishot_data: Array[Vector3] = [Vector3(0, 0, -1)]
enum MultishotMode {
		SHOTGUN, ## Each bullet deals the weapon's hitscan damage. 
		BURST, ## Fires a burst of bullets every time it shoots.
		SHAPE ## Only applies to hitscan! Multiple bullets over 1 do not do extra damage: Ideal for melee
	}
@export var multishot_mode: MultishotMode = MultishotMode.SHOTGUN:
	set(value):
		multishot_mode = value
		notify_property_list_changed()
@export var burst_post_shoot_delay: float = 0.05 ##Note that if this is higher than the actual shoot delay, it will act interesting, it does not add to the delay!
@export var burst_fire_has_recoil: bool = true


#@export_group("Visuals")
### The 3D model scene to spawn and attach to the weapon holder.
#@export var weapon_model: PackedScene
### Positional offset of the weapon model relative to the weapon holder.
#@export var weapon_offset: Vector3 = Vector3(0.2, -0.4, -0.55)
### Rotation of the weapon model in degrees, converted to radians internally.
#@export_custom(PROPERTY_HINT_RANGE, "-360,360,0.1,radians")
#var weapon_rotation: Vector3 = Vector3.ZERO
### Scale of the weapon model.
#@export var weapon_scale: Vector3 = Vector3(1.0, 1.0, 1.0)

@export_group("Sound")
## Sound played when the weapon fires successfully.
@export var shoot_sound: AudioStream = load("res://assets/sounds/gun_sound.mp3")
## Sound played when the trigger is pulled with an empty magazine.
@export var empty_sound: AudioStream = load("res://assets/sounds/empty_gun.mp3")
### Sound played when a reload begins.
#@export var reload_sound: AudioStream = load("res://assets/sounds/reload.mp3")

func _validate_property(property: Dictionary) -> void:
	var shoot_only_props: Array[String] = [
		"automatic", "pre_shoot_delay", "post_shoot_delay", "ammo_cost",
		"recoil_data", "recoil_knockback",
		"bullet_type", "hitscan_damage", "hitscan_range", "headshot_multiplier",
		"has_damage_falloff", "falloff_start", "falloff_end", "falloff_curve",
		"projectile_scene", "multishot_data",
		"shoot_sound", "empty_sound",
	]

	if property.name in shoot_only_props:
		if action_type != ActionType.SHOOT:
			property.usage = PROPERTY_USAGE_NO_EDITOR
			return

	if property.name in ["hitscan_damage", "hitscan_range", "has_damage_falloff", "headshot_multiplier"]:
		if bullet_type == BulletType.PROJECTILE:
			property.usage = PROPERTY_USAGE_NO_EDITOR


	if property.name in ["falloff_start", "falloff_end", "falloff_curve"]:
		if has_damage_falloff == false:
			property.usage = PROPERTY_USAGE_NO_EDITOR

	if property.name == "projectile_scene":
		if bullet_type == BulletType.HITSCAN:
			property.usage = PROPERTY_USAGE_NO_EDITOR
	
	if property.name in ["burst_post_shoot_delay", "burst_fire_has_recoil"]:
		if multishot_mode != MultishotMode.BURST:
			property.usage = PROPERTY_USAGE_NO_EDITOR
