# Toon Rocket Trails for Godot

Open `godot/project.godot` in Godot 4.6 or newer and press F5. The demo runs a projectile along a curved path and then lets the trail fade. Use the picker to select a trail, **Space** to replay, and **S** for slow motion.

The 29 presets include standard, underwater, Air Strike, sentry, critical, and Pyrovision rockets, plus red and blue flare and Scorch Shot variants. The Air Strike and critical overlays can also be previewed separately. The standard rocket uses connected, camera-facing strips with a bright core and layered smoke. Flare and Scorch Shot profiles add team-colored exhaust and, where configured, rings or a spiraling ribbon.

## Attach a trail to a projectile

Copy `godot/effects/toon_trail/` into your project at `res://effects/toon_trail/`. Add a `Marker3D` to your projectile at the exhaust position and orient its local **−Z** toward the nose. Add the trail scene to a world or effects node so it can outlive the projectile.

```gdscript
const TOON_TRAIL = preload("res://effects/toon_trail/toon_trail.tscn")

func launch_trail(nozzle: Node3D) -> Node3D:
    var trail := TOON_TRAIL.instantiate()
    trail.effect_scale = 1.0
    add_child(trail)
    trail.start("rockettrail", nozzle)
    return trail
```

`catalog.json` lists the supported IDs. `start()` returns false for an unknown ID or an invalid nozzle. The optional third argument sets a random seed. Call `stop()` at impact. Freeing the exhaust marker also stops emission. Previously emitted samples drain in world space and the trail emits `finished`, then frees itself by default. Set `auto_free` to false to restart the same node with `start()`.

## Extracted reference

- `reference/rockettrail/` contains typed particle and flattened emitter JSON for all 85 definitions. This includes incidental stock tracer and healing definitions. The Godot picker focuses on the rocket and flare effects.
- `reference/halloween/` contains the five Air Strike definitions from `halloween.pcf`. Their scoped binary is under `reference/source/particles/`.
- `reference/source/particles/` also contains byte-identical copies of the mod's `rockettrail.pcf` and `rockettrail_dx80.pcf`.
- `reference/materials.json` lists the material dependencies, with hashes and atlas frame coordinates for supplied textures. `in_mod: false` marks references supplied by the base game or absent from the archive.

The Godot presets use original procedural shading, with source-derived rates, colors, lifetimes, and width curves. The port caps emission and tessellation density and approximates specialized Source operators. The Godot demo and its graphics run independently of the Source reference files.

All 29 presets were exercised headlessly in Godot 4.7. The checks covered moving-nozzle emission, connected ribbon geometry, and cleanup after stop or nozzle removal. Graphical and web previews were unverified in this session.

Source reference by Chaofanatic. [Toon Rocket Trails on GameBanana](https://gamebanana.com/mods/12410)

## Preset list

29 presets, all on the general scene (`effects/toon_trail/toon_trail.tscn`). Columns: preset id — layer count — approximate longest layer lifetime (some layers keep emitting beyond the projectile lifetime).

### Rocket (9)

| Preset | Layers | ≈Life | Description |
|---|---:|---:|---|
| `rockettrail` | 7 | 8 s | Standard rocket: bright core ribbon, beam, fire, plus star burst, secondary ribbon and glowing bits |
| `rockettrail_underwater` | 6 | 4 s | Standard shape with water bubbles in place of the trailing rope |
| `rockettrail_airstrike` | 10 | 9 s | Air Strike: wider ribbon, beam, glow, fire, plus the secondary line ribbon |
| `sentry_rocket` | 5 | 4 s | Sentry rocket: short ribbon with burst, fire glow and beam |
| `critical_rocket_red_combined` | 12 | 8 s | Standard rocket plus the red critical overlay (stars, arcs, electricity) |
| `critical_rocket_blue_combined` | 12 | 8 s | Standard rocket plus the blue critical overlay |
| `rockettrail_!` | 3 | 1.2 s | Classic rocket: smoke ribbon, star burst, fire |
| `halloween_rockettrail` | 3 | 1.2 s | Halloween rocket: smoke variant with star burst and fire |
| `pyrovision_rockettrail` | 5 | 1.4 s | Pyrovision rocket: bubble ribbon, star burst, beam, fire, glowing bits |

### Flare (4)

| Preset | Layers | ≈Life | Description |
|---|---:|---:|---|
| `flaregun_trail_red` | 7 | 2.6 s | Red flare: exhaust ribbon, sparkles, glowing bits, two fire ribbons, glow |
| `flaregun_trail_blue` | 7 | 2.6 s | Blue flare: same structure |
| `flaregun_trail_crit_red` | 10 | 2.6 s | Red critical flare: flare layers plus crit extras |
| `flaregun_trail_crit_blue` | 10 | 2.6 s | Blue critical flare |

### Scorch Shot (4)

| Preset | Layers | ≈Life | Description |
|---|---:|---:|---|
| `scorchshot_trail_red` | 9 | 8 s | Red Scorch Shot: ribbon, energy-field ring, fire ribbons, ring stack and spiral |
| `scorchshot_trail_blue` | 9 | 8 s | Blue Scorch Shot |
| `scorchshot_trail_crit_red` | 12 | 8 s | Red critical Scorch Shot: adds the crit layers |
| `scorchshot_trail_crit_blue` | 12 | 8 s | Blue critical Scorch Shot |

### Pyrovision (8)

| Preset | Layers | ≈Life | Description |
|---|---:|---:|---|
| `pyrovision_flaregun_trail_red` | 7 | 1.4 s | Red Pyrovision flare: bubble ribbon with flare layers |
| `pyrovision_flaregun_trail_blue` | 7 | 1.4 s | Blue Pyrovision flare |
| `pyrovision_flaregun_trail_crit_red` | 10 | 1.4 s | Red Pyrovision critical flare |
| `pyrovision_flaregun_trail_crit_blue` | 10 | 1.4 s | Blue Pyrovision critical flare |
| `pyrovision_scorchshot_trail_red` | 9 | 8 s | Red Pyrovision Scorch Shot: bubble ribbon, rings and spiral |
| `pyrovision_scorchshot_trail_blue` | 9 | 8 s | Blue Pyrovision Scorch Shot |
| `pyrovision_scorchshot_trail_crit_red` | 12 | 8 s | Red Pyrovision critical Scorch Shot |
| `pyrovision_scorchshot_trail_crit_blue` | 12 | 8 s | Blue Pyrovision critical Scorch Shot |

### Components (4)

| Preset | Layers | ≈Life | Description |
|---|---:|---:|---|
| `halloween/rockettrail_airstrike_line` | 5 | 9 s | Air Strike secondary ribbon: line plus spin ribbons and wisp |
| `critical_rocket_red` | 5 | 1 s | Red critical rocket overlay: star, sparks, electric arcs, beam, glow |
| `critical_rocket_blue` | 5 | 1 s | Blue critical rocket overlay |
| `rockettrail_bubbles` | 1 | 1.4 s | Rocket bubbles component, on its own |
