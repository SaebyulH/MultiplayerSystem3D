extends Resource
class_name Weapon

@export var display_name: String = "Default Weapon"

@export_group("Combat")
@export var automatic: bool = false
@export var damage: float = 10.0
@export var pre_shoot_delay: float = 0.0
@export var post_shoot_delay: float = 0.5
@export var mag_size: int = 6
@export var mag_current: int = 6
@export var reload_time: float = 1.0

@export_group("Bullet")
@export var recoil_data: RecoilData = RecoilData.new()
@export var projectile_scene: PackedScene

@export_group("Visuals")
@export var weapon_model: PackedScene
@export var weapon_offset: Vector3 = Vector3(0.3, -0.4, -0.8)
@export_custom(PROPERTY_HINT_RANGE, "-360,360,0.1,radians") 
var weapon_rotation: Vector3 = Vector3.ZERO
@export var weapon_scale: Vector3 = Vector3(1.0, 1.0, 1.0)

@export_group("Sound")
@export var shoot_sound: AudioStream
@export var empty_sound: AudioStream
@export var reload_sound: AudioStream
