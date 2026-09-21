class_name BulletImpact extends Node3D

## Neutral warm-white tint applied to the impact particles.  Intentionally
## NOT team-colored (unlike the muzzle flash / tracer).
const DEFAULT_COLOR := Color(0.543, 0.452, 0.358, 0.145)

## Reusable node pool so automatic fire doesn't instantiate + free an impact per
## shot (see #4 in docs/05-known-issues.md).  The one-shot lifetime is tracked in
## `_process` instead of an awaited timer, and the node is recycled rather than
## freed.
const MAX_POOL: int = 64
static var _pool: Array[BulletImpact] = []

var _lifetime: float = 0.0
var _elapsed: float = 0.0


static func acquire() -> BulletImpact:
	while not _pool.is_empty():
		var b: BulletImpact = _pool.pop_back()
		if is_instance_valid(b):
			return b
	return null


func set_color(color: Color) -> void:
	$ImpactPlanes.material_override.albedo_color = color
	$ImpactCone.material_override.albedo_color = color
	$Sparks.material_override.albedo_color = color


func _ready() -> void:
	set_color(DEFAULT_COLOR)
	set_process(false)


## Plays the one-shot impact effect, then returns the node to the pool once the
## particles have finished.
func fire() -> void:
	$ImpactPlanes.emitting = true
	$ImpactCone.emitting = true
	$Sparks.emitting = true

	# `randomness` can stretch particle lifetime up to 2x, so wait well past the
	# longest one-shot (ImpactPlanes + Sparks share a 0.2s lifetime) before
	# releasing the node.
	_lifetime = $ImpactPlanes.lifetime * 2.0
	_elapsed = 0.0
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _lifetime:
		_release()


func _release() -> void:
	set_process(false)
	var parent := get_parent()
	if parent != null:
		parent.remove_child(self)
	if _pool.size() < MAX_POOL:
		_pool.append(self)
	else:
		queue_free()
