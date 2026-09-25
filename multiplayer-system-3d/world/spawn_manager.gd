extends Node
class_name SpawnManager

@onready var spawn_parent: Node3D = get_parent().get_node("%SpawnParent")
var player_scene: PackedScene
var bot_scene: PackedScene  # assign in editor
var _bot_counter: int = 0

const SPAWN_BOT_MENU_SCENE := preload("res://world/spawn_bot_menu.tscn")
var _spawn_menu: Node = null

func _ready() -> void:
	get_tree().get_multiplayer().peer_connected.connect(_peer_connected)
	get_tree().get_multiplayer().peer_disconnected.connect(_peer_disconnected)
	_add_player_to_game(1)
	randomize()
	_spawn_menu = SPAWN_BOT_MENU_SCENE.instantiate()
	get_tree().root.add_child(_spawn_menu)


func _exit_tree() -> void:
	if _spawn_menu and is_instance_valid(_spawn_menu):
		_spawn_menu.queue_free()
		_spawn_menu = null

func _peer_connected(network_id):
	if OS.is_debug_build(): print("Peer connected: Network ID: %s" % network_id)
	_add_player_to_game(network_id)
	# Existing players were added before this peer connected, so their
	# rpc_reset already fired.  When Godot replicates those nodes to the
	# new peer, _ready() calls despawn() and nothing re-shows them.
	# Sync their visibility a frame later, once tree sync is settled.
	_sync_existing_players_to_peer(network_id)

## Make already-spawned players visible to a late-joining peer.
func _sync_existing_players_to_peer(peer_id: int) -> void:
	await get_tree().process_frame
	for child in spawn_parent.get_children():
		if child is Player and child.spawned and child.name != str(peer_id):
			# `_size_scale` / `starting_health` are read live rather than derived
			# from the effect, so they are correct whether or not a size buff is
			# active — and they carry the character-resolved max either way.
			var max_health: float = child.attribute_component.starting_health if child.attribute_component else 100.0
			child.rpc_sync_full_state.rpc_id(peer_id, child.global_position, child._loadout_primary_path, child._loadout_secondary_path, child._loadout_melee_path, child._loadout_character_path, child._size_scale, max_health)
			# Permanent status-effect markers (wallhacked/health-visible) are no
			# longer re-broadcast on a 10 Hz timer, so push them explicitly to a
			# late-joining peer.
			if child.status_effect_manager:
				child.status_effect_manager._sync_to_clients(peer_id)

func _peer_disconnected(network_id):
	if OS.is_debug_build(): print("Peer disconnected: Network ID: %s" % network_id)
	var player_to_remove = spawn_parent.find_child(str(network_id), false, false)
	if player_to_remove:
		player_to_remove.queue_free()
	Leaderboard.request_remove_player(str(network_id))

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
	Leaderboard.request_remove_player(entity_id)
	# Drop it from the persistent manual-bot roster so it isn't re-created.
	for i in range(GameManager.lobby_bots.size() - 1, -1, -1):
		if GameManager.lobby_bots[i].get("name", "") == entity_id:
			GameManager.lobby_bots.remove_at(i)
	
	
	
	
# At the top — point these at your actual class resources
const BOT_CLASSES: Array[String] = [
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assistance.tres",
]

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("add_bot_sci"):  # B — toggle spawn-bot menu
		if multiplayer.is_server() and _spawn_menu:
			if _spawn_menu.is_open():
				_spawn_menu.close()
			else:
				_spawn_menu.open()

func add_bot(team: Player.Team) -> String:
	if not multiplayer.is_server():
		return ""
	var entity_id := _spawn_bot(team)
	var loadout := _apply_random_bot_loadout(entity_id)
	if not loadout.is_empty():
		loadout["team"] = int(team)
		loadout["name"] = entity_id
		GameManager.lobby_bots.append(loadout)
	return entity_id


## Auto-fill bot: identical to add_bot but NOT recorded to the persistent roster,
## so it's freed when the host returns to the lobby.
func add_autofill_bot(team: Player.Team) -> void:
	if not multiplayer.is_server():
		return
	var entity_id := _spawn_bot(team)
	_apply_random_bot_loadout(entity_id)


## Re-create a previously-recorded manual bot (after return_to_lobby).
func add_bot_with_loadout(entry: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var team: Player.Team = int(entry.get("team", Player.Team.FFA))
	var entity_id := _spawn_bot(team)
	entry["name"] = entity_id  # update to the new entity id
	_apply_saved_bot_loadout(entity_id, entry)


func _spawn_bot(team: Player.Team) -> String:
	_bot_counter += 1
	var entity_id := "bot_%d" % _bot_counter
	var bot = player_scene.instantiate()
	bot.name = entity_id
	bot.is_bot = true
	bot.team = team  # set BEFORE add_child so _ready() sees correct team
	bot.set_multiplayer_authority(1)
	bot.spawn_manager = self
	spawn_parent.add_child(bot)
	bot.global_position = Vector3(0, 100, 0)
	Leaderboard.request_add_player(entity_id)
	return entity_id


## Picks a random character + weapons and applies them.  Returns the loadout
## paths so a manual bot can be recorded to GameManager.lobby_bots.
func _apply_random_bot_loadout(entity_id: String) -> Dictionary:
	var player := GameManager.find_player(entity_id)
	if player == null:
		push_error("Bot not found: " + entity_id)
		return {}

	# Pick a character no other bot on this team is already using.
	var pick := _choose_character(player.team)
	var bot_class := pick.get("class", null) as Class
	var character := pick.get("character", null) as Character
	if bot_class == null:
		push_error("No bot classes available")
		return {}

	return _apply_bot_loadout_with(entity_id, character, bot_class)


## Spawn a bot with a specific character + class (used by the spawn-bot menu).
func add_bot_with_character(team: Player.Team, character: Character, bot_class: Class) -> String:
	if not multiplayer.is_server():
		return ""
	var entity_id := _spawn_bot(team)
	var loadout := _apply_bot_loadout_with(entity_id, character, bot_class)
	if not loadout.is_empty():
		loadout["team"] = int(team)
		loadout["name"] = entity_id
		GameManager.lobby_bots.append(loadout)
	return entity_id


## Applies a given character + class (random weapons) to a bot and returns the
## loadout paths for recording.
func _apply_bot_loadout_with(entity_id: String, character: Character, bot_class: Class) -> Dictionary:
	var player := GameManager.find_player(entity_id)
	if player == null:
		push_error("Bot not found: " + entity_id)
		return {}

	var primary := bot_class.primary_weapons[randi() % bot_class.primary_weapons.size()]
	var secondary := bot_class.secondary_weapons[randi() % bot_class.secondary_weapons.size()]
	var melee: Weapon = null
	if not bot_class.melee_weapons.is_empty():
		melee = bot_class.melee_weapons[randi() % bot_class.melee_weapons.size()]

	_apply_bot_weapons(player, primary, secondary, melee)
	if character:
		player.set_character(character)

	var spawn_pos: Vector3 = player._get_spawn_position()
	player.rpc_reset.rpc(spawn_pos)

	return {
		"character_path": character.resource_path if character else "",
		"primary_path": primary.resource_path,
		"secondary_path": secondary.resource_path,
		"melee_path": melee.resource_path if melee else "",
	}


func _apply_saved_bot_loadout(entity_id: String, entry: Dictionary) -> void:
	var player := GameManager.find_player(entity_id)
	if player == null:
		push_error("Bot not found: " + entity_id)
		return

	var character: Character = load(str(entry.get("character_path", ""))) as Character
	var primary: Weapon = load(str(entry.get("primary_path", ""))) as Weapon
	var secondary: Weapon = load(str(entry.get("secondary_path", ""))) as Weapon
	var melee: Weapon = null
	if str(entry.get("melee_path", "")) != "":
		melee = load(str(entry.get("melee_path", ""))) as Weapon

	if primary and secondary:
		_apply_bot_weapons(player, primary, secondary, melee)
	if character:
		player.set_character(character)

	var spawn_pos: Vector3 = player._get_spawn_position()
	player.rpc_reset.rpc(spawn_pos)


func _apply_bot_weapons(player: Player, primary: Weapon, secondary: Weapon, melee: Weapon) -> void:
	var controller: WeaponController = player.get_node("WeaponController")
	if controller == null:
		return
	var new_weapons: Array[Weapon] = []
	new_weapons.append(primary.duplicate(true) as Weapon)
	new_weapons.append(secondary.duplicate(true) as Weapon)
	if melee:
		new_weapons.append(melee.duplicate(true) as Weapon)
	controller.set_weapons(new_weapons)
	controller.current_weapon_index = 0


## Pick the rarest character across all classes for a bot joining [param team].
## Characters already in use by other bots on the team are skipped while a free
## one exists; once every character is represented, the least-used one is chosen
## (ties broken at random).  Returns { "class": Class, "character": Character }.
func _choose_character(team: Player.Team) -> Dictionary:
	var characters: Array[Character] = []
	var class_of: Dictionary = {}
	for path in BOT_CLASSES:
		var bot_class := load(path) as Class
		if bot_class == null:
			continue
		for ch in bot_class.characters:
			if ch == null:
				continue
			var key := _char_key(ch)
			if class_of.has(key):
				continue
			characters.append(ch)
			class_of[key] = bot_class

	# Count how many bots on this team already use each character.  Human players
	# are ignored so their picks never influence the bot roster.
	var used: Dictionary = {}
	for child in spawn_parent.get_children():
		if not child is Player:
			continue
		var p := child as Player
		if not p.is_bot or p.team != team:
			continue
		var ch := p.get_character()
		if ch:
			var key := _char_key(ch)
			used[key] = used.get(key, 0) + 1

	var candidates: Array[Character] = []
	var rarest := 0x7fffffff
	for ch in characters:
		var count: int = used.get(_char_key(ch), 0)
		if count < rarest:
			rarest = count
			candidates.clear()
			candidates.append(ch)
		elif count == rarest:
			candidates.append(ch)

	if candidates.is_empty():
		return {}
	var chosen: Character = candidates[randi() % candidates.size()]
	return { "class": class_of[_char_key(chosen)], "character": chosen }


func _char_key(ch: Character) -> String:
	return ch.resource_path if ch.resource_path != "" else ch.character_name
