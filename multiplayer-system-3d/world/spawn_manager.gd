extends Node
class_name SpawnManager

@onready var spawn_parent: Node3D = get_parent().get_node("%SpawnParent")
var player_scene: PackedScene
var bot_scene: PackedScene  # assign in editor
## A dedicated match server has no peer-1 player; world_1 clears this before
## adding the manager.  Legacy/listen hosts keep it true.
var spawn_local_player: bool = true
var _bot_counter: int = 0

func _ready() -> void:
	get_tree().get_multiplayer().peer_connected.connect(_peer_connected)
	get_tree().get_multiplayer().peer_disconnected.connect(_peer_disconnected)
	if MatchSession.role == MatchSession.Role.SERVER:
		if not MatchSession.player_left.is_connected(_on_player_left):
			MatchSession.player_left.connect(_on_player_left)
	if spawn_local_player:
		# On a listen server the host is a real participant; register it before
		# the Player node so identity lookups agree from the first frame.
		if MatchSession.role == MatchSession.Role.SERVER:
			MatchSession.register_host_player(1)
		_add_player_to_game(1, 1)
	randomize()

func _peer_connected(network_id):
	# Match-session servers add players from `MatchSession.hello`, after the
	# client's world exists (#124).  Legacy P2P still adds on connect.
	if MatchSession.role == MatchSession.Role.SERVER:
		return
	if OS.is_debug_build(): print("Peer connected: Network ID: %s" % network_id)
	_add_player_to_game(network_id, network_id)


## Match-session server entry point: called from `MatchSession._accept_peer`.
func add_remote_player(player_id: int, owner_peer_id: int) -> void:
	if MatchSession.role != MatchSession.Role.SERVER:
		return
	if has_remote_player(player_id):
		return
	_add_player_to_game(player_id, owner_peer_id)


## Per-peer replication gate for a joining client.  Existing players' sync data
## must not arrive before their spawn packets, or Godot logs "Ignoring sync data
## from non-authority or for missing node".
func hide_players_from_peer(peer_id: int) -> void:
	for sync in _all_player_syncs():
		sync.set_visibility_for(peer_id, false)


func show_players_to_peer(peer_id: int) -> void:
	for sync in _all_player_syncs():
		sync.set_visibility_for(peer_id, true)


func _all_player_syncs() -> Array[MultiplayerSynchronizer]:
	var out: Array[MultiplayerSynchronizer] = []
	for child in spawn_parent.get_children():
		if child is Player:
			for node in child.find_children("*", "MultiplayerSynchronizer", true, false):
				var sync := node as MultiplayerSynchronizer
				if sync != null:
					out.append(sync)
	return out


## Wait a few frames after a spawn before the new Player's state sync is
## enabled, so the spawner's reliable spawn packet reaches peers first.
##
## NOTE: `public_visibility = false` on a newly spawned Player's synchronizers is
## NOT safe here — Godot does not spawn a node to a peer whose synchronizer is
## not visible to it, so the client never receives its own Player.  Visibility
## gating is only applied to peers on synchronizers that are still public; see
## 05-known-issues.md #127.
func _reveal_player_after_spawn(player: Player) -> void:
	for _i in range(3):
		await get_tree().process_frame
	if not is_instance_valid(player):
		return
	for node in player.find_children("*", "MultiplayerSynchronizer", true, false):
		var sync := node as MultiplayerSynchronizer
		if sync != null:
			sync.public_visibility = true


func has_remote_player(player_id: int) -> bool:
	return spawn_parent != null and spawn_parent.find_child(str(player_id), false, false) != null


## A peer dropped.  Keep the Player node (score/team/loadout live on it) but
## despawn it so it stops simulating and cannot be shot during the grace period.
func reserve_player(player_id: int) -> void:
	var player := _find_player(player_id)
	if player == null:
		return
	player.set_reserved.rpc(true)


## A reserved player reconnected on a new peer.  Rebind input authority and
## respawn at a team spawn; score/team/loadout are untouched.
func resume_player(player_id: int, peer_id: int) -> void:
	var player := _find_player(player_id)
	if player == null:
		push_error("resume_player: no Player node for id %d" % player_id)
		return
	if OS.is_debug_build():
		print("[MATCH] server resume player %d on peer %d (spawned was %s)" % [
			player_id, peer_id, player.spawned])
	player.bind_owner_peer(peer_id)
	player.rpc_reset.rpc(player._get_spawn_transform())


func remove_reserved_player(player_id: int) -> void:
	var player := _find_player(player_id)
	if player != null:
		# `player_left`/Leaderboard cleanup is done by the caller for an expired
		# slot; this only frees the node.
		player.queue_free()


func _find_player(player_id: int) -> Player:
	if spawn_parent == null:
		return null
	var node := spawn_parent.find_child(str(player_id), false, false)
	return node as Player


## Make already-spawned players visible to a late-joining peer.  `exclude_player_id`
## is the joining player's stable id (not its peer id).
func sync_existing_players_to_peer(peer_id: int, exclude_player_id: int) -> void:
	await get_tree().process_frame
	for child in spawn_parent.get_children():
		if child is Player and child.spawned and child.player_id != exclude_player_id:
			# Read live off the player rather than derived from the effect, so
			# they are correct whether or not a size effect is active (both are
			# 1.0 when none is).
			var health_mult: float = child.attribute_component.max_health_mult if child.attribute_component else 1.0
			child.rpc_sync_full_state.rpc_id(peer_id, child.global_position, child._loadout_primary_path, child._loadout_secondary_path, child._loadout_melee_path, child._loadout_character_path, child._size_scale, health_mult)
			# Permanent status-effect markers (wallhacked/health-visible) are no
			# longer re-broadcast on a 10 Hz timer, so push them explicitly to a
			# late-joining peer.
			if child.status_effect_manager:
				child.status_effect_manager._sync_to_clients(peer_id)

func _peer_disconnected(network_id):
	# A match-session server routes disconnects through `MatchSession.player_left`
	# so the stable player id (not the dying peer id) is what gets removed.
	if MatchSession.role == MatchSession.Role.SERVER:
		return
	if OS.is_debug_build(): print("Peer disconnected: Network ID: %s" % network_id)
	var player_to_remove = spawn_parent.find_child(str(network_id), false, false)
	if player_to_remove:
		player_to_remove.queue_free()
	Leaderboard.request_remove_player(str(network_id))


func _on_player_left(player_id: int) -> void:
	if OS.is_debug_build(): print("Player %d left" % player_id)
	var player_to_remove = spawn_parent.find_child(str(player_id), false, false)
	if player_to_remove:
		player_to_remove.queue_free()
	Leaderboard.request_remove_player(str(player_id))


func _add_player_to_game(player_id: int, owner_peer_id: int):
	var entity_id := str(player_id)
	var player_to_add = player_scene.instantiate()
	player_to_add.name = entity_id
	player_to_add.player_id = player_id
	player_to_add.owner_peer_id = owner_peer_id
	# Root authority is always the server (state authority); Player._enter_tree
	# assigns input authority to `owner_peer_id`.
	player_to_add.set_multiplayer_authority(1)
	player_to_add.spawn_manager = self
	spawn_parent.add_child(player_to_add)
	player_to_add.global_position = Vector3(0, 100, 0)
	Leaderboard.request_add_player(entity_id)
	if MatchSession.role == MatchSession.Role.SERVER:
		var spawner := get_parent().get_node_or_null("MultiplayerSpawner") as MultiplayerSpawner
		if OS.is_debug_build():
			print("[MATCH] added player %d owner %d; spawnable=%s" % [
				player_id, owner_peer_id,
				str(spawner._spawnable_scenes) if spawner != null else "<no spawner>"])
		_reveal_player_after_spawn(player_to_add)


## Dev-menu "remove all bots".  Snapshots the names first (remove_bot frees
## nodes, and iterating the live child list while freeing is unsafe), then goes
## through remove_bot so the leaderboard and lobby_bots roster stay in step.
func remove_all_bots() -> void:
	if not multiplayer.is_server() or not is_instance_valid(spawn_parent):
		return
	var names: Array[String] = []
	for child in spawn_parent.get_children():
		if child is Player:
			var p := child as Player
			# Practice targets are also `is_bot`, but they are not roster bots:
			# "Remove all bots" must leave them standing.
			if p.is_bot and not p.is_practice_target and not p.is_queued_for_deletion():
				names.append(str(p.name))
	for entity_id in names:
		remove_bot(entity_id)


func remove_bot(entity_id: String) -> void:
	var bot = spawn_parent.find_child(entity_id, false, false)
	if bot:
		bot.queue_free()
	Leaderboard.request_remove_player(entity_id)
	# Drop it from the persistent manual-bot roster so it isn't re-created.
	for i in range(GameManager.lobby_bots.size() - 1, -1, -1):
		if GameManager.lobby_bots[i].get("name", "") == entity_id:
			GameManager.lobby_bots.remove_at(i)
	
	
	
	
## Keep a manual bot's persisted roster entry in step after its loadout, team or
## skill was edited from the dev menu.  Autofill bots have no entry; that is a
## no-op.
func update_lobby_bot_entry(bot_name: String) -> void:
	var bot := GameManager.find_player(bot_name)
	if bot == null:
		return
	for entry in GameManager.lobby_bots:
		if entry.get("name", "") == bot_name:
			entry["character_path"] = bot._loadout_character_path
			entry["primary_path"] = bot._loadout_primary_path
			entry["secondary_path"] = bot._loadout_secondary_path
			entry["melee_path"] = bot._loadout_melee_path
			entry["team"] = int(bot.team)
			var bc := bot.get_node_or_null("BotController") as BotController
			if bc != null:
				entry["skill"] = bc.skill
				entry["trait_overrides"] = bc.get_bot_trait_overrides()
			return


# At the top — point these at your actual class resources
const BOT_CLASSES: Array[String] = [
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assistance.tres",
]
## Every newly spawned bot starts at full skill.  The dev menu can change it
## afterwards; Randomize bot skills is the only thing that rolls it.
const DEFAULT_BOT_SKILL: float = 1.0

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
	bot.player_id = 0
	bot.owner_peer_id = 1
	bot.team = team  # set BEFORE add_child so _ready() sees correct team
	bot.set_multiplayer_authority(1)
	bot.spawn_manager = self
	# Explicit rather than relying on the scene default: every new bot starts
	# with a full skill dial, and only the dev menu's Randomize button rolls it.
	var bc := bot.get_node_or_null("BotController") as BotController
	if bc != null:
		bc.skill = DEFAULT_BOT_SKILL
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

	var spawn_tf: Transform3D = player._get_spawn_transform()
	player.rpc_reset.rpc(spawn_tf)

	return {
		"character_path": character.resource_path if character else "",
		"primary_path": primary.resource_path,
		"secondary_path": secondary.resource_path,
		"melee_path": melee.resource_path if melee else "",
		"skill": DEFAULT_BOT_SKILL,
		"trait_overrides": {},
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

	var bc := player.get_node_or_null("BotController") as BotController
	if bc != null:
		bc.set_bot_skill(float(entry.get("skill", DEFAULT_BOT_SKILL)))
		bc.set_bot_trait_overrides(entry.get("trait_overrides", {}))

	var spawn_tf: Transform3D = player._get_spawn_transform()
	player.rpc_reset.rpc(spawn_tf)


func _apply_bot_weapons(player: Player, primary: Weapon, secondary: Weapon, melee: Weapon) -> void:
	var controller: WeaponController = player.get_node("WeaponController")
	if controller == null:
		return
	var new_weapons: Array[Weapon] = []
	new_weapons.append(primary.duplicate(true) as Weapon)
	new_weapons.append(secondary.duplicate(true) as Weapon)
	if melee:
		new_weapons.append(melee.duplicate(true) as Weapon)
	# apply_loadout, not set_weapons: the bots' rpc_reset() below would otherwise
	# cancel the pending model swap and leave the previous weapon in hand.
	controller.apply_loadout(new_weapons)


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
