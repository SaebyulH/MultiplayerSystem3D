extends VBoxContainer

@onready var spawn_parent := %SpawnParent
@onready var class_option: OptionButton = $VBoxContainer/ClassOption
@onready var primary_option: OptionButton = $VBoxContainer2/PrimaryWeaponOption
@onready var secondary_option: OptionButton = $VBoxContainer3/SecondaryWeaponOption
@onready var confirm_button: Button = $ConfirmBuild

var player_id: String
var available_classes: Array[Class] = []
var selected_class: Class = null

func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())
	
	primary_option.visible = false
	secondary_option.visible = false
	
	for i in class_option.item_count:
		var path := class_option.get_item_text(i)
		var c := load(path) as Class
		if c:
			available_classes.append(c)
			class_option.set_item_text(i, c.class_display_name)
	
	class_option.item_selected.connect(_on_class_selected)
	confirm_button.pressed.connect(_on_confirm_pressed)


func load_classes(classes: Array[Class]) -> void:
	available_classes = classes
	class_option.clear()
	class_option.add_item("-- Select Class --")
	for c in classes:
		class_option.add_item(c.class_display_name)

func _on_class_selected(index: int) -> void:
	selected_class = available_classes[index]
	
	primary_option.clear()
	for w in selected_class.primary_weapons:
		primary_option.add_item(w.display_name)
	
	secondary_option.clear()
	for w in selected_class.secondary_weapons:
		secondary_option.add_item(w.display_name)
	
	primary_option.visible = true
	secondary_option.visible = true


func _on_confirm_pressed() -> void:
	if selected_class == null:
		return
	
	var primary_index := primary_option.selected
	var secondary_index := secondary_option.selected
	
	if primary_index < 0 or secondary_index < 0:
		return
	
	var primary: Weapon = selected_class.primary_weapons[primary_index]
	var secondary: Weapon = selected_class.secondary_weapons[secondary_index]
	
	_apply_loadout.rpc(player_id, primary.resource_path, secondary.resource_path)
	
	get_parent().visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

@rpc("any_peer", "call_local", "reliable")
func _apply_loadout(target_player_id: String, primary_path: String, secondary_path: String) -> void:
	var primary: Weapon = load(primary_path) as Weapon
	var secondary: Weapon = load(secondary_path) as Weapon
	
	var player := _find_player(target_player_id)
	if player == null:
		return
	
	var controller: WeaponController = player.get_node("WeaponController")
	if controller == null:
		return
	
	var new_weapons: Array[Weapon] = []
	new_weapons.append(primary.duplicate(true) as Weapon)
	new_weapons.append(secondary.duplicate(true) as Weapon)
	controller.weapons = new_weapons
	controller.current_weapon_index = 0
	
	player.no_health()
	controller.spawn_weapon_model()

func _find_player(id: String) -> Node:
	var node := spawn_parent
	while node != null:
		for child in node.get_children():
			if child.name == id:
				return child
		node = node.get_parent()
		if node == get_tree().root:
			break
	return null
