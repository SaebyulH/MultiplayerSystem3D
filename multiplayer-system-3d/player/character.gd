extends Resource
class_name Character

## A playable character within a class.  Stat multipliers are applied on top
## of the player's base values — 1.0 = no change, 2.0 = double, 0.5 = half.

@export var character_name: String = ""
@export var description: String = ""

@export var character_scene: PackedScene

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
## Multiplier on the player's gravity while airborne.  1.0 = normal gravity.
@export var gravity_scale: float = 1.0
## Minimum time (seconds) spent grounded before a jump is allowed again.
@export var min_ground_contact_time: float = 0.1

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
@export var regen_per_sec: float = 5.0      # if set, overrides base passive heal rate
@export var regen_delay: float = 5.0        # if set, overrides base heal delay (seconds)
@export var heal_on_kill: float = 0.0       # HP restored on kill
## Multiplier on all knockback received.  Defaults to 2.0 to compensate for the
## 30 Hz rollback tickrate (movement simulates half as often, so knockback
## impulses must be doubled to feel identical to 60 Hz).
@export var knockback_multiplier: float = 2.0

# --
@export_group("Sound")
@export var death_sound: AudioStream

# -- Abilities --
@export_group("Abilities")
## Abilities this character can use (max 4).  See player/abilities/ability.gd.
@export var abilities: Array[Ability] = []

## If true, this character always sees enemy health bars.
@export var passive_see_enemy_health: bool = false
