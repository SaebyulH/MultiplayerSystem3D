extends RefCounted
class_name NavmeshGenerator

## Editor-only helper that gives a map a standard [NavigationRegion3D] and [NavigationMesh].
##
## Static, like [PayloadPathBuilder] — not an autoload and not `@tool`; only [Map]'s tool button
## calls it.  It writes editor-time state (a group, a node, a resource), so it refuses to run
## outside the editor.
##
## [b]Idempotent.[/b]  The map root joins [constant NAV_GROUP] once, a direct-child
## [NavigationRegion3D] is reused, and each resource property is written only when it differs.
## Pressing the button twice adds nothing and touches nothing.

## The map root joins this group.  [member NavigationMesh.geometry_source_group_name] points
## here, so a bake walks the whole map — including geometry a `FuncGodotMap` parents under
## itself — rather than only the region's subtree.  The add must be persistent to survive a save.
const NAV_GROUP: StringName = &"map_nav_geometry"

## Name for a newly created region only.  An existing region is found by direct-child type,
## never by name.
const REGION_NAME: StringName = &"NavigationRegion3D"

# ─────────────────────────────────────────────
#  SOURCE GEOMETRY
# ─────────────────────────────────────────────

## Read collision, not meshes: plain [MeshInstance3D] props, spawn markers and other visual
## geometry contribute no polygons.  Static-collider mode parses [StaticBody3D] shapes
## (func_godot's generated collision and collision-bearing props) and [CSGShape3D] nodes with
## `use_collision` enabled (the hand-authored CSG maps).
const PARSED_GEOMETRY_TYPE: NavigationMesh.ParsedGeometryType = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

## Layer 1 (WORLD), where every map collider lives.  In static-collider mode this mask decides
## which bodies are read; players, hurtboxes and other layers are ignored.
const GEOMETRY_COLLISION_MASK: int = 1 << 0

# ─────────────────────────────────────────────
#  AGENT & CELL SETTINGS
# ─────────────────────────────────────────────

## `player/player.tscn`: `CapsuleShape3D_kb6p2.radius` on the root's `CollisionShape3D`.
## Recast quantises the radius up to a whole cell during a bake (0.4243164 → 2 × 0.25 = 0.5 m);
## the authored value is kept here so the source stays traceable.
const AGENT_RADIUS: float = 0.4243164

## The capsule's `height` is unauthored (engine default 2.0) and its origin is y = 1.0, so the
## standing body spans y = 0..2.  `player.gd`'s `stand_height = 2.0` agrees.  Crouch height
## (1.3333) is deliberately ignored — an agent must fit standing.
const AGENT_HEIGHT: float = 2.0

## FLAGGED — the player has no step-up; bots climb risers with knee-probe jumps
## (`bot_controller.gd` `Traversal._perceive` / `_ledge_jump_state`).  Recast
## links walkable surfaces up to this height difference, and the player's jump
## apex is ~1.27 m, so 1.0 m (four 0.25 m cells) is the tallest ledge the mesh
## may connect and the follower can still clear.  Raising it further creates
## links the character cannot climb; lowering it leaves jumpable ledges out of
## the mesh.  This is a traversal abstraction, not geometry: a 1.0 m connection
## is drawn across a face the character must jump.  Lower it for a more literal
## mesh, at the cost of losing navmesh routes up those ledges.  Re-bake every
## map after changing this — the baked vertices, not this constant, are what
## ships.
const AGENT_MAX_CLIMB: float = 1.0

## FLAGGED — engine default: `CharacterBody3D.floor_max_angle` is not authored on the player, so
## 45° is the steepest surface it can stand on.
const AGENT_MAX_SLOPE: float = 35.0

## FLAGGED — not derived: the player has no cell size.  These are the NavigationMesh and
## NavigationServer 3D defaults; `project.godot` overrides neither, so they match the live map.
## Raising fidelity further means 0.125 and also setting `navigation/3d/default_cell_size`
## and `navigation/3d/default_cell_height` to 0.125 (the bake cell and the map cell must
## match), then re-baking EVERY map; see "Navigation mesh setup" in
## `docs/06-trenchbroom-entities.md`.
const CELL_SIZE: float = 0.25
const CELL_HEIGHT: float = 0.25

## How closely the simplified contour may follow the collision outline, in CELL units
## (Recast voxels, the same unit family as `detail_sample_*`).  Godot's default 1.3 is
## ≈0.33 m at 0.25 m cells; 0.25 is ≈6 cm.  `edge_max_length` is in the same units.
const EDGE_MAX_ERROR: float = 0.25

## Detail-mesh sampling distance and max height error, in CELL units.  Godot's defaults
## (6.0 / 1.0) sample only every 1.5 m at 0.25 m cells; 1.0 / 0.1 samples every 0.25 m
## with ~2.5 cm height error.  This is what makes the drawn mesh hug uneven floors.
const DETAIL_SAMPLE_DISTANCE: float = 1.0
const DETAIL_SAMPLE_MAX_ERROR: float = 0.1

## Godot's defaults (2.0 / 20.0) discard small patches and merge regions up to 20 cells
## across.  1.0 / 8.0 keeps small ledges and landings while still removing raster noise.
const REGION_MIN_SIZE: float = 1.0
const REGION_MERGE_SIZE: float = 8.0

## Opt-in convenience bake.  Off by default: parsing the SceneTree runs on the editor's main
## thread and can freeze it for a long time on the large maps, so the region's own
## "Bake NavigationMesh" inspector button is the normal path.
const BAKE_AFTER_SETUP: bool = false


static func setup(map: Node) -> void:
	if not Engine.is_editor_hint():
		push_warning("NavmeshGenerator: navigation setup is editor-only.")
		return
	if not map.is_inside_tree():
		push_warning("NavmeshGenerator: the map is not inside the scene tree.")
		return

	# Same rule as Map._editable_owner(): the owner must be the edited scene root, and a map
	# instanced inside another scene would serialize its region into that scene's file.
	var scene_root := map.get_tree().edited_scene_root
	if scene_root != map:
		push_warning(
			"NavmeshGenerator: not setting up navigation — this map is instanced inside "
			+ "another scene, so the region would serialize into that scene's file instead of "
			+ "this map's.")
		return

	var regions: Array[NavigationRegion3D] = []
	for child in map.get_children():
		var candidate := child as NavigationRegion3D
		if candidate != null:
			regions.append(candidate)

	if regions.size() > 1:
		push_warning(
			"NavmeshGenerator: this map has %d direct NavigationRegion3D children. Keep one and "
			% regions.size() + "press Setup Navigation again.")
		return

	var region: NavigationRegion3D = null
	if not regions.is_empty():
		region = regions[0]
		if region.is_baking():
			push_warning(
				"NavmeshGenerator: a bake is already running on '%s'; wait for it to finish."
				% String(region.get_path()))
			return

	var changed := false

	# `persistent = true` is required: PackedScene only writes persistent groups, and a
	# non-persistent membership would be gone the next time the map loads.
	if not map.is_in_group(NAV_GROUP):
		map.add_to_group(NAV_GROUP, true)
		changed = true

	var created := false
	if region == null:
		region = NavigationRegion3D.new()
		region.name = REGION_NAME
		map.add_child(region)
		# `add_child` does not propagate ownership.  The region has no children of its own,
		# so this single assignment covers the whole new subtree.
		region.owner = scene_root
		created = true
		changed = true

	# Reuse the existing mesh rather than replacing it: a replacement would discard whatever
	# was already baked and mint a new SubResource on every press.  These setters change bake
	# inputs only — they do not clear existing vertices/polygons.
	var navmesh: NavigationMesh = region.navigation_mesh
	if navmesh == null:
		navmesh = NavigationMesh.new()
		region.navigation_mesh = navmesh
		changed = true

	if navmesh.geometry_parsed_geometry_type != PARSED_GEOMETRY_TYPE:
		navmesh.geometry_parsed_geometry_type = PARSED_GEOMETRY_TYPE
		changed = true
	if navmesh.geometry_collision_mask != GEOMETRY_COLLISION_MASK:
		navmesh.geometry_collision_mask = GEOMETRY_COLLISION_MASK
		changed = true
	if navmesh.geometry_source_geometry_mode != NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN:
		navmesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		changed = true
	if navmesh.geometry_source_group_name != NAV_GROUP:
		navmesh.geometry_source_group_name = NAV_GROUP
		changed = true
	if not is_equal_approx(navmesh.agent_radius, AGENT_RADIUS):
		navmesh.agent_radius = AGENT_RADIUS
		changed = true
	if not is_equal_approx(navmesh.agent_height, AGENT_HEIGHT):
		navmesh.agent_height = AGENT_HEIGHT
		changed = true
	if not is_equal_approx(navmesh.agent_max_climb, AGENT_MAX_CLIMB):
		navmesh.agent_max_climb = AGENT_MAX_CLIMB
		changed = true
	if not is_equal_approx(navmesh.agent_max_slope, AGENT_MAX_SLOPE):
		navmesh.agent_max_slope = AGENT_MAX_SLOPE
		changed = true
	if not is_equal_approx(navmesh.cell_size, CELL_SIZE):
		navmesh.cell_size = CELL_SIZE
		changed = true
	if not is_equal_approx(navmesh.cell_height, CELL_HEIGHT):
		navmesh.cell_height = CELL_HEIGHT
		changed = true
	if not is_equal_approx(navmesh.edge_max_error, EDGE_MAX_ERROR):
		navmesh.edge_max_error = EDGE_MAX_ERROR
		changed = true
	if not is_equal_approx(navmesh.detail_sample_distance, DETAIL_SAMPLE_DISTANCE):
		navmesh.detail_sample_distance = DETAIL_SAMPLE_DISTANCE
		changed = true
	if not is_equal_approx(navmesh.detail_sample_max_error, DETAIL_SAMPLE_MAX_ERROR):
		navmesh.detail_sample_max_error = DETAIL_SAMPLE_MAX_ERROR
		changed = true
	if not is_equal_approx(navmesh.region_min_size, REGION_MIN_SIZE):
		navmesh.region_min_size = REGION_MIN_SIZE
		changed = true
	if not is_equal_approx(navmesh.region_merge_size, REGION_MERGE_SIZE):
		navmesh.region_merge_size = REGION_MERGE_SIZE
		changed = true

	if changed:
		_mark_scene_unsaved()

	if BAKE_AFTER_SETUP:
		# Parsing the SceneTree is main-thread regardless of this flag; `true` only moves the
		# rasterisation to a worker.  The editor can still freeze while it parses.
		region.bake_finished.connect(
			func() -> void: _mark_scene_unsaved(),
			CONNECT_ONE_SHOT)
		region.bake_navigation_mesh(true)
		print("NavmeshGenerator: baking '%s' — this can freeze the editor while it parses."
			% String(region.get_path()))
	elif created:
		print("NavmeshGenerator: created %s under '%s'. Press its Bake NavigationMesh button."
			% [String(REGION_NAME), String(map.get_path())])
	elif changed:
		print("NavmeshGenerator: updated navigation on '%s'. Bake it to apply the settings."
			% String(region.get_path()))
	else:
		print("NavmeshGenerator: navigation is already set up on '%s'." % String(map.get_path()))


## Tool-script tree/resource edits do not mark the edited scene as modified by themselves.
##
## `EditorInterface` is editor-only and its bare identifier breaks exported builds, so it is
## looked up by name.
static func _mark_scene_unsaved() -> void:
	var editor_interface: Object = Engine.get_singleton(&"EditorInterface")
	if editor_interface != null and editor_interface.has_method(&"mark_scene_as_unsaved"):
		editor_interface.call(&"mark_scene_as_unsaved")
