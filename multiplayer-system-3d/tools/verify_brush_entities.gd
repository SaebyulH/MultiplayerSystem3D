extends Node
## Builds `trenchbroom/maps/brush_entity_test.map` and checks that the brush entities come
## out of the build wired to each other.
##
## The thing under test is the build-time `trigger` → `use()` link, which func_godot has no
## equivalent of and which [BrushEntityUtil.link_targets] reimplements.  Everything about
## it is easy to get silently wrong:
##
##   * it only runs from `_func_godot_build_complete`, which the assembler calls *deferred*
##     — so linking from `_func_godot_apply_properties` instead finds only the entities
##     built before this one, and a map whose mover happens to come first still looks fine;
##   * it resolves `target` against `targetname` by walking the map subtree, so a name typo
##     connects nothing and a wrong root finds nothing;
##   * it must connect `CONNECT_PERSIST`, or the link is live in the editor and gone from
##     the saved scene the moment the editor closes.
##
## This proves the connection is made, resolves, and carries the persist flag.  It cannot
## prove the *serialization*: connections only reach a `.tscn` when both endpoints carry an
## `owner`, and `edited_scene_root` is null outside the editor, so that half still needs a
## real build-and-save in the editor.
##
## HOW TO USE:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/verify_brush_entities.tscn
##
## Expect a wall of `Attempting to initialize the wrong RID` / `mesh_set_blend_shape_mode`
## errors from `generate_solid_entity_node` on the way through.  They are the dummy
## renderer: `--headless` has no mesh storage, so every entity that builds visuals trips it.
## They are printed, not fatal, and the run still reaches its assertions — the exit code is
## the thing to read.
##
## Exits with the number of failed assertions, so 0 means the wiring works.

const MAP_SETTINGS_PATH := "res://trenchbroom/multiplayer_system_3d_map_settings.tres"
const FIXTURE_PATH := "res://trenchbroom/maps/brush_entity_test.map"

## The mover's authored `move_translation` in the fixture, in TrenchBroom map units.
const FIXTURE_MOVE_TRANSLATION := 64.0
## The button's authored `depth`, likewise.
const FIXTURE_DEPTH := 16.0
## The physics brush's authored `velocity`, in map units per second, along TrenchBroom's
## up axis.
const FIXTURE_VELOCITY := 32.0
## `FuncGodotMapSettings.inverse_scale_factor`, the divisor the build applies.
const MAP_UNITS_PER_GODOT_UNIT := 32.0

var _failures := 0


func _ready() -> void:
	var settings := load(MAP_SETTINGS_PATH) as FuncGodotMapSettings
	if settings == null:
		printerr("FAIL: could not load %s" % MAP_SETTINGS_PATH)
		get_tree().quit(1)
		return

	var map := FuncGodotMap.new()
	map.map_settings = settings
	map.local_map_file = FIXTURE_PATH
	add_child(map)

	var verify_err := map.verify()
	if verify_err != OK:
		printerr("FAIL: could not open %s (error %d)" % [FIXTURE_PATH, verify_err])
		get_tree().quit(1)
		return

	map.build()
	# `_func_godot_build_complete` is `call_deferred` per entity, so the wiring does not
	# exist until the deferred queue has run.  One idle frame, plus one to spare, because
	# this is precisely the timing the check is here to catch.
	await get_tree().process_frame
	await get_tree().process_frame

	var mover := _sole(map, "MovingBrush") as MovingBrush
	var trigger := _sole(map, "TriggerVolume") as TriggerVolume
	var button := _sole(map, "ButtonBrush") as ButtonBrush
	var rotator := _sole(map, "RotatingBrush") as RotatingBrush
	var body := _sole(map, "PhysicsBrush") as PhysicsBrush

	if mover == null or trigger == null or button == null or rotator == null or body == null:
		_report()
		return

	# 1. The link itself, which is the whole point.
	_check_link(trigger, mover)
	_check_link(button, mover)

	# 2. A source with no target must not be wired to anything.
	if trigger.target == "door_01":
		print("ok   target: trigger carries its target name")
	else:
		_fail("trigger.target is %s, expected \"door_01\"" % trigger.target)

	# 3. Axes converted at build time.  Every one of these is typed in TrenchBroom's Z-up
	#    axes and has to arrive in Godot's Y-up ones; the assertions are raw Godot vectors
	#    rather than calls back into BrushEntityUtil, so they cannot agree with a broken
	#    helper.  A missing swap is invisible in TrenchBroom and moves the brush sideways.
	_check_vector("mover.move_translation", mover.move_translation,
		Vector3(0.0, FIXTURE_MOVE_TRANSLATION / MAP_UNITS_PER_GODOT_UNIT, 0.0))
	_check_vector("rotate.axis", rotator.axis, Vector3(0.0, 1.0, 0.0))
	_check_vector("physics.velocity", body.velocity, Vector3(0.0, FIXTURE_VELOCITY / MAP_UNITS_PER_GODOT_UNIT, 0.0))

	# 4. Map units converted too.  A length left raw would be 32x too far, which looks like
	#    a working door until the mover ends up in the next room.
	_check_converted("button.depth", button.depth, FIXTURE_DEPTH)
	_check_unchanged("mover.speed", mover.speed, 1.0)
	_check_unchanged("rotate.speed", rotator.speed, 90.0)
	_check_unchanged("physics.mass", body.mass, 20.0)

	# 5. `build_visuals = false` gates only the mesh (`geometry_generator.gd:522-540`);
	#    collision is built separately (`:546`).  A trigger that lost its collision would
	#    build cleanly and never fire.
	_check_has_collision(trigger, "trigger")
	_check_has_collision(button, "button")
	_check_has_collision(mover, "mover")
	_check_no_mesh(trigger, "trigger")

	_check_wait_logic()
	_check_pose()
	_report()


## The pose must be a function of [member MovingBrush._progress] alone.
##
## This is the assertion the mover's first version needed. Anchoring the interpolation at
## the pose being travelled *to* looks right on the way out and collapses on the way back:
## once the target is the authored pose, both ends of the interpolation are the same
## transform, so every progress value yields fully closed and the mover snaps home instead
## of travelling. Needs no clock, no map and no peer — just the two ends and the midpoint.
func _check_pose() -> void:
	var m := MovingBrush.new()
	# Kinematic bodies defer their transform to the physics step, and the arithmetic under
	# test here writes `global_transform` and reads it straight back.
	m.sync_to_physics = false
	add_child(m)

	m.base_transform = Transform3D(Basis(), Vector3.ZERO)
	m.move_translation = Vector3(0, 2, 0)
	m._build_offset_transform()

	m._progress = 0.0
	m._apply_progress()
	var closed := m.global_transform.origin

	m._progress = 1.0
	m._target_open = true
	m._apply_progress()
	var outbound := m.global_transform.origin

	# The same progress while heading the other way has to be the same place. `_target_open`
	# says which way the mover is moving; it must not say where it is.
	m._target_open = false
	m._apply_progress()
	var inbound := m.global_transform.origin

	m._progress = 0.5
	m._apply_progress()
	var halfway := m.global_transform.origin

	if closed.is_equal_approx(Vector3.ZERO):
		print("ok   pose: progress 0 is the authored pose")
	else:
		_fail("progress 0 gave %s, expected the authored pose" % closed)

	if outbound.is_equal_approx(Vector3(0, 2, 0)):
		print("ok   pose: progress 1 is the offset pose")
	else:
		_fail("progress 1 gave %s, expected (0, 2, 0)" % outbound)

	if inbound.is_equal_approx(outbound):
		print("ok   pose: the return leg travels the same path rather than snapping")
	else:
		_fail("the same progress gave %s outbound and %s inbound — the pose depends on which"
			% [outbound, inbound]
			+ " way the mover is heading, so returning collapses to the end point")

	if halfway.is_equal_approx(Vector3(0, 1, 0)):
		print("ok   pose: the midpoint is halfway along")
	else:
		_fail("progress 0.5 gave %s, expected (0, 1, 0)" % halfway)

	remove_child(m)
	m.free()


## Drives the wait / toggle / automatic state machine directly, on a bare node.
##
## The map fixture cannot cover this. The behaviour is a function of elapsed time, and
## stepping enough physics frames to watch a real mover complete a return trip would make
## the harness slow and timing-dependent — for decisions that are all reachable without a
## map, a clock, or a peer.
func _check_wait_logic() -> void:
	# In the tree, because `Node.multiplayer` is null outside it and every gated method
	# below reads it — off the tree, `play_motion` dies on a null call rather than no-opping.
	var m := MovingBrush.new()
	add_child(m)

	# 1. Arming, which happens on the frame the mover lands on a pose.
	m.wait = -1.0
	m._arm_rest_timer()
	if m._rest_pending:
		_fail("wait = -1 armed a timer — the mover would move itself")
	else:
		print("ok   wait: -1 arms nothing, so the pose is permanent")

	m.wait = 0.5
	m._arm_rest_timer()
	if m._rest_pending and is_equal_approx(m._rest_timer, 0.5):
		print("ok   wait: 0.5 arms a 0.5 s timer")
	else:
		_fail("wait = 0.5 armed %s (pending=%s), expected 0.5" % [m._rest_timer, m._rest_pending])

	# `0` is legal and means "the instant it lands". This is the whole reason arming needs
	# a separate flag — a zero timer is otherwise indistinguishable from "idle".
	m._clear_rest_timer()
	m.wait = 0.0
	m._arm_rest_timer()
	if m._rest_pending:
		print("ok   wait: 0 arms an immediate timer rather than hanging")
	else:
		_fail("wait = 0 armed nothing — the mover would hang until its next trigger")

	# 2. The guard, which is toggle-only. A one-shot door needs none: `play_motion` already
	# no-ops while it is open.
	m._clear_rest_timer()
	m.toggle = false
	m._rest_pending = true
	if m._is_guarded():
		_fail("a one-shot mover was guarded — triggers would be swallowed while it sits open")
	else:
		print("ok   guard: a one-shot mover is never guarded")

	m.toggle = true
	if m._is_guarded():
		print("ok   guard: a toggling mover is guarded while its wait runs")
	else:
		_fail("a toggling mover was not guarded — a player in the trigger would rattle it open and shut")

	m._clear_rest_timer()
	if m._is_guarded():
		_fail("a toggling mover stayed guarded after the wait expired")
	else:
		print("ok   guard: clears when the wait expires")

	# 3. Expiry — what the wait actually does, which is the only thing the three flags
	# disagree about.
	m.automatic = false
	m.toggle = false
	m._target_open = true
	m._on_rest_elapsed()
	if m._target_open:
		_fail("one-shot: the wait expired and the mover stayed open")
	else:
		print("ok   expiry: a one-shot mover returns home")

	m.automatic = false
	m.toggle = true
	m._target_open = false
	m._on_rest_elapsed()
	if m._target_open:
		_fail("toggle: the wait expired and the mover moved on its own")
	else:
		print("ok   expiry: a toggling mover stays put and re-arms")

	m.automatic = true
	m.toggle = false
	m._target_open = false
	m._on_rest_elapsed()
	if m._target_open:
		print("ok   expiry: an automatic mover starts a leg from home")
	else:
		_fail("automatic: the wait expired at home and nothing moved")

	m._target_open = true
	m._on_rest_elapsed()
	if m._target_open:
		_fail("automatic: the wait expired at the far pose and it did not come back")
	else:
		print("ok   expiry: an automatic mover turns around at the far pose")

	remove_child(m)
	m.free()


## Asserts `source`'s `trigger` signal is connected to `target.use()`, with CONNECT_PERSIST
## set — that flag is what carries the link into the saved scene.
func _check_link(source: Node, target: Node) -> void:
	var wanted := Callable(target, "use")
	if not source.is_connected("trigger", wanted):
		_fail("%s is not connected to %s.use()" % [source.name, target.name])
		return
	print("ok   wired: %s -> %s.use()" % [source.name, target.name])

	for connection in source.get_signal_connection_list("trigger"):
		if connection["callable"] != wanted:
			continue
		if int(connection["flags"]) & CONNECT_PERSIST:
			print("ok   persist: %s -> %s would serialize" % [source.name, target.name])
		else:
			_fail("%s -> %s is connected without CONNECT_PERSIST — it would vanish on save"
				% [source.name, target.name])
		return


## Exact-vector comparison against a literal Godot-space value.  Deliberately not derived
## from the authored `.map` text through the same helper the build uses — a test that
## computes its expectation the way the code under test does cannot detect that code being
## wrong.
func _check_vector(label: String, actual: Vector3, expected: Vector3) -> void:
	if actual.is_equal_approx(expected):
		print("ok   axes: %s = %s" % [label, actual])
	else:
		_fail("%s is %s, expected %s — TrenchBroom's Z-up axes were not swapped to Godot's Y-up"
			% [label, actual, expected])


func _check_converted(label: String, actual: float, authored_map_units: float) -> void:
	var expected := authored_map_units / MAP_UNITS_PER_GODOT_UNIT
	if is_equal_approx(actual, expected):
		print("ok   units: %s = %s Godot units (from %s map units)"
			% [label, actual, authored_map_units])
	else:
		_fail("%s is %s, expected %s — map units were not converted at build time"
			% [label, actual, expected])


func _check_unchanged(label: String, actual: float, expected: float) -> void:
	if is_equal_approx(actual, expected):
		print("ok   value: %s %s" % [label, actual])
	else:
		_fail("%s is %s, expected %s — a non-length property was converted by mistake"
			% [label, actual, expected])


func _check_has_collision(node: Node, label: String) -> void:
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			print("ok   collision: %s has a shape" % label)
			return
	_fail("%s has no CollisionShape3D — it would build cleanly and never interact" % label)


func _check_no_mesh(node: Node, label: String) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_fail("%s has a MeshInstance3D — build_visuals = false was ignored" % label)
			return
	print("ok   invisible: %s has no mesh" % label)


## The single node of the given script class under the built map.
func _sole(root: Node, script_class: String) -> Node:
	var found: Array[Node] = []
	for node in root.find_children("*", "", true, false):
		if node.get_script() != null and node.get_script().get_global_name() == script_class:
			found.append(node)
	if found.size() != 1:
		_fail("expected exactly one %s, found %d" % [script_class, found.size()])
		return null
	return found[0]


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL: %s" % message)


func _report() -> void:
	print("---")
	if _failures == 0:
		print("PASS: brush entities built and wired")
	else:
		printerr("FAIL: %d assertion(s) failed" % _failures)
	get_tree().quit(_failures)
