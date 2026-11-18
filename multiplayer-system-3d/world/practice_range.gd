extends Area3D
class_name PracticeRange

## Shared timed target range.
##
## Walk into the zone and press E to start one **shared** run: a practice target
## spawns at a random point inside [member spawn_half_extents], every kill
## respawns it somewhere new, and [member target_kills] kills ends the run.  The
## result is the elapsed time only — lower is better.  Every player's kills count
## toward the same counter and the same clock.
##
## Authority follows the rest of the simulation: the server owns the run, the
## target and the clock; clients ask with a start RPC and receive progress/result
## broadcasts.  Practice targets never touch the Leaderboard (see
## `AttributeComponent`), so a run cannot pollute the match score.
##
## Reuse note: the body tracking, local-player check and crosshair
## `InteractionPrompt` follow `world/host_server_area.gd`; the
## CanvasLayer-under-root run HUD is local to this script.

@export var spawn_half_extents: Vector3 = Vector3(4.0, 0.0, 4.0)
## Height above the zone origin that random points are cast down from.
@export var spawn_height: float = 6.0
## How far down the floor probe reaches.
@export var ray_length: float = 40.0
@export var target_kills: int = 30
## Seconds the result stays up before another run can start.
@export var result_hold_seconds: float = 6.0
## A shared run nobody finishes (everyone wandered off) would block the zone
## forever.  After this long the server abandons it and returns to idle.
@export var run_timeout_seconds: float = 180.0

const HUD_TICK_INTERVAL := 0.1
const WORLD_MASK := 1  # collision layer 1

var _players_inside: Array[Player] = []
var _prompt: InteractionPrompt = null

# -- Server run state --
var _running: bool = false
var _kills: int = 0
var _start_ms: int = 0
var _cooldown_until_ms: int = 0
var _facing_player: Player = null
var _target: PracticeTarget = null
## Best completed run of this lobby session, in ms.  -1 = none yet.
var _best_ms: int = -1
## Most recent completed run, in ms.  -1 = none yet.  Server-owned; mirrored to
## every peer through the progress/result broadcasts for the prompt readout.
var _last_ms: int = -1
## Players this zone currently grants infinite ammo to, by node name.
## Server-owned; the grant itself is broadcast by `Player`.
var _ammo_granted: Dictionary = {}

# -- Local presentation state (every peer) --
var _hud_layer: CanvasLayer = null
var _hud_panel: PanelContainer = null
var _hud_kills_label: Label = null
var _hud_time_label: Label = null
var _hud_result_label: Label = null
var _hud_server_elapsed: float = 0.0
var _hud_local_elapsed: float = 0.0
var _hud_tick: float = 0.0
var _hud_running: bool = false
var _hud_finished: bool = false
var _local_cooldown_until_ms: int = 0
var _prompt_text: String = ""


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_prompt = InteractionPrompt.new()
	_prompt.name = "PracticeRangePrompt"
	get_tree().root.add_child(_prompt)
	_refresh_prompt()
	if OS.is_debug_build() and multiplayer.is_server() \
			and "--test-range-autokill" in OS.get_cmdline_user_args():
		_test_autokill()


func _exit_tree() -> void:
	# Teardown, not a gameplay abort: do not RPC from a node that is leaving the
	# tree.  The map (and every peer's copy of this zone) is going away anyway.
	_running = false
	_clear_range_ammo()
	_free_target()
	_facing_player = null
	_kills = 0
	if _hud_layer and is_instance_valid(_hud_layer):
		_hud_layer.queue_free()
		_hud_layer = null
	if _prompt and is_instance_valid(_prompt):
		_prompt.queue_free()
		_prompt = null


# ---------------------------------------------------------------------------
#  Interaction
# ---------------------------------------------------------------------------

func _on_body_entered(body: Node3D) -> void:
	if body is Player and not (body as Player).is_practice_target:
		if body not in _players_inside:
			_players_inside.append(body)
			_sync_range_ammo()
		_refresh_prompt()


func _on_body_exited(body: Node3D) -> void:
	if body in _players_inside:
		_players_inside.erase(body)
		_sync_range_ammo()
	_refresh_prompt()


func _local_player() -> Player:
	var my_id := MatchSession.local_id_string()
	for p in _players_inside:
		# `body_exited` is not guaranteed for a Player that is freed outright.
		if is_instance_valid(p) and p.name == my_id:
			return p
	return null


func _local_player_inside() -> bool:
	return _local_player() != null


func _unhandled_input(event: InputEvent) -> void:
	if not _local_player_inside():
		return
	if not event.is_action_pressed("interact") or event.is_echo():
		return
	# Another menu (loadout, dev hacks, …) owns input.
	if PlayerInput.ui_open:
		return
	if _hud_running or Time.get_ticks_msec() < _local_cooldown_until_ms:
		return
	get_viewport().set_input_as_handled()
	if multiplayer.is_server():
		_try_start(_local_player())
	else:
		rpc_request_start.rpc_id(1)


## Test hook: start a run and kill the target repeatedly so a second peer can be
## checked for death/respawn replication.  Debug builds only.
func _test_autokill() -> void:
	await get_tree().create_timer(4.0).timeout
	var local: Player = GameManager.find_player(MatchSession.local_id_string())
	if local == null:
		return
	_try_start(local)
	for i in range(3):
		await get_tree().create_timer(2.0).timeout
		if _target != null and is_instance_valid(_target.player):
			print("[PRACTICE RANGE] test killing at %s" % _target.player.global_position)
			_target.player.change_health(-500.0, local.name)


## Client → server start request.  The server resolves the sender's own Player
## (stable id, not peer id) and re-checks everything; the client is never
## trusted to name the starter.
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_start() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var p: Player = GameManager.find_player(MatchSession.player_id_string_for_peer(sender))
	if p == null or p.is_practice_target or not p.is_owned_by_peer(sender):
		return
	if p not in _players_inside:
		return
	_try_start(p)


# ---------------------------------------------------------------------------
#  Server run
# ---------------------------------------------------------------------------

## A run target is its own dummy, separate from any placed `PracticeTargetSpawn`
## standing dummy: it exists only while a run is active and is freed at the end.
func _try_start(started_by: Player) -> void:
	if not multiplayer.is_server() or _running:
		return
	if Time.get_ticks_msec() < _cooldown_until_ms:
		return
	if not is_instance_valid(GameManager.spawn_parent):
		return
	if started_by == null or not is_instance_valid(started_by) or started_by.is_practice_target:
		return

	_facing_player = started_by
	_running = true
	_kills = 0
	_start_ms = Time.get_ticks_msec()

	_target = PracticeTarget.new()
	_target.name = "PracticeTargetController"
	add_child(_target)
	_target.died.connect(_on_target_died)
	var player := _target.spawn(GameManager.spawn_parent,
		Callable(self, "_next_spawn_transform"), "target")
	if player == null:
		_abort_run()
		return
	player.tree_exiting.connect(_on_target_tree_exiting, CONNECT_ONE_SHOT)

	_sync_range_ammo()
	_broadcast_progress(0, 0.0)
	_refresh_prompt()


func _on_target_died(_changer: String) -> void:
	if not _running:
		return
	var died_player: Player = _target.player if _target != null else null
	var death_pos := died_player.global_position if is_instance_valid(died_player) else Vector3.ZERO
	_kills += 1
	if _kills >= maxi(target_kills, 1):
		_finish_run()
	else:
		_broadcast_progress(_kills, _elapsed_seconds())
		_refresh_prompt()
	_verify_respawn(died_player, death_pos)


## The normal death path (`AttributeComponent.practice_target_died` is emitted
## immediately before `health = new_health`, which runs `Player.no_health` →
## `rpc_reset`) is what moves the dummy.  Verify it actually happened and force
## a reset when it did not — a target that keeps standing while the kill counter
## rises is exactly that failure.
func _verify_respawn(p: Player, death_pos: Vector3) -> void:
	if not multiplayer.is_server() or not is_instance_valid(p):
		return
	# Four frames: one for the death tick to finish, and enough ticks for the
	# rollback/tick-interpolation state to settle on the new spawn point.
	for _i in range(4):
		await get_tree().physics_frame
	if not is_instance_valid(p) or p.is_queued_for_deletion():
		return
	var still_there := p.global_position.distance_to(death_pos) < 0.2
	# Health is reset by `rpc_reset` before the short respawn delay elapses, and
	# the pending teleport moves the body on the same tick; `spawned` flips a
	# tick later.  Only a still-dead or still-stationary target needs forcing.
	if p.attribute_component.health > 0.0 and not still_there:
		return
	if OS.is_debug_build():
		print("[PRACTICE RANGE] forcing respawn (spawned=%s health=%.1f moved=%.2f)" % [
			p.spawned, p.attribute_component.health, p.global_position.distance_to(death_pos)])
	# A fresh random point, then the same reliable reset every peer already
	# understands.  Practice targets respawn after the fixed short delay.
	p.attribute_component.reset()
	p.rpc_reset.rpc(_next_spawn_transform())


func _finish_run() -> void:
	if not _running:
		return
	var elapsed_ms := Time.get_ticks_msec() - _start_ms
	_running = false
	_clear_range_ammo()
	_last_ms = elapsed_ms
	_cooldown_until_ms = Time.get_ticks_msec() + int(maxf(result_hold_seconds, 0.0) * 1000.0)
	if _best_ms < 0 or elapsed_ms < _best_ms:
		_best_ms = elapsed_ms
	# The run target is not the standing practice dummy: remove it at the end.
	_facing_player = null
	_free_target()
	_apply_result(elapsed_ms, _best_ms)
	rpc_result.rpc(elapsed_ms, _best_ms)
	_refresh_prompt()


## Runtime abort (the target vanished outside a normal kill).  Hides the HUD on
## every peer; map teardown takes `_exit_tree` instead and sends nothing.
func _abort_run() -> void:
	if not _running:
		return
	_running = false
	_clear_range_ammo()
	_free_target()
	_facing_player = null
	_kills = 0
	_clear_local_hud()
	if multiplayer.is_server():
		rpc_abort.rpc()


func _free_target() -> void:
	if _target == null:
		return
	_target.free_target()
	_target.queue_free()
	_target = null


func _on_target_tree_exiting() -> void:
	# Normally fired by `_free_target`, which runs only after `_running` is
	# already false (finish/abort), so an unexpected exit is the only case that
	# reaches this body.
	if not _running:
		return
	_running = false
	_clear_range_ammo()
	# The Player is already leaving the tree; drop the controller wrapper and
	# let the idle path rebuild it on the next start.
	if is_instance_valid(_target):
		_target.queue_free()
	_target = null
	_facing_player = null
	_kills = 0
	_clear_local_hud()
	if multiplayer.is_server():
		rpc_abort.rpc()


func _elapsed_seconds() -> float:
	if not _running:
		return 0.0
	return (Time.get_ticks_msec() - _start_ms) / 1000.0


## Reconcile the infinite-ammo grants: every real player inside the zone has it
## while a run is live, nobody otherwise.  Server-only; `Player` broadcasts the
## flag so each peer's own copy agrees.
func _sync_range_ammo() -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	var want: Dictionary = {}
	if _running:
		for p in _players_inside:
			if is_instance_valid(p) and not p.is_practice_target:
				want[String(p.name)] = true
	for id in _ammo_granted.keys():
		if not want.has(id):
			_set_range_ammo(String(id), false)
	for id in want.keys():
		if not _ammo_granted.has(id):
			_set_range_ammo(String(id), true)


func _clear_range_ammo() -> void:
	# `return_to_lobby` nulls the peer before the map is freed, so `_exit_tree`
	# can reach here with no peer at all.  The players are freed with that world
	# swap anyway; skipping the broadcast is the safe branch.
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	for id in _ammo_granted.keys():
		_set_range_ammo(String(id), false)


func _set_range_ammo(id: String, on: bool) -> void:
	if on:
		_ammo_granted[id] = true
	else:
		_ammo_granted.erase(id)
	var p := GameManager.find_player(id)
	if is_instance_valid(p):
		p.set_range_infinite_ammo(on)


func _broadcast_progress(kills: int, elapsed_s: float) -> void:
	_apply_progress(kills, target_kills, elapsed_s, _last_ms, _best_ms)
	rpc_progress.rpc(kills, target_kills, elapsed_s, _last_ms, _best_ms)


@rpc("authority", "call_remote", "reliable")
func rpc_progress(kills: int, total: int, elapsed_s: float, last_ms: int, best_ms: int) -> void:
	_apply_progress(kills, total, elapsed_s, last_ms, best_ms)


@rpc("authority", "call_remote", "reliable")
func rpc_result(elapsed_ms: int, best_ms: int) -> void:
	_apply_result(elapsed_ms, best_ms)


@rpc("authority", "call_remote", "reliable")
func rpc_abort() -> void:
	_clear_local_hud()


## Random point on the floor inside the exported box, facing the player who
## started the run.  Server-only; the ray masks WORLD so it can never land on a
## player or the target itself.
func _next_spawn_transform() -> Transform3D:
	var half := spawn_half_extents
	var local_x := randf_range(-absf(half.x), absf(half.x))
	var local_z := randf_range(-absf(half.z), absf(half.z))
	var from: Vector3 = global_transform * Vector3(local_x, spawn_height, local_z)
	var to: Vector3 = from + Vector3.DOWN * maxf(ray_length, 1.0)

	var point := global_transform * Vector3(local_x, 0.0, local_z)
	var space := get_world_3d().direct_space_state
	if space:
		var query := PhysicsRayQueryParameters3D.create(from, to, WORLD_MASK)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			point = hit.position

	if OS.is_debug_build():
		print("[PRACTICE RANGE] spawn point %s (origin=%s half=%s)" % [
			point, global_position, spawn_half_extents])
	var yaw := randf() * TAU
	if _facing_player != null and is_instance_valid(_facing_player):
		var dir: Vector3 = _facing_player.global_position - point
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			# Player forward is -Z.
			yaw = atan2(-dir.x, -dir.z)
	return Transform3D(Basis(Vector3.UP, yaw), point)


# ---------------------------------------------------------------------------
#  Local HUD (every peer)
# ---------------------------------------------------------------------------

func _apply_progress(kills: int, total: int, elapsed_s: float, last_ms: int, best_ms: int) -> void:
	_last_ms = last_ms
	_best_ms = best_ms
	_ensure_hud()
	_hud_running = true
	_hud_finished = false
	_hud_server_elapsed = elapsed_s
	_hud_local_elapsed = 0.0
	_hud_tick = HUD_TICK_INTERVAL
	_local_cooldown_until_ms = 0
	if _hud_panel:
		_hud_panel.visible = true
	if _hud_kills_label:
		_hud_kills_label.text = "KILLS  %d / %d" % [kills, total]
	if _hud_result_label:
		_hud_result_label.visible = false
	_update_hud_time()


func _apply_result(elapsed_ms: int, best_ms: int) -> void:
	_last_ms = elapsed_ms
	_best_ms = best_ms
	var elapsed_s := elapsed_ms / 1000.0
	var best_s := best_ms / 1000.0 if best_ms >= 0 else -1.0
	_ensure_hud()
	_hud_running = false
	_hud_finished = true
	_hud_server_elapsed = elapsed_s
	_hud_local_elapsed = 0.0
	_local_cooldown_until_ms = Time.get_ticks_msec() + int(maxf(result_hold_seconds, 0.0) * 1000.0)
	if _hud_panel:
		_hud_panel.visible = true
	if _hud_kills_label:
		_hud_kills_label.text = "KILLS  %d / %d" % [target_kills, target_kills]
	if _hud_time_label:
		_hud_time_label.text = _fmt_time(elapsed_s)
	if _hud_result_label:
		_hud_result_label.text = "TIME  %s" % _fmt_time(elapsed_s)
		if best_s >= 0.0:
			_hud_result_label.text += "     BEST  %s" % _fmt_time(best_s)
		_hud_result_label.visible = true
	get_tree().create_timer(maxf(result_hold_seconds, 0.1)).timeout.connect(_hide_hud_after_result)


func _hide_hud_after_result() -> void:
	if not is_instance_valid(self):
		return
	_hud_finished = false
	if _hud_panel:
		_hud_panel.visible = false
	_refresh_prompt()


func _clear_local_hud() -> void:
	_hud_running = false
	_hud_finished = false
	_hud_server_elapsed = 0.0
	_hud_local_elapsed = 0.0
	_hud_tick = 0.0
	if _hud_panel:
		_hud_panel.visible = false
	_refresh_prompt()


func _process(delta: float) -> void:
	# Server-side idle guard: an abandoned shared run must not lock the zone.
	if _running and run_timeout_seconds > 0.0 \
			and Time.get_ticks_msec() - _start_ms > int(run_timeout_seconds * 1000.0):
		_abort_run()
		return
	# Timer label is throttled; nothing here runs per-frame when idle.
	if _hud_running and not _hud_finished and _hud_panel and _hud_panel.visible:
		_hud_local_elapsed += delta
		_hud_tick += delta
		if _hud_tick >= HUD_TICK_INTERVAL:
			_hud_tick = 0.0
			_update_hud_time()
	if _local_player_inside() and _prompt_state() != _prompt_text:
		_refresh_prompt()


func _update_hud_time() -> void:
	if _hud_time_label:
		_hud_time_label.text = _fmt_time(_hud_server_elapsed + _hud_local_elapsed)


func _ensure_hud() -> void:
	if _hud_layer and is_instance_valid(_hud_layer):
		return
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "PracticeRangeHUD"
	_hud_layer.layer = 1
	get_tree().root.add_child(_hud_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	center.offset_top = 20.0
	center.offset_bottom = 200.0
	_hud_layer.add_child(center)

	_hud_panel = PanelContainer.new()
	_hud_panel.custom_minimum_size = Vector2(340.0, 0.0)
	_hud_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	_hud_panel.visible = false
	center.add_child(_hud_panel)

	var content := MarginContainer.new()
	content.add_theme_constant_override("margin_left", 14)
	content.add_theme_constant_override("margin_right", 14)
	content.add_theme_constant_override("margin_top", 10)
	content.add_theme_constant_override("margin_bottom", 10)
	_hud_panel.add_child(content)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	content.add_child(box)

	box.add_child(UITheme.display_label("TARGET RANGE", UITheme.FS_SECTION))
	box.add_child(UITheme.accent_bar(UITheme.TEAL, 3))

	_hud_kills_label = UITheme.body_label("KILLS  0 / %d" % target_kills, UITheme.FS_BODY, UITheme.TEXT)
	box.add_child(_hud_kills_label)

	_hud_time_label = UITheme.body_label(_fmt_time(0.0), UITheme.FS_TITLE, UITheme.TEXT)
	box.add_child(_hud_time_label)

	_hud_result_label = UITheme.body_label("", UITheme.FS_BODY, UITheme.TEAL)
	_hud_result_label.visible = false
	box.add_child(_hud_result_label)


func _fmt_time(seconds: float) -> String:
	var t := maxf(seconds, 0.0)
	return "%.2f s" % t


# ---------------------------------------------------------------------------
#  Prompt
# ---------------------------------------------------------------------------

func _prompt_state() -> String:
	if _hud_running:
		return "Run in progress"
	if Time.get_ticks_msec() < _local_cooldown_until_ms:
		return "Range cooldown"
	return "Target range"


## Last and best completion times, for the prompt's secondary line.  Both are
## mirrored to every peer through the progress/result broadcasts, so a client
## sees the same times the server does.
func _prompt_detail() -> String:
	var parts: Array[String] = []
	if _last_ms >= 0:
		parts.append("Last %s" % _fmt_time(_last_ms / 1000.0))
	if _best_ms >= 0:
		parts.append("Best %s" % _fmt_time(_best_ms / 1000.0))
	return "   ".join(parts)


func _refresh_prompt() -> void:
	if _prompt == null:
		return
	_prompt_text = _prompt_state()
	if not _local_player_inside():
		_prompt.hide_prompt()
		return
	var detail := _prompt_detail()
	if _hud_running or Time.get_ticks_msec() < _local_cooldown_until_ms:
		_prompt.show_note(_prompt_text, detail)
	else:
		_prompt.show_action(_prompt_text, "E", UITheme.TEAL, detail)
