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
## Where a spawn is *placed* is not decided here. func_godot names generated nodes
## `entity_<index>_<classname>` (`entity_assembler.gd:274-277`), and `Map._enter_tree()`
## routes a spawn by reading that name — or the `team` property below, which wins when it
## is present. See the spawn-discovery comment in `maps/map.gd`.

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


func _ready() -> void:
	# The setter can run before the scene's children exist, when properties are applied
	# during instantiation — so the tint is (re)applied here, once the mannequin is there.
	_tint()

	# Editor-only decoration: a running game shows nothing at a spawn point. Hiding the
	# Marker3D hides the mannequin with it.
	if not Engine.is_editor_hint():
		hide()


## Overrides every surface of the mannequin with one flat material. `material_override`
## rather than per-surface overrides so it does not matter how many surfaces the GLB has.
func _tint() -> void:
	var color: Color = COLORS.get(team, COLORS[Team.ANY])
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		var material := mesh_instance.material_override as StandardMaterial3D
		if material == null:
			material = StandardMaterial3D.new()
			mesh_instance.material_override = material
		material.albedo_color = color
