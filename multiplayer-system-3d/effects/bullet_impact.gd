class_name BulletImpact extends Node3D

## Neutral warm-white tint applied to the impact particles.  Intentionally
## NOT team-colored (unlike the muzzle flash / tracer).
const DEFAULT_COLOR := Color(0.543, 0.452, 0.358, 0.145)


func set_color(color: Color) -> void:
	$ImpactPlanes.material_override.albedo_color = color
	$ImpactCone.material_override.albedo_color = color
	$Sparks.material_override.albedo_color = color


func _ready() -> void:
	set_color(DEFAULT_COLOR)


## Plays the one-shot impact effect, then frees this node once the particles
## have finished.
func fire() -> void:
	$ImpactPlanes.emitting = true
	$ImpactCone.emitting = true
	$Sparks.emitting = true

	# `randomness` can stretch particle lifetime up to 2x, so wait well past the
	# longest one-shot (ImpactPlanes + Sparks share a 0.2s lifetime) before
	# freeing the node.
	var duration: float = $ImpactPlanes.lifetime * 2.0
	await get_tree().create_timer(duration).timeout
	queue_free()
