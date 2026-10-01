extends Marker3D
class_name PayloadCheckpointVisual

## A payload checkpoint marker.  Placeable in TrenchBroom as the `PayloadCheckpoint`
## entity — see `trenchbroom/entities/payload_checkpoint.tres`.
##
## [b]It does not have to sit on the track.[/b] A checkpoint's position only ever mattered
## as a place to project onto the route (`PayloadNode._world_pos_to_path_progress`), so this
## projects itself once at load and drops a helper [PathFollow3D] onto the path at the
## closest point, then takes that follower's transform.  A mapper can drop these roughly
## beside the route and they land squarely on it.
##
## [b]Two layouts, and the old one is left completely alone.[/b]
##
##   * [b]Parent is already a [PathFollow3D][/b] — how the three hand-authored maps
##     (`castle`, `esc_castle`, `hyb_castle`) are built, with the follower's `progress`
##     dialled in by eye.  That follower [i]is[/i] the helper, so nothing is created and
##     nothing moves.  These maps behave exactly as they did before this script had a body.
##   * [b]Anything else[/b] — the entity case.  Build the helper, then snap.
##
## The snap is a single transform copy rather than a re-parent: the checkpoint stays where
## the map put it in the tree, and there is no reason to mutate the tree while the map is
## still running its `_ready` pass.

## The follower this checkpoint rides — the existing parent in the old layout, a generated
## one in the new.  `null` until [method ensure_resolved] has run, and permanently if the
## map has no route at all.
var _helper: PathFollow3D = null

var _path: Node = null
var _resolved: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Deferred for the same reason the path points defer: the route may not have been
	# compiled yet, and whoever gets there first builds it.  `PayloadNode` calls
	# [method ensure_resolved] directly when it wants the answer sooner, so nothing here
	# depends on this particular call winning the race.
	ensure_resolved.call_deferred()


## Resolves this checkpoint onto the route, once.  Idempotent, and safe to call from any
## peer — a checkpoint is map furniture, not state, so none of this is gated or networked.
##
## Returns the route it landed on, or `null` when the map has none.
func ensure_resolved() -> Node:
	if _resolved:
		return _path
	_resolved = true

	var parent := get_parent()
	if parent is PathFollow3D:
		_helper = parent
		_path = parent.get_parent()
		return _path

	_path = PayloadPathBuilder.ensure_path(self)
	var path := _path as Path3D
	if path == null or path.curve == null:
		return null

	var baked_length: float = path.curve.get_baked_length()
	if baked_length <= 0.0:
		return null

	_helper = PathFollow3D.new()
	_helper.name = "CheckpointFollower"
	_helper.rotation_mode = PathFollow3D.ROTATION_Y
	_helper.loop = false

	# Added before `progress` is written, because `PathFollow3D` resolves its transform
	# against the curve when it enters the tree.
	path.add_child(_helper)
	_helper.progress = path.curve.get_closest_offset(path.to_local(global_position))

	# This is the whole point of the entity: the marker moves onto the track, so a mapper
	# never has to land it precisely.
	global_transform = _helper.global_transform
	return _path


## Where this checkpoint sits along the route, as a fraction of its baked length.
##
## Reads the follower rather than re-projecting, so it stays exact — and so a checkpoint in
## the old, hand-authored layout reports the `progress` its mapper actually dialled in.
func get_path_ratio() -> float:
	ensure_resolved()
	if _helper == null:
		return 0.0

	var path := _path as Path3D
	if path == null or path.curve == null:
		return 0.0

	var baked_length: float = path.curve.get_baked_length()
	if baked_length <= 0.0:
		return 0.0

	return _helper.progress / baked_length
