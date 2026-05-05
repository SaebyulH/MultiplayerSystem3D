extends Node
class_name SpawnManager

@onready var spawn_parent: Node3D = get_parent().get_node("%SpawnParent")
var player_scene: PackedScene
var bot_scene: PackedScene  # assign in editor
var _bot_counter: int = 0

func _ready() -> void:
	get_tree().get_multiplayer().peer_connected.connect(_peer_connected)
	get_tree().get_multiplayer().peer_disconnected.connect(_peer_disconnected)
	_add_player_to_game(1)
	randomize()

func _peer_connected(network_id):
	print("Peer connected: Network ID: %s" % network_id)
	_add_player_to_game(network_id)

func _peer_disconnected(network_id):
	print("Peer disconnected: Network ID: %s" % network_id)
	var player_to_remove = spawn_parent.find_child(str(network_id), false, false)
	if player_to_remove:
		player_to_remove.queue_free()

func _add_player_to_game(network_id: int):
	var entity_id := str(network_id)  # players keep net ID as their entity_id
	var player_to_add = player_scene.instantiate()
	player_to_add.name = entity_id
	player_to_add.set_multiplayer_authority(network_id)
	player_to_add.spawn_manager = self
	spawn_parent.add_child(player_to_add)
	player_to_add.global_position = Vector3(0, 100, 0)
	Leaderboard.request_add_player(entity_id)


func remove_bot(entity_id: String) -> void:
	var bot = spawn_parent.find_child(entity_id, false, false)
	if bot:
		bot.queue_free()
	# no leaderboard cleanup needed unless your game mode requires it
	
	
	
	
# At the top — point these at your actual class resources
const BOT_CLASSES: Array[String] = [
	"res://player/player_classes/assasin.tres",
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assistance.tres",
]

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("add_bot_spi"):
		if multiplayer.is_server():
			add_bot(Player.Team.SPI)
	if event.is_action_pressed("add_bot_sci"):
		if multiplayer.is_server():
			add_bot(Player.Team.SCI)

func add_bot(team: Player.Team) -> void:
	if not multiplayer.is_server():
		return
	_bot_counter += 1
	var entity_id := "bot_%d" % _bot_counter
	var bot = player_scene.instantiate()
	bot.name = entity_id
	bot.is_bot = true
	bot.team = team  # ← set BEFORE add_child so _ready() sees correct team
	bot.set_multiplayer_authority(1)
	bot.spawn_manager = self
	spawn_parent.add_child(bot)
	bot.global_position = Vector3(0, 100, 0)
	Leaderboard.request_add_player(entity_id)
	_apply_bot_loadout(entity_id)

func _apply_bot_loadout(entity_id: String) -> void:
	# Pick a random class
	var class_path := BOT_CLASSES[randi() % BOT_CLASSES.size()]
	var bot_class := load(class_path) as Class
	if bot_class == null:
		push_error("Failed to load bot class: " + class_path)
		return

	var primary := bot_class.primary_weapons[randi() % bot_class.primary_weapons.size()]
	var secondary := bot_class.secondary_weapons[randi() % bot_class.secondary_weapons.size()]

	var player := GameManager.find_player(entity_id)
	if player == null:
		push_error("Bot not found: " + entity_id)
		return

	var controller: WeaponController = player.get_node("WeaponController")
	if controller == null:
		return

	var new_weapons: Array[Weapon] = []
	new_weapons.append(primary.duplicate(true) as Weapon)
	new_weapons.append(secondary.duplicate(true) as Weapon)
	controller.set_weapons(new_weapons)
	controller.current_weapon_index = 0

	#player.team = team
	var spawn_pos :Vector3= player._get_spawn_position()
	player.rpc_reset.rpc(spawn_pos)
