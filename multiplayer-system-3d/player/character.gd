extends Resource
class_name Character

## A playable character within a class.  Stat multipliers are applied on top
## of the player's base values — 1.0 = no change, 2.0 = double, 0.5 = half.

@export var character_name: String = ""
@export var description: String = ""

# -- Ground Movement --
@export_group("Movement")
@export var speed_mult: float = 1.0
@export var acceleration_mult: float = 1.0
@export var friction_mult: float = 1.0
@export var crouch_speed_mult: float = 1.0

# -- Air --
@export_group("Air")
@export var air_accel_mult: float = 1.0
@export var air_speed_cap_mult: float = 1.0
@export var jump_mult: float = 1.0

# -- Slide --
@export_group("Slide")
@export var slide_friction_mult: float = 1.0
@export var slide_entry_boost_mult: float = 1.0
@export var slope_gravity_mult: float = 1.0

# -- Combat --
@export_group("Combat")
@export var damage_amp_mult: float = 1.0
@export var reload_speed_mult: float = 1.0
@export var shoot_delay_mult: float = 1.0

# -- Defense --
@export_group("Defense")
@export var health_mult: float = 1.0
@export var lifesteal_percent: float = 0.0
@export var regen_per_sec: float = 0.0      # additive, added to base passive heal
@export var regen_delay: float = 0.0        # additive, negative = faster regen start
@export var heal_on_kill: float = 0.0       # additive, HP restored on kill
