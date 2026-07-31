@tool
extends Resource
class_name WeaponFire

## ---------------------------------------------------------------------------
## WeaponFire â€” a single fire-mode slot on a Weapon resource.
##
## Action types
##   SHOOT  â€“ hitscan or projectile weapon
##   ADS    â€“ aim-down-sights (no bullet; hides bullet props in the inspector)
##   SHIELD â€“ deployable barrier that absorbs damage (see "Shield" group)
## ---------------------------------------------------------------------------

@export_group("Universal Combat")

enum ActionType {SHOOT, ADS, SHIELD, SIGNAL}

@export var action_type: ActionType = ActionType.SHOOT:
	set(value):
		action_type = value
		notify_property_list_changed()

## FOV to use when aiming down sights.  (ADS only.)
@export var zoom_fov: float = 20.0

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
## Health delta applied to the shooter once per trigger-pull (negative = self-damage).
## For per-bullet healing in burst mode, see self_health_delta_per_burst_bullet.  (SHOOT only.)
@export var self_health_delta_on_shoot: float = 0.0
## Movement-speed multiplier applied while this fire mode is active (shooting).
## 1.0 = normal speed, 0.5 = half speed.  Lasts for the full firing cycle incl. burst.  (SHOOT only.)
@export var move_speed_mult_while_shooting: float = 1.0


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
## Health delta applied to the shooter per unique enemy hit (shotguns/shape once per opponent).
## Negative = self-damage on hit.  (SHOOT only.)
@export var self_health_delta_on_hit: float = 0.0
## Extra spread from player movement (Counter-Strike style).  0 = none.  (SHOOT only.)
@export var movement_spread: float = 0.0

@export var has_damage_falloff: bool = true:
	set(value):
		has_damage_falloff = value
		notify_property_list_changed()
		emit_changed()

@export var falloff_start: float = 5.0            ## (HITSCAN, has_falloff)
@export var falloff_end: float = 15.0          ## (HITSCAN, has_falloff)
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
## Ammo consumed per bullet in a burst.  0 = use global ammo_cost once per burst.  (BURST only)
@export var burst_ammo_per_shot: int = 0
## Health delta applied per bullet during burst fire (negative = self-damage).
## Separate from self_health_delta_on_shoot — that fires once per trigger, this fires per bullet.  (BURST only)
@export var self_health_delta_per_burst_bullet: float = 0.0


# ----------------------------------------------------------------------- Shield
@export_group("Shield")

## 3D scene instantiated as the shield visual + collision volume.
## Must contain at least a MeshInstance3D (visual) and an Area3D named
## "ShieldArea" with a CollisionShape3D child.
@export var shield_scene: PackedScene

## Maximum hit-points of the shield.
@export var shield_hp: float = 100.0
## Current shield HP â€” persists per WeaponFire so switching weapons and
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


# --------------------------------------------------------------- Status Effects
@export_group("Status Effects")

## Status effects applied to the target on a successful hitscan hit.
@export var status_effects: Array[StatusEffect] = []


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
		"self_health_delta_on_shoot", "self_health_delta_per_burst_bullet", "move_speed_mult_while_shooting",
		"bullet_type", "hitscan_damage", "hitscan_range", "has_damage_falloff", "headshot_multiplier",
		"self_health_delta_on_hit", "movement_spread",
		"has_damage_falloff", "falloff_start", "falloff_end", "falloff_curve",
		"projectile_scene", "multishot_data", "multishot_mode",
		"burst_post_shoot_delay", "burst_fire_has_recoil",
		"status_effects",
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

	if property.name in ["burst_post_shoot_delay", "burst_fire_has_recoil", "burst_ammo_per_shot", "self_health_delta_per_burst_bullet"]:
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

	# ---- ADS properties hidden unless action_type == ADS ----
	const ADS_ONLY: Array[String] = ["zoom_fov"]
	if property.name in ADS_ONLY and action_type != ActionType.ADS:
		property.usage = PROPERTY_USAGE_NO_EDITOR
