@tool
extends Marker3D
class_name PlayerSpawn

## A player spawn point.
##
## The mannequin child is **editor-only decoration**. It exists so a mapper can see at a
## glance which pool a spawn feeds — SPI red, SCI blue, grey for one any team may use —
## and it is hidden the moment the game runs. That means this has to be `@tool`: run
## without it, nothing here executes in the editor, which is the only place the marker is
## meant to be seen.
##
## Which *pool* a spawn feeds is not decided here either: `Map._enter_tree()` finds every
## `PlayerSpawn` in the map and routes it by reading `team` below. The node's name is
## never consulted, so renaming one cannot move it between pools — see the
## spawn-discovery comment in `maps/map.gd`.

## Which pool this spawn feeds. Its own enum rather than `Player.Team`: a spawn has an
## `ANY` case the player enum has no room for, and this keeps the scene independent of
## `Player`. The values must stay in step with the `choices` list on
## `trenchbroom/entities/player_spawn.tres`, which is what a mapper actually picks from.
enum Team { SPI, SCI, ANY }

const COLORS := {
	Team.SPI: Color(1.0, 0.25, 0.25),
	Team.SCI: Color(0.3, 0.55, 1.0),
	Team.ANY: Color(0.7, 0.7, 0.7),
}

@export var team: Team = Team.ANY:
	set(value):
		team = value
		_tint()

## Set by func_godot on map build from the entity's class properties. Only a fallback:
## `team` is applied directly to the exported property above, because the entity sets
## `auto_apply_to_matching_node_properties`.
@export var func_godot_properties: Dictionary = {}


## One material per team, built on first use and shared by every spawn and every surface.
## Allocating one per mesh meant 400 StandardMaterial3D objects for 200 spawns — this is
## three for the whole session, and a shared material lets the markers batch.
##
## Static, so it survives for the editor session.  Changing `COLORS` therefore needs a
## project reload before the new colours appear.
static var _shared_materials: Dictionary = {}


static func _material_for(spawn_team: Team) -> StandardMaterial3D:
	if not _shared_materials.has(spawn_team):
		var material := StandardMaterial3D.new()
		material.albedo_color = COLORS.get(spawn_team, COLORS[Team.ANY])
		_shared_materials[spawn_team] = material
	return _shared_materials[spawn_team]


# Everything below runs on load or on a property change — never per frame.  There is
# deliberately no `_process`/`_physics_process`: a spawn is static geometry, and its only
# dynamic act is hiding itself once, at startup.
func _ready() -> void:
	# The setter can run before the scene's children exist, when properties are applied
	# during instantiation — so the tint is (re)applied here, once the mannequin is there.
	_tint()

	# Editor-only decoration: a running game shows nothing at a spawn point. Hiding the
	# Marker3D hides the mannequin with it.
	if not Engine.is_editor_hint():
		hide()


## Points every surface of the mannequin at the shared team material. Assigned as
## `material_override` rather than per-surface overrides so it does not matter how many
## surfaces the GLB has.
func _tint() -> void:
	var material := _material_for(team)
	for node in find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override = material
