extends Label3D

@export var weapon_controller: WeaponController

func _process(delta: float) -> void:
	if weapon_controller == null:
		return
	
	var weapons = weapon_controller.weapons
	var index = weapon_controller.current_weapon_index
	
	if index < 0 or index >= weapons.size():
		return
	
	var weapon = weapons[index]
	
	if weapon_controller._is_reloading:
		# show remaining reload time (1 decimal is usually enough)
		text = "Reloading: %.1f" % weapon_controller._reload_timer
	else:
		if weapon.has_infinite_ammo:
			text = "Infinite"
		else:
			text = "%d/%d" % [weapon.mag_current, weapon.mag_size]
