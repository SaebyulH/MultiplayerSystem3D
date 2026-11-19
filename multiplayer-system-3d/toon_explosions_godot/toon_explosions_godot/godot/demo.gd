extends Node3D

const ROCKET_IMPACT := preload("res://effects/rocket_impact/rocket_impact.tscn")
const TOON_EXPLOSION := preload("res://effects/toon_explosions/toon_explosion.tscn")
const TOON_SCRIPT := preload("res://effects/toon_explosions/toon_explosion.gd")
const GROUPS := ["Core impacts", "Payload set pieces", "Aftermath", "Fire, smoke and trails", "Components"]
const FLOOR_COLOR := Color("#424855")
const WALL_COLOR := Color("#626978")
const SEAM_COLOR := Color("#383d47")

@onready var camera: Camera3D = $Camera3D
@onready var _picker: OptionButton = $Overlay/Toolbar/Effect
@onready var _slow_button: CheckButton = $Overlay/Toolbar/Slow
var _impact_number := 0
var _active_effect: Node3D

func _ready() -> void:
	_picker.add_item("Rocket surface impact")
	_picker.set_item_metadata(0, {"id": ""})
	var catalog := TOON_SCRIPT.effect_catalog()
	for group: String in GROUPS:
		_picker.add_separator(group)
		for entry: Dictionary in catalog:
			if entry.group == group:
				_picker.add_item(entry.name + "  ·  " + entry.package)
				_picker.set_item_metadata(_picker.item_count - 1, entry)
	_picker.select(0)
	_picker.item_selected.connect(_on_selected)
	$Overlay/Toolbar/Replay.pressed.connect(_replay)
	_slow_button.toggled.connect(_set_slow)
	camera.look_at(Vector3(0.0, 1.0, -0.5))
	_box(Vector3(0, -0.11, 0), Vector3(26, 0.20, 19), FLOOR_COLOR)
	for x in range(-12, 13, 2):
		_box(Vector3(x, 0, 0), Vector3(0.016, 0.007, 19), SEAM_COLOR)
	for z in range(-8, 9, 2):
		_box(Vector3(0, 0, z), Vector3(26, 0.007, 0.016), SEAM_COLOR)
	_box(Vector3(0, 1.5, -3.1), Vector3(10.0, 3.0, 0.24), WALL_COLOR)
	for x in range(-4, 5, 2):
		_box(Vector3(x, 1.50, -2.973), Vector3(0.015, 3.0, 0.01), SEAM_COLOR)
	_box(Vector3(0, 1.5, -2.974), Vector3(10.0, 0.015, 0.01), SEAM_COLOR)
	if not OS.get_cmdline_user_args().has("--manual"):
		await get_tree().create_timer(0.35).timeout
		_impact(false)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_SPACE:
			_replay()
		elif event.physical_keycode == KEY_W:
			_impact(true)
		elif event.physical_keycode == KEY_S:
			_slow_button.button_pressed = not _slow_button.button_pressed

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var start := camera.project_ray_origin(event.position)
		var heading := camera.project_ray_normal(event.position)
		if heading.z < 0.0:
			var wall := start + heading * ((-2.97 - start.z) / heading.z)
			if absf(wall.x) <= 5.0 and wall.y > 0.0 and wall.y < 3.0:
				_fire(wall, Vector3.BACK)
				return
		if heading.y < 0.0:
			var ground := start + heading * (-start.y / heading.y)
			if absf(ground.x) <= 12.5 and absf(ground.z) <= 9.0:
				_fire(ground, Vector3.UP)

func _impact(wall: bool) -> void:
	if wall:
		_fire(Vector3(0.0, 1.35, -2.97), Vector3.BACK)
	else:
		_fire(Vector3.ZERO, Vector3.UP)

func _on_selected(_index: int) -> void:
	var entry: Dictionary = _picker.get_selected_metadata()
	var distant: bool = entry.get("group", "") in ["Payload set pieces", "Aftermath", "Fire, smoke and trails"]
	camera.position = Vector3(9.0, 5.0, 14.0) if distant else Vector3(5.2, 3.1, 8.6)
	camera.look_at(Vector3(0.0, 1.9 if distant else 1.0, -0.5))
	_replay()

func _set_slow(enabled: bool) -> void:
	Engine.time_scale = 0.10 if enabled else 1.0

func _replay() -> void:
	var entry: Dictionary = _picker.get_selected_metadata()
	if "midair" in String(entry.get("name", "")).to_lower():
		_fire(Vector3(0.0, 1.4, 0.0), Vector3.UP)
	else:
		_impact(false)

func _fire(point: Vector3, normal: Vector3) -> void:
	if is_instance_valid(_active_effect):
		_active_effect.queue_free()
	var entry: Dictionary = _picker.get_selected_metadata()
	var seed_value := 24691 + _impact_number
	if String(entry.id).is_empty():
		_active_effect = ROCKET_IMPACT.instantiate()
		add_child(_active_effect)
		_active_effect.play(point, normal, Vector3.UP, seed_value)
	else:
		_active_effect = TOON_EXPLOSION.instantiate()
		if entry.group == "Payload set pieces":
			_active_effect.effect_scale = 0.75
		add_child(_active_effect)
		_active_effect.play(entry.id, point, normal, Vector3.UP, seed_value)
	_impact_number += 1

func _box(center: Vector3, dimensions: Vector3, color: Color) -> void:
	var box := BoxMesh.new()
	box.size = dimensions
	var instance := MeshInstance3D.new()
	instance.mesh = box
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	instance.material_override = material
	instance.position = center
	add_child(instance)
