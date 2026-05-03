extends Control
@onready var spawn_parent := %SpawnParent
@onready var team_option: OptionButton = %TeamOption

@onready var class_option: OptionButton = %ClassOption
@onready var primary_option: OptionButton = %PrimaryWeaponOption
@onready var secondary_option: OptionButton = %SecondaryWeaponOption
@onready var confirm_button: Button = %ConfirmBuild
@onready var primary_viewport: SubViewport = %PrimarySubViewport
@onready var secondary_viewport: SubViewport = %SecondarySubViewport

var player_id: String
var available_classes: Array[Class] = []
var selected_class: Class = null
@onready var world := $"../../.."

func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())

	primary_option.visible = false
	secondary_option.visible = false

	# Load classes from editor-assigned items, then rebuild the option list cleanly
	var loaded_classes: Array[Class] = []
	for i in class_option.item_count:
		var path := class_option.get_item_text(i)
		var c := load(path)
		if c:
			loaded_classes.append(c)

	load_classes(loaded_classes)

	class_option.item_selected.connect(_on_class_selected)
	primary_option.item_selected.connect(_on_primary_selected)
	secondary_option.item_selected.connect(_on_secondary_selected)
	confirm_button.pressed.connect(_on_confirm_pressed)

func _clear_viewport(viewport: SubViewport) -> void:
	var preview_root := viewport.get_node("Node3D/PreviewRoot")
	for child in preview_root.get_children():
		child.queue_free()

func _spawn_weapon_preview(weapon: Weapon, viewport: SubViewport) -> void:
	if weapon == null or weapon.weapon_model == null:
		return
	_clear_viewport(viewport)
	var model: Node3D = weapon.weapon_model.instantiate()
	model.position = Vector3.ZERO
	model.rotation = weapon.weapon_rotation
	model.scale = weapon.weapon_scale
	viewport.get_node("Node3D/PreviewRoot").add_child(model)

	await get_tree().process_frame

	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var muzzle := model.get_node_or_null("Muzzle")
	if muzzle:
		var dist: float = muzzle.position.length() * 2.7 + 0.4
		camera.position.x = dist

func load_classes(classes: Array[Class]) -> void:
	available_classes = classes
	class_option.clear()
	class_option.add_item("-- Select Class --")
	for c in classes:
		class_option.add_item(c.class_display_name)

func _on_class_selected(index: int) -> void:
	# index 0 is the "-- Select Class --" placeholder
	if index <= 0 or index - 1 >= available_classes.size():
		selected_class = null
		primary_option.visible = false
		secondary_option.visible = false
		return

	selected_class = available_classes[index - 1]

	primary_option.clear()
	for w in selected_class.primary_weapons:
		primary_option.add_item(w.display_name)

	secondary_option.clear()
	for w in selected_class.secondary_weapons:
		secondary_option.add_item(w.display_name)

	primary_option.visible = true
	secondary_option.visible = true

	# index into weapons is 0-based, no offset needed — no placeholder here
	if selected_class.primary_weapons.size() > 0:
		_spawn_weapon_preview(selected_class.primary_weapons[0], primary_viewport)
	if selected_class.secondary_weapons.size() > 0:
		_spawn_weapon_preview(selected_class.secondary_weapons[0], secondary_viewport)

func _on_primary_selected(index: int) -> void:
	if selected_class == null:
		return
	_spawn_weapon_preview(selected_class.primary_weapons[index], primary_viewport)

func _on_secondary_selected(index: int) -> void:
	if selected_class == null:
		return
	_spawn_weapon_preview(selected_class.secondary_weapons[index], secondary_viewport)

func _get_selected_team() -> Player.Team:
	match team_option.selected:
		0: return Player.Team.SPI
		1: return Player.Team.SCI
		2: return Player.Team.FFA
	return Player.Team.SPI

func _on_confirm_pressed() -> void:
	world.class_selected = true

	if selected_class == null:
		return

	var primary_index := primary_option.selected
	var secondary_index := secondary_option.selected

	if primary_index < 0 or secondary_index < 0:
		return

	var primary: Weapon = selected_class.primary_weapons[primary_index]
	var secondary: Weapon = selected_class.secondary_weapons[secondary_index]
	var team := _get_selected_team()

	visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if multiplayer.is_server():
		_request_loadout(player_id, primary.resource_path, secondary.resource_path, team)
	else:
		_request_loadout.rpc_id(1, player_id, primary.resource_path, secondary.resource_path, team)

# Client → server only
@rpc("any_peer", "reliable")
func _request_loadout(target_player_id: String, primary_path: String, secondary_path: String, team: Player.Team) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != 0 and str(sender_id) != target_player_id:
		return

	var primary: Weapon = load(primary_path) as Weapon
	var secondary: Weapon = load(secondary_path) as Weapon
	if primary == null or secondary == null:
		return

	var player := GameManager.find_player(target_player_id)
	if player == null:
		return

	var controller: WeaponController = player.get_node("WeaponController")
	if controller == null:
		return

	var new_weapons: Array[Weapon] = []
	new_weapons.append(primary.duplicate(true) as Weapon)
	new_weapons.append(secondary.duplicate(true) as Weapon)

	controller.set_weapons(new_weapons)
	controller.current_weapon_index = 0
	player.team = team
	player.despawned = false
	player.no_health()

	_apply_loadout.rpc(target_player_id, primary_path, secondary_path, team)

# Server → all peers
@rpc("authority", "call_remote", "reliable")
func _apply_loadout(target_player_id: String, primary_path: String, secondary_path: String, team: Player.Team) -> void:
	var primary: Weapon = load(primary_path) as Weapon
	var secondary: Weapon = load(secondary_path) as Weapon
	if primary == null or secondary == null:
		return

	var player := GameManager.find_player(target_player_id)
	if player == null:
		return

	var controller: WeaponController = player.get_node("WeaponController")
	if controller == null:
		return

	var new_weapons: Array[Weapon] = []
	new_weapons.append(primary.duplicate(true) as Weapon)
	new_weapons.append(secondary.duplicate(true) as Weapon)
	controller.set_weapons(new_weapons)
	controller.current_weapon_index = 0
	#controller._apply_recoil_data()
	player.team = team
	player.despawned = false
