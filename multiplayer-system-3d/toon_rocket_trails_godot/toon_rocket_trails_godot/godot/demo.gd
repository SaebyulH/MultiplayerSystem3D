extends Node3D

const TRAIL := preload("res://effects/toon_trail/toon_trail.tscn")
const TRAIL_SCRIPT := preload("res://effects/toon_trail/toon_trail.gd")
const FLIGHT_TIME := 2.1

@onready var _picker: OptionButton = $Overlay/Toolbar/Preset
@onready var _slow: CheckButton = $Overlay/Toolbar/Slow
var _projectile := Node3D.new()
var _nozzle := Node3D.new()
var _trail: Node3D
var _flight_time := 0.0
var _flying := false

func _ready() -> void:
	$Camera.look_at(Vector3(0.0, 1.7, 0.0), Vector3.UP)
	_add_box(Vector3(0.0, -0.12, 0.0), Vector3(27.0, 0.2, 21.0), Color("#303947"), self)
	for i in range(-12, 13, 2):
		_add_box(Vector3(i, -0.01, 0.0), Vector3(0.016, 0.01, 21.0), Color("#252e3b"), self)
	for i in range(-10, 11, 2):
		_add_box(Vector3(0.0, -0.01, i), Vector3(27.0, 0.01, 0.016), Color("#252e3b"), self)
	add_child(_projectile)
	_projectile.add_child(_nozzle)
	_nozzle.position = Vector3(0.0, 0.0, 0.14)
	_add_box(Vector3(0.0, 0.0, -0.12), Vector3(0.18, 0.18, 0.52), Color("#a5bac5"), _projectile)
	_add_box(Vector3(0.0, 0.0, -0.42), Vector3(0.12, 0.12, 0.12), Color("#e0edf1"), _projectile)
	var group := ""
	for item in TRAIL_SCRIPT.catalog():
		if group != item.group:
			group = item.group
			_picker.add_separator(group)
		_picker.add_item(item.title)
		_picker.set_item_metadata(_picker.item_count - 1, item.id)
	_picker.select(1)
	_picker.item_selected.connect(func(_index: int) -> void: _replay())
	$Overlay/Toolbar/Replay.pressed.connect(_replay)
	_slow.toggled.connect(func(on: bool) -> void: Engine.time_scale = 0.16 if on else 1.0)
	_replay()

func _replay() -> void:
	if is_instance_valid(_trail):
		_trail.queue_free()
	_flying = true
	_flight_time = 0.0
	_projectile.show()
	_update_projectile()
	_trail = TRAIL.instantiate()
	add_child(_trail)
	_trail.start(_picker.get_selected_metadata(), _nozzle, 12410)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_SPACE:
			_replay()
		elif event.physical_keycode == KEY_S:
			_slow.button_pressed = not _slow.button_pressed

func _process(delta: float) -> void:
	if not _flying:
		return
	_flight_time = minf(_flight_time + delta, FLIGHT_TIME)
	_update_projectile()
	if _flight_time >= FLIGHT_TIME:
		_flying = false
		_projectile.hide()
		_trail.stop()

func _path(t: float) -> Vector3:
	return Vector3(lerpf(-7.35, 7.35, t), 1.65 + 0.68 * sin(t * TAU), 1.3 * cos(t * PI))

func _update_projectile() -> void:
	var t := _flight_time / FLIGHT_TIME
	_projectile.global_position = _path(t)
	_projectile.look_at(_path(t + 0.002), Vector3.UP)

func _add_box(point: Vector3, size: Vector3, tint: Color, parent: Node3D) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = tint
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = point
	parent.add_child(instance)
