@tool
extends Node
class_name Map

## Populated by `_enter_tree()` from this node's **direct** `Marker3D` children, and by
## nothing else — see the rules there.  Deliberately NOT `@export`: an inspector slot
## would look authoritative, accept assignments, and then have every one of them wiped on
## load, so a renamed marker would silently change spawning while the Inspector still read
## correctly.  The names are the source of truth.
var spi_spawn_locations: Array[Marker3D] = []
var sci_spawn_locations: Array[Marker3D] = []



@export var despawn_location: Marker3D
@onready var camera: Camera3D = $Camera3D

## Fills in the `target`/`targetname` links of this map's payload route and saves them to the
## `.map` it is built from.
##
## A route chains by placement order by default, which needs nothing typed but breaks when a
## point is inserted into the middle of an existing one — the new point is created last, so it
## appends to the end of the chain rather than slotting in. Pressing this once makes the links
## explicit, after which insertion cannot reorder anything. Points that already have a name or
## a `target` are left alone, so it is safe to press repeatedly. See [PayloadPathLinker].
@export_tool_button("Auto Setup Payload Path") var auto_setup_payload_path: Callable = _auto_setup_payload_path

## Bakes this map's payload route and its railroad track into the scene, so both are saved and
## visible in the editor rather than compiled at runtime.
##
## [b]You usually do not need this button[/b] — [method _notification] runs the same bake on
## every save. Press it only to see the result before saving, which also avoids the one extra
## save the hook costs: adding nodes during a save marks the scene dirty again, so the save you
## pressed it before is the only one.
##
## Writes two nodes under this map root, never under the `FuncGodotMap`: [PayloadPath] (the
## route, a shell — its zone table and glowing line are rebuilt on every peer) and the track
## container [constant PayloadTrackBuilder.CONTAINER_NAME].  See [PayloadPathBuilder.bake_path]
## and [PayloadTrackBuilder.bake].
@export_tool_button("Bake Payload Route & Track") var bake_payload_route: Callable = bake_payload_route_and_track

## Standardises this map for navigation-mesh baking: adds the map root to
## [constant NavmeshGenerator.NAV_GROUP], creates or reuses a direct-child
## [NavigationRegion3D], and applies the agent/cell settings from [NavmeshGenerator].
##
## Safe to press repeatedly — it never adds a second region.  It does not bake by default; use
## the region's "Bake NavigationMesh" inspector button, or set
## [constant NavmeshGenerator.BAKE_AFTER_SETUP].
@export_tool_button("Setup Navigation") var setup_navigation: Callable = _setup_navigation

## The painted-toon world preset every surface is re-shaded through, and whether this map
## is currently wearing it.  [b]These two are the only thing the swap persists.[/b]  Every
## per-surface [ShaderMaterial] is derived from the preset when the map loads, because
## Godot drops property overrides written into an instanced sub-scene on save
## (`05-known-issues.md` #1099) and would otherwise bake one generated SubResource per
## surface into the map scene.  See [ToonMaterialConverter].
@export var toon_world_preset: ShaderMaterial = preload("res://assets/materials/painted_toon_world.tres")
@export var toon_world_enabled: bool = false

## Re-shades every mesh and CSG surface in the map through [member toon_world_preset],
## keeping each surface's own textures.  Every scalar comes from the preset, so editing it
## re-tunes the whole map — see [ToonMaterialConverter.convert_material].  Safe to press
## repeatedly.
@export_tool_button("Replace With Painted Toon World") var replace_toon_world: Callable = replace_with_painted_toon_world

## Puts back every material [method replace_with_painted_toon_world] replaced.
@export_tool_button("Reset To Original Materials") var reset_toon_world: Callable = reset_to_original_materials

func _enter_tree() -> void:
	# `@tool` is here for the button above, and nothing else on this node has any business
	# running while the editor has a map scene open — the spawn pools and the global below
	# are read at runtime only.
	if Engine.is_editor_hint():
		return

	GameManager.game_mode_component = $GameModeComponent

	var spawn_parent := GameManager.spawn_parent
	if spawn_parent != null and spawn_parent.get_parent() != null:
		var hud := spawn_parent.get_parent().get_node_or_null("GameMenu/CanvasLayer")
		if hud != null and hud.has_method("setup_gmc"):
			hud.setup_gmc()

	# Spawn discovery.  This is the ONLY thing that decides where players spawn, so the
	# rules are worth stating exactly — a spawn that stops qualifying silently drops out
	# of the pool and the map falls back to Vector3(0, 12, 0) rather than erroring.
	#
	#   - a spawn is a `PlayerSpawn` node, and ONLY that.  The pool comes from its `team`
	#     property; the node's NAME is never consulted.  Renaming a spawn therefore cannot
	#     move it between pools, and a stray `Marker3D` that merely has "spawn" in its
	#     name is ignored instead of being picked up as one.
	#   - recursive, because func_godot parents every entity it builds under its
	#     `FuncGodotMap` node: a spawn placed through TrenchBroom is one level deeper than
	#     a hand-placed one, and a direct-children scan found none of them.
	sci_spawn_locations.clear()
	spi_spawn_locations.clear()

	for node in find_children("*", "Marker3D", true, false):
		var spawn := node as PlayerSpawn
		if spawn == null:
			continue

		match spawn.team:
			PlayerSpawn.Team.SPI:
				spi_spawn_locations.append(spawn)
			PlayerSpawn.Team.SCI:
				sci_spawn_locations.append(spawn)
			_:
				# ANY — a spawn either team may use.  Also what an unset `team` gives,
				# since that is the property's default.
				spi_spawn_locations.append(spawn)
				sci_spawn_locations.append(spawn)


## A random spawn for `team`: where to stand **and** which way to face.
##
## The basis is built from the marker's yaw alone — not its `global_transform` — so a
## marker scaled in TrenchBroom cannot leak scale onto the player.  Yaw is the whole
## facing a first-person body has, so pitch/roll on a marker are ignored.
func get_random_spawn_transform(team: Player.Team) -> Transform3D:
	var picked: Marker3D = null
	if team == Player.Team.SPI and not spi_spawn_locations.is_empty():
		picked = spi_spawn_locations[randi() % spi_spawn_locations.size()]
	elif team == Player.Team.SCI and not sci_spawn_locations.is_empty():
		picked = sci_spawn_locations[randi() % sci_spawn_locations.size()]
	elif team != Player.Team.SPI and team != Player.Team.SCI:
		# FFA / any team: pick from all available spawns.
		var all_spawns: Array[Marker3D] = []
		all_spawns.append_array(sci_spawn_locations)
		all_spawns.append_array(spi_spawn_locations)
		if not all_spawns.is_empty():
			picked = all_spawns[randi() % all_spawns.size()]

	# Absolute fallback.
	if picked == null:
		return Transform3D(Basis.IDENTITY, Vector3(0, 12, 0))

	return Transform3D(Basis(Vector3.UP, picked.global_rotation.y), picked.global_position)

func get_despawn_position() -> Vector3:
	return despawn_location.global_position


# ─────────────────────────────────────────────
#  EDITOR TOOLS
# ─────────────────────────────────────────────

## Backing the "Auto Setup Payload Path" button — see [member auto_setup_payload_path].
##
## Editor-only in effect: it rewrites the `.map` this scene is built from, which is a source
## file a running game has no business touching.
##
## [b]Run it with the map closed in TrenchBroom, or reload it there straight afterwards.[/b]
## TrenchBroom holds the open map in memory and does not re-read the file underneath itself,
## so saving from it later would write the pre-link contents back over this.
func _auto_setup_payload_path() -> void:
	var func_map := _find_func_godot_map()
	if func_map == null:
		push_warning(
			"Map: no FuncGodotMap under this node, so there is no .map to link — this map was "
			+ "authored in the editor rather than in TrenchBroom.")
		return

	var map_path: String = func_map.local_map_file
	if map_path.is_empty():
		push_warning("Map: the FuncGodotMap has no local_map_file set, so there is no .map to link.")
		return
	if not FileAccess.file_exists(map_path):
		push_warning("Map: %s does not exist." % map_path)
		return

	var original := FileAccess.get_file_as_string(map_path)
	if original.is_empty():
		push_warning("Map: %s is empty or could not be read." % map_path)
		return

	var result := PayloadPathLinker.link_map_text(original)
	for message in result["messages"]:
		print("Payload path: %s" % message)

	# An unchanged result means there was nothing to fill in — writing anyway would rewrite
	# the file's bytes for no reason, and any diff noise is a real cost on a source file.
	if result["text"] == original:
		return

	var file := FileAccess.open(map_path, FileAccess.WRITE)
	if file == null:
		push_error("Map: could not open %s for writing (error %d)."
			% [map_path, FileAccess.get_open_error()])
		return
	file.store_string(result["text"])
	file.close()

	print("Payload path: wrote %s. Rebuild the map, and reload it in TrenchBroom to see the "
		% map_path + "links.")


## The [FuncGodotMap] this scene is built from, or `null` when it is not a TrenchBroom map.
##
## `find_children` is filtered by `is FuncGodotMap` rather than by a type string: the addon's
## class is a `class_name`, and `find_children`'s type filter only answers for native classes.
func _find_func_godot_map() -> FuncGodotMap:
	for node in find_children("*", "", true, false):
		if node is FuncGodotMap:
			return node as FuncGodotMap
	return null


# ─────────────────────────────────────────────
#  NAVIGATION
# ─────────────────────────────────────────────

## Backing the "Setup Navigation" button — see [member setup_navigation].
func _setup_navigation() -> void:
	NavmeshGenerator.setup(self)


# ─────────────────────────────────────────────
#  PAYLOAD BAKE
# ─────────────────────────────────────────────

## Backing the "Bake Payload Route & Track" button — see [member bake_payload_route].
##
## Editor-only in effect: it writes generated nodes into the scene, which is authoring work a
## running game has no business doing. Bakes the route first, because the track is swept along
## it, then reports what happened in the Output panel.
func bake_payload_route_and_track() -> void:
	if not Engine.is_editor_hint():
		push_warning("Map: the payload bake is editor-only.")
		return

	# Not `owner`: this script is on a `Node`, which already has an `owner` property, and
	# shadowing it is a warning rather than the scene root this actually is.
	var scene_root := _editable_owner()
	if scene_root == null:
		return

	var path := PayloadPathBuilder.bake_path(self, scene_root)
	var track := PayloadTrackBuilder.bake(self, scene_root)

	if path != null:
		print("Map: baked payload route — %d point(s)." % path.curve.point_count)
	if not String(track["warning"]).is_empty():
		push_warning("Map: payload track — %s." % track["warning"])
	elif bool(track["changed"]):
		print("Map: baked payload track — %d tie(s), %d vertex(es)."
			% [track["ties"], track["vertices"]])
	else:
		print("Map: payload track is already up to date.")


## The bake [method bake_payload_route_and_track] runs on every save, so a route edited in
## TrenchBroom is re-baked the moment it is saved — no button press.
##
## Silent on a map with no payload route (the lobby, an ordinary gameplay map): this fires for
## *every* map save, and warning about the absence of a feature is noise.
func _auto_bake_payload() -> void:
	if not Engine.is_editor_hint():
		return
	if not _has_payload_route():
		return

	var scene_root := _editable_owner()
	if scene_root == null:
		return

	PayloadPathBuilder.bake_path(self, scene_root)
	PayloadTrackBuilder.bake(self, scene_root)


## Whether anything here should ever be baked.  True when the map already carries a route — a
## baked [PayloadPath] or a hand-authored one — or has the path points to build one from.
func _has_payload_route() -> bool:
	if PayloadTrackBuilder.find_route(self) != null:
		return true
	return PayloadPathBuilder.find_path_points(self).size() >= 2


## The node the generated route and track must be owned by to serialize, or `null` when baking
## would write into the wrong file.
##
## [method Node.add_child] does not propagate `owner`, so without this the nodes would exist
## only in the editor session and vanish on reload.  The owner is the *edited scene root*, not
## [member owner] — this script is on that root, so its own `owner` is `null`.  When the map is
## instanced inside another scene instead (the thumbnail generator, a test scene) the two
## differ, and baking then would serialize the generated nodes into the enclosing file.
func _editable_owner() -> Node:
	if not is_inside_tree():
		return null
	var root := get_tree().edited_scene_root
	if root != self:
		push_warning(
			"Map: not baking — this map is instanced inside another scene, so the generated "
			+ "route and track would serialize into that scene's file instead of this map's.")
		return null
	return root


## Drops the baked route's derived half — the zone table and the tube mesh — so neither reaches
## the `.tscn`.  Mirror of [method _strip_derived_materials], and for the same reason.
func _strip_derived_route() -> void:
	for node in find_children("*", "", true, false):
		var path := node as PayloadPath
		if path != null:
			path.strip_derived()


# ─────────────────────────────────────────────
#  PAINTED TOON WORLD
# ─────────────────────────────────────────────

## What [method replace_with_painted_toon_world] found before it swapped, so
## [method reset_to_original_materials] can put it back.  Deliberately NOT `@export`:
## it holds live node references, and the only durable record of "this map is tooned"
## is [member toon_world_enabled].
var _saved_materials: Dictionary = {}

## The [ShaderMaterial]s the swap generated, one per distinct source material, so a change
## to [member toon_world_preset] can be written straight into them.  See [method _on_preset_changed].
var _generated_materials: Array = []

## [member toon_world_preset]'s parameter values as of the last refresh.  [method _process]
## compares against this to notice an edit to the preset — see [method _watch_preset].
var _preset_snapshot: Array = []


func _ready() -> void:
	# Re-derive rather than serialize.  `_ready` runs in the editor as well as in game,
	# which is exactly what makes the preview survive a reload — and it is what keeps a
	# joining client's copy of the map tooned without any RPC.
	_watch_preset()
	if toon_world_enabled:
		replace_with_painted_toon_world()


func _exit_tree() -> void:
	# Never leave derived materials behind when the map scene is closed or reloaded in the
	# editor.  A runtime teardown (map swap) has nothing to strip for: the whole tree is
	# going with it.
	if Engine.is_editor_hint():
		_strip_derived_route()
		_strip_derived_materials()


func _notification(what: int) -> void:
	# Derived state must not reach the `.tscn`.  Godot only serializes overrides on an
	# instance's *root* (#1099), but geometry a map scene owns outright — the func_godot
	# [MeshInstance3D], `bind.tscn`'s editable-instance meshes — would serialize one
	# generated SubResource per surface, thousands of them on the big maps.  Strip before
	# the write, put the preview back after it.  Note [member toon_world_enabled] is left
	# alone, so the post-save re-apply can see it.
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		# The bake must run *before* the write, so the nodes it adds are in the file.  It goes
		# first so the route's derived half can then be stripped like the toon materials are;
		# `POST_SAVE`'s re-apply walks the whole map, so the fresh track is re-tooned there
		# without any ordering special-case here.
		_auto_bake_payload()
		_strip_derived_route()
		_strip_derived_materials()
	elif what == NOTIFICATION_EDITOR_POST_SAVE and toon_world_enabled:
		replace_with_painted_toon_world()


## Backing the "Replace With Painted Toon World" button.
##
## Idempotent — pressing it again re-derives from the originals rather than converting the
## toon materials it made the first time.
func replace_with_painted_toon_world() -> void:
	if toon_world_preset == null or toon_world_preset.shader == null:
		push_warning("Map: no toon world preset is set, so there is nothing to swap to.")
		return

	# Re-entering would convert our own output, so start from the originals.
	_strip_derived_materials()
	_watch_preset()

	var result := ToonMaterialConverter.swap_under(self, toon_world_preset)
	_saved_materials = result["state"]
	_generated_materials = result["generated"]
	toon_world_enabled = true
	_watch_preset()

	print("Map: painted toon world — %d surface(s) swapped, %d skipped (%s)."
		% [result["converted"], result["skipped"], name])


## Backing the "Reset To Original Materials" button.
func reset_to_original_materials() -> void:
	_strip_derived_materials()
	toon_world_enabled = false
	_watch_preset()


## Undoes a swap without touching [member toon_world_enabled].  Separate from
## [method reset_to_original_materials] because the save/close paths must strip the
## derived materials *without* clearing the flag that says to put them back.
func _strip_derived_materials() -> void:
	_generated_materials.clear()
	if _saved_materials.is_empty():
		return
	ToonMaterialConverter.restore(_saved_materials)
	_saved_materials.clear()


## Arms — or disarms — the live preview, and re-baselines the snapshot it compares against.
##
## [b]Why this polls instead of watching [signal Resource.changed].[/b]  It would be the
## obvious mechanism, and it does not work: `ShaderMaterial.set_shader_parameter` does not
## emit `changed` (verified — setting a parameter and then checking the signal shows it
## never fired), which is exactly the edit this feature exists to catch.  Editing a `.tres`
## through the inspector may or may not raise it depending on the editor's own property
## path, so relying on it risks a feature that silently does nothing.
##
## So the map compares [member toon_world_preset]'s values against the last snapshot once a
## frame instead — see [method _process].  [b]Editor-only, and only while tooned:[/b]
## [method set_process] is off in game and off whenever [member toon_world_enabled] is
## false, so this costs a running peer nothing at all, and nothing to a mapper who has not
## turned the preview on.
func _watch_preset() -> void:
	set_process(Engine.is_editor_hint() and toon_world_enabled)
	_preset_snapshot = _preset_values()


func _process(_delta: float) -> void:
	# Live preview.  A drag on a slider in `painted_toon_world.tres` lands here as one
	# refresh per frame, which is why [method ToonMaterialConverter.refresh] rewrites the
	# generated materials in place: no node property is reassigned, so the scene is not
	# re-dirtied and nothing has to be reallocated on every tick.
	var values := _preset_values()
	if values == _preset_snapshot:
		return
	_preset_snapshot = values
	ToonMaterialConverter.refresh(_generated_materials, toon_world_preset)


## Every uniform of the preset, in declaration order, as one comparable Array.
func _preset_values() -> Array:
	var values: Array = []
	if toon_world_preset == null or toon_world_preset.shader == null:
		return values
	for uniform in toon_world_preset.shader.get_shader_uniform_list():
		values.append(toon_world_preset.get_shader_parameter(uniform["name"]))
	return values
