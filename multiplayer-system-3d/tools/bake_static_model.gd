extends Node
## Manual escape hatch: bake ONE rigged source scene into a static display model.
##
## `tools/generate_prop_entities.gd` does this automatically for anything dropped into
## `assets/props/`; this is for a model outside that folder (the mannequin lives in
## `assets/character_models/mannequin/`) or for re-baking one by hand. The work itself
## is in `tools/static_model_baker.gd` — see there for why a rig has to be stripped.
##
## HOW TO USE:
##   edit SRC/OUT below, then
##   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/bake_static_model.tscn
##
## Exits non-zero if nothing was baked.

const SRC := "res://assets/character_models/mannequin/mannequin.glb"
const OUT := "res://trenchbroom/models/mannequin_static.glb"

var _failures := 0


func _ready() -> void:
	var packed := load(SRC) as PackedScene
	if packed == null:
		printerr("FAIL: could not load %s" % SRC)
		get_tree().quit(1)
		return

	if await StaticModelBaker.bake(self, packed, OUT):
		print("ok   baked %s -> %s" % [SRC, OUT])
	else:
		_failures += 1

	print("---")
	get_tree().quit(_failures)
