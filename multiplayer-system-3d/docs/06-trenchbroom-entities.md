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

**For a prop, let the generator do it.** `tools/generate_prop_entities.gd` encodes the whole
checklist below — every setting, the computed `size`, the rigged-model bake, and the registration:

1. Drop the model into `assets/props/<name>/` — **any** format that imports as a `PackedScene`
   (`.glb`, `.gltf`, `.fbx`, `.obj`, `.dae`, `.tscn`). A generically-named file (`model.glb`) takes
   its classname from the folder instead.
2. ```
   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/generate_prop_entities.tscn
   ```
3. Re-export and check:
   ```
   "C:/tools/godot/godot_console.exe" --path . --headless res://tools/export_trenchbroom_fgd.tscn
   ```
4. Reload the game config in TrenchBroom.

It is **create-missing-only**: an existing `.tres` is never rewritten, so hand-tuned entities survive.
To regenerate one, delete its `.tres` and re-run. It always rebuilds `entity_definitions` from the
folder — sorted, deduped, uids preserved — so deleting an entity's `.tres` removes it from the FGD
too. It never exports; the harness stays the step that validates, because a generator that also
published would hide its own mistakes.

### Generated props have no collision — they are visual only

The generator points `scene_file` at the **raw model**, and a glTF/GLB imports with no physics at
all. Verified: the forklift's imported scene contains no `StaticBody3D` and no `CollisionShape3D`.
Godot's glTF importer only synthesises collision for meshes whose **names** carry a `-col`,
`-convcol` or `-colonly` suffix — `nodes/use_name_suffixes=true` is set in the import settings, and
the forklift's mesh is named `Cube.001`.

**So a generated prop is decoration you walk straight through.** This is a deliberate trade, not an
oversight: collision is hand-authored where it matters.

`Truck` is solid and always has been, which is exactly why it is the one entity still authored by
hand — its `scene_file` is a CSG scene with `use_collision = true`, not a model. If a prop needs to
be solid, do the same:

- **Wrap it.** Author a `<name>.tscn` with a `StaticBody3D`, the model instanced under it, and a
  `CollisionShape3D` (`BoxShape3D` from the computed `size`, or a `ConvexPolygonShape3D` from the
  mesh), then point `scene_file` at that `.tscn` instead of the raw model.
- **Or name the source meshes** `something-col` and let the importer generate collision.

Either way the entity keeps working — `scene_file` is only ever "the thing the map builds", and the
display model is separate.

### Adding one by hand

Needed for anything outside `assets/props/` — `Truck`, whose source is a `.tscn` under
`assets/map_models/`, is hand-authored. **Duplicate an existing `.tres` rather than building one in
the Inspector**: every setting below mis-defaults silently and was only found by hitting its bug, so
a duplicate inherits all of them.

1. Copy `trenchbroom/entities/truck.tres` to `<name>.tres`.
2. **Change the `uid=` on line 1**, or delete the attribute and let Godot assign one.
   FileSystem-duplicating a `.tres` copies the uid verbatim, and two resources sharing a uid break
   every reference to both, quietly.
3. Set `classname` (unique; this is the name in TrenchBroom), `description` and `scene_file`, then
   work the checklist below and measure `size`.
4. Register it in `entity_definitions` on `multiplayer_system_3d_fgd.tres` — or simply run the
   generator, which rebuilds that array from the folder.
5. Re-export. No list needs updating: the harness discovers entities by scanning the folder.
6. Reload the game config in TrenchBroom.

Note the harness checks **every** entity `.tres` in the folder automatically — it no longer keeps a
hand-maintained list, which is the step that used to be forgotten.

### The settings checklist

None of these error on their own — each one just silently produces the wrong result.

| Setting | Value | What breaks otherwise |
|---|---|---|
| `target_map_editor` | `1` (TRENCHBROOM) | emits `studio`, not `model`; TrenchBroom draws a bare box (#61) |
| `models_sub_folder` | `"trenchbroom/models"` | the display `.glb` is generated into the project root |
| `generate_size_property` | **`false`** | derived AABB is off-centre, so TrenchBroom refuses to rotate (#63) |
| `meta_properties["size"]` | hand-authored: contains the origin, and XY-symmetric | no preview model, and/or `R` won't rotate (#64) |
| `class_properties` | `{"mangle": "0 0 0", "scale": 1.0}` | no rotation property → no gizmo; no `scale` → not scalable; a **string** `scale` → the prop never draws |
| `scale_expression` (on `FuncGodotFGDModelPointClass`) **or** `display_descriptors[0].scale` (on `FuncGodotFGDPointClass`) | `"{{ scale == undefined -> 32, scale * 32 }}"` | the prop **never draws** — neither in the browser nor in the world (#65) |
| `apply_rotation_on_map_build` | `true` | the map builds every entity unrotated, whatever the map says |
| `apply_scale_on_map_build` | `true` | the map builds every entity at natural size, whatever the map says |
| `entity_scale` (on `trenchbroom_config.tres`) | `"32"` — a **literal** | the outer fallback if the model map's expression cannot be evaluated |
| `rotation_offset` | `Vector3(0, 180, 0)` | preview faces 180° opposite the built node |
| the display `.glb` | **`skins: 0`** — no rig | a rigged model previews as **nothing at all**; bake it first |
| `meta_properties["color"]` | anything | cosmetic only |

Two notes on reading these files, both of which look like something is missing when it isn't:

- **Godot omits any property that still holds its default**, so `apply_rotation_on_map_build` does
  *not* appear in a correct file — its default is already `true`. Absence is the healthy case; only
  an explicit `= false` is a bug. The same applies to `target_map_editor` (`GENERIC` is the default,
  so any working entity shows `= 1`).
- **`apply_scale_on_map_build` works the same way** — absent means `true`, so an explicit `= false` is
  the only form that breaks building scaled props.

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

## Scaling

All three axes, uniform or per-axis. Like rotation it is two halves — a `scale` key the mapper edits,
and the assembler applying it — and unlike rotation there is no dedicated editor tool wired to it.

**The key.** `class_properties` declares `scale` as a **`float`**, defaulting to `1.0`:

| value | effect |
|---|---|
| `1` | natural size (default) |
| `2` | uniform 2× |

The type matters to the **editor, not the build**. A `String` property would additionally allow
per-axis (`"2 3 4"` → a `Vector3`, `entity_assembler.gd:208-210`), but TrenchBroom does not write a
default onto a newly placed entity for a string property, and an unset `scale` makes the game
config's scale expression evaluate to nothing — the prop then does not draw at all. A numeric
property is the form TrenchBroom is expected to materialise a default for; **that is the hypothesis
under test**, and if it does not hold the string form comes back and the invisible-until-set wart
returns with it.

The build handles either type: the map parser yields the keyvalue as a string regardless, so
`"2 3 4"` written into a `.map` by hand still builds per-axis even though the editor's numeric field
will not accept it.

**The build.** `entity_assembler.gd:202-218` reads it and multiplies the instantiated node's scale.
A 3-value string is axis-swapped exactly like `origin` — TB `(x, y, z)` becomes Godot `(y, z, x)`, so
`"2 3 4"` lands as Godot scale `(3, 4, 2)`. This needs **`apply_scale_on_map_build` left at its
default `true`**; an explicit `= false` silently builds every prop at natural size.

**The preview needs a bare `model()` and the game config's expression — both.** TrenchBroom's model
scale is *not* a multiplier: it is units-per-model-unit, defaulting to 32. Tracking a `scale` key
therefore needs the expression to multiply, and **a per-model `scale` overrides the game config's
expression entirely** (the manual: the config default is used only when no expression "is given or it
can't be evaluated"). `FuncGodotFGDModelPointClass` always writes one — `_generate_model()` emits a
literal `32.0` whenever `scale_expression` is empty (`func_godot_fgd_model_point_class.gd:76-80`) —
so on that class the config expression is never consulted, and writing the multiply *into* the model
map is what produced a ~32×-too-small preview and then an invisible one.

The knob is `entity_scale` on `trenchbroom_config.tres`, which becomes the `"scale"` value in
`GameConfig.cfg`. **It is deliberately a literal:**

```
entity_scale = "32"
```

→ `GameConfig.cfg`: `"scale": 32`.

### The preview does not follow `scale`, and cannot — read this before changing it back

Property-driven preview scale is a **supported TrenchBroom feature** (Quake 3's `modelscale` /
`modelscale_vec` are the precedent; the manual documents `"scale": modelscale` directly), and it
**works** — but only in one specific shape. Five other forms were tried first, and each failed
differently, so they are tabulated as traps rather than history:

| form | where | result |
|---|---|---|
| `scale * 32` | model map | prop **not drawn at all** |
| `[scale * 32, 32]` | model map | prop **~32× too small** |
| `[scale * 32, 32]` | game config | scales once set; an unset prop **invisible** |
| `{{ scale == undefined -> 32, scale * 32 }}` | game config | always natural size — the `32` branch always wins |
| `[scale * 32, 32]` + a numeric `scale` property | game config | unchanged — the property is still absent when unset |
| **`{{ scale == undefined -> 32, scale * 32 }}`** | **model map** | **works — this is the one** |

### The one shape that works

```
model({ "path": "trenchbroom/models/Truck.glb", "scale": {{ scale == undefined -> 32, scale * 32 }} })
```

Both halves of that are load-bearing:

- **In the model map, not the game config.** The identical conditional in `entity_scale` always takes
  its `32` branch. Why the two contexts differ is not established — only that they do.
- **With a property-free branch.** TrenchBroom evaluates a model expression with **no entity behind
  it** for the entity browser (`TrenchBroom/TrenchBroom` #4253), and a freshly placed prop carries no
  `scale` key because an FGD default is not written on placement. Both make the property *absent*, so
  any form that requires it — every row above the last — leaves the prop undrawn, in the browser or in
  the world.

Giving that missing case a value is what makes the browser thumbnail draw **and** the viewport prop
draw **and** the scale apply, all at once. `scale` stays a plain multiplier of the 32 units-per-model-unit,
which is why the preview and the build agree.

The property **must** be called `scale` — `entity_assembler.gd:202-218` looks up `properties["scale"]`
literally — and it must be a numeric (`float`) type so the mapper gets a number field.

`entity_scale` on `trenchbroom_config.tres` stays a literal `32`: it is the outer fallback if the
model map's expression cannot be evaluated at all.

### Setting it — two equivalent routes

| entity class | field to set | emits |
|---|---|---|
| `FuncGodotFGDModelPointClass` | `scale_expression` | the model map, from the generated display model |
| `FuncGodotFGDPointClass` | `display_descriptors[0].scale` | the same, for a hand-authored display model |

`_generate_model()` writes `scale_expression` straight into the model map
(`func_godot_fgd_model_point_class.gd:69-82`); `_build_model_branch_text()` does the same for the
descriptor's `scale` (`func_godot_fgd_point_class.gd:61-62`). Both produce the identical `.fgd` line.
`Truck` and `mannequin` use the first, `Forklift` the second — an artefact of an earlier experiment,
and either is fine.

A `FuncGodotFGDPointClass` entity is authored **by hand** rather than generated: its display `.glb` is
not regenerated on export, so `rotation_offset` / `models_sub_folder` / `generate_size_property` do
not apply to it. The committed `.glb`s already carry the 180° yaw bake.

The harness asserts both halves of the recipe for **every** registered entity.

Two caveats:

- **The `size` box does not scale with the prop.** `size` is static FGD data, so a prop at `"3"` keeps
  its authored selection box. Cosmetic, but it also means a heavily scaled prop can end up outside the
  box the rotation/origin rules depend on — re-check those if scaling gets extreme.
- **No drag-scaling.** TrenchBroom's manual lists the Scale tool as "Scaling brushes" and never
  describes it writing an entity property (contrast the Rotate tool, which explicitly rewrites
  `angle`/`angles`/`mangle`). Type the value in the entity inspector's property list. If a future
  TrenchBroom wires the scale tool to a property, `scale` is already the key it would write.

## Rigged source models need a static display model

**A display model carrying a skin may not draw at all.** TrenchBroom renders display models through
Assimp, and the one structural property that separates a model that previews from one that does not
is whether it is rigged:

| model | `skins` | nodes | `JOINTS_0`/`WEIGHTS_0` | previews |
|---|---|---|---|---|
| `Truck.glb` (CSG, exported) | 0 | 23 | no | yes |
| `Forklift.glb` (Blender) | 0 | 2 | no | yes |
| `mannequin.glb` (Blender, **rigged**) | 1 | 168 | yes | **no** |

Nothing else differs — the GLB is valid, its buffers are consistent, it uses no unsupported glTF
extensions (`GODOT_single_root` only, which the working models carry too), its materials need no
textures, its `size` box contains the origin and is XY-symmetric, and it carries the same scale
expression as the other two. Assimp does have a skeletal-animation path, added for HL1 and
[never validated against glTF](https://github.com/TrenchBroom/TrenchBroom/issues/1140), but it is
documented to fall back to the unanimated path when a model has no animations — and this one has
none, so that is not a complete explanation. **Treat "rigged models do not preview" as the leading
hypothesis rather than a proven rule**; it is the third explanation offered for this specific model,
after `studio`-vs-`model` and the bounds, both of which were real defects that did not fix it.

### The workaround: bake the display model

`tools/bake_static_model.tscn` strips the rig and writes a static `.glb` — every `MeshInstance3D`'s
geometry rebound to a fresh `ArrayMesh` with the bone/weight arrays removed, its global transform
baked in, then the usual 180° display rotation applied. Positions are already in bind-pose space, so
the result is the model at rest.

```
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/bake_static_model.tscn
```

Edit `SRC`/`OUT` at the top of `tools/bake_static_model.gd` to retarget it. For the mannequin it
produced a 1.2 MB `skins=0` model from a 4.3 MB rigged one.

The entity then takes that as its **display** while keeping the rigged scene as its build input —
`scene_file` is unchanged, so maps still build the real model and only the editor preview differs.
That requires `FuncGodotFGDPointClass` + `display_descriptors`, since a
`FuncGodotFGDModelPointClass` would regenerate its display from `scene_file` and undo the bake.
`mannequin_ref.tres` is authored this way; `Truck` and `mannequin`'s scale expressions are identical,
so this is the only structural difference between them.

**Confirmed 2026-09-28:** swapping the mannequin to a `skins=0` display model made it preview. The
rigged model is the cause.

## Current entities

| classname | Built from | Display model | Rotatable | Scalable |
|---|---|---|---|---|
| `Truck` | `assets/map_models/props/truck.tscn` (CSG, `use_collision = true`) | generated | `mangle` | `scale` |
| `Forklift` | `assets/props/forklift.glb` | generated | `mangle` | `scale` |
| `mannequin` | `assets/mannequin/mannequin.glb` (rigged) | static bake — see above | `mangle` | `scale` |
