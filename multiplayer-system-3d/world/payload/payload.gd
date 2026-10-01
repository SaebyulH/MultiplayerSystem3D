extends AnimatableBody3D
class_name PayloadNode

# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

## Which [GameModeComponent] this cart belongs to.
##
## Optional.  TrenchBroom cannot author a `NodePath`, so the `Payload` entity leaves this
## unset and `_ready()` falls back to `GameManager.game_mode_component` — the same route
## `ControlPoint` and `HealthPackSpawner` take.  A hand-authored map still wires it directly.
@export var game_mode_component: GameModeComponent

## The [PathFollow3D] the cart rides.
##
## Optional as well, and for the same reason: on a map built from `PayloadPathPoint`s the
## route does not exist until it is compiled at load, so `_ready()` resolves it.  Setting it
## explicitly (as `castle`, `esc_castle` and `hyb_castle` do) skips both that and checkpoint
## discovery, and wins over them.
@export var path_follower: PathFollow3D

## Checkpoints in route order.
##
## Optional override, like [member path_follower].  Left empty — the `Payload` entity's
## case — it is filled in from the [PayloadCheckpointVisual] nodes in the map, sorted by
## where they sit along the route.
@export var checkpoints: Array[Marker3D] = []
@export var attacking_team: Player.Team = Player.Team.SPI

@export var push_radius: float = 3.0
## Base push speed with 1 attacker (progress 0..1 per second)
@export var push_speed_base: float = 0.035
## Speed multiplier per pusher count (diminishing returns)
## Index 0 = 1 pusher, index 1 = 2 pushers, etc.
@export var push_speed_curve: Array[float] = [1.0, 1.6, 2.0, 2.3, 2.5]
@export var max_push_players: int = 3

@export var return_speed: float = 0.005
@export var return_delay: float = 10.0

## Progress units per second while the cart is in a `rollforward_zone` stretch with nobody
## on it.  The route drives itself there; see [PayloadPathPoint.rollforward_zone].
@export var rollforward_speed: float = 0.02

@export var vertical_offset: Vector3 = Vector3.ZERO
@export var heal_per_second: float = 10.0

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal checkpoint_reached(index: int)
signal payload_delivered()
signal push_started()
signal push_stopped()

# ─────────────────────────────────────────────
#  STATE
# ─────────────────────────────────────────────

enum PayloadState {
	LOCKED,
	IDLE,
	PUSHING,
	CONTESTED,
	RETURNING,
	AT_CHECKPOINT,
	DELIVERED,
	## Driving itself through a `rollforward_zone` stretch with nobody on it.
	ROLLFORWARD,
}

var payload_state: PayloadState = PayloadState.LOCKED
var progress: float = 0.0
var is_delivered: bool = false
var is_locked: bool = true

## Read by GameModeComponent / HybridMode for overtime/contested checks
var is_contested: bool = false
var is_being_pushed: bool = false

var _return_countdown: float = 0.0
var _sync_timer: float = 0.0
## Set by [method _func_godot_apply_properties] so a second build pass cannot convert
## [member vertical_offset] into a 32x offset.
var _offset_converted: bool = false
const PAYLOAD_SYNC_RATE: float = 0.066  # ~15 Hz
var _next_checkpoint_index: int = 0
var _pushers: Array = []

var _checkpoint_progresses: Array[float] = []

## Client only.  Where along the route the cart is *drawn*, eased toward [member progress]
## rather than snapped to it.  See [method _smooth_client_position].
var _display_progress: float = 0.0

## Time constant for that easing, in seconds.  The cart's own speed varies by state and by
## pusher count, so there is no single rate to `move_toward` at; exponential decay converges
## from any of them.  The lag it costs is `SMOOTH_TAU x speed` — about 0.1 x 0.0875 = under 1%
## of the route at three pushers, well inside the 15 Hz replication error it replaces.
const SMOOTH_TAU: float = 0.1

## A correction further ahead than this fraction of the route is a teleport, not travel — a
## late joiner's pulled state, or a reset — and is snapped to instead of eased into.  Well
## clear of what one 15 Hz packet can carry: the fastest the cart moves is 0.0875/s, so a
## packet is worth under 0.006.
const SNAP_THRESHOLD: float = 0.05

@onready var push_zone: Area3D = $PushZone
@onready var label: Label3D = $Label3D
@onready var mesh: MeshInstance3D = $MeshInstance3D

var _mesh_mat: StandardMaterial3D

# ─────────────────────────────────────────────
#  READY
# ─────────────────────────────────────────────

func _ready() -> void:
	# Both of these are optional exports that only a hand-authored map fills in — see the
	# notes on them.  A `Payload` entity leaves them empty and gets them resolved instead.
	if game_mode_component == null:
		game_mode_component = GameManager.game_mode_component
	if not is_instance_valid(game_mode_component):
		push_error("PayloadNode: no GameModeComponent — is this node inside a Map?")
		return

	_mesh_mat = StandardMaterial3D.new()
	mesh.set_surface_override_material(0, _mesh_mat)

	if path_follower == null:
		# The route is compiled from the path points, so it does not exist yet: this runs
		# during the map's own `_ready` pass, before the deferred build has happened.  A
		# `call_deferred` here lands after the whole subtree is up, which is the earliest
		# point every path point is guaranteed to have entered the tree.
		_resolve_generated_route.call_deferred()
	else:
		_bake_checkpoint_progresses()

	_warn_if_duplicate.call_deferred()

	push_zone.body_entered.connect(_on_body_entered)
	push_zone.body_exited.connect(_on_body_exited)

	game_mode_component.phase_changed.connect(_on_phase_changed)
	game_mode_component.round_won.connect(_on_round_won)

	if game_mode_component.game_mode == GameModeComponent.GameMode.HYBRID:
		game_mode_component.hybrid_point_captured_signal.connect(_on_hybrid_point_captured)

	game_mode_component.register_payload(self)

	_snap_to_progress()
	_set_state(PayloadState.LOCKED)

	# The cart's position is not replicated by a `MultiplayerSynchronizer` — `_rpc_sync` at
	# ~15 Hz is the only writer — so a late joiner would sit at the route start until an
	# unreliable packet happened to arrive.  Pull the live state once instead, the way
	# `MovingBrush`, `RotatingBrush`, `ButtonBrush` and `PhysicsBrush` all do.
	if BrushEntityUtil.should_pull_state(self):
		_request_state.rpc_id(1)


## Fills in [member path_follower] and [member checkpoints] from a route compiled out of
## [PayloadPathPoint]s, for a map that did not author either by hand.
##
## Deferred from [method _ready], so by the time it runs every path point and every
## checkpoint in the map has entered the tree and the route exists — or never will, if the
## mapper drew no chain.
func _resolve_generated_route() -> void:
	var path := PayloadPathBuilder.ensure_path(self)
	if path == null:
		push_error(
			"PayloadNode: no path_follower and no PayloadPathPoint chain in this map — "
			+ "the cart cannot move.")
		return

	path_follower = path.follower

	# Compaction first, so a `checkpoints` array whose `NodePath`s no longer resolve counts
	# as empty rather than as "already authored" and skips discovery.
	_bake_checkpoint_progresses()
	if checkpoints.is_empty():
		checkpoints = _discover_checkpoints(path)
		_bake_checkpoint_progresses()

	_apply_position_to_path()
	_update_path_line()
	_update_visuals()


## Warns when a map carries more than one cart.
##
## Two [PayloadNode]s both register with the `GameModeComponent` and both ride the same
## route, so the map gets two carts moving in lockstep while whichever registered last owns
## the mode's payload reference. Nothing about that reads as a bug from in-game — it reads
## as a duplicated payload. It is what a map ends up with when a rebuild adds a `Payload`
## entity to a map that already had a hand-placed cart: the build only owns the subtree
## under its `FuncGodotMap`, so the old cart, sitting at the map root, survives the rebuild
## beside the new one.
func _warn_if_duplicate() -> void:
	var root := PayloadPathBuilder.map_root(self)
	if root == null:
		return

	var carts := 0
	for node in root.find_children("*", "", true, false):
		if node is PayloadNode:
			carts += 1

	if carts > 1:
		push_warning(
			"PayloadNode: this map has %d payload carts, and they will all ride the route "
			% carts
			+ "and register with the GameModeComponent. Delete the spare — a map authored "
			+ "with the Payload entity should have exactly one, and any other is a "
			+ "hand-placed cart that survived a rebuild.")


## Every [PayloadCheckpointVisual] on this route, ordered along it.
##
## Order comes from the route rather than from the map's node order, which is the only
## ordering that matches what the player sees: a checkpoint further along the route is
## always later, whatever order the entities happen to sit in the scene.
func _discover_checkpoints(path: PayloadPath) -> Array[Marker3D]:
	var found: Array[Marker3D] = []
	var root := PayloadPathBuilder.map_root(self)
	if root == null:
		return found

	for node in root.find_children("*", "", true, false):
		var checkpoint := node as PayloadCheckpointVisual
		if checkpoint != null and checkpoint.ensure_resolved() == path:
			found.append(checkpoint)

	found.sort_custom(func(a: Marker3D, b: Marker3D) -> bool:
		return (a as PayloadCheckpointVisual).get_path_ratio() \
			< (b as PayloadCheckpointVisual).get_path_ratio())
	return found


## Derives each checkpoint's position along the route, and drops any entry that is no
## longer a live object.
##
## [b]That compaction is not defensive coding — an authored `checkpoints` array goes
## [i]null[/i], not empty, when the nodes its `NodePath`s named are replaced.[/b] Rebuilding
## a TrenchBroom map regenerates the `FuncGodotMap` subtree, so a map that used to carry
## hand-placed `PathFollow3D` checkpoint anchors ends up with `checkpoints = [null, null, …]`
## and a `path_follower` that resolved to nothing. Reading a property off one of those nulls
## is an immediate crash on map load, and skipping the compaction makes it worse than that:
## a non-empty array of garbage would also stop [method _resolve_generated_route] from
## discovering the checkpoints the map now actually has.
func _bake_checkpoint_progresses() -> void:
	var live: Array[Marker3D] = []
	for cp in checkpoints:
		if is_instance_valid(cp):
			live.append(cp)
	if live.size() != checkpoints.size():
		push_warning(
			"PayloadNode: %d of %d checkpoints are missing — a NodePath in the "
			% [checkpoints.size() - live.size(), checkpoints.size()]
			+ "'checkpoints' array no longer resolves, most likely because the map was "
			+ "rebuilt. They have been dropped.")
	checkpoints = live

	_checkpoint_progresses.clear()
	for cp in checkpoints:
		# A checkpoint knows exactly where it sits, because it put itself there: it projects
		# onto the route once at load.  Deriving it again from the checkpoint's world
		# position — which is what this used to do — read a position that the projection had
		# only approximated, so nudging the curve silently moved every checkpoint.
		var checkpoint := cp as PayloadCheckpointVisual
		if checkpoint != null:
			_checkpoint_progresses.append(checkpoint.get_path_ratio())
		else:
			_checkpoint_progresses.append(_world_pos_to_path_progress(cp.global_position))

# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func set_locked(locked: bool) -> void:
	is_locked = locked
	if is_locked:
		_set_state(PayloadState.LOCKED)

# ─────────────────────────────────────────────
#  PROCESS
# ─────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		# Clients do not simulate the cart, but they do drive its transform — see
		# `_apply_position_to_path`, which the RPC no longer calls.
		_smooth_client_position(delta)
		return
	# The route is resolved from a `call_deferred`, so a cart that never got one — a map
	# with no chain — must not be ticked into a null deref.
	if path_follower == null:
		return
	if is_delivered or is_locked:
		return

	_tick_healing(delta)

	var attackers := _count_team(attacking_team)
	var defenders := _count_team(_get_defending_team())

	# ── Update readable flags ─────────────────
	is_being_pushed = attackers > 0 and defenders == 0
	is_contested    = attackers > 0 and defenders > 0

	# ── Determine new state ───────────────────
	var new_state: PayloadState

	if attackers > 0 and defenders == 0:
		new_state = PayloadState.PUSHING
	elif attackers > 0 and defenders > 0:
		new_state = PayloadState.CONTESTED
	else:
		is_being_pushed = false
		is_contested    = false
		if _zone_flag("rollforward", false):
			# A conveyor stretch: the route drives the cart whether or not anyone is on it.
			_return_countdown = return_delay
			new_state = PayloadState.ROLLFORWARD
		else:
			# [b]Every stretch rolls back; a `rollback_zone` is where it starts at once.[/b]
			# Left alone, the cart waits out `return_delay` before it begins to drift — the
			# unconcerned timeout.  Inside a rollback zone there is no wait at all, so the
			# cart slides back the moment it is unattended, the way something on a slope
			# would.  The flag is therefore an intensifier rather than a permission, and a
			# route with no flags anywhere behaves exactly like the pre-entity maps.
			if _zone_flag("rollback", false):
				_return_countdown = 0.0
			if _return_countdown > 0.0:
				_return_countdown -= delta
				new_state = PayloadState.IDLE
			else:
				var checkpoint_floor := _get_checkpoint_floor()
				if progress > checkpoint_floor + 0.0005:
					new_state = PayloadState.RETURNING
				else:
					new_state = PayloadState.AT_CHECKPOINT

	# ── Apply movement ────────────────────────
	match new_state:
		PayloadState.PUSHING:
			_return_countdown = return_delay
			var speed_mult := _get_speed_multiplier(attackers)
			progress += push_speed_base * speed_mult * delta
			progress = minf(progress, 1.0)
			_check_checkpoints()
			if progress >= 1.0:
				_on_delivered()
				return

		PayloadState.CONTESTED:
			_return_countdown = return_delay

		PayloadState.ROLLFORWARD:
			progress += rollforward_speed * delta
			progress = minf(progress, 1.0)
			_check_checkpoints()
			if progress >= 1.0:
				_on_delivered()
				return

		PayloadState.RETURNING:
			var checkpoint_floor := _get_checkpoint_floor()
			progress -= return_speed * delta
			if progress <= checkpoint_floor:
				progress = checkpoint_floor
				new_state = PayloadState.AT_CHECKPOINT

		PayloadState.AT_CHECKPOINT:
			progress = _get_checkpoint_floor()

	# Captured *before* `_set_state` writes the new value over the old one. Read afterwards,
	# this comparison is always false and the immediate-sync branch below never fires —
	# which is what it used to do, silently costing a state change up to a full sync
	# interval. See `05-known-issues.md` #88.
	var state_changed: bool = new_state != payload_state
	if state_changed:
		_set_state(new_state)

	_sync_position_to_path()
	_update_label()
	_sync_timer += delta
	if state_changed or _sync_timer >= PAYLOAD_SYNC_RATE:
		_sync_timer = 0.0
		_rpc_sync.rpc(progress, payload_state, _return_countdown)

# ─────────────────────────────────────────────
#  SPEED CURVE
# ─────────────────────────────────────────────

func _get_speed_multiplier(attacker_count: int) -> float:
	if attacker_count <= 0:
		return 0.0
	var idx := mini(attacker_count, push_speed_curve.size()) - 1
	idx = mini(idx, max_push_players - 1)
	return push_speed_curve[idx]

# ─────────────────────────────────────────────
#  ZONES
# ─────────────────────────────────────────────

## One of [member PayloadPath.zones]'s flags for the stretch the cart is currently in.
##
## [param fallback] is what a map with no zones at all answers.  Every caller passes the
## **pre-entity behaviour** rather than the flag's own default, so a hand-authored map —
## including the three that predate the TrenchBroom entities, whose route is a plain
## [Path3D] with no path points to carry flags — keeps behaving exactly as it always did.
## For `rollback` that means `false`: nothing is a rollback zone, so the cart waits out
## [member return_delay] like it always has.
func _zone_flag(key: String, fallback: bool) -> bool:
	var path := _path() as PayloadPath
	if path == null:
		return fallback
	return bool(path.zone_at(progress).get(key, fallback))


## The [PayloadPath] this cart rides, or `null` when the route is a plain [Path3D].
func _path() -> Path3D:
	if path_follower == null:
		return null
	return path_follower.get_parent() as Path3D

# ─────────────────────────────────────────────
#  STATE SETTER
# ─────────────────────────────────────────────

func _set_state(new_state: PayloadState) -> void:
	payload_state = new_state
	_update_visuals()

# ─────────────────────────────────────────────
#  HEALING
# ─────────────────────────────────────────────

func _tick_healing(delta: float) -> void:
	# Server only — called after the is_server() guard in _physics_process
	for p in _pushers:
		if p is Player and p.team == attacking_team:
			p.change_health(heal_per_second * delta, p.name)

# ─────────────────────────────────────────────
#  PATH POSITION
# ─────────────────────────────────────────────

## Server.  Writes the cart's whole transform from the follower, so a player standing on it
## is carried rather than shoved — the direct assignment *is* the mechanism, whatever this
## comment previously claimed about `move_and_collide`.
func _sync_position_to_path() -> void:
	path_follower.progress_ratio = progress
	global_transform = _offset_transform(path_follower.global_transform)
	_update_path_line()

## Client.  Same write, from the progress the server pushed down; the cart is never
## simulated on a client.
func _apply_position_to_path() -> void:
	if path_follower == null:
		return
	path_follower.progress_ratio = progress
	global_transform = _offset_transform(path_follower.global_transform)
	_update_path_line()


## Places the cart exactly where [member progress] says it is, with no easing.  For the
## writes that are a teleport rather than travel: load, round reset, and a late joiner's
## pulled state.
func _snap_to_progress() -> void:
	_display_progress = progress
	_apply_position_to_path()


## Eases the cart toward the replicated [member progress] instead of snapping to it.
##
## `progress` arrives on an unreliable RPC at ~15 Hz, so assigning the transform straight
## from it stepped the cart a whole packet's worth at a time — visible stutter, and a
## platform whose position jumps four times then holds still is one that a rider's platform
## carry cannot measure.  `_rpc_sync` therefore only records the target and this, on every
## client physics frame, is what actually moves the cart.  Easing is frame-rate independent
## and settles to the same place.
func _smooth_client_position(delta: float) -> void:
	if path_follower == null:
		return
	if absf(progress - _display_progress) > SNAP_THRESHOLD:
		_snap_to_progress()
		return
	_display_progress = lerp(_display_progress, progress, 1.0 - exp(-delta / SMOOTH_TAU))
	path_follower.progress_ratio = _display_progress
	global_transform = _offset_transform(path_follower.global_transform)
	_update_path_line()

## [member vertical_offset] folded into the follower's transform, in the follower's own
## basis so it rises off the route rather than off the world.
##
## This used to be computed and immediately thrown away — the old line was
## `var target_pos := path_follower.global_position + vertical_offset`, and the very next
## statement assigned `global_transform` from the follower and discarded it — so the export
## did nothing at all.  Every shipped map leaves it at [constant Vector3.ZERO], so hoisting
## a cart off its route is available now without moving anything that exists.
func _offset_transform(base: Transform3D) -> Transform3D:
	if vertical_offset == Vector3.ZERO:
		return base
	var out := base
	out.origin += base.basis * vertical_offset
	return out

## Shortens the route's glowing line to the part still ahead of the cart.
##
## Local presentation of already-replicated progress — no RPC, no server gate — so the line
## tracks the cart on every peer for the cost of one shader uniform.
func _update_path_line() -> void:
	var path := _path() as PayloadPath
	if path != null:
		path.set_progress(progress)

# ─────────────────────────────────────────────
#  CHECKPOINTS
# ─────────────────────────────────────────────

func _check_checkpoints() -> void:
	if _next_checkpoint_index >= _checkpoint_progresses.size():
		return
	var cp_progress := _checkpoint_progresses[_next_checkpoint_index]
	if progress >= cp_progress:
		checkpoint_reached.emit(_next_checkpoint_index)
		_rpc_checkpoint_reached.rpc(_next_checkpoint_index)
		_next_checkpoint_index += 1

func _get_checkpoint_floor() -> float:
	if _next_checkpoint_index == 0:
		return 0.0
	return _checkpoint_progresses[_next_checkpoint_index - 1]

func _world_pos_to_path_progress(world_pos: Vector3) -> float:
	if not path_follower:
		return 0.0
	var path: Path3D = path_follower.get_parent()
	if not path or not path.curve:
		return 0.0
	var closest := path.curve.get_closest_offset(path.to_local(world_pos))
	return closest / path.curve.get_baked_length()

# ─────────────────────────────────────────────
#  DELIVERY
# ─────────────────────────────────────────────

func _on_delivered() -> void:
	is_delivered    = true
	is_being_pushed = false
	is_contested    = false
	progress        = 1.0
	payload_delivered.emit()
	_set_state(PayloadState.DELIVERED)
	_rpc_delivered.rpc()
	if game_mode_component:
		game_mode_component.on_payload_delivered(attacking_team)

# ─────────────────────────────────────────────
#  ROUND RESET
# ─────────────────────────────────────────────

func _on_round_won(_winning_team: Player.Team) -> void:
	pass

# ─────────────────────────────────────────────
#  PHASE HANDLER
# ─────────────────────────────────────────────

func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	if new_phase == GameModeComponent.PhaseState.SETUP:
		_rpc_reset.rpc()

	var is_hybrid := game_mode_component and \
		game_mode_component.game_mode == GameModeComponent.GameMode.HYBRID

	if is_hybrid:
		if not game_mode_component.hybrid_mode or \
				not game_mode_component.hybrid_mode.point_is_captured:
			is_locked = true
			_set_state(PayloadState.LOCKED)
		return

	is_locked = not game_mode_component.is_objective_unlocked()
	if is_locked:
		_set_state(PayloadState.LOCKED)

func _on_hybrid_point_captured() -> void:
	is_locked = false

# ─────────────────────────────────────────────
#  TEAM HELPERS
# ─────────────────────────────────────────────

func _get_defending_team() -> Player.Team:
	match attacking_team:
		Player.Team.SPI: return Player.Team.SCI
		Player.Team.SCI: return Player.Team.SPI
		_:               return Player.Team.FFA

func _count_team(team: Player.Team) -> int:
	var count := 0
	for p in _pushers:
		if p is Player and p.team == team:
			count += 1
	return count

func get_push_progress() -> float:
	return progress

func get_attackers_on_point() -> int:
	return _count_team(attacking_team)

func get_defenders_on_point() -> int:
	return _count_team(_get_defending_team())

# ─────────────────────────────────────────────
#  AREA TRACKING
# ─────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if body is Player and body not in _pushers:
		_pushers.append(body)

func _on_body_exited(body: Node3D) -> void:
	_pushers.erase(body)

# ─────────────────────────────────────────────
#  VISUALS
# ─────────────────────────────────────────────

func _update_visuals() -> void:
	_update_color()
	_update_label()

func _update_color() -> void:
	if not _mesh_mat:
		return
	match payload_state:
		PayloadState.PUSHING:       _mesh_mat.albedo_color = Color.RED
		PayloadState.CONTESTED:     _mesh_mat.albedo_color = Color.ORANGE
		PayloadState.RETURNING:     _mesh_mat.albedo_color = Color.CORNFLOWER_BLUE
		PayloadState.AT_CHECKPOINT: _mesh_mat.albedo_color = Color.YELLOW
		PayloadState.DELIVERED:     _mesh_mat.albedo_color = Color.GREEN
		PayloadState.LOCKED:        _mesh_mat.albedo_color = Color.DARK_GRAY
		PayloadState.ROLLFORWARD:   _mesh_mat.albedo_color = Color(1.0, 0.45, 0.1)
		_:                          _mesh_mat.albedo_color = Color.WHITE

func _update_label() -> void:
	if not label:
		return
	match payload_state:
		PayloadState.DELIVERED:
			label.text = "DELIVERED"
		PayloadState.AT_CHECKPOINT:
			label.text = "CHECKPOINT\n%d%%" % int(progress * 100)
		PayloadState.CONTESTED:
			label.text = "CONTESTED\n%d%%" % int(progress * 100)
		PayloadState.PUSHING:
			var attackers := _count_team(attacking_team)
			var mult      := _get_speed_multiplier(attackers)
			label.text = "PUSHING x%.1f\n%d%%" % [mult, int(progress * 100)]
		PayloadState.RETURNING:
			label.text = "RETURNING\n%d%%" % int(progress * 100)
		PayloadState.ROLLFORWARD:
			label.text = "ROLLING\n%d%%" % int(progress * 100)
		PayloadState.IDLE:
			label.text = "%.1fs\n%d%%" % [_return_countdown, int(progress * 100)]
		PayloadState.LOCKED:
			label.text = "LOCKED"
		_:
			label.text = "%d%%" % int(progress * 100)

# ─────────────────────────────────────────────
#  RPC
# ─────────────────────────────────────────────

@rpc("authority", "call_local", "unreliable")
func _rpc_sync(p_progress: float, p_state: PayloadState, p_countdown: float) -> void:
	if multiplayer.is_server():
		return
	progress          = p_progress
	payload_state     = p_state
	_return_countdown = p_countdown
	# The transform is not written here — `_smooth_client_position` eases toward this on
	# every client physics frame, so the cart travels instead of stepping.
	_update_visuals()

@rpc("authority", "call_local", "reliable")
func _rpc_reset() -> void:
	progress              = 0.0
	is_delivered          = false
	is_being_pushed       = false
	is_contested          = false
	_return_countdown     = 0.0
	_next_checkpoint_index = 0
	_pushers.clear()
	var is_hybrid := game_mode_component and \
		game_mode_component.game_mode == GameModeComponent.GameMode.HYBRID
	is_locked = is_hybrid
	_snap_to_progress()
	_set_state(PayloadState.LOCKED)


## A joining client asking where the cart stands.  Answered only by the host.
##
## Replaces the `spawn = true` position sync the cart used to carry on a
## `MultiplayerSynchronizer`: that was a second writer racing `_rpc_sync` and it had to go,
## but it was also what put a late joiner's cart in the right place.
@rpc("any_peer", "call_remote", "reliable")
func _request_state() -> void:
	if not multiplayer.is_server():
		return
	_rpc_sync.rpc_id(multiplayer.get_remote_sender_id(), progress, payload_state, _return_countdown)

@rpc("authority", "call_local", "reliable")
func _rpc_checkpoint_reached(index: int) -> void:
	checkpoint_reached.emit(index)

@rpc("authority", "call_local", "reliable")
func _rpc_push_started() -> void:
	push_started.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_push_stopped() -> void:
	push_stopped.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_delivered() -> void:
	if multiplayer.is_server():
		return
	is_delivered = true
	payload_delivered.emit()
	_update_visuals()


# ─────────────────────────────────────────────
#  BUILD
# ─────────────────────────────────────────────

## Runs at map build time, after `auto_apply_to_matching_node_properties` has written the
## raw `.map` values — the same hook and the same reasoning as `moving_brush.gd:362-372`.
##
## [member vertical_offset] is the only vector the `Payload` entity exposes, and a mapper
## types it in TrenchBroom's Z-up axes and map units.  func_godot converts `origin` for its
## own properties but not a custom one, so skipping this would move the cart sideways
## instead of up.  Guarded, because a second call would compound the conversion.
func _func_godot_apply_properties(_properties: Dictionary) -> void:
	if _offset_converted:
		return
	_offset_converted = true
	vertical_offset = BrushEntityUtil.to_godot_axes(vertical_offset) \
		* BrushEntityUtil.map_units(self)
