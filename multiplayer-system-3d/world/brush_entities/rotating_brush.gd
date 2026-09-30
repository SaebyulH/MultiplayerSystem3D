@tool
extends AnimatableBody3D
class_name RotatingBrush

## A brush that spins continuously about its own origin. Ported from Qodot's `rotate`.
##
## Placeable in TrenchBroom as the `rotate` entity — see
## `trenchbroom/entities/rotate.tres`.
##
## [b]This is the one entity that streams no transform and costs no recurring
## bandwidth.[/b] A rotation is a pure function of elapsed time, so every peer integrates
## it locally at [member speed] and the host only sends a ~1 Hz correction to absorb
## accumulated frame-time drift. Streaming a transform at the usual 15 Hz would step
## 24 degrees at a time at the default speed, which reads as a stutter, and sending it
## faster would cost bandwidth to say something every peer can already compute.
##
## Like Qodot's, it has no [method use] and never stops — it is not a target, only
## scenery. See `docs/02-netcode.md` for the pattern.
##
## [b]Deviations from Qodot:[/b] `AnimatableBody3D` rather than `CharacterBody3D` (Godot 4's
## kinematic-platform idiom, and what [PayloadNode] uses), and `axis`/`speed` are
## re-exported with the same names because neither collides with a `Node3D` property —
## unlike the mover, whose `rotation` and `scale` had to be renamed.

## Name this entity answers to. It is never a `target`, but a name costs nothing and makes
## it selectable in a future revision.
@export var targetname: String = ""

## Axis to spin about, in the brush's own space. Normalised on use.
@export var axis: Vector3 = Vector3.UP

## Degrees per second.
@export var speed: float = 360.0

## How often the host re-states the authoritative angle, in seconds.
const CORRECTION_RATE: float = 1.0

## Past this much disagreement a client adopts the host's angle outright. Below it the
## correction is ignored, so the common case (a few thousandths of a degree) never
## produces a visible snap.
const DRIFT_LIMIT: float = 0.25

var _base_transform: Transform3D
var _base_basis: Basis
var _angle: float = 0.0
var _correction_timer: float = 0.0
var _axis_converted: bool = false


func _ready() -> void:
	# `@tool`: the editor runs this before the class properties are written
	# (`entity_assembler.gd:339` adds the node, `:356` applies properties), so the pose
	# cached here would be cached from defaults. At runtime the scene is already baked.
	if Engine.is_editor_hint():
		return

	_base_transform = global_transform
	_base_basis = _base_transform.basis

	if BrushEntityUtil.should_pull_state(self):
		_request_state.rpc_id(1)
		return
	BrushEntityUtil.connect_round_reset(self, _on_phase_changed)


## Runs on every peer, host included — this is the local integration that makes the
## per-frame traffic unnecessary.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	_angle = fposmod(_angle + speed * delta, 360.0)
	_apply_angle()

	if not multiplayer.is_server():
		return
	_correction_timer += delta
	if _correction_timer >= CORRECTION_RATE:
		_correction_timer = 0.0
		_rpc_sync.rpc(_angle)


func _apply_angle() -> void:
	var spin_axis := axis.normalized()
	var basis := _base_basis if spin_axis.is_zero_approx() \
		else _base_basis.rotated(spin_axis, deg_to_rad(_angle))
	global_transform = Transform3D(basis, _base_transform.origin)


# ─────────────────────────────────────────────
#  RPC
# ─────────────────────────────────────────────

## Drift correction, at [constant CORRECTION_RATE]. Reliable is affordable at 1 Hz and
## means a late joiner's one-shot answer cannot be dropped.
@rpc("authority", "call_local", "reliable")
func _rpc_sync(p_angle: float) -> void:
	if multiplayer.is_server():
		return
	# Deliberately not an unconditional assignment: the client is already spinning under
	# its own integration, and snapping it every second would be a visible tick for no
	# gain. Only a real disagreement is worth correcting.
	if absf(angle_difference(deg_to_rad(_angle), deg_to_rad(p_angle))) <= deg_to_rad(DRIFT_LIMIT):
		return
	_angle = p_angle
	_apply_angle()


## A joining client asking where this brush stands. Answered only by the host.
@rpc("any_peer", "call_remote", "reliable")
func _request_state() -> void:
	if not multiplayer.is_server():
		return
	_rpc_sync.rpc_id(multiplayer.get_remote_sender_id(), _angle)


# ─────────────────────────────────────────────
#  ROUND RESET
# ─────────────────────────────────────────────

func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	if Engine.is_editor_hint():
		return
	if new_phase != GameModeComponent.PhaseState.SETUP:
		return
	_restore()


## Strictly idempotent — the host sees every transition twice.
func _restore() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if is_zero_approx(_angle):
		return
	_angle = 0.0
	_apply_angle()
	_correction_timer = 0.0
	_rpc_sync.rpc(0.0)


# ─────────────────────────────────────────────
#  BUILD
# ─────────────────────────────────────────────

## Runs at map build time. `axis` is a direction typed in TrenchBroom's Z-up axes, so it
## has to be swapped into Godot's Y-up ones — `"0 0 1"` in the editor means "about up", and
## without the swap this spins about a horizontal axis instead. See
## [method BrushEntityUtil.to_godot_axes].
func _func_godot_apply_properties(_properties: Dictionary) -> void:
	if _axis_converted:
		return
	_axis_converted = true
	axis = BrushEntityUtil.to_godot_axes(axis)
