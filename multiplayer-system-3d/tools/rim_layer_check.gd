extends Node
## Throwaway verification harness for known-issues #51 (the rim-light render layer).
##
## Instantiates a Player, applies a real Character, and reports whether the spawned
## character model's meshes carry PlayerModel.RIM_LAYER — the bit the RimPivot
## spotlights cull to (`light_cull_mask = 512`).  Runs both cases: someone else's
## model (must opt IN) and the local player's own (must stay OUT).
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/rim_layer_check.tscn
##
## Exits with the number of failed assertions, so 0 means the layer handshake holds.

const RIM_LAYER := 1 << 9
const CHARACTER_PATH := "res://player/characters/stalker.tres"

var _failures := 0


func _ready() -> void:
	var character: Character = load(CHARACTER_PATH) as Character
	if character == null or character.character_scene == null:
		printerr("FAIL: could not load %s (or it has no character_scene)" % CHARACTER_PATH)
		get_tree().quit(1)
		return

	# NOTE: no multiplayer peer is set, so the tree's unique id is 0.  Each case
	# forces `body`'s authority to match (or mismatch) that id to produce the
	# relation `_is_own_model()` reads, and asserts the predicate took effect —
	# otherwise the run would be vacuously green.
	await _check("remote model (bot)", character, false, true)
	await _check("own model", character, true, false)

	print("---")
	if _failures == 0:
		print("PASS: rim layer handshake is correct")
	else:
		printerr("FAIL: %d assertion(s) failed" % _failures)
	get_tree().quit(_failures)


func _check(label: String, character: Character, expect_own: bool, expect_layer: bool) -> void:
	var player: Node = load("res://player/player.tscn").instantiate()
	player.name = "1"
	# A bot's `_enter_tree` branch pins body authority to 1; a human's sets it to
	# its own id.  Either way, re-pin it so it agrees with (own) or differs from
	# (remote) this process's unique id.
	player.is_bot = false
	add_child(player)
	await get_tree().process_frame

	var unique_id: int = multiplayer.get_unique_id()
	player.body.set_multiplayer_authority(unique_id if expect_own else unique_id + 1)

	var is_own: bool = player._is_own_model()
	if is_own != expect_own:
		_failures += 1
		printerr("FAIL [%s]: _is_own_model() is %s, expected %s — case not exercised" % [
			label, is_own, expect_own,
		])

	player.set_character(character)
	await get_tree().process_frame

	if player.model_script == null:
		_failures += 1
		printerr("FAIL [%s]: model_script is null — character model did not spawn" % label)
		player.queue_free()
		return

	var meshes: Array[Node] = player.model.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		_failures += 1
		printerr("FAIL [%s]: character model has no MeshInstance3D children" % label)
		player.queue_free()
		return

	var on_layer := 0
	for node in meshes:
		if (node as MeshInstance3D).layers & RIM_LAYER:
			on_layer += 1

	var ok := (on_layer == meshes.size()) if expect_layer else (on_layer == 0)
	if not ok:
		_failures += 1
	print("%s [%s]: %d/%d meshes on the rim layer (expected %s)" % [
		"ok  " if ok else "FAIL",
		label,
		on_layer,
		meshes.size(),
		"all" if expect_layer else "none",
	])
	player.queue_free()
