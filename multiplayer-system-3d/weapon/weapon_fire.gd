@tool
extends Resource
class_name WeaponFire

## ---------------------------------------------------------------------------
## WeaponFire — a single fire-mode slot on a Weapon resource.
##
## Action types
##   SHOOT  – hitscan or projectile weapon
##   ADS    – aim-down-sights (no bullet; hides bullet props in the inspector)
##   SHIELD – deployable barrier that absorbs damage (see "Shield" group)
## ---------------------------------------------------------------------------

@export_group("Universal Combat")

enum ActionType {SHOOT, ADS, SHIELD, SIGNAL}

@export var action_type: ActionType = ActionType.SHOOT:
	set(value):
		action_type = value
		notify_property_list_changed()

## If true, the weapon fires repeatedly while the trigger is held.  (SHOOT only.)
@export var automatic: bool = false
## Delay in seconds before the shot is fired after pulling the trigger.  (SHOOT only.)
@export var pre_shoot_delay: float = 0.0
## Minimum time in seconds between shots.  (SHOOT only.)
@export var post_shoot_delay: float = 0.5

## Ammo consumed per shot.  (SHOOT only.)
@export var ammo_cost: int = 1

## Recoil behaviour data.  (SHOOT only.)
@export var recoil_data: RecoilData = RecoilData.new()
## Knockback impulse applied to the shooter.  (SHOOT only.)
@export var recoil_knockback: Vector3 = Vector3.ZERO


# ------------------------------------------------------------------------ Bullet
@export_group("Bullet")

enum BulletType {HITSCAN, PROJECTILE}
@export var bullet_type: BulletType:
	set(value):
		bullet_type = value
		notify_property_list_changed()
		emit_changed()

@export var hitscan_damage: float = 10.0          ## (HITSCAN, non-PROJECTILE)
@export var hitscan_range: float = 1_000_000_000.0## (HITSCAN, non-PROJECTILE)
@export var headshot_multiplier: float = 1.0       ## (HITSCAN, non-PROJECTILE)

@export var has_damage_falloff: bool = false:
	set(value):
		has_damage_falloff = value
		notify_property_list_changed()
		emit_changed()

@export var falloff_start: float = 10.0            ## (HITSCAN, has_falloff)
@export var falloff_end: float = 30.0              ## (HITSCAN, has_falloff)
@export var falloff_curve: CurveTexture = preload("res://defaults/default_damage_falloff_curve.tres")

@export var projectile_scene: PackedScene          ## (PROJECTILE only)

## Each Vector3 is one bullet's direction relative to the muzzle.
## (SHOOT only, SHOTGUN / BURST / SHAPE modes.)
@export var multishot_data: Array[Vector3] = [Vector3(0, 0, -1)]

enum MultishotMode {
	SHOTGUN,  ## every bullet deals full hitscan_damage
	BURST,    ## fires a burst with a short inter-bullet delay
	SHAPE,    ## hitscan-only; multiple rays, no extra damage (e.g. melee)
}
@export var multishot_mode: MultishotMode = MultishotMode.SHOTGUN:
	set(value):
		multishot_mode = value
		notify_property_list_changed()

@export var burst_post_shoot_delay: float = 0.05   ## (BURST only)
@export var burst_fire_has_recoil: bool = true     ## (BURST only)


# ----------------------------------------------------------------------- Shield
@export_group("Shield")

## 3D scene instantiated as the shield visual + collision volume.
## Must contain at least a MeshInstance3D (visual) and an Area3D named
## "ShieldArea" with a CollisionShape3D child.
@export var shield_scene: PackedScene

## Maximum hit-points of the shield.
@export var shield_hp: float = 100.0
## Current shield HP — persists per WeaponFire so switching weapons and
## coming back remembers the shield's remaining strength.
@export var shield_current_hp: float = 100.0

## Seconds after the last hit before regeneration begins.
@export var shield_regen_delay: float = 2.0

## HP restored per second while regenerating.
@export var shield_regen_per_sec: float = 30.0

## Extra seconds to wait after the shield breaks before regen can begin.
@export var shield_break_regen_delay: float = 3.0

## If false (default), shooting is blocked while the shield is deployed.
@export var can_shoot_while_shielded: bool = false


# ------------------------------------------------------------------------ Sound
@export_group("Sound")

@export var shoot_sound: AudioStream = load("res://assets/sounds/gun_sound.mp3")
@export var empty_sound: AudioStream = load("res://assets/sounds/empty_gun.mp3")


# ------------------------------------------------------------ property hiding
func _validate_property(property: Dictionary) -> void:
	# ---- everything that only makes sense for SHOOT ----
	const SHOOT_ONLY: Array[String] = [
		"automatic", "pre_shoot_delay", "post_shoot_delay", "ammo_cost",
		"recoil_data", "recoil_knockback",
		"bullet_type", "hitscan_damage", "hitscan_range", "headshot_multiplier",
		"has_damage_falloff", "falloff_start", "falloff_end", "falloff_curve",
		"projectile_scene", "multishot_data", "multishot_mode",
		"burst_post_shoot_delay", "burst_fire_has_recoil",
		"shoot_sound", "empty_sound",
	]
	if property.name in SHOOT_ONLY and action_type != ActionType.SHOOT:
		property.usage = PROPERTY_USAGE_NO_EDITOR
		return

	# ---- bullet sub-visibility based on bullet_type ----
	if property.name in ["hitscan_damage", "hitscan_range", "has_damage_falloff",
			"headshot_multiplier"]:
		if bullet_type == BulletType.PROJECTILE:
			property.usage = PROPERTY_USAGE_NO_EDITOR

	if property.name in ["falloff_start", "falloff_end", "falloff_curve"]:
		if not has_damage_falloff:
			property.usage = PROPERTY_USAGE_NO_EDITOR

	if property.name == "projectile_scene":
		if bullet_type == BulletType.HITSCAN:
			property.usage = PROPERTY_USAGE_NO_EDITOR

	if property.name in ["burst_post_shoot_delay", "burst_fire_has_recoil"]:
		if multishot_mode != MultishotMode.BURST:
			property.usage = PROPERTY_USAGE_NO_EDITOR

	# ---- shield properties hidden unless action_type == SHIELD ----
	const SHIELD_ONLY: Array[String] = [
		"shield_scene", "shield_hp", "shield_current_hp",
		"shield_regen_delay", "shield_regen_per_sec", "shield_break_regen_delay",
		"can_shoot_while_shielded",
	]
	if property.name in SHIELD_ONLY and action_type != ActionType.SHIELD:
		property.usage = PROPERTY_USAGE_NO_EDITOR
