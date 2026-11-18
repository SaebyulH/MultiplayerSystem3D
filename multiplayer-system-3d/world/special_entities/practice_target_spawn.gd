@tool
extends Marker3D
class_name PracticeTargetSpawn

## Placeable practice dummy.
##
## Drop this scene into any map.  On the server it spawns one stationary,
## non-AI target at the marker's position and yaw, and that target respawns here
## after each death.  The dummy itself is a regular [Player], so every peer can
## damage it through the normal damage pipeline.
##
## The mannequin child is editor-only decoration, like [PlayerSpawn]'s: it shows
## where the dummy will stand and is hidden the moment the game runs.
##
## The server check is deliberately `multiplayer.is_server()`, the same rule the
## rest of the simulation uses.  An offline lobby peer reports true here, which
## is what makes the dummy spawn in the single-player shell; a client's copy of
## the map never spawns anything.

var _target: PracticeTarget = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	hide()
	# No peer at all (map thumbnail generation) or a client: nothing to spawn.
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	if not is_instance_valid(GameManager.spawn_parent):
		return

	_target = PracticeTarget.new()
	_target.name = "PracticeTargetController"
	add_child(_target)
	_target.spawn(GameManager.spawn_parent, Callable(self, "_spawn_transform"),
		"dummy")


func _exit_tree() -> void:
	if is_instance_valid(_target):
		_target.free_target()
		_target = null


## Position and yaw only.  A scaled or tilted marker must not leak scale or pitch
## into the player transform — same rule as `Map.get_random_spawn_transform`.
func _spawn_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, rotation.y), global_position)
