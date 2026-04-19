extends Resource
class_name Weapon

@export var display_name: String = "Default Weapon"

@export_group("Universal Combat")
@export var automatic: bool = false
@export var pre_shoot_delay: float = 0.0
@export var post_shoot_delay: float = 0.5
@export var has_infinite_ammo: bool = false
@export var mag_size: int = 6
@export var mag_current: int = 6
@export var reload_individually: bool = false
@export var reload_time: float = 1.0
@export var recoil_data: RecoilData = RecoilData.new()
@export var speed_multiplier: float = 1.0

@export_group("Bullet")
enum BulletType {HITSCAN, PROJECTILE}
@export var bullet_type: BulletType
@export var hitscan_damage: float = 10.0
@export var hitscan_range: float = 1000000000.0
@export var projectile_scene: PackedScene #Projectile damage is configured in the scene
@export var multishot_data: Array[Vector3] = [Vector3(0, 0, -1)]

@export_group("Visuals")
@export var weapon_model: PackedScene
@export var weapon_offset: Vector3 = Vector3(0.2, -0.4, -0.55)
@export_custom(PROPERTY_HINT_RANGE, "-360,360,0.1,radians") 
var weapon_rotation: Vector3 = Vector3.ZERO
@export var weapon_scale: Vector3 = Vector3(1.0, 1.0, 1.0)

@export_group("Sound")
@export var shoot_sound: AudioStream
@export var empty_sound: AudioStream
@export var reload_sound: AudioStream
