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
`entity_definitions` is invisible: it gets no class declaration, so TrenchBroom cannot place it.

**This applies to base classes even though `get_entity_definitions()` never returns them.**
That getter yields only the two *placeable* kinds (`func_godot_fgd_file.gd:130`) and folds a base
class's properties into its descendants; `build_class_text` walks the raw array instead. So a
`@BaseClass` that is missing from `entity_definitions` disappears from the FGD while still looking
registered to any code that asks the getter — taking every inherited property with it.

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
3. Reload the game config in TrenchBroom.

**Step 2 exports as well as generates.** It finishes by calling
`TrenchBroomGameConfig.export_file()` on `trenchbroom_config.tres` — the identical call the
**Export GameConfig** tool button makes — so one command covers the whole round trip: scan → create →
register → publish, writing `icon.png`, `GameConfig.cfg` and the FGD.

It is **create-missing-only**: an existing `.tres` is never rewritten, so hand-tuned entities survive.
To regenerate one, delete its `.tres` and re-run. It always rebuilds `entity_definitions` from the
folder — sorted, deduped, uids preserved — so deleting an entity's `.tres` removes it from the FGD
too.

Because it publishes, it does **not** validate. `tools/export_trenchbroom_fgd.tscn` is still what
asserts registration, bounds and the scale expression — run it after any hand-edit to an entity, and
whenever you want the round-trip check:

```
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/export_trenchbroom_fgd.tscn
```

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
**written file** — every expected classname has a block carrying the tokens its kind needs. It
exits non-zero on failure.

It handles all three FGD kinds, and each is checked differently: `@PointClass` (the `model(`/`size(`
tokens, the scale expression, and the bounds rules), `@SolidClass` (must carry **no** `model(`/`size(`
— a brush's shape is the volume the mapper drew, `func_godot_fgd_entity_class.gd:82-87`), and
`@BaseClass` (its own properties, plus every entity's `base(...)` list). Splitting on `@PointClass`
alone finds neither of the other two, which is how the first brush entity added here failed with a
misleading "no @PointClass for trigger".

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

## Brush entities (solid classes)

Everything above is a **point** entity: a `PackedScene` instanced at an origin, with a
generated display model. A **brush** entity is the other kind — the mapper draws a volume and
func_godot builds geometry, collision and a scripted node from it. Triggers, doors and
buttons are brush entities, because their shape *is* their definition.

`FuncGodotFGDSolidClass` (`func_godot_fgd_solid_class.gd`) is the definition type. Two things
about it differ from a point class and both surprise people:

- **There is no `scene_file`.** A brush cannot be a `PackedScene` — the geometry only exists
  once the map is parsed. The built node is `node_class` (a built-in name like `"Area3D"`, or
  a GDScript `class_name`) with `script_class` attached over the top
  (`entity_assembler.gd:297`). So a brush entity is always *node type + script*, never a scene.
- **Properties must be plain `@export` vars on the script**, not a properties dictionary.
  func_godot has no `QodotEntity.update_properties()` equivalent, and
  `_func_godot_apply_properties()` is build-time only (see below), so
  `auto_apply_to_matching_node_properties = true` writing real exports is the only mechanism
  that survives into the baked scene. **Forgetting that flag is silent:** every property
  falls back to its script default and the entity builds looking correct but inert. It is the
  one setting on this list that produces no error at all.

### The five entities

All are authored in `trenchbroom/entities/`, scripted under `world/brush_entities/`, and
ported from Qodot's brush set.

| classname | Node | Script | What it does |
|---|---|---|---|
| `trigger` | `Area3D` | `TriggerVolume` | fires its `target` when a player walks in |
| `mover` | `AnimatableBody3D` | `MovingBrush` | door/platform; slides to an offset pose. The only entity with `use()`, so the only useful target |
| `rotate` | `AnimatableBody3D` | `RotatingBrush` | spins forever from map load; never triggered |
| `button` | `Area3D` | `ButtonBrush` | sinks when stood on, fires its `target` |
| `physics` | `RigidBody3D` | `PhysicsBrush` | a rigid body that falls and tumbles |

Two shared property sets live beside them: `target_base.tres` (`classname = "Target"`, the
`target` key) and `targetname_base.tres` (`classname = "Targetname"`). They are ordinary
`FuncGodotFGDBaseClass` resources and are declared through each entity's `base_classes`.

### The mover's behaviour flags

`mover` has three properties that decide what it does over time. All three default to the
original one-way behaviour, so an existing map is unaffected.

| property | default | meaning |
|---|---|---|
| `automatic` | `false` | runs with no trigger — plays its motion on map load, and again after every round reset |
| `toggle` | `false` | a trigger flips it between poses instead of only ever opening it |
| `wait` | `-1` | seconds after each activation. **`-1` means permanent** — see below |

**`wait` means two different things depending on `toggle`, and `-1` is the important case:**

| `toggle` | what `wait` is | what `wait = -1` means |
|---|---|---|
| `false` | how long it stays at the offset pose before returning home | it never returns — the pose is **permanent** |
| `true` | a guard: how long it ignores further triggers after each activation | **no guard** — it can be toggled at any time |

So `wait = -1` with `toggle = true` is not "permanent" in the sense of frozen; in toggle mode
the pose *is* the state, and there is nothing to stay for. Permanent means "nothing moves it
again on its own", which is what `-1` always means.

The guard exists because the source entities re-fire on every `body_entered` (#72): in toggle
mode a player standing in a trigger would otherwise rattle the mover open and shut as fast as
the signal fires. In one-shot mode no guard is needed, because `play_motion()` already no-ops
while the mover is open.

Some worked examples on a mover with `move_translation "0 0 128"`:

| `automatic` | `toggle` | `wait` | behaviour |
|---|---|---|---|
| `0` | `0` | `-1` | a trigger opens it and it stays open — the original behaviour |
| `0` | `0` | `3` | a trigger opens it; it returns home 3 s later |
| `0` | `1` | `2` | a trigger flips it; further triggers ignored for 2 s |
| `0` | `1` | `-1` | a trigger flips it, with no guard |
| `1` | — | `2` | rises on load, sinks 2 s after arriving, rises 2 s after that, forever |
| `1` | — | `-1` | rises on load and stays up |

`automatic` ignores `toggle` — there is nothing to toggle when nothing is firing it.

The wait is armed by the **server** on the frame the mover lands on a pose, not when the
trigger fired, so `wait` measures from arrival. `wait = 0` is legal and means "the instant it
lands". Clients never run any of this: they follow `_progress` and `_target_open` over the
existing RPCs, so all three flags are server-only behaviour even though they are plain
exports on every peer.

### Deviations from Qodot's originals

Qodot is archived and its brush set is a demo. The port is behavioural, not literal, and these
are the places a copy would have been wrong:

- **`translation` / `rotation` / `scale` are renamed `move_translation` / `move_rotation` /
  `move_scale`.** A real collision, not taste: `auto_apply_to_matching_node_properties` does
  `if property in node` (`entity_assembler.gd:250-259`), and `Node3D` **already has** `rotation`
  and `scale`. Qodot's names would have overwritten the brush's absolute transform instead of
  describing an offset from it. `speed`, `axis`, `depth`, `target`, `targetname` and `mass` are
  safe and kept — none is a `Node3D` property.
- **`AnimatableBody3D`, not `CharacterBody3D`,** for `mover` and `rotate` — Godot 4's idiom for a
  kinematic platform that *carries* a player rather than shoving them, and what `PayloadNode`
  already uses.
- **`node_class = "RigidBody3D"` on `physics`.** Qodot's definition says `"RigidBody"`, the Godot
  **3** name, which `ClassDB.instantiate()` cannot resolve on Godot 4 — Qodot's own entity could
  not have built.
- **`origin_type = 4` (`BOUNDS_CENTER`) on all five.** The func_godot default is `BRUSH`, which
  needs an `origin`-textured brush and otherwise silently falls back to the bounds centre
  (`geometry_generator.gd:207-224`). Declaring it means a mapper never needs an `origin` brush
  and the pivot is predictable. Qodot pivoted at the averaged brush vertices, which is close.
- **`button.depth` defaults to `4` (map units), not Qodot's `0.8`;** `0.8` at this project's
  32-units-per-metre scale would be a quarter of a millimetre of travel.
- **`button`'s `press_signal_delay` / `release_signal_delay` are gone.** Qodot declared
  `release_signal_delay` and never read it, and applied `release_delay` twice.

### Vectors are authored in TrenchBroom's axes and map units, and converted at build time

A mapper types into the editor they can see, so every vector property here is written in
**TrenchBroom's Z-up axes** and in **map units**, and the build converts both. Neither conversion
is automatic for a custom `class_properties` vector — the parser hands the value over exactly as
written, in the order it was written. func_godot only does this for its own keys: `origin` is
swapped at `entity_assembler.gd:224` and a per-axis `scale` at `:209`, both `(x, y, z) -> (y, z, x)`.

Concretely: a mapper setting a mover to rise writes `move_translation "0 0 128"` — 128 up in the
axes they can see, which has to arrive as `Vector3(0, 128, 0)`, then divide by 32 to become 4 Godot
units. Skip the axis swap and the door slides *sideways*; skip the unit conversion and it travels
128 units into the next room. Both are silent in TrenchBroom.

| Property | Axes | Units |
|---|---|---|
| `move_translation` | swapped | map units |
| `move_scale` | swapped | — |
| `axis` (`rotate`, `button`) | swapped | — |
| `velocity` (`physics`) | swapped | map units |
| `depth` (`button`) | — | map units |
| `move_rotation` | **not swapped** | degrees |
| `speed` | — | per-second |

**`move_rotation` is deliberately not swapped.** It is a (pitch, yaw, roll) triple, and "yaw about
the up axis" is the same rotation in both engines even though the two engines give the up axis a
different name. Component order, not axis identity, is what a rotation triple encodes. So the
default `axis` on `rotate` and `button` is written `Vector3(0, 0, 1)` / `Vector3(0, 0, -1)` — up
and down *in TrenchBroom's axes* — not the `Vector3(0, 1, 0)` a Godot reader would expect.

Both conversions happen in `_func_godot_apply_properties()`, **not at runtime**, and that is
forced: `FuncGodotMap.build()` is editor-only (a tool button, with no `_ready` build —
`func_godot_map.gd:26,92`), so maps ship pre-baked and nothing here runs in a running game. The
hook writes the converted value into the `@export`, which then serializes into the scene.
`BrushEntityUtil.to_godot_axes()` and `BrushEntityUtil.map_units()` supply the two factors — the
latter from the map's own `FuncGodotMapSettings.scale_factor`.

### The trigger → target link is made at map build time

This is the part with no func_godot equivalent. Qodot's `QodotMap.connect_signals()` wired
`source.trigger` → `target.use()` as a build step; func_godot's assembler has nothing of the
kind, so `BrushEntityUtil.link_targets()` reimplements it, called from each source entity's
`_func_godot_build_complete()`.

**One `target` name carries two contracts, and a target is wired for whichever it implements:**

| source signal | target method | target today |
|---|---|---|
| `trigger` | `use()` | `MovingBrush` (a door) |
| `occupant_entered` / `occupant_exited` | `add_occupant()` / `remove_occupant()` | `ControlPoint` |

They are **additive, not exclusive**. `use()` is a one-shot and cannot express "who is standing in
this volume", which is why a `ControlPoint` — whose capture volume *is* a trigger brush — needs the
second pair. A `MovingBrush` implements only `use()`, so the occupancy half is skipped for it and
every trigger→door link behaves exactly as it did before the pair was added. Occupancy is wired for
**both** methods or neither: a half-wired pair would leave a volume that could add an occupant it
could never remove.

Unlike `trigger`, `occupant_entered`/`occupant_exited` are **deliberately not gated on the server** —
they change no replicated state, and `ControlPoint._process` gates its own simulation while tracking
bodies peer-locally, exactly as it did when an `Area3D` did the tracking.

Three more things about it are load-bearing:

- **It must be `_func_godot_build_complete`, which the assembler calls *deferred*** after every
  entity has been added (`entity_assembler.gd:267-268`). Linking from `_func_godot_apply_properties`
  instead runs during the build loop and finds only the entities built *before* this one — a map
  whose mover happens to come first still works, which is exactly what makes that bug nasty.
- **The connection is made with `CONNECT_PERSIST`**, so it becomes a serialized fact of the map
  scene. **It therefore only exists after the map is rebuilt *and the scene is saved*** —
  a rebuild you do not save loses every link.
- **It exists on every peer, so sources must gate their own emission on the server.** A client
  that emitted `trigger` would call `use()` on its own copy and move a door its host never agreed
  to move. Every source does `if not multiplayer.is_server(): return` before emitting.

Target names resolve against a `targetname`, matched by walking the `FuncGodotMap` subtree —
**not** by Godot group, so it cannot collide with the `node_groups` namespace. An unresolvable
`target`, or a target implementing **neither** contract, raises a `push_warning` at build time;
Qodot failed silently on both. `use()` is hardcoded per Qodot, so a mover is the only single-shot
target — `ControlPoint` is the only occupancy one.

### `build_visuals = false` does not mean no collision

It gates **only** the mesh (`geometry_generator.gd:522-540`); convex collision is built
separately and unconditionally (`:546-558`). A `trigger` is therefore both invisible and solid —
which is the point, and would be an easy thing to "fix" into a broken trigger. Note the same
function skips any brush carrying an `origin` texture (`:549`), so an `origin` brush inside a
trigger has no collision.

### Verifying brush entities

Beyond the FGD harness below, `tools/verify_brush_entities.tscn` builds
`trenchbroom/maps/brush_entity_test.map` — one of each entity — and asserts the wiring, the
`CONNECT_PERSIST` flag, the unit conversion, collision presence and trigger invisibility. The
fixture carries **two** triggers and a `ControlPoint` on purpose, so both contracts are covered
and so is the gate: the mover must come out *without* the occupancy pair attached.

```
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/verify_brush_entities.tscn
```

It expects a screen of `Attempting to initialize the wrong RID` noise on the way — that is the
dummy renderer (`--headless` has no mesh storage) and it is not fatal. **It cannot check
serialization**, because connections only reach a `.tscn` when both endpoints carry an `owner`
and `edited_scene_root` is null outside the editor. That half is the manual build-and-save.

### Making a brush entity always carry a certain texture

TrenchBroom game-config **tags** can assign a material to every brush matching a classname, which is
how a mapper gets a trigger brush that always paints the same texture — and, with the same tag, show
it semi-transparent the way the `clip` face tag does. func_godot exposes the mechanism as
`TrenchBroomTag.texture_name` (`addons/func_godot/src/trenchbroom/trenchbroom_tag.gd`), emitted as
the tag's `material` key by `trenchbroom_game_config.gd:167-169`. The addon ships a ready-made
example, `addons/func_godot/game_config/trenchbroom/tb_brush_tag_trigger.tres` — classname pattern
`trigger*`, material `trigger`, and the default `tag_attributes` of `["transparent"]`.

**It is wired up for `trigger`.** `trenchbroom/trenchbroom_config.tres` lists that resource in
`brush_tags`, which is the only switch — `brush_tags` is empty by default and nothing is written
until something is listed there. The exported `GameConfig.cfg` then carries:

```
"brush": [
	{ "name": "Trigger", "attribs": [ "transparent" ],
	  "match": "classname", "pattern": "trigger*", "material": "trigger" }
]
```

`"transparent"` is the same attribute the shipped `Clip` face tag uses, which is why the two behave
identically. To cover another entity, add a `TrenchBroomTag` (`tag_match_type = CLASSNAME`,
`tag_pattern` = the entity classname, `texture_name` = a name that resolves under
`trenchbroom/textures`) to `brush_tags` and re-export.

**Two things to know before relying on it:**

- **It never reaches Godot.** `trigger.tres` has `build_visuals = false`, so a trigger builds no
  `MeshInstance3D` at all and the texture has nothing to attach to. This is an editor-only
  affordance — which is the point, since an invisible trigger is meant to be found in the editor.
- **The `material` name must resolve in TrenchBroom's material collection, by full relative path, or
  the tag does nothing — silently.** See `05-known-issues.md` #77. Our name is `trigger` because
  `trigger.png` sits at the root of `trenchbroom/textures`, matching how `clip`/`skip`/`origin` are
  named. TrenchBroom builds that collection **when it loads the game and does not watch the folder**,
  so a texture added while it is running is invisible until a restart — and an unresolvable material
  fails without an error.
- **Do not read "the brush went transparent" as "the material applied".** The `attribs` half is a
  rendering attribute resolved per matching brush entity — a separate code path from the material.
  They fail independently, which is exactly what an unresolved material name looks like.
- **A tag only supplies a *default*, so it never repaints a face that already carries a texture.**
  A brush that had one before it became a trigger keeps it.

`trigger.tres` also sets `meta_properties["color"]` to amber, which tints trigger brushes in the
viewport independently of any of this.

## Current entities

Point entities only — the brush entities (`trigger`, `mover`, `rotate`, `button`, `physics`) are
tabulated in [Brush entities](#brush-entities-solid-classes) above, where the settings here mostly
do not apply to them (no `scene_file`, no display model, no `size` box).

| classname | Built from | Display model | Rotatable | Scalable |
|---|---|---|---|---|
| `Truck` | `assets/map_models/props/truck.tscn` (CSG, `use_collision = true`) | generated | `mangle` | `scale` |
| `Forklift` | `assets/props/forklift.glb` | generated | `mangle` | `scale` |
| `mannequin` | `assets/mannequin/mannequin.glb` (rigged) | static bake — see above | `mangle` | `scale` |
| `PlayerSpawn` | `world/special_entities/player_spawn.tscn` | static bake (the mannequin) | `mangle` | — |
| `HealthPackSpawner` | `world/special_entities/health_pack_spawner.tscn` | generated | — | — |
| `ControlPoint` | `world/special_entities/control_point.tscn` | generated (the sphere) | — | — |

`Truck`, `PlayerSpawn` and `HealthPackSpawner` are **hand-authored** — the generator only covers
`assets/props/`, and the other two are scenes under `world/`. `PlayerSpawn` takes no `scale`: it is a
spawn point, not a prop, and the harness only requires the keys an entity actually declares.

Its `mangle` sets **which way the player faces on spawn** — `Map.get_random_spawn_transform()` reads
the built marker's yaw, `rpc_reset()` carries it as a `Transform3D`, and the player's body is turned
to match. Rotating the entity in TrenchBroom rotates the preview mannequin to match, so what a mapper
aims is what a player gets.

Its one property is `team`, a `choices` list (`SPI (red)` 0 / `SCI (blue)` 1 / `Any` 2, default
`Any`) that `auto_apply_to_matching_node_properties` pushes onto the built node's exported `team`.
`Map._enter_tree()` reads it to route the spawn into a pool. A spawn is identified by **type, not by
name**: the scan keeps every `PlayerSpawn` it finds (recursively, since func_godot nests entities
under `FuncGodotMap`) and takes the pool from `team` alone, so renaming one cannot move it between
pools. Anything that is not a `PlayerSpawn` is ignored — a bare `Marker3D` named "…spawn…" is no
longer a spawn at all; the old name rules (`spi`/`sci` in the name) are gone.

The enum values must stay in step with that `choices` list — the enum lives on
`world/special_entities/player_spawn.gd`.

**`HealthPackSpawner` takes neither `mangle` nor `scale`, and that is a decision rather than an
omission.** `PlayerSpawn` needs `mangle` because a spawn's yaw is gameplay; a health pack has no
meaningful facing, and declaring a rotation property would additionally drag in the XY-centring rule
above for nothing. `scale` is the dangerous one — `apply_scale_on_map_build` scales the built node, so
a scaled spawner would grow its pickup `Area3D` while the FGD `size` box stayed put (the same caveat
the scaling section records for every prop). What a mapper *can* set is **`respawn_time`**, a `float`
defaulting to `10.0`, pushed onto the built node by `auto_apply_to_matching_node_properties` — the
mechanism `PlayerSpawn`'s `team` uses. It has to stay a `float` on both sides: `parser.gd:144-145`
converts the raw `.map` string with `to_float()` for a `TYPE_FLOAT` default, and
`entity_assembler.gd:255` `push_error`s on a `typeof` mismatch rather than coercing.

The entity's `scene_file` is the spawner, so its generated display model is the **pack itself** —
which is what a mapper wants to see, since the pack is the thing players aim at. Everything in the
scene is centred on the origin in X and Z because the map build applies an unconditional 180° yaw
(`entity_assembler.gd:196-199`); an off-centre child would be mirrored relative to the preview.

**`ControlPoint` is placed as a point entity, but its capture volume is a `trigger` brush.** The
scene holds only the sphere and a billboard `Label3D`; there is deliberately no `Area3D` in it, since
a volume drawn in the map is visible, draggable and per placement, where a `BoxShape3D` buried in a
`.tscn` is none of those. The mapper sets the point's **`targetname`** and gives a `trigger` brush
that same name as its **`target`** — `link_targets` then wires the brush's occupancy signals to
`add_occupant()` / `remove_occupant()` (see [the link section](#the-trigger--target-link-is-made-at-map-build-time)).

Its `game_mode_component` is **not** an `@export NodePath` — TrenchBroom cannot author one. The script
reads `GameManager.game_mode_component`, which `Map._enter_tree()` sets before any descendant's
`_ready`, the same route `HealthPackSpawner` takes. That also removes an old silent failure where an
unset export meant the point never registered at all.

The other three properties are `capture_time` (`float`), `contest_slow_multiplier` (`float`) and
`default_owner` (a `choices` list, `SPI (red)` 0 / `SCI (blue)` 1 / `FFA (neutral)` 2, default 2) —
all pushed onto the built node by `auto_apply_to_matching_node_properties`. Like `PlayerSpawn`'s
`team` and `HealthPackSpawner`'s `respawn_time`, the `.map` stores them as strings and the assembler
coerces each to the property's type before assigning. Verified by the brush-entity harness, which
asserts all three land (`tools/verify_brush_entities.gd` `_check_applied`).
