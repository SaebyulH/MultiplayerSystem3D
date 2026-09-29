extends Node3D
class_name HealthPack

## A stationary first-aid pickup: heals one player who walks over it, then goes away
## until its spawner brings it back.
##
## [b]Not the same object as `weapon/projectiles/scenes/healthpack.tscn`[/b] — that is
## a `SimpleProjectile` the medpack launcher fires, which heals whoever it hits in
## flight and credits the medic who fired it.
##
## This one has no shooter at all, which is exactly why it does not use
## `HitboxComponent`. `HitboxComponent._process_hurtbox_hit` always hands the delta
## to the victim's `HurtComponent`, and that resolves a `changer` from the hitbox's
## parent and then dereferences `GameMode.find_player(changer).is_bot` with no null
## check (`components/attribute_component.gd:197-203`) — a neutral pickup would crash
## on the heal path. So the overlap is handled here and the heal goes through
## `Player.change_health` directly, the way `world/payload/payload.gd` heals its
## pushers.
##
## Who is inside is tracked from the area's signals, but [b]consumption is decided in
## `_physics_process`, not in `body_entered`[/b]. `body_entered` is edge-triggered and
## cannot express either half of the pack's contract: a player already standing here
## when the respawn timer expires produces no new entry, and neither does one who
## walked over at full health and was then shot without moving.

## Emitted on the server when the pack is actually taken. The spawner listens and
## takes it from there — hide it, start the respawn timer.
signal consumed

@export var heal_amount: float = 50.0

@onready var _pickup_area: Area3D = $PickupArea
@onready var _visual: Node3D = $Visual

## Availability is owned by the spawner and applied with `set_available()`; the pack
## never decides this itself.
var _available := true

## Players currently overlapping. Deliberately NOT cleared when the pack goes
## unavailable: the player who just took it is usually still standing on the spot,
## and they have to be eligible again the moment it comes back.
var _bodies_inside: Array[Player] = []


func _ready() -> void:
	_pickup_area.body_entered.connect(_on_body_entered)
	_pickup_area.body_exited.connect(_on_body_exited)
	_apply_availability()


## Show or hide the pack. Idempotent — the spawner applies this from an RPC as well
## as locally, and a round-start reset can arrive while it is already available.
func set_available(available: bool) -> void:
	if _available == available:
		return
	_available = available
	_apply_availability()


func is_available() -> bool:
	return _available


## Hides the meshes and nothing else. The pickup `Area3D` keeps monitoring
## deliberately: a hidden pack still has to know who is standing on it, so it can
## heal them when it returns. Toggling `monitoring` is also rejected by Godot while
## physics queries are flushing, which is exactly when the consume happens.
func _apply_availability() -> void:
	_visual.visible = _available


func _on_body_entered(body: Node3D) -> void:
	if body is Player and not _bodies_inside.has(body):
		_bodies_inside.append(body)


func _on_body_exited(body: Node3D) -> void:
	_bodies_inside.erase(body)


## The whole per-frame cost of a pack is this early-out: server-only, and doing
## nothing at all unless somebody is actually standing in it.
func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server() or not _available or _bodies_inside.is_empty():
		return

	# Backwards so a disconnected Player can be erased in place. `body_exited`
	# normally covers that, but a freed node left dangling here would keep the list
	# non-empty forever and defeat the early-out above.
	for i in range(_bodies_inside.size() - 1, -1, -1):
		var body := _bodies_inside[i]
		if not is_instance_valid(body):
			_bodies_inside.remove_at(i)
		elif _try_heal(body):
			consumed.emit()
			return


## Heals [param body] if it can actually use the pack, and reports whether the pack
## was taken. Server only — reached from `_physics_process` behind its guard.
func _try_heal(body: Player) -> bool:
	# Parked or dead players are not eligible. `spawned` alone is not enough: the
	# health setter runs `no_health` -> `rpc_reset` -> `despawn()` *inside* the
	# assignment, so there is a frame where a lethal hit has landed but the player is
	# not yet despawned — healing across that frame would revive them in place.
	if not body.spawned:
		return false

	var attributes := body.attribute_component
	if attributes == null or attributes.health <= 0.0:
		return false

	# Already at full health: walk straight through and leave the pack for someone
	# who needs it. The epsilon matters — regen lands on values like 99.99, and
	# `apply_health_delta` floors a zero application, so without it a regenerating
	# player would burn the pack and start the respawn timer for nothing.
	if attributes.health >= attributes.max_health - 0.01:
		return false

	# The player's own name as `changer` makes `changee == changer` inside
	# `apply_health_delta`, which takes the self-heal branch — the only one that does
	# not dereference a changer `Player` that does not exist.
	body.change_health(heal_amount, body.name)
	return true
