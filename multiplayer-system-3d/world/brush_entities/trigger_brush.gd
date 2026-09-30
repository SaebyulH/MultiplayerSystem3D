@tool
extends Area3D
class_name TriggerVolume

## A brush that fires when something walks into it. Ported from Qodot's `trigger`.
##
## Placeable in TrenchBroom as the `trigger` entity — see
## `trenchbroom/entities/trigger.tres`. Solid classes are authored as brushes, so the
## volume is the brush you draw, not a shape you configure.
##
## [b]`target` is wired up at map build time, not at runtime.[/b] This entity's
## [method _func_godot_build_complete] connects its own `trigger` signal to the `use()`
## method of every entity named by `target`, using `CONNECT_PERSIST` so the link
## serializes into the map scene. That reimplements Qodot's `QodotMap.connect_signals()`,
## which func_godot dropped — see [method BrushEntityUtil.link_targets]. Because it is a
## build-time step, [b]the link only exists after the map is rebuilt [i]and the scene is
## saved[/i][/b]; a rebuild you do not save loses it.
##
## [b]The connection is a plain local signal connection and therefore exists on every
## peer[/b] — which is exactly why the emission below is gated on the server. A client
## that emitted `trigger` would call `use()` locally and move a door its host never
## agreed to move.
##
## Faithful to Qodot, which means deliberately unadorned: there is no `wait`, no
## `spawnflags` and no re-arm, so walking in and out fires again every time. For a mover
## that is harmless (its target is already the open pose), but it is not a Quake
## `trigger_multiple`. See `docs/05-known-issues.md`.

## Fired when a body enters, on the server only. Wired to a target's `use()` at build time.
signal trigger()

## Name this entity answers to — how another entity's `target` finds it.
@export var targetname: String = ""

## Name of the entity to fire. Resolved at build time; empty means "wired to nothing".
@export var target: String = ""


func _ready() -> void:
	# `@tool` means this runs in the editor too, where there is nothing to listen for and
	# no peers to gate against. The build-time wiring lives in _func_godot_build_complete.
	if Engine.is_editor_hint():
		return
	body_entered.connect(_on_body_entered)


## Server-only, deliberately. `collision_mask` is PLAYER_COLLISION, so the only bodies
## that reach here are players and bots; the `StaticBody3D` guard is Qodot's and is kept
## as a backstop in case a map configures a wider mask.
func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	if body is StaticBody3D:
		return
	trigger.emit()


## Called by the assembler, deferred, once every entity in the map exists
## (`entity_assembler.gd:267-268`) — so this is the point at which a `target` name can
## actually be resolved.
func _func_godot_build_complete() -> void:
	BrushEntityUtil.link_targets(self, target)
