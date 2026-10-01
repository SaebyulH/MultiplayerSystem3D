@tool
extends AnimatableBody3D
class_name MovingBrush

## A brush that slides to an offset pose when triggered. Ported from Qodot's `mover`,
## and the only entity that defines [method use] — so it is the only useful `target` for
## a [TriggerVolume] or [ButtonBrush].
##
## Placeable in TrenchBroom as the `mover` entity — see `trenchbroom/entities/mover.tres`.
##
## [b]Deviations from Qodot, all deliberate:[/b]
##
## [b]1. `AnimatableBody3D`, not `CharacterBody3D`.[/b] Godot 4's idiom for a kinematic
## platform that *carries* a player rather than shoving them, and what this project
## already uses for its one other moving map entity (`world/payload/payload.gd`).
##
## [b]2. `translation`/`rotation`/`scale` are renamed `move_translation`/`move_rotation`/
## `move_scale`.[/b] Not cosmetic: the entity definition sets
## `auto_apply_to_matching_node_properties`, which does `if property in node` — and
## `Node3D` [i]already has[/i] `rotation` and `scale`. Qodot's names would have overwritten
## this node's absolute transform instead of describing an offset from it.
## `move_translation` is authored in **TrenchBroom map units** like every other vector a
## mapper types; the build converts it to Godot units (see
## [method _func_godot_apply_properties]). `move_rotation` is in **degrees**.
##
## [b]3. The travel is linear, not Qodot's exponential ease.[/b] Qodot ran
## `transform = transform.interpolate_with(target, speed * delta)` — a framerate-dependent
## exponential approach that a client cannot reconstruct from a single scalar. Here the
## server advances a normalised `_progress` at a constant rate and clients interpolate
## with it, so `speed` means *progress units per second* (1.0 ⇒ one second of travel,
## roughly Qodot's feel at its default).
##
## [b]The three behaviour flags.[/b] Between them they cover everything from a one-way
## platform to a self-running lift:
##
##   * [member automatic] — fires itself on map load, with no trigger involved.
##   * [member toggle] — a trigger flips it open/closed instead of only ever opening it.
##   * [member wait] — what happens after each activation, in seconds. Its meaning depends
##     on [member toggle]; see the table below. [b]`-1` means the mover stays exactly where
##     it ended up, permanently[/b], and that is the default.
##
## | [member toggle] | what [member wait] is |
## |---|---|
## | `false` | how long it stays at the offset pose before returning home |
## | `true` | a guard: how long it ignores further triggers after each activation |
##
## [b]`wait = -1` with `toggle = true` means no guard at all[/b] — the mover is togglable
## at any time. There is nothing to "stay" for, because in toggle mode the pose is the
## state.
##
## Worked examples, all on a mover with `move_translation "0 0 128"`:
##
##   * `wait -1` (default) — a trigger opens it and it stays open. The original behaviour.
##   * `wait 3` — a trigger opens it, it returns home 3 s later.
##   * `toggle 1`, `wait 2` — a trigger flips it; for 2 s afterwards further triggers are
##     ignored, which is what stops a player standing in the trigger from rattling it.
##   * `automatic 1`, `wait 2` — it rises on load, sinks 2 s after arriving, rises 2 s after
##     that, forever. A patrolling platform.
##   * `automatic 1`, `wait -1` — it rises on load and stays up.
##
## [b]Syncing.[/b] Server-authoritative, like every other map entity in this project.
## Continuous state (the progress) rides an unreliable RPC at ~15 Hz; discrete state (the
## target flipping) rides a reliable one; a late joiner pulls once on `_ready`. The
## transform itself is never replicated by a `MultiplayerSynchronizer`, and none of this
## is rollback state — `RollbackSynchronizer` is Player-only.

## Name this entity answers to — how another entity's `target` finds it.
@export var targetname: String = ""

## How far to travel when triggered, in TrenchBroom map units, converted to Godot units
## at build time.
@export var move_translation: Vector3 = Vector3.ZERO

## How far to rotate when triggered, in degrees.
@export var move_rotation: Vector3 = Vector3.ZERO

## Scale to apply at the open pose. Inert at Vector3.ONE, which is the default.
@export var move_scale: Vector3 = Vector3.ONE

## Progress units per second — 1.0 means one second of travel.
@export var speed: float = 1.0

## Runs with no trigger at all: the mover plays its motion on map load, and again after
## every round reset.
@export var automatic: bool = false

## Seconds. What this means depends on [member toggle] — a return delay in one-shot mode, a
## re-trigger guard in toggle mode. [b]Negative means permanent:[/b] the mover stays where
## it ended up and nothing moves it again. See the class description for the full table.
@export var wait: float = -1.0

## A trigger flips the mover between its two poses rather than only ever opening it.
@export var toggle: bool = false

const SYNC_RATE: float = 0.066  # ~15 Hz, matching PayloadNode

## Pose at map load, cached before anything moves.
var base_transform: Transform3D

var _offset_transform: Transform3D
## 0.0 = authored pose, 1.0 = fully at the offset pose.
var _progress: float = 0.0
## Which pose `_progress` is heading for. False is the authored pose, which is where the
## mapper put the brush — deliberately the default, so a peer that has heard nothing is
## wrong in the harmless direction.
var _target_open: bool = false
var _sync_timer: float = 0.0
var _offset_converted: bool = false
## Server-only. Seconds left before whatever the wait armed actually fires, paired with
## [_rest_pending] because `wait = 0` is legal and would otherwise be indistinguishable
## from "nothing pending" on the value alone.
var _rest_timer: float = 0.0
var _rest_pending: bool = false

## Client only. Where along the travel the brush is *drawn*, eased toward [member _progress]
## rather than snapped to it. Servers write the pose directly and never read this. See
## [method _smooth_client_position].
var _display_progress: float = 0.0

## Time constant for that easing, in seconds — the mover's travel is linear, so the lag it
## costs is a fixed `SMOOTH_TAU x speed` that settles to the same pose the server is at.
const SMOOTH_TAU: float = 0.1

## A correction bigger than this is a teleport, not travel — a late joiner's pulled state, or
## a round reset sending the brush home — and is snapped to instead of eased into. A 15 Hz
## packet carries at most `speed / 15`, and `speed` is in progress units per second.
const SNAP_THRESHOLD: float = 0.05


func _ready() -> void:
	# `@tool`: the editor runs this before `apply_entity_properties` has written the class
	# properties (`entity_assembler.gd:339` adds the node, `:356` applies properties), so
	# anything cached here would be cached from defaults. The runtime loads a baked scene
	# where the exports already hold their final values, so this is the only correct place
	# to snapshot the base pose.
	if Engine.is_editor_hint():
		return

	base_transform = global_transform
	_build_offset_transform()
	_apply_progress()

	if BrushEntityUtil.should_pull_state(self):
		_request_state.rpc_id(1)
		return
	BrushEntityUtil.connect_round_reset(self, _on_phase_changed)

	# Server-only in effect — `play_motion` gates itself. A client that receives this map
	# later pulls the same state in `_request_state` above.
	if automatic:
		play_motion()


func _build_offset_transform() -> void:
	var basis := Basis.from_euler(Vector3(
		deg_to_rad(move_rotation.x),
		deg_to_rad(move_rotation.y),
		deg_to_rad(move_rotation.z),
	))
	if move_scale != Vector3.ONE:
		basis = basis.scaled(move_scale)
	_offset_transform = Transform3D(basis, move_translation)


# ─────────────────────────────────────────────
#  PUBLIC API — what a baked `trigger` connection calls
# ─────────────────────────────────────────────

## What a `target` resolves to — Qodot hardcoded the name, and so do we.
##
## Without [member toggle] this opens the mover, which is all Qodot ever did. With it, this
## flips between the two poses instead.
func use() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if _is_guarded():
		return
	if toggle and _target_open:
		reverse_motion()
		return
	play_motion()


func play_motion() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if _target_open:
		return
	_clear_rest_timer()
	_target_open = true
	_rpc_set_target.rpc(true)


## Slides back to the authored pose. Reached by [method use] when [member toggle] is set,
## by the wait expiring in one-shot mode, and by the round reset. A baked trigger alone
## never calls it directly — Qodot's wire format only ever names `use()`.
func reverse_motion() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if not _target_open:
		return
	_clear_rest_timer()
	_target_open = false
	_rpc_set_target.rpc(false)


# ─────────────────────────────────────────────
#  SIMULATION — server only
# ─────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not multiplayer.is_server():
		# Clients do not simulate the travel, but they do drive the pose — `_rpc_sync` no
		# longer writes it. See `_smooth_client_position`.
		_smooth_client_position(delta)
		return

	var goal := 1.0 if _target_open else 0.0

	if not is_equal_approx(_progress, goal):
		_progress = move_toward(_progress, goal, speed * delta)
		_apply_progress()

		_sync_timer += delta
		if _sync_timer >= SYNC_RATE or is_equal_approx(_progress, goal):
			_sync_timer = 0.0
			_rpc_sync.rpc(_progress)

		# Arm on the frame it arrives, so the wait starts from the pose being reached
		# rather than from the trigger being pulled.
		if is_equal_approx(_progress, goal):
			_arm_rest_timer()
		return

	# At rest. The only thing left to do is count down whatever the wait armed.
	if not _rest_pending:
		return
	_rest_timer -= delta
	if _rest_timer > 0.0:
		return
	_clear_rest_timer()
	_on_rest_elapsed()


# ─────────────────────────────────────────────
#  WAIT / TOGGLE
# ─────────────────────────────────────────────

## Whether this mover should ignore a trigger right now.
##
## Only [member toggle] uses the wait as a guard. There a trigger flips the pose, so without
## one a player standing in the trigger would rattle the mover open and shut as fast as
## `body_entered` fires. In one-shot mode the wait is the return delay instead, and
## re-triggering while already open is a no-op in [method play_motion] anyway.
func _is_guarded() -> bool:
	return toggle and _rest_pending


## Called once, on the frame the mover reaches either pose. [member wait] decides what
## happens next, and a negative value means nothing ever does — that is the default.
func _arm_rest_timer() -> void:
	if wait < 0.0:
		return
	_rest_pending = true
	_rest_timer = maxf(wait, 0.0)  # `wait = 0` is legal and means "as soon as it lands"


func _clear_rest_timer() -> void:
	_rest_pending = false
	_rest_timer = 0.0


## What the wait expiring actually does. Three cases, and the third is the quiet one.
func _on_rest_elapsed() -> void:
	if automatic:
		# A self-running mover: go back the other way. The next leg arms its own timer on
		# arrival, and that is what makes this a loop rather than a single round trip.
		if _target_open:
			reverse_motion()
		else:
			play_motion()
	elif not toggle:
		# A one-shot: it returns to where it came from.
		reverse_motion()
	# toggle: the timer was only ever the guard. It is now clear, so the mover is ready for
	# another trigger — and it stays exactly where it is until one arrives.


## Writes the pose both sides agree on. Derived, never simulated on a client.
##
## [b]The interpolation is anchored at the authored pose, never at the pose being travelled
## to.[/b] Interpolating `base -> target` looks correct on the way out and is degenerate on
## the way back: once the target [i]is[/i] the base, both ends of the interpolation are the
## same transform, so every progress value yields fully closed and the mover snaps home
## instead of travelling. The offset pose is the fixed far end and [member _progress] alone
## carries the position along it, so direction never enters into the arithmetic.
func _apply_progress() -> void:
	global_transform = base_transform.interpolate_with(
		base_transform * _offset_transform, _progress)


## Places the brush exactly where [member _progress] says, with no easing. For the writes
## that are a teleport rather than travel: load, round reset, a pulled state.
func _snap_to_progress() -> void:
	_display_progress = _progress
	_apply_progress()


## Eases the brush toward the replicated [member _progress] instead of snapping to it.
##
## The mover's travel rides an unreliable RPC at ~15 Hz, so writing the pose straight from
## it stepped the brush a whole packet's worth at a time — visible stutter, and a platform
## whose position jumps then holds still is one that a rider's platform carry cannot measure.
## `_rpc_sync` therefore only records the value and this, on every client physics frame, is
## what actually moves the brush.
func _smooth_client_position(delta: float) -> void:
	if absf(_progress - _display_progress) > SNAP_THRESHOLD:
		_snap_to_progress()
		return
	_display_progress = lerp(_display_progress, _progress, 1.0 - exp(-delta / SMOOTH_TAU))
	global_transform = base_transform.interpolate_with(
		base_transform * _offset_transform, _display_progress)


# ─────────────────────────────────────────────
#  RPC
# ─────────────────────────────────────────────

## Discrete: which pose we are heading for. Reliable, so the flip cannot be lost.
@rpc("authority", "call_local", "reliable")
func _rpc_set_target(p_target_open: bool) -> void:
	if multiplayer.is_server():
		return
	_target_open = p_target_open


## Continuous: how far along. Unreliable — a dropped packet is corrected by the next one,
## and the final packet always carries the exact goal because it is sent when
## `_progress` reaches it.
@rpc("authority", "call_local", "unreliable")
func _rpc_sync(p_progress: float) -> void:
	if multiplayer.is_server():
		return
	_progress = p_progress
	# The pose is not written here — `_smooth_client_position` eases toward this on every
	# client physics frame, so the brush travels instead of stepping.


## A joining client asking where this brush stands. Answered only by the host, and only
## about its own brush.
@rpc("any_peer", "call_remote", "reliable")
func _request_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	_rpc_set_target.rpc_id(sender, _target_open)
	_rpc_sync.rpc_id(sender, _progress)


# ─────────────────────────────────────────────
#  ROUND RESET
# ─────────────────────────────────────────────

func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	if Engine.is_editor_hint():
		return
	if new_phase != GameModeComponent.PhaseState.SETUP:
		return
	_restore()


## Strictly idempotent — the host sees every transition twice (once from
## `phase_changed.emit`, once through the `call_local` `_rpc_sync_phase`).
func _restore() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	_clear_rest_timer()
	if _target_open or not is_equal_approx(_progress, 0.0):
		_target_open = false
		_progress = 0.0
		_apply_progress()
		_rpc_set_target.rpc(false)
		_rpc_sync.rpc(0.0)
	# An automatic mover restarts its cycle from the authored pose; a trigger-driven one has
	# nothing more to do until something fires it. `play_motion` is a no-op if it is already
	# open, so this stays idempotent across the host's doubled SETUP transition.
	if automatic:
		play_motion()


# ─────────────────────────────────────────────
#  BUILD
# ─────────────────────────────────────────────

## Runs at map build time, after `auto_apply_to_matching_node_properties` has written the
## raw `.map` values (`entity_assembler.gd:250-265`). This is where map units become
## Godot units, and it has to happen here rather than in `_ready` because the result must
## be **baked into the scene** — `FuncGodotMap.build()` is editor-only, so nothing here
## runs in a running game, and a map node with no live `FuncGodotMap` sibling could not
## look the factor up later.
##
## Guarded so a second call cannot compound the conversion into a 32x offset.
func _func_godot_apply_properties(properties: Dictionary) -> void:
	if _offset_converted:
		return
	_offset_converted = true
	# Axes first, then units: `move_translation` is typed in TrenchBroom's Z-up axes and
	# must become Godot's Y-up before anything downstream sees it. See
	# [method BrushEntityUtil.to_godot_axes] — without this, a mapper's "0 0 128" (up)
	# moves the brush sideways.
	move_translation = BrushEntityUtil.to_godot_axes(move_translation) * BrushEntityUtil.map_units(self)
	# Same swap func_godot applies to a prop's per-axis `scale`, for the same reason.
	move_scale = BrushEntityUtil.to_godot_axes(move_scale)
