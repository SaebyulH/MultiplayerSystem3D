extends Label3D

@export var weapon_controller: WeaponController

func _ready() -> void:
	#This happens on ALL peers because the health is the attribute component's health
	_on_mag_or_weapon_updated()
	weapon_controller.mag_changed.connect(_on_mag_or_weapon_updated)
	weapon_controller.weapon_changed.connect(_on_mag_or_weapon_updated)
	


func _on_mag_or_weapon_updated(_current = null, _max = null) -> void:
	if weapon_controller == null:
		return
	
	var weapons = weapon_controller.weapons
	var index = weapon_controller.current_weapon_index
	
	if index < 0 or index >= weapons.size():
		return
	
	var weapon = weapons[index]
	if weapon.has_infinite_ammo:
		text = "Infinite"
	else:
		text = "%d/%d" % [weapon.mag_current, weapon.mag_size]

func _process(delta: float) -> void:
	if weapon_controller._is_reloading:
		# show remaining reload time (1 decimal is usually enough)
		text = "Reloading: %.1f" % weapon_controller._reload_timer
		
