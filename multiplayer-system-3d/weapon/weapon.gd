extends Resource
class_name Weapon

@export var display_name: String = "Default Weapon"
@export var damage: float = 10.0
@export var pre_shoot_delay: float = 0.0
@export var post_shoot_delay: float = 0.5
@export var mag_size: int = 6
#@export var reserve_ammo: int = 40

@export var recoil_data: RecoilData = RecoilData.new()
@export var weapon_model: PackedScene
@export var projectile_scene: PackedScene

@export var weapon_offset: Vector3 = Vector3(0.3, -0.4, -0.8)

@export_custom(PROPERTY_HINT_RANGE, "-360,360,0.1,radians") 
var weapon_rotation: Vector3 = Vector3.ZERO

@export var automatic: bool = false
