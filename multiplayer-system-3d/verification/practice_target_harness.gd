extends Node

## Headless verification for the practice dummy + shared range.
##
##   "C:/tools/godot/godot_console.exe" --path . --headless \
##       res://verification/practice_target_harness.tscn
##
## Boots the offline lobby, then asserts:
##   * the placable marker dummy has no BotController and fixed-respawns;
##   * damage lands, the death signal fires, and no Leaderboard kill is recorded;
##   * a run spawns a separate target that random-respawns and is freed at the end.
##
## The process exit code is the script's `get_tree().quit(code)`.

var _failures: PackedStringArray = []


func _ready() -> void:
	await _run()
	if _failures.is_empty():
		print("[HARNESS] practice target: PASS")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("[HARNESS] FAIL: " + f)
		get_tree().quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


# NetworkManager calls these on `current_scene` during scene entry; the real one
# is `world/main.gd`.
func hide_main_menu() -> void:
	pass


func show_main_menu() -> void:
	pass


func _run() -> void:
	await NetworkManager.boot_offline_lobby()
	# Local player spawns through the usual 1 s respawn timer.
	await get_tree().create_timer(1.6).timeout
	await get_tree().process_frame

	var local: Player = GameManager.find_player(MatchSession.local_id_string())
	_check(local != null, "local player did not spawn")
	if local == null:
		return

	var map := GameManager.spawn_parent.get_node_or_null("Map")
	var range_node := map.find_child("PracticeRange", true, false) as PracticeRange if map else null
	_check(range_node != null, "lobby map has no PracticeRange")
	if range_node == null:
		return

	# 1. Placable standing dummy: fixed marker respawn, independent of the range.
	var standing := _find_practice_player("practice_dummy_")
	_check(standing != null, "lobby did not spawn the placable practice dummy")
	if standing == null:
		return

	_check(standing.is_practice_target, "dummy is not flagged is_practice_target")
	_check(standing.team == Player.Team.FFA, "dummy is not on FFA (damageable by everyone)")
	_check(standing.get_node_or_null("BotController") == null, "dummy still has a BotController")
	_check(not standing.is_owned_by_local_peer(), "dummy is locally owned (would take input)")

	var kills_before := Leaderboard.get_kills(local.name)
	var died_count := [0]
	standing.attribute_component.practice_target_died.connect(func(_c: String) -> void:
		died_count[0] += 1)

	standing.change_health(-50.0, local.name)
	_check(is_equal_approx(standing.attribute_component.health, 50.0),
		"damage did not land (health=%s)" % standing.attribute_component.health)

	standing.change_health(-500.0, local.name)
	_check(died_count[0] == 1, "practice_target_died fired %d times, expected 1" % died_count[0])
	_check(Leaderboard.get_kills(local.name) == kills_before,
		"practice target death changed the Leaderboard kill count")

	await get_tree().create_timer(0.2).timeout
	_check(is_instance_valid(standing) and standing.spawned, "standing dummy did not respawn")
	if is_instance_valid(standing):
		_check(is_equal_approx(standing.attribute_component.health,
			standing.attribute_component.max_health), "standing dummy respawned hurt")
		var flat := Vector2(standing.global_position.x, standing.global_position.z)
		_check(flat.distance_to(Vector2(0.0, -6.0)) < 1.0,
			"standing dummy respawned away from its marker: %s" % standing.global_position)

	# 2. Range run target: a different dummy, spawned only for the run.
	range_node._try_start(local)
	await get_tree().process_frame
	_check(range_node._running, "range run did not start")
	var target := _find_practice_player("practice_target_")
	_check(target != null, "range run did not spawn its own target")
	if target == null:
		return
	_check(target != standing, "range run reused the standing dummy")
	var half: Vector3 = range_node.spawn_half_extents
	_check(absf(target.global_position.x - range_node.global_position.x) <= absf(half.x) + 0.5,
		"run target spawned outside x extents")
	_check(absf(target.global_position.z - range_node.global_position.z) <= absf(half.z) + 0.5,
		"run target spawned outside z extents")

	var run_pos := target.global_position
	target.change_health(-500.0, local.name)
	await get_tree().create_timer(0.2).timeout
	_check(range_node._kills == 1, "range did not count the kill (kills=%d)" % range_node._kills)
	_check(is_instance_valid(target) and target.spawned, "run target did not respawn")
	var moved := Vector2(target.global_position.x, target.global_position.z).distance_to(
		Vector2(run_pos.x, run_pos.z))
	_check(moved > 0.25, "run target respawned at the same point (moved %.2f m)" % moved)

	# 3. Finishing frees the run target and leaves the standing dummy alone.
	range_node.target_kills = 2
	target.change_health(-500.0, local.name)
	await get_tree().create_timer(0.2).timeout
	_check(not range_node._running, "range run did not finish at target_kills")
	_check(range_node._best_ms >= 0, "range did not record a best time")
	_check(range_node._local_cooldown_until_ms > Time.get_ticks_msec(),
		"range did not enter its result cooldown")
	_check(not is_instance_valid(target), "run target survived the end of its run")
	_check(is_instance_valid(standing), "standing dummy was removed with the run target")
	_check(Leaderboard.get_kills(local.name) == kills_before,
		"range kills changed the Leaderboard kill count")


func _find_practice_player(prefix: String) -> Player:
	if not is_instance_valid(GameManager.spawn_parent):
		return null
	for child in GameManager.spawn_parent.get_children():
		if child is Player and String(child.name).begins_with(prefix):
			return child as Player
	return null
