@tool
extends Path3D
class_name PayloadPath

## The route a payload cart rides, compiled from a chain of [PayloadPathPoint]s.
##
## [b]The node is a shell; only its curve is baked.[/b]  [PayloadPathBuilder.bake_path] writes
## it into the map scene at editor time — instantiating `payload_path.tscn`, filling in the
## curve from the chain, and dropping it under the `Map` — so the route is visible and editable
## rather than appearing only at runtime.  The curve is the whole of what it owns: the derived
## half ([member path_points], [member zones] and the [member line] mesh) is stripped before the
## save and rebuilt on every peer by [method configure].  That split is deliberate — see
## [method strip_derived] — and it means this is still, in the parts that matter, map furniture
## every peer derives for itself.
##
## Maps that predate the TrenchBroom entities still carry a plain `Path3D` instead: this is a
## strict superset of one, and [PayloadNode] reaches its follower through
## `path_follower.get_parent()` either way.
##
## Structure, all authored in `payload_path.tscn`:
##
## [codeblock]
## PayloadPath      (Path3D, group "payload_path")
##   PayloadFollower (PathFollow3D)  — the cart rides this
##   PathLine        (PayloadPathLine) — the glowing red route
## [/codeblock]
##
## [b]The derived half is built identically on every peer and must never be gated on
## `multiplayer.is_server()`.[/b] The path, the line and the checkpoints are map furniture,
## like the TrenchBroom brush entities — only the payload's own state is
## server-authoritative.
##
## [b]This is a `@tool` script, and it has to be.[/b] The node is *written* by editor-side code:
## [PayloadPathBuilder.bake_path] and [Map]'s save/exit hooks both call [method strip_derived]
## on it. Godot instantiates a script that is not in tool mode as a **placeholder** in the
## editor — an object with the right class and `class_name`, but no methods whatsoever — so
## those calls died with "Attempt to call a method on a placeholder instance"
## (`05-known-issues.md` #102). Nothing here runs while the editor has the map open: there is
## no `_ready`, no `_process`, and [method configure] is only ever reached from the game. The
## annotation exists purely to make the script real on the editor side.

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


## Drops everything derived from the curve, so none of it reaches the `.tscn`.
##
## The tube mesh is the important half: it is a generated [ArrayMesh] plus a [ShaderMaterial],
## and as a node property it would serialize into every map scene that carries a route — the
## same trade [ToonMaterialConverter] makes, for the same reason.  [member zones] and
## [member path_points] are not `@export`, so they would not serialize anyway; clearing them
## keeps the in-memory object honest against what is on disk.
##
## Called by [PayloadPathBuilder.bake_path] and by the Map's save hook.  The route is rebuilt
## from it by [method configure] on every peer at load.
func strip_derived() -> void:
	# Guarded rather than assigned blind: `mesh` is a stored property, so writing it marks the
	# scene dirty even when the value is unchanged — and this runs on every save.
	if line.mesh != null:
		line.mesh = null
	zones.clear()
	path_points.clear()


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
