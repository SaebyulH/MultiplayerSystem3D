@tool
class_name MaterialReplacer
extends Node

## Assigns one material to every mesh under a node — in the editor and in game.
##
## Attach it to a container (e.g. koth_castle's `Geometry`, which holds 106 mesh
## instances across ~15 imported GLB scenes), set [member material], and every
## [MeshInstance3D] below it picks the material up.  Reach it programmatically with
## [method replace_under].
##
## [b]Why it re-applies on load.[/b]  A GLB's scene root is a `Node3D` and the
## [MeshInstance3D] sits [i]inside[/i] it, so map geometry is always a descendant of
## a non-editable instanced sub-scene.  Godot only serializes property overrides on
## an instance's [i]root[/i], so `material_override` written to one of those meshes is
## silently dropped on save — the tool looks like it worked until you reopen the map.
## The one thing that [i]does[/i] survive is the [member material] reference on this
## node, because this node belongs to the map scene.  [member apply_on_ready]
## therefore re-derives the overrides from that reference every time the node enters
## the tree.  Don't expect a tick of [member run] alone to stick.
##
## [b]Override, not surface, by default.[/b]  Godot shares Resource instances across
## scene instances (CLAUDE.md → "Key conventions & gotchas"), and imported GLBs are
## the worst case: a whole map can instantiate from a handful of `PackedScene`s, so
## writing through to a mesh's surface material re-skins every sibling that shares it
## — and every other map using the same GLB.  `material_override` is per-node state
## and cannot leak.  [constant Mode.SURFACE] opts into the invasive version.
##
## Nothing here touches the network: a material applied this way is cosmetic and
## local, exactly like team tinting (CLAUDE.md → "Player & character architecture").
## Every peer instantiates the same extracted map scene, so [member apply_on_ready]
## lands identically everywhere with no RPC.

enum Mode {
	## Sets `MeshInstance3D.material_override`.  One slot, never mutates the mesh.
	OVERRIDE,
	## Replaces each surface material on the [Mesh] resource itself.  Writes through
	## to a shared resource — see the class note above before using this.
	SURFACE,
}

## Material to apply.  Leaving it unset means [method _ready] does nothing; ticking
## [member run] with it unset clears the overrides instead.
@export var material: Material

@export var mode: Mode = Mode.OVERRIDE

## Recurse into children.  Off means only this node's direct children are visited.
@export var recursive: bool = true

## Apply when this node enters the tree — in the editor as well as in game.  This is
## what makes the look stick across a reload; see the class note above.
@export var apply_on_ready: bool = true

## Tick to apply by hand.  Useful after changing [member material], since editing the
## inspector does not re-run [method _ready].  Snaps back to false so it can be
## ticked again.
@export var run: bool:
	set(value):
		if not value:
			return
		run = false
		_apply()


func _ready() -> void:
	if apply_on_ready and material != null:
		_apply()


func _apply() -> void:
	var count := replace_under(self, material, mode, recursive)
	print("MaterialReplacer: %d mesh(es) -> %s" % [count, material])


## Assign [param material] to every [MeshInstance3D] below [param root] and return
## how many were touched.  The reusable half of this script — a map's own tool
## script can call it without needing a MaterialReplacer node in the scene.
static func replace_under(
	root: Node,
	material: Material,
	mode: Mode = Mode.OVERRIDE,
	recursive: bool = true
) -> int:
	if root == null:
		return 0

	var count := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			_apply_to_mesh(child, material, mode)
			count += 1
		if recursive:
			count += replace_under(child, material, mode, recursive)
	return count


static func _apply_to_mesh(mesh_instance: MeshInstance3D, material: Material, mode: Mode) -> void:
	if mode == Mode.OVERRIDE:
		mesh_instance.material_override = material
		return

	var mesh := mesh_instance.mesh
	if mesh == null:
		return

	for i in mesh.get_surface_count():
		# Drop any lingering override first — otherwise the old material keeps
		# rendering on top of the surface material we are about to write.
		mesh_instance.set_surface_override_material(i, null)
		mesh.surface_set_material(i, material)
