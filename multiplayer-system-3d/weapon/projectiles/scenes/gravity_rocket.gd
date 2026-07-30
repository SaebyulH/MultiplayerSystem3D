extends SimpleProjectile


func _on_weapon_signal(target: Vector3, player_transform: Vector3) -> void:
	gravity_scale *= -1
