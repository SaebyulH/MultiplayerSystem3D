class_name BulletDecal extends Node3D

## Long-lived surface decal (bullet hole or melee scratch).  Recycled through a
## pool instead of a per-hit `Timer.new()` + `queue_free()` (see #4 in
## docs/05-known-issues.md).  The two scenes differ only in their Sprite3D
## texture, which is (re)applied on `place` so a recycled decal of either kind
## renders correctly.

const LIFETIME := 7.0
const MAX_POOL: int = 128
static var _pool: Array[BulletDecal] = []

var _age: float = 0.0


static func acquire() -> BulletDecal:
	while not _pool.is_empty():
		var d: BulletDecal = _pool.pop_back()
		if is_instance_valid(d):
			return d
	return null


func _ready() -> void:
	set_process(false)


## Position the caller has already set (global_position / basis); this just
## applies the correct texture and starts the lifetime countdown.
func place(texture: Texture2D) -> void:
	$Sprite3D.texture = texture
	_age = 0.0
	set_process(true)


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
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
