extends Node
class_name PracticeTarget

## Server-only driver for one stationary, non-AI practice target.
##
## A target is a **real [Player]** instantiated from `player.tscn`, so it rides
## the normal pipeline: hurtboxes resolve to a Player, `GameManager.find_player`
## finds it, health bars/ragdolls/replication already work, and every peer can
## damage it.  What makes it a practice target is:
##
## * `is_bot = true` — no input gathering, no first-person HUD, no cameras, and
##   the server keeps authority over the body.
## * `is_practice_target = true` — a replicated flag the rest of the game uses to
##   exclude it from score, team counts, rosters, bot targeting and spectators.
## * `BotController` is removed before the node enters the tree.  This is the
##   "completely different script": the target stands still and never thinks.
## * `spawn_transform_provider` decides where it respawns (a marker, or the next
##   random point inside a range).
##
## **Parent this controller to the map marker / range, never to `SpawnParent`**:
## the world `MultiplayerSpawner` only accepts `player.tscn` there, and a plain
## Node added under it would be rejected or ignored.  The Player it drives lives
## under `SpawnParent` like every other Player.

signal died(changer: String)

const PLAYER_SCENE := preload("res://player/player.tscn")

static var _next_id: int = 0

var player: Player = null


## Spawns the target.  [param provider] must return a `Transform3D` and is
## polled only on the server, at spawn and on every death.  Returns the Player.
func spawn(spawn_parent: Node, provider: Callable,
		name_prefix: String = "dummy") -> Player:
	if not multiplayer.is_server() or not is_instance_valid(spawn_parent):
		return null
	if not provider.is_valid():
		push_error("PracticeTarget.spawn: invalid spawn provider")
		return null
	if player != null and is_instance_valid(player):
		return player

	var p := PLAYER_SCENE.instantiate() as Player
	if p == null:
		push_error("PracticeTarget.spawn: player scene did not instantiate a Player")
		return null

	p.name = "practice_%s_%d" % [name_prefix, _next_id]
	_next_id += 1
	# Everything below must be set before add_child; Player._ready() reads them.
	p.is_bot = true
	p.is_practice_target = true
	p.team = Player.Team.FFA
	p.player_id = 0
	p.owner_peer_id = 1
	# Respawn timing is the fixed `Player.PRACTICE_RESPAWN_DELAY`, not
	# `respawn_time`: every peer must agree, and it must not be 0 (rollback).
	p.spawn_transform_provider = provider
	p.set_multiplayer_authority(1)

	# Strip the AI before it can run _ready() (which adds it to the bot list and
	# connects sound/game-mode signals).  Player never requires it.
	var bc := p.get_node_or_null("BotController")
	if bc != null:
		p.remove_child(bc)
		bc.free()

	spawn_parent.add_child(p)
	p.attribute_component.practice_target_died.connect(_on_practice_target_died)
	player = p

	# Immediate spawn: a marker-placed dummy must be standing on map load, and a
	# range target must be killable on the same frame the run starts.
	p.rpc_spawn_now.rpc(provider.call())
	return p


## Re-point where the next respawn happens.  Used when a range re-arms its run.
func set_spawn_provider(provider: Callable) -> void:
	if player != null and is_instance_valid(player):
		player.spawn_transform_provider = provider


func free_target() -> void:
	if player != null and is_instance_valid(player):
		player.queue_free()
	player = null


func _on_practice_target_died(changer: String) -> void:
	died.emit(changer)


func _exit_tree() -> void:
	# Map swap / range teardown must not leave a Player in SpawnParent behind.
	free_target()
