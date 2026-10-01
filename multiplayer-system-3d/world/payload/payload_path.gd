extends Path3D
class_name PayloadPath

## The route a payload cart rides, compiled from a chain of [PayloadPathPoint]s.
##
## Nothing places this by hand.  [PayloadPathBuilder.ensure_path] instantiates
## `payload_path.tscn`, fills in the curve from the chain, and drops it under the `Map` —
## which is why the three maps that predate the TrenchBroom entities still carry a plain
## `Path3D` instead: this is a strict superset of one, and
## [PayloadNode] reaches its follower through `path_follower.get_parent()` either way.
##
## Structure, all authored in `payload_path.tscn`:
##
## [codeblock]
## PayloadPath      (Path3D, group "payload_path")
##   PayloadFollower (PathFollow3D)  — the cart rides this
##   PathLine        (PayloadPathLine) — the glowing red route
## [/codeblock]
##
## [b]Everything here is built identically on every peer and must never be gated on
## `multiplayer.is_server()`.[/b] The path, the line and the checkpoints are map furniture,
## like the TrenchBroom brush entities — only the payload's own state is
## server-authoritative.

const GROUP: String = "payload_path"

## Every point of the chain, in order from the head.  Written by [method configure].
var path_points: Array[PayloadPathPoint] = []

## One entry per path point: `{ "start": float, "rollback": bool, "rollforward": bool }`,
## where `start` is the normalised curve offset that stretch begins at.  A stretch runs to
## the next entry, and the last one to the end of the route.
var zones: Array[Dictionary] = []

@onready var follower: PathFollow3D = $PayloadFollower
@onready var line: PayloadPathLine = $PathLine


## Fills in the chain and everything derived from it.  Called once, by
## [PayloadPathBuilder], immediately after the curve has been set.
func configure(points: Array[PayloadPathPoint]) -> void:
	path_points = points

	follower.loop = false
	# [b]`ROTATION_XYZ`, not `ROTATION_Y`.[/b] The latter locks the follower's up vector to
	# world up, which yaws the cart to face along the route but leaves it level however steep
	# the route gets — a cart climbing a ramp would sit parallel to the ground rather than to
	# the track. `ROTATION_XYZ` takes the whole basis from the curve, so the cart pitches with
	# the slope. The cart's transform is derived from the follower on every peer and from the
	# same replicated `progress`, so nothing about this needs syncing.
	#
	# It also means the cart *rolls* wherever the curve banks. Godot builds the curve's up
	# vectors to minimise that, so a route that only turns in the horizontal plane stays
	# level, but a route with vertical variation can accumulate some. If a cart is ever seen
	# leaning sideways, that is where it comes from.
	follower.rotation_mode = PathFollow3D.ROTATION_XYZ

	_rebuild_zones()
	line.rebuild(self)


## The stretch of route [param ratio] falls in, or an empty dictionary when this path has
## no zones at all — which is the pre-entity case, and the caller reads an empty result as
## "rollback allowed, no rollforward", i.e. exactly the behaviour those maps already had.
func zone_at(ratio: float) -> Dictionary:
	if zones.is_empty():
		return {}

	var found: Dictionary = zones[0]
	for zone in zones:
		if ratio + 0.0001 >= float(zone["start"]):
			found = zone
		else:
			break
	return found


## Moves the cart and shortens the line to match.  Both are local presentations of the same
## already-replicated progress, so this is safe to call on any peer at any time.
func set_progress(ratio: float) -> void:
	var clamped: float = clampf(ratio, 0.0, 1.0)
	follower.progress_ratio = clamped
	line.set_progress(clamped)


## Normalised offset of each chain point along the baked curve, and the zone flags that
## stretch carries.
##
## The offset is a projection, not `index / (count - 1)`: a Catmull-Rom spline through
## unevenly spaced waypoints does not put equal arc length between them, and a stretch
## whose real-world length is misreported would misplace every checkpoint after it.  This
## is the same `get_closest_offset` projection `PayloadNode` has always used.
func _rebuild_zones() -> void:
	zones.clear()
	if curve == null:
		return

	var baked_length: float = curve.get_baked_length()
	if baked_length <= 0.0:
		return

	for point in path_points:
		var offset: float = curve.get_closest_offset(to_local(point.global_position))
		var ratio: float = offset / baked_length
		# Cached on the point so the zone table and the payload agree on where it sits.
		point.path_offset = ratio
		zones.append({
			"start": ratio,
			"rollback": point.rollback_zone,
			"rollforward": point.rollforward_zone,
		})
