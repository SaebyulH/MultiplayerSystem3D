extends Node3D


func fire():
	$MuzzlePlanes.emitting = true
	$MuzzleCone.emitting = true
	$Sparks.emitting = true
	$OmniLight3D.show()

	var duration = $MuzzlePlanes.lifetime

	await get_tree().create_timer(duration).timeout

	$OmniLight3D.hide()
