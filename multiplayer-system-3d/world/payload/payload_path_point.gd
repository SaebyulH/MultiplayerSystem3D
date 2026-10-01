extends Node3D
class_name PayloadPathPoint

## One waypoint of a payload route.  Placeable in TrenchBroom as the `PayloadPathPoint`
## entity — see `trenchbroom/entities/payload_path_point.tres`.
##
## The point itself never becomes anything — [PayloadPathBuilder] collects every path point
## at map load and compiles them into a single [PayloadPath], so a mapper authors waypoints
## and the engine builds the spline.  Nothing here is networked, because nothing here is
## state: the route is baked from map data that every peer already has.
##
## [b]You do not have to link the points together.[/b] By default the route is simply the
## points in the order you placed them — draw them front to back and they connect
## themselves.  [member target] and [member targetname] are only needed for the cases
## placement order cannot express; see [method PayloadPathBuilder.build_chain].
##
## [b]The point's origin is the bottom of its marker[/b], so dropping one on the floor puts
## the route on the floor.  The marker is authoring decoration and is hidden at runtime.
##
## [b]The two zone flags are stretch flags, not point markers.[/b] A flag set on a point
## applies from that point until the next one on the route — see [method
## PayloadPath.zone_at].  Both may be set on one point: they are independent axes, since
## `rollforward` only governs driving with nobody pushing and `rollback` only governs the
## unattended drift back.

## Name for this point.
##
## [b]Only read when the map uses an explicit chain[/b] — that is, when some point in it
## sets [member target].  Otherwise the route is placement order and names do nothing.
@export var targetname: String = ""

## `targetname` of the **next** point on the route.  Empty ends the route.
##
## [b]Leave this empty unless you need to override placement order.[/b] Setting it on any
## point switches the whole map from "connect the points in the order they were placed" to
## an explicit chain, exactly like Quake's `path_corner` or TF2's `path_track`.  That is
## what a route needs when its points were not drawn in order, when a leg has to run
## somewhere other than the next point, or when a loop is wanted.
##
## A plain [String] rather than a `NodePath`, deliberately.  `target_base.tres` declares its
## `target` as a `NodePath` so TrenchBroom offers a `target_destination` picker, but
## func_godot hands that back as a `NodePath` and `entity_assembler.gd` reports a type
## mismatch rather than coercing — the chain is resolved by our own string walk anyway, so
## the picker would buy nothing and cost a silent build error.
@export var target: String = ""

## Rollback starts the instant the cart is unattended here, instead of after
## [member PayloadNode.return_delay].
##
## [b]It is an intensifier, not a permission.[/b] Every stretch of every route rolls the cart
## back once it has been left alone for `return_delay` seconds — that is the base behaviour,
## including on the maps that predate these entities.  A rollback zone simply removes the
## wait, so the cart slides back the moment nobody is on it, the way something on a slope
## would.  Use it for a downhill leg you want contested continuously.
@export var rollback_zone: bool = false

## From here to the next point, the cart drives itself forward even with nobody on it.
@export var rollforward_zone: bool = false

## Normalised offset of this point along the compiled curve (0..1), or -1.0 while the route
## has not been built.  Written by [method PayloadPath._rebuild_zones]; read by anything
## that needs to talk about the route in progress terms.
var path_offset: float = -1.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# The marker is authoring decoration, like `PlayerSpawn`'s mannequin — a running game
	# shows nothing at a waypoint.
	hide()

	# Deferred, not immediate: the route cannot be compiled until every point in the map has
	# entered the tree, because the chain is discovered by scanning for them.  Deferring
	# also means the build happens after the whole map subtree has run `_ready`, which is
	# what lets a checkpoint re-parent nothing and still land in the right place.
	#
	# Every point calls this, and [method PayloadPathBuilder.ensure_path] is idempotent, so
	# it does not matter which one gets there first — or whether the payload beat them all.
	_ensure_path.call_deferred()


func _ensure_path() -> void:
	PayloadPathBuilder.ensure_path(self)
