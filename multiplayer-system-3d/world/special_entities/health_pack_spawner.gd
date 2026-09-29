extends Node3D
class_name HealthPackSpawner

## Holds one [HealthPack] and brings it back [member respawn_time] seconds after a
## player takes it. Starts the map with the pack already there. Placeable in
## TrenchBroom — see `trenchbroom/entities/health_pack_spawner.tres`.
##
## [b]The pack is authored under this node and toggled available; nothing is
## instantiated at runtime, deliberately.[/b] A `MultiplayerSpawner` inside a map
## cannot place a node into a client that is still receiving that map: the map itself
## arrives through `world/world1.tscn`'s spawner, so a client's own spawner is created
## *while* the map is being instantiated, after the host added the pack — and
## `MultiplayerSpawner` only replicates `node_added` events it sees live, replaying
## nothing. The initial pack would therefore be missing for every peer that joined
## before the map swap, which is the normal case. Keeping the pack in the scene gets
## it to every peer with the map for free and leaves only a boolean to sync. The same
## reasoning applies to any future "spawned" node that lives inside a map; see
## docs/02-netcode.md §6.
##
## Availability rides a reliable RPC rather than a `MultiplayerSynchronizer` property:
## it changes at most twice per pickup, so there is nothing to interpolate and no
## reason to pay for a synced property every frame.

@export var respawn_time: float = 10.0

@onready var _pack: HealthPack = $HealthPack
@onready var _respawn_timer: Timer = $RespawnTimer


func _ready() -> void:
	_respawn_timer.one_shot = true
	_respawn_timer.wait_time = maxf(respawn_time, 0.01)
	_respawn_timer.timeout.connect(_on_respawn_timeout)

	_pack.consumed.connect(_on_pack_consumed)

	# Only a real client has something to ask. The test is peer id, not `is_server()`,
	# because an **offline peer reports `is_server()` as false while still being peer
	# 1** — `NetworkEvents` documents exactly that — so on a second instance sitting in
	# a lobby it would try to RPC itself. Peer 1 is the host by definition here, which
	# is the same rule the HostServer zone gates on.
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
		# A client starts from the scene default and asks the host for the truth: a
		# pack consumed before this client joined is on a cooldown that nothing else
		# would tell it about, because `phase_changed` is not replayed to a late joiner
		# either (the 10 Hz state sync writes the phase without emitting it).
		_request_availability.rpc_id(1)
		return

	# The host, or a peer with nobody to ask. `maps/map_thumbnail_generator.tscn`
	# renders every map and so runs every entity's `_ready` with no peer at all, which
	# is the other half of why this is not an unconditional `rpc_id(1, ...)`.
	_connect_round_reset()


## Hooks the round-start reset.
##
## `Map._enter_tree()` (`maps/map.gd:17-18`) sets the global before any descendant's
## `_ready`, so it is live on every path a map is built — boot, `load_match_map`, and a
## client's spawner-driven instantiation. It is *not* cleared when the lobby tears its
## world down, though, so a freed component still compares unequal to null in
## GDScript; `is_instance_valid` is the check that actually holds
## (`network/network_manager.gd:666-672`). With no component there are simply no phase
## events and the pack never round-resets, which is the MAIN_MENU case.
func _connect_round_reset() -> void:
	var gmc := GameManager.game_mode_component
	if not is_instance_valid(gmc):
		return
	gmc.phase_changed.connect(_on_phase_changed)


## Strictly idempotent: the host sees every transition twice — once from the
## `phase_changed.emit` in `_transition_phase`, and again through the
## `call_local` `_rpc_sync_phase` it fires immediately after
## (`components/game_mode_component.gd:431-432`).
func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	if new_phase != GameModeComponent.PhaseState.SETUP:
		return
	_restore_pack()


## The only state this node owns, applied on every peer. `authority` means only the
## host may call it, which is what keeps a client from desyncing itself.
@rpc("authority", "call_local", "reliable")
func _set_available(available: bool) -> void:
	_pack.set_available(available)


## A joining client asking where the pack stands. Answered only by the host, and only
## about its own pack.
@rpc("any_peer", "call_remote", "reliable")
func _request_availability() -> void:
	if not multiplayer.is_server():
		return
	_set_available.rpc_id(multiplayer.get_remote_sender_id(), _pack.is_available())


## Emitted by the pack server-side only — its `_physics_process` returns early on
## every other peer, so this cannot run on a client.
func _on_pack_consumed() -> void:
	_set_available.rpc(false)
	_respawn_timer.start()


func _on_respawn_timeout() -> void:
	_set_available.rpc(true)


## Available now, cooldown cancelled. Used by the round-start reset.
##
## The early return is what makes that reset idempotent in practice rather than just
## on paper: the host sees each transition twice, and a pack that is already there
## should not spend either RPC saying so. Available implies the timer is stopped —
## it only runs while the pack is away — but the stop comes first anyway, so a future
## path that respawns early cannot leave one running.
func _restore_pack() -> void:
	_respawn_timer.stop()
	if _pack.is_available():
		return
	_set_available.rpc(true)
