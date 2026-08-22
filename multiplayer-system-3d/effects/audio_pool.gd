class_name AudioPool
extends RefCounted

## Minimal object pool for one-shot AudioStreamPlayer3D nodes.
##
## Every shot / footstep / hit used to allocate a fresh AudioStreamPlayer3D and
## free it on `finished`.  With many bots firing that's thousands of node
## allocations per second — pure GC churn.  This recycles finished players.
##
## Use:  AudioPool.play(parent, stream, global_transform, pitch_scale)

const MAX_POOL: int = 32

static var _pool: Array[AudioStreamPlayer3D] = []


static func play(parent: Node, stream: AudioStream, at: Transform3D, pitch: float = 1.0, volume_db: float = 0.0, unit_size: float = 1.0) -> void:
	if stream == null or parent == null:
		return

	var player: AudioStreamPlayer3D = null
	while not _pool.is_empty():
		player = _pool.pop_back()
		if is_instance_valid(player):
			break
		player = null

	if player == null:
		player = AudioStreamPlayer3D.new()
		player.finished.connect(_return_to_pool.bind(player))

	player.stream = stream
	parent.add_child(player)
	# Set the world transform AFTER parenting so it converts to local correctly
	# when the parent is a Node3D (avoids the transform being applied twice).
	player.global_transform = at
	player.pitch_scale = pitch
	player.volume_db = volume_db
	player.unit_size = unit_size
	player.play()


static func _return_to_pool(player: AudioStreamPlayer3D) -> void:
	if not is_instance_valid(player):
		return
	var p := player.get_parent()
	if p != null:
		p.remove_child(player)
	if _pool.size() < MAX_POOL:
		_pool.append(player)
	else:
		player.queue_free()
