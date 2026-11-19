extends Node3D

## One preview effect inside the asset viewer's own SubViewport world.
##
## Owns spawn, looping, speed/scale and the trail nozzle.  Local-only: nothing
## here is replicated, and no node enters the gameplay World3D.
##
## Speed is applied through the `speed_scale` property: built-in
## GPUParticles3D has it, and the three code-driven toon sims gained the same
## export for this viewer (default 1.0, so gameplay is untouched).

const STAGE_POINT := Vector3(0.0, 0.6, 0.0)

const MUZZLE_INTERVAL := 0.35
const IMPACT_INTERVAL := 0.9
const EXPLOSION_INTERVAL := 2.2
const ROCKET_INTERVAL := 2.0
const TOON_EXPLOSION_INTERVAL := 3.0

const TRAIL_RADIUS := 1.3
const TRAIL_PATH_SPEED := 0.9

var _entry: Dictionary = {}
var _kind := ""
var _id := ""
var _speed := 1.0
var _scale := 1.0
var _loop := true
var _trail_auto := false

var _node: Node3D = null
var _nozzle: Node3D = null
var _camera: Camera3D = null
## Impact normal captured when the effect is selected.  Re-using one normal
## keeps the burst oriented while the camera orbits, instead of snapping back
## to face the viewer on every loop.
var _normal := Vector3.BACK
var _timer := 0.0
var _auto_time := 0.0
var _last_nozzle := STAGE_POINT
var _nozzle_point := STAGE_POINT + Vector3(-0.8, 0.0, 0.0)


func _ready() -> void:
	set_process(false)


## Play [param entry] (a row from AssetViewerCatalog.effect_entries()).
## [param scale_override] > 0 keeps the viewer's current scale slider value
## (tab re-show); 0 selects the entry's authored default.
func select(entry: Dictionary, scale_override := 0.0) -> void:
	_clear()
	_entry = entry
	_kind = str(entry.get("kind", "scene"))
	_id = str(entry.get("id", ""))
	_scale = scale_override if scale_override > 0.0 else float(entry.get("default_scale", 1.0))
	_normal = _impact_normal()
	_auto_time = 0.0
	_nozzle_point = STAGE_POINT + Vector3(-0.8, 0.0, 0.0)
	_last_nozzle = _nozzle_point
	if _kind == "toon_trail":
		_spawn()
	else:
		_fire()
	_timer = _interval()
	set_process(true)


func set_speed(speed: float) -> void:
	_speed = maxf(speed, 0.05)
	_apply_speed_scale(self)


## Named set_effect_scale (not set_scale) because Node3D already owns
## set_scale(Vector3) for the transform.
func set_effect_scale(scale: float) -> void:
	_scale = maxf(scale, 0.05)
	if _entry.is_empty():
		return
	if _kind == "toon_trail":
		_clear()
		_spawn()
	else:
		_fire()
		_timer = _interval()


func set_auto(loop: bool) -> void:
	_loop = loop
	if loop:
		_timer = minf(_timer, _interval())


func set_trail_auto(auto: bool) -> void:
	_trail_auto = auto


func restart() -> void:
	if _entry.is_empty():
		return
	_fire()
	_timer = _interval()


## World point the trail nozzle should follow (the asset viewer projects the
## cursor onto the camera plane).  Ignored while AUTO flight is on.
func set_nozzle_point(point: Vector3) -> void:
	_nozzle_point = point


func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Stop emitting and free every spawned node.  The viewer calls this on close.
func stop() -> void:
	_clear()
	set_process(false)


func _process(delta: float) -> void:
	if _kind == "toon_trail":
		_update_trail(delta)
		return
	if not _loop:
		return
	_timer -= delta
	if _timer <= 0.0:
		_fire()
		_timer = _interval()


# ─────────────────────────────────────────────
#  Spawn / fire
# ─────────────────────────────────────────────

func _spawn() -> void:
	match str(_entry.get("kind", "scene")):
		"scene":
			_spawn_scene()
		"toon_explosion":
			var scene := load("res://effects/toon_explosions/toon_explosion.tscn")
			if scene == null:
				return
			var node := scene.instantiate() as Node3D
			if node == null:
				return
			node.set("auto_free", false)
			node.set("effect_scale", _scale)
			node.set("speed_scale", _speed)
			add_child(node)
			_node = node
		"toon_trail":
			var scene := load("res://effects/toon_trail/toon_trail.tscn")
			if scene == null:
				return
			var node := scene.instantiate() as Node3D
			if node == null:
				return
			node.set("auto_free", false)
			node.set("effect_scale", _scale)
			node.set("speed_scale", _speed)
			add_child(node)
			_node = node
			_nozzle = Node3D.new()
			_nozzle.name = "TrailNozzle"
			add_child(_nozzle)
			_nozzle.global_position = _nozzle_point
			_last_nozzle = _nozzle_point
			node.call("start", _id, _nozzle)


func _spawn_scene() -> void:
	var path := str(_entry.get("scene_path", ""))
	if path.is_empty():
		return
	var scene := load(path)
	if scene == null:
		return
	var node := scene.instantiate() as Node3D
	if node == null:
		return
	if _id == "bullet_impact":
		node.set("auto_release", false)
	if _id == "rocket_impact":
		node.set("auto_free", false)
		node.set("effect_scale", _scale)
		node.set("speed_scale", _speed)
	add_child(node)
	_node = node
	_apply_speed_scale(node)
	if _id == "muzzle_flash" or _id == "bullet_impact":
		_orient_node(node)


func _fire() -> void:
	match _kind:
		"scene":
			_fire_scene()
		"toon_explosion":
			if _node == null or not is_instance_valid(_node):
				_spawn()
			if _node != null:
				if "effect_scale" in _node:
					_node.set("effect_scale", _scale)
				_node.call("play", _id, STAGE_POINT, _normal, Vector3.UP)
		"toon_trail":
			pass


func _fire_scene() -> void:
	match _id:
		"muzzle_flash":
			if _node == null or not is_instance_valid(_node):
				_spawn()
			if _node != null:
				_node.scale = Vector3.ONE * _scale
				_node.call("fire")
		"bullet_impact":
			if _node == null or not is_instance_valid(_node):
				_spawn()
			if _node != null:
				_node.scale = Vector3.ONE * _scale
				_node.call("fire")
		"explosion":
			# GenericExplosion frees itself; instantiate a fresh one per burst.
			_spawn_scene()
			if _node != null:
				_apply_speed_scale(_node)
				_node.call("start_effect", _scale)
				_node = null
		"rocket_impact":
			if _node == null or not is_instance_valid(_node):
				_spawn()
			if _node != null:
				if "effect_scale" in _node:
					_node.set("effect_scale", _scale)
				_node.call("play", STAGE_POINT, _normal, Vector3.UP)


func _clear() -> void:
	for child in get_children():
		if child is Node3D and _kind == "toon_trail" and child.has_method("stop"):
			child.call("stop")
		remove_child(child)
		child.queue_free()
	_node = null
	_nozzle = null


# ─────────────────────────────────────────────
#  Trail nozzle
# ─────────────────────────────────────────────

func _update_trail(delta: float) -> void:
	if _nozzle == null or not is_instance_valid(_nozzle):
		return
	var point := _nozzle_point
	if _trail_auto:
		_auto_time += delta * _speed
		var t := _auto_time * TRAIL_PATH_SPEED
		point = STAGE_POINT + Vector3(
			cos(t) * TRAIL_RADIUS,
			sin(t * 0.7) * TRAIL_RADIUS * 0.55,
			sin(t * 0.9) * TRAIL_RADIUS)
	_nozzle.global_position = point
	var motion := point - _last_nozzle
	if motion.length_squared() > 0.000001:
		_nozzle.look_at(point + motion, Vector3.UP)
	_last_nozzle = point


# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────

func _interval() -> float:
	match _kind:
		"scene":
			match _id:
				"muzzle_flash": return MUZZLE_INTERVAL
				"bullet_impact": return IMPACT_INTERVAL
				"explosion": return EXPLOSION_INTERVAL
				"rocket_impact": return ROCKET_INTERVAL
		"toon_explosion":
			return TOON_EXPLOSION_INTERVAL
	return 1.0


## Impact-style presets read best facing the viewer at spawn time.
func _impact_normal() -> Vector3:
	if _camera == null or not is_instance_valid(_camera):
		return Vector3.BACK
	return (_camera.global_position - STAGE_POINT).normalized()


func _orient_node(node: Node3D) -> void:
	node.global_position = STAGE_POINT
	node.scale = Vector3.ONE * _scale
	if _normal.length_squared() > 0.000001:
		node.look_at(STAGE_POINT + _normal, Vector3.UP)


func _apply_speed_scale(node: Node) -> void:
	if "speed_scale" in node:
		node.set("speed_scale", _speed)
	for child in node.get_children():
		_apply_speed_scale(child)
