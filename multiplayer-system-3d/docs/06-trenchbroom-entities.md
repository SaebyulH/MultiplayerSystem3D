# 06 — TrenchBroom entities (func_godot)

How maps get authored outside Godot, and how a Godot scene becomes a placeable, rotatable entity
in the map editor. Read this before adding or changing anything under `trenchbroom/`.

## The shape of the pipeline

```
trenchbroom/entities/<name>.tres      one FuncGodotFGD*Class resource per entity
        │                             (the "folder system" — drop a .tres in, register it)
        ▼
trenchbroom/entities/multiplayer_system_3d_fgd.tres
        │                             FuncGodotFGDFile: fgd_name + base_fgd_files + entity_definitions
        ▼  Export FGD
C:/Trenchbroom/games/MultiplayerSystem3D/MultiplayerSystem3D.fgd   ← what TrenchBroom reads
        │  (written to FGD_OUTPUT_FOLDER, a machine-local path)
        ▼
trenchbroom/maps/*.map                drawn in TrenchBroom
        ▼  FuncGodotMap.build()       (in the editor, on a map scene)
maps/<map>.tscn                       generated Godot scene: brushwork + one node per entity
```

Two machine-local paths come from `user://func_godot_config.json`
(`addons/func_godot/src/util/func_godot_local_config.gd:64-67`, read by `:106-122`):

- `FGD_OUTPUT_FOLDER` → where the `.fgd` is written (`C:/Trenchbroom/games/MultiplayerSystem3D`).
- `MAP_EDITOR_GAME_PATH` → the project folder, where **display models** are written.

Neither is in the repo, so **the `.fgd` is a build artifact, not a source file** — it is not
committed and regenerating it is expected.

## Registering an entity — the one step that is easy to forget

`FuncGodotFGDFile.build_class_text()` walks `base_fgd_files` + `entity_definitions` and nothing else
(`func_godot_fgd_file.gd:88-100`). A `.tres` sitting in `trenchbroom/entities/` that is **not** in
`entity_definitions` is invisible: it gets no `@PointClass`, so TrenchBroom cannot place it.

Worse, the failure is silent on the Godot side too. `parser.gd:83-87` resolves a classname through
`map_settings.entity_fgd.get_entity_definitions()` and falls back to
`default_point_class.node_class = "Marker3D"` — so rebuilding a map whose entity is unregistered
**replaces the placed prop with an empty marker and reports no error**
(`05-known-issues.md` #60).

## Adding a new entity

**Duplicate an existing `.tres` rather than building one from scratch in the Inspector.** Every
setting in the checklist below is non-obvious, mis-defaults silently, and was only found by hitting
the resulting bug — a duplicate inherits all of them.

1. Copy `trenchbroom/entities/truck.tres` to `<name>.tres`.
2. **Change the `uid=` on line 1**, or delete the attribute and let Godot assign one.
   FileSystem-duplicating a `.tres` copies the uid verbatim, and two resources sharing a uid break
   every reference to both, quietly.
3. Set the per-entity fields — `classname` (unique; this is the name in TrenchBroom), `description`,
   `scene_file` — then work through the checklist below.
4. Register it in `entity_definitions` on `multiplayer_system_3d_fgd.tres`, as an
   `[ext_resource type="Resource" …]` line plus an array entry, or via the Inspector.
5. Re-export, then add the classname to `EXPECTED` at the top of `tools/export_trenchbroom_fgd.gd`
   so it stays checked from then on:
   ```
   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/export_trenchbroom_fgd.tscn
   ```
6. Reload the game config in TrenchBroom.

### The settings checklist

None of these error on their own — each one just silently produces the wrong result.

| Setting | Value | What breaks otherwise |
|---|---|---|
| `target_map_editor` | `1` (TRENCHBROOM) | emits `studio`, not `model`; TrenchBroom draws a bare box (#61) |
| `models_sub_folder` | `"trenchbroom/models"` | the display `.glb` is generated into the project root |
| `generate_size_property` | **`false`** | derived AABB is off-centre, so TrenchBroom refuses to rotate (#63) |
| `meta_properties["size"]` | hand-authored: contains the origin, and XY-symmetric | no preview model, and/or `R` won't rotate (#64) |
| `class_properties` | `{"mangle": "0 0 0"}` | no rotation property → no gizmo, entity not rotatable |
| `apply_rotation_on_map_build` | `true` | the map builds every entity unrotated, whatever the map says |
| `rotation_offset` | `Vector3(0, 180, 0)` | preview faces 180° opposite the built node |
| `meta_properties["color"]` | anything | cosmetic only |

Two notes on reading these files, both of which look like something is missing when it isn't:

- **Godot omits any property that still holds its default**, so `apply_rotation_on_map_build` does
  *not* appear in a correct file — its default is already `true`. Absence is the healthy case; only
  an explicit `= false` is a bug. The same applies to `target_map_editor` (`GENERIC` is the default,
  so any working entity shows `= 1`).
- **`apply_scale_on_map_build` *does* appear**, as `= false`, because its default is `true`.

### Measuring `size` for a new entity

You cannot author a correct box without the model's real extents. Two ways to get them:

**Read them off the model — accurate.** Every glTF mesh primitive's `POSITION` accessor carries
`min`/`max`, which is the true geometry. Convert to TrenchBroom units (× the 32 scale) with the
assembler's axis swap — `TB.x = Godot.z`, `TB.y = Godot.x`, `TB.z = Godot.y` — and check the result
spans the origin. That is how the mannequin's `z 0…58` was derived, after the generated box turned
out to be `z 7…65`.

**Or let `generate_size_property` measure it — quick, unreliable.** Turn it on, export, and read the
derived box out of the FGD. Treat that as a starting point only: it is exact for a single-child root
and arbitrary for a rigged one.

Either way, then:

1. Symmetrise X and Y — take the larger magnitude on each of those two axes and use it for both
   signs, so the box still contains the model.
2. Make sure Z spans the origin, extending it if the model floats above or hangs below.
3. Set `generate_size_property = false` and write the box into `meta_properties["size"]` as
   `AABB(min.x, min.y, min.z, max.x, max.y, max.z)` — min and max, *not* position and size.

## Exporting the FGD

```
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/export_trenchbroom_fgd.tscn
```

`tools/export_trenchbroom_fgd.gd` loads the FGD resource, exports it via
`FuncGodotFGDFile.do_export_file()` (`func_godot_fgd_file.gd:25-49`), and then asserts against the
**written file** — every expected classname has an `@PointClass` block carrying the tokens it needs.
It exits non-zero on failure.

The same export is available in the editor as the **Export FGD** tool button on the resource
(`func_godot_fgd_file.gd:20`). Use the harness when scripting; either is fine interactively, but note
the editor path does not verify anything.

Exporting has a **side effect**: it regenerates every `FuncGodotFGDModelPointClass`'s display `.glb`
(see `_generate_model`, `func_godot_fgd_model_point_class.gd:55-85`). Those `.glb` files are
committed, so an export shows up as a diff on them even when nothing about the entity changed.

**Where that `.glb` lands is set by `models_sub_folder`, and leaving it empty dumps it in the
project root.** The path is `ProjectSettings.func_godot/model_point_class_save_path` joined with
`models_sub_folder` (`:103-107`), and that project setting is unset here — so the folder is *entirely*
`models_sub_folder`. Every model entity must therefore set **`models_sub_folder = "trenchbroom/models"`**,
which is what keeps the display models together and out of `res://`. `mannequin_ref.tres` was missing
it and wrote a 4.3 MB `res://mannequin.glb` on every export until 2026-09-28.

Because the models sit under `res://`, Godot imports each one and writes a `.import` sidecar (all
committed — a new entity's first export needs a second Godot run before its sidecar appears). The
addon ships the intended fix for that: the **Generate GD Ignore File** tool button on any
`FuncGodotFGDModelPointClass` writes a `.gdignore` into the model folder
(`func_godot_fgd_model_point_class.gd:30-46`), after which Godot stops importing them at all. Not
currently used — the committed `.import` sidecars and this export-side effect are the status quo.

## Class anatomy

Pick the class type by where the display model comes from:

- **`FuncGodotFGDModelPointClass`** — the display model is *generated* from `scene_file`, so the
  editor preview always matches what gets built. Used by `truck.tres`, `forklift.tres`,
  `mannequin_ref.tres`.
- **`FuncGodotFGDPointClass`** + `display_descriptors` — the display model is a hand-made asset you
  point at (`func_godot_fgd_point_class.gd:110-120`). Use this when the built node is *not* what you
  want rendered (a CSG scene, a scripted node).

The two property bags do different jobs:

| | Purpose | Notes |
|---|---|---|
| `scene_file` | The `PackedScene` instantiated on map build | Authoritative for gameplay — give it collision |
| `meta_properties` | Map-editor *appearance* only | `color`, `size` (AABB), and `model`/`studio` |
| `class_properties` | Key/values the mapper can set | Becomes the FGD property list |
| `class_property_descriptions` | Tooltips + defaults for those keys | |

`meta_properties["model"]` and `["size"]` are **overwritten in memory** by `_generate_model()` on
every export (`func_godot_fgd_model_point_class.gd:69-85`), so hand-writing them on a
`FuncGodotFGDModelPointClass` is pointless — leave `generate_size_property = true` to derive the
AABB from the real mesh instead.

### The `model` vs `studio` trap — `target_map_editor`

`FuncGodotFGDModelPointClass.target_map_editor` **defaults to `GENERIC`**
(`func_godot_fgd_model_point_class.gd:20`), which makes `_generate_model()` write the `studio`
keyword (`:82`). `studio` is the Hammer/J.A.C.K. spelling; TrenchBroom only understands `model`. The
result is an entity that looks right in the inspector, exports without complaint, and shows up in
TrenchBroom as a bare bounding box. **Always set `target_map_editor = 1` (`TRENCHBROOM`)** on a model
entity — see `05-known-issues.md` #61.

`generate_size_property` also silently needs a scale to mean anything: with `scale_expression` empty
it falls back to `ProjectSettings.func_godot/default_inverse_scale_factor` (32.0,
`func_godot_fgd_model_point_class.gd:180-188`), which is what the GameConfig's `entities.scale` is
set to. The two must agree or the editor box will not match the model.

## Rotation

**A property an entity does not declare is not rotatable in TrenchBroom.** func_godot never
synthesises one — you have to add it to `class_properties` yourself. `entity_assembler.gd:172-200`
then reads it back on map build, in this precedence order:

1. `angles` or `mangle` (a `"x y z"` string, split with `split_floats(' ')`), else
2. `angle` (a single float yaw).

Quake→Godot axis mapping is `Vector3(-pitch, yaw, -roll)` for mangle, and yaw-only for `angle`. In
**both** cases `angles.y += 180` is then applied unconditionally (`:199`) — the GLTF Y-up ↔ Quake
Z-up flip. So `mangle "0 0 0"` builds a node at 180° yaw, which is what `"angle" "0"` in
`trenchbroom/maps/test.map` produces too.

Declare **one** of them. Declaring both makes `angle` a silently dead key, because mangle wins.

For a prop you only ever yaw, `angle` is the simpler property:

```
class_properties = {"angle": 0.0}
class_property_descriptions = {"angle": "Yaw rotation in degrees"}
```

For full pitch/yaw/roll (a flipped or tilted truck used as cover), use mangle — a `String`, so it
serialises as `"(string)` and parses through `split_floats`:

```
class_properties = {"mangle": "0 0 0"}
class_property_descriptions = {"mangle": "Pitch Yaw Roll"}
```

All three entities use `mangle`.

### The `size` box — two hard constraints, both silent when violated

TrenchBroom reads `size` as the point entity's bounds, and enforces two rules that produce no error,
no log line, and no visual clue beyond the symptom itself:

1. **The box must contain the origin.** If it does not, TrenchBroom **does not preview the entity's
   model at all** (`TrenchBroom/TrenchBroom` #4573 — reported as "3D model is missing/invisible in
   entity browser with specific `size()`", fixed in milestone 2024.2). The viewports and the browser
   are both affected in practice.
2. **If the entity is rotatable, the box must also be centred on X and Y.** Otherwise `R` silently
   degrades to *moving* the entity — it "rotates" by shoving the prop around instead of changing
   `mangle` (the manual documents the guard; `#2498` is the same finding from the bug side). Z is
   exempt: it is the vertical axis.

**`generate_size_property = true` violates both, and is off on every entity here for that reason.**
It is the setting the addon documents and the obvious one to reach for, but it derives the box from
the mesh AABB plus an offset that is only correct for a single-child root:

```gdscript
# func_godot_fgd_model_point_class.gd:157-171
for node in nodes:
    if node.parent == 0:          # direct children of the scene root only
        pos_ofs += node.position
        ct += 1
pos_ofs /= maxi(ct, 1)
aabb.position += pos_ofs
```

A racked prop's real box is off-centre to begin with (a truck's cab is at one end, giving `x -92…71`,
centre −10.5). Worse, **`mannequin` is rigged**: its root has four armature children, so that average
shifted the whole box `+7` on Z and produced `z 7…65` — a box the origin sits *outside*, which is
constraint 1, and the reason the mannequin had no preview model while the other two were fine.

So `size` is **authored by hand** on all three, with `generate_size_property` off — symmetric on X
and Y, and always spanning the origin:

| entity | real extents | authored `size` |
|---|---|---|
| `Truck` | `x −92…71` | `(-92 -32 -43, 92 32 34)` |
| `Forklift` | `x −32…99` | `(-99 -25 -37, 99 25 70)` |
| `mannequin` | `z 0…58` | `(-7 -15 -2, 7 15 58)` |

The cost is a selection box looser than the model on one side. The alternative is a prop that cannot
be rotated, or one that does not draw.

`tools/export_trenchbroom_fgd.tscn` asserts **both** rules for every registered entity — constraint 1
always, constraint 2 only for entities that declare a rotation property — so turning
`generate_size_property` back on fails the harness instead of silently breaking `R` or the preview.

### Orientation

The build side is asserted by the harness — `mangle "0 90 0"` on a Truck resolves to a `truck.tscn`
instance at yaw 270°. **`apply_rotation_on_map_build` must stay `true` for that**: it is the switch
that makes the assembler read `mangle`/`angle`/`angles` at all, so setting it `false` builds every
entity unrotated no matter what the map says.

**The TrenchBroom preview and the built node are 180° apart unless `rotation_offset` corrects it, and
all three entities carry `rotation_offset = Vector3(0, 180, 0)` to do exactly that.**

That offset is not a fudge — it is the missing half of a convention the assembler applies on one side
only. Quake entities face `+X` at `angle 0`, Godot entities face `-Z`, and the assembler bridges the
gap by adding `180` to yaw *unconditionally* at the end of `generate_point_entity_node`
(`entity_assembler.gd:199`). TrenchBroom's own glTF display does not, so without the offset the same
entity reads as facing one way in the viewport and the opposite way once built — verified on both
Forklift and Truck, which disagreed by exactly 180°.

`rotation_offset` rotates the exported display `.glb` only (`func_godot_fgd_model_point_class.gd:28`,
applied in Godot's Y at `:117-119`, which survives the Y-up→Z-up glTF conversion as pure yaw). The
built node is untouched, so this is the correct side to fix. Confirmed in the exported model: the
root node of `Truck.glb`/`Forklift.glb` carries a 180° Y quaternion.

Rotate it in Godot's axes, not TrenchBroom's — `Vector3(0, 180, 0)` is yaw; an X or Z value here
would tip or roll the preview instead.

## Current entities

| classname | Built from | Display model | Rotatable |
|---|---|---|---|
| `Truck` | `assets/map_models/props/truck.tscn` (CSG, `use_collision = true`) | generated | `mangle` |
| `Forklift` | `assets/props/forklift.glb` | generated | `mangle` |
| `mannequin` | `assets/mannequin/mannequin.glb` | generated | `mangle` |
