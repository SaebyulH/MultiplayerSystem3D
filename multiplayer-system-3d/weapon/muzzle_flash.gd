extends Node3D


func fire():
	$MuzzlePlanes.emitting = true
	$MuzzleCone.emitting = true
	$Sparks.emitting = true
	$OmniLight3D.show()

	var duration = $MuzzlePlanes.lifetime  # or .emission_duration if you're using one_shot

	await get_tree().create_timer(duration).timeout

	#$MuzzlePlanes.emitting = false
	#$MuzzleCone.emitting = false
	#$Sparks.emitting = false
	$OmniLight3D.hide()
