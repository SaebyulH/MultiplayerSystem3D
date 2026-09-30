@tool
extends Area3D
class_name ButtonBrush

## A brush that sinks into the wall when something presses it, and fires `trigger` on the
## way in. Ported from Qodot's `button`.
##
## Placeable in TrenchBroom as the `button` entity — see
## `trenchbroom/entities/button.tres`. Like [TriggerVolume] it is a *source*: its `target`
## is wired to a target's `use()` at map build time via
## [method BrushEntityUtil.link_targets], with `CONNECT_PERSIST`.
##
## [b]Syncing is deliberately cheaper than [MovingBrush]'s.[/b] The only agreed state is
## [member is_pressed], which flips reliably; every peer then animates its own sink locally
## from that flag. A mover has to stream because a client cannot reconstruct its server's
## easing from a scalar — but a button's travel is a pure function of `is_pressed` and
## elapsed time, so there is nothing to stream and nothing to drift, because the animation
## always starts and ends on an exact value.
##
## [b]Deviations from Qodot:[/b]
##
## [b]1. `depth` is authored in TrenchBroom map units[/b] and converted at build time, the
## same as [member MovingBrush.move_translation]. Qodot's default was `0.8`, which at this
## project's 32-units-per-metre scale would be a quarter of a millimetre of travel; the
## default here is 4 map units (about 12 cm), and an author writing `depth "8"` gets the
## 8 units they drew.
##
## [b]2. `press_signal_delay` and `release_signal_delay` are gone.[/b] Qodot declared
## `release_signal_delay` and never read it, and `press_signal_delay` only delayed a
## signal nothing consumed. Delaying an informational signal behind a timer buys nothing
## and introduces an ordering hazard on a rapid re-press, so [signal pressed] and
## [signal released] now fire immediately and only [member trigger_signal_delay] remains.
##
## [b]3. `release_delay` is applied once.[/b] Qodot awaited it in `body_shape_exited`
## *and* again inside `release()`, so a configured delay took twice as long as written.

signal trigger()
signal pressed()
signal released()

## Name this entity answers to — how another entity's `target` finds it.
@export var targetname: String = ""

## Name of the entity to fire. Resolved at build time; empty means "wired to nothing".
@export var target: String = ""

## Direction the button sinks, in its own space. Normalised on use.
@export var axis: Vector3 = Vector3.DOWN

## How far it sinks, in TrenchBroom map units.
@export var depth: float = 4.0

## Press units per second — 8.0 means an eighth of a second to sink.
@export var speed: float = 8.0

## Delay between the button being pressed and [signal trigger] firing. Unlike the two
## signal delays above, this one gates the gameplay-relevant event, so it is kept.
@export var trigger_signal_delay: float = 0.0

## Debounce before releasing once the last body leaves. Fractional seconds.
@export var release_delay: float = 0.0

var is_pressed: bool = false

var _base_translation: Vector3
## 0.0 = fully out, 1.0 = fully sunk.
var _press: float = 0.0
## Server-side count of bodies standing on the button.
var _overlaps: int = 0
## Server-side memo so the build-time conversion cannot compound.
var _depth_converted: bool = false


func _ready() -> void:
	# `@tool`: the editor runs this before the class properties are written
	# (`entity_assembler.gd:339` adds the node, `:356` applies properties), so the pose
	# cached here would be cached from defaults. At runtime the scene is already baked.
	if Engine.is_editor_hint():
		return

	_base_translation = position

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	if BrushEntityUtil.should_pull_state(self):
		_request_state.rpc_id(1)
		return
	BrushEntityUtil.connect_round_reset(self, _on_phase_changed)


## Every peer, host included — the sink is derived from [member is_pressed], which every
## peer already agrees on.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var goal := 1.0 if is_pressed else 0.0
	if is_equal_approx(_press, goal):
		return
	_press = move_toward(_press, goal, speed * delta)
	_apply_press()


func _apply_press() -> void:
	position = _base_translation + axis.normalized() * (depth * _press)


# ─────────────────────────────────────────────
#  OVERLAP — server only
# ─────────────────────────────────────────────

## Server-only, deliberately: the baked `trigger` connection below exists on every peer,
## so a client that ran this would fire `use()` on its own copy of the target.
func _on_body_entered(body: Node3D) -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if body is StaticBody3D:
		return
	_overlaps += 1
	if _overlaps == 1:
		press()


func _on_body_exited(body: Node3D) -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if body is StaticBody3D:
		return
	_overlaps = maxi(_overlaps - 1, 0)
	if _overlaps == 0:
		_schedule_release()


## Re-checks [member _overlaps] after the wait, so stepping off and straight back on does
## not release a button that is being held down.
func _schedule_release() -> void:
	if release_delay <= 0.0:
		release()
		return
	await get_tree().create_timer(release_delay).timeout
	if not is_instance_valid(self) or _overlaps > 0:
		return
	release()


func press() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if is_pressed:
		return
	_apply_pressed(true)
	if trigger_signal_delay > 0.0:
		await get_tree().create_timer(trigger_signal_delay).timeout
		# A button released during the delay should not fire late.
		if not is_instance_valid(self) or not is_pressed:
			return
	trigger.emit()


func release() -> void:
	if Engine.is_editor_hint() or not multiplayer.is_server():
		return
	if not is_pressed:
		return
	_apply_pressed(false)


## The one place [member is_pressed] changes, on every peer, so [signal pressed] and
## [signal released] fire everywhere exactly once per transition.
func _apply_pressed(value: bool) -> void:
	if is_pressed == value:
		return
	is_pressed = value
	if value:
		pressed.emit()
	else:
		released.emit()


# ─────────────────────────────────────────────
#  RPC
# ─────────────────────────────────────────────

## The only state this entity syncs. Reliable — a lost flip is a button stuck down.
@rpc("authority", "call_local", "reliable")
func _rpc_set_pressed(value: bool) -> void:
	if multiplayer.is_server():
		return
	_apply_pressed(value)


## A joining client asking whether the button is currently held. Answered only by the host.
@rpc("any_peer", "call_remote", "reliable")
func _request_state() -> void:
	if not multiplayer.is_server():
		return
	_rpc_set_pressed.rpc_id(multiplayer.get_remote_sender_id(), is_pressed)


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
	_overlaps = 0
	if not is_pressed:
		return
	_apply_pressed(false)
	_rpc_set_pressed.rpc(false)


# ─────────────────────────────────────────────
#  BUILD
# ─────────────────────────────────────────────

## Runs at map build time, after `auto_apply_to_matching_node_properties` has written the
## raw `.map` values (`entity_assembler.gd:250-265`). See
## [method MovingBrush._func_godot_apply_properties] for why the conversion has to happen
## here rather than at runtime.
func _func_godot_apply_properties(properties: Dictionary) -> void:
	if _depth_converted:
		return
	_depth_converted = true
	# `axis` is a direction the mapper types in TrenchBroom's Z-up axes; `depth` is a length
	# in map units. Both need converting, and neither is converted for you — see
	# [method BrushEntityUtil.to_godot_axes].
	axis = BrushEntityUtil.to_godot_axes(axis)
	depth *= BrushEntityUtil.map_units(self)


## Called by the assembler, deferred, once every entity in the map exists
## (`entity_assembler.gd:267-268`) — so this is the point at which a `target` name can
## actually be resolved. Linking from [_func_godot_apply_properties] instead would only
## ever find entities built before this one.
func _func_godot_build_complete() -> void:
	BrushEntityUtil.link_targets(self, target)
