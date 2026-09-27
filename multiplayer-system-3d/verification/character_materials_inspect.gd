extends Node3D

## Throwaway: verifies the hand-written surface_material_override entries in the
## character scenes actually land.
##
##   "C:/tools/godot/godot_console.exe" --path . res://verification/character_materials_inspect.tscn
##
## The overrides were authored as text onto nodes that live inside an instanced
## GLB, which is not a supported-by-inspection operation — it only works if
## Godot resolves an instance-descendant node entry by path.  This loads each
## scene and counts how many surfaces ended up on the painted-toon shader.
## Exit code is the number of surfaces that did NOT land.

const DIR := "res://assets/character_models/characters"

# Surfaces the patcher reported overriding, per scene.
const EXPECTED := {
	"blackhat.tscn": 19, "flier.tscn": 14, "ghost.tscn": 14,
	"governess.tscn": 16, "jett.tscn": 3, "juggernaut.tscn": 14,
	"nerd.tscn": 16, "scientist.tscn": 16, "stalker.tscn": 13,
}


func _ready() -> void:
	var files := DirAccess.get_files_at(DIR)
	files.sort()

	var missed := 0
	for file in files:
		if file.ends_with(".tscn"):
			missed += _check(DIR.path_join(file), file)

	print("")
	print("surfaces that did not land: ", missed)
	get_tree().quit(missed)


func _check(path: String, file: String) -> int:
	var packed := load(path) as PackedScene
	if packed == null:
		print("%-16s FAILED TO LOAD" % file)
		return EXPECTED.get(file, 1)

	var root := packed.instantiate()
	add_child(root)

	var total := 0
	var toon := 0
	var not_toon: Array[String] = []
	for node in _meshes(root):
		var mi := node as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			total += 1
			var mat := mi.get_active_material(i)
			if mat is ShaderMaterial and (mat as ShaderMaterial).shader != null \
					and "painted_toon" in (mat as ShaderMaterial).shader.resource_path:
				toon += 1
			else:
				not_toon.append("%s[%d]" % [mi.name, i])

	var want: int = EXPECTED.get(file, -1)
	var ok := toon == want
	print("%-16s total=%2d  toon=%2d  expected=%2s  %s"
			% [file, total, toon, str(want), "OK" if ok else "MISMATCH"])
	for n in not_toon:
		print("       not toon: ", n)

	root.queue_free()
	return 0 if ok else absi(toon - want)


func _meshes(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out
