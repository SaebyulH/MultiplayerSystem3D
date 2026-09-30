@tool
extends RigidBody3D
class_name PhysicsBrush

## A brush that is a rigid body — it falls, tumbles and can be knocked around. Ported
## from Qodot's `physics`, which is a demo stub: `use()` gives it an upward shove and
## nothing else.
##
## Placeable in TrenchBroom as the `physics` entity — see
## `trenchbroom/entities/physics.tres`.
##
## [b]This is the one port whose synchronisation is approximate, and it is worth being
## clear about why.[/b] Every other brush entity here is *kinematic*: the host computes a
## pose and everyone else adopts it, so all peers agree exactly. A `RigidBody3D` is
## simulated by the physics engine on each machine independently, and two Godot physics
## worlds given identical inputs do not stay identical — Jolt is deterministic only for
## identical builds, identical timesteps and identical contact ordering, none of which
## survives a network. There is no cheap way to make the client's simulation *match*.
##
## So it is not made to match. The host owns the body outright and streams its transform
## at [constant SYNC_RATE]; clients freeze their copy and follow. That is honest about
## what it is: a follower of a remote body, not a simulation. Expect it to look correct
## at rest and slightly rubbery while it is actually moving. See
## `docs/05-known-issues.md`.
##
## [b]Deviations from Qodot:[/b] `node_class` is `RigidBody3D` — Qodot's definition said
## `RigidBody`, the Godot 3 name, which `ClassDB.instantiate()` cannot resolve on Godot 4,
## so Qodot's own entity could not have built. `velocity` is applied as an initial
## velocity, which Qodot declared and then never read.

## Name this entity answers to — how another entity's `target` finds it.
@export var targetname: String = ""

## Initial linear velocity, in TrenchBroom's axes and map units per second. Applied by the
## host at map load and again on a round reset.
## `mass` needs no export: the entity definition declares it and
## `auto_apply_to_matching_node_properties` writes it straight onto `RigidBody3D.mass`.
@export var velocity: Vector3 = Vector3.ZERO

## Upward speed given by [method use]. Qodot's hardcoded value, kept as written — in this
## project's Godot-unit world that is a modest hop under standard gravity.
const BOUNCE_SPEED: float = 10.0

const SYNC_RATE: float = 0.05  # 20 Hz — higher than the mover's, because this one moves

var _base_transform: Transform3D
var _sync_timer: float = 0.0
var _velocity_converted: bool = false


func _ready() -> void:
	# `@tool`: the editor runs this before the class properties are written
	# (`entity_assembler.gd:339` adds the node, `:356` applies properties), so the pose
	# cached here would be cached from defaults. At runtime the scene is already baked.
	if Engine.is_editor_hint():
		return

	_base_transform = global_transform

	# A client must not run its own simulation: two physics worlds will not agree, and a
	# body that disagrees with the host is worse than one that does not move. Frozen as
	# KINEMATIC so the transform can still be assigned — the default FREEZE_MODE_STATIC
	# would pin it and the follower would never move.
	if not multiplayer.is_server():
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		if BrushEntityUtil.should_pull_state(self):
			_request_state.rpc_id(1)
		return

	linear_velocity = velocity
	BrushEntityUtil.connect_round_reset(self, _on_phase_changed)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	_sync_timer += delta
	if _sync_timer < SYNC_RATE:
		return
	_sync_timer = 0.0
	_rpc_sync.rpc(global_transform)


# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func use() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	bounce()


func bounce() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	linear_velocity.y = BOUNCE_SPEED


# ─────────────────────────────────────────────
#  RPC
# ─────────────────────────────────────────────

## The host's pose, adopted wholesale. Unreliable: it is sent twenty times a second and a
## dropped packet is superseded by the next one.
@rpc("authority", "call_local", "unreliable")
func _rpc_sync(p_transform: Transform3D) -> void:
	if multiplayer.is_server():
		return
	global_transform = p_transform


## A joining client asking where this body is. Answered only by the host. Reliable, since
## an unreliable answer to a one-shot question could simply not arrive.
@rpc("any_peer", "call_remote", "reliable")
func _request_state() -> void:
	if not multiplayer.is_server():
		return
	_rpc_sync.rpc_id(multiplayer.get_remote_sender_id(), global_transform)


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
	linear_velocity = velocity
	angular_velocity = Vector3.ZERO
	global_transform = _base_transform
	_sync_timer = 0.0
	_rpc_sync.rpc(_base_transform)


# ─────────────────────────────────────────────
#  BUILD
# ─────────────────────────────────────────────

## Runs at map build time. `velocity` needs both conversions every other length here gets:
## axes, because it is typed in TrenchBroom's Z-up ones — `"0 0 32"` means "up", and without
## the swap the brush launches sideways — and units, because a mapper types speed in the
## same map units as everything else. See [method BrushEntityUtil.to_godot_axes].
func _func_godot_apply_properties(_properties: Dictionary) -> void:
	if _velocity_converted:
		return
	_velocity_converted = true
	velocity = BrushEntityUtil.to_godot_axes(velocity) * BrushEntityUtil.map_units(self)
