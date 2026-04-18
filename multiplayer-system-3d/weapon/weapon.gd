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
@export var weapon_offset: Vector3 = Vector3(0.2, -0.2, -0.3)
@export var weapon_rotation: Vector3 = Vector3(0.0, 0.0, 0.0)

@export var automatic: bool = false
