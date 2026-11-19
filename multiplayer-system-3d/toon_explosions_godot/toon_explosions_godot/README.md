# Toon Explosion FX collection for Godot

Open `godot/project.godot` in Godot 4.6 or newer and press F5. The effect picker has 31 additional presets from the two mod packages, plus the rocket surface impact from the earlier export.

- Use the effect picker and **Replay** or **Space**. Click a point on the demo floor or wall to place the effect there.
- Press **W** to preview against the wall and **S** to toggle slow motion.
- The package name in the picker distinguishes effects whose identifiers appear in both particle files. Long smoke systems can take up to about 27 seconds at normal speed.

## Use a preset in your game

Copy `godot/effects/` into the project's `res://effects/` directory. The general explosion scene uses the procedural shaders in the rocket impact folder.

```gdscript
const TOON_EXPLOSION = preload("res://effects/toon_explosions/toon_explosion.tscn")

func play_hoodoo(hit_position: Vector3, hit_normal: Vector3, local_up: Vector3) -> void:
    var effect := TOON_EXPLOSION.instantiate()
    effect.effect_scale = 0.75
    add_child(effect)
    effect.play("dirty_explode/asplode_hoodoo", hit_position, hit_normal, local_up)
```

See `catalog.json` for stable preset IDs. Call `play()` after adding the node to the tree. It returns false for an unknown ID. An optional fifth argument supplies a random seed. The scene emits `finished` and frees itself by default. Set `auto_free` to false for reuse between bursts. For a game export, include `effects/toon_explosions/profiles.json` in the preset's non-resource include filter. [Godot export documentation](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html)

The 31 previews use each source effect's emitter graph, child delays, lifetimes, colors, and size and fade curves. The 3D motion, collisions, trails, and materials are approximated with Godot geometry and original shaders. Dense emitters have sample caps and open-ended emission runs for 2.5 seconds so a preview can finish. The scenes are visual effects.

## Source files

| Input particle file | Additional presets |
|---|---:|
| `bigboom.pcf` | 17 |
| `dirty_explode.pcf` | 14 |

Each effect under `reference/<particle file>/effects/<effect>/` has its own scoped binary PCF, typed `particles.json`, and flattened `emitters.json`. These preserve source values, operator order, and duplicate child links. The binary files remap element indices to the scoped graph.

Each particle file has a shared `materials.json` manifest for its presets. It links the original VMT and VTF bytes under `source/materials/`, with checksums and embedded atlas rectangles where available. Entries marked `in_mod: false` reference base-game materials outside the supplied package. The original rocket extraction is included under `reference/rocket_surface_impact/`.

I round-tripped all 31 scoped PCFs and exercised every Godot preset headlessly in Godot 4.6.3. I also checked the underwater surface impact and both payload explosions in the graphical preview.

## Preset list

32 effects: 31 presets on the general scene (`effects/toon_explosions/toon_explosion.tscn`) plus the standalone rocket surface impact (`effects/rocket_impact/rocket_impact.tscn`).

Columns: preset id — group — emitter systems — approximate total duration (root lifetime plus child delays).

### bigboom (17)

*Fire, smoke and trails*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `bigboom/fireSmokeExplosion4` | Fire, smoke and trails | 2 | 8 s | Fireball with trailing smoke burst |
| `bigboom/fireSmokeExplosion3` | Fire, smoke and trails | 2 | 8 s | Same shape, different curve and tint |
| `bigboom/fireSmokeExplosion2` | Fire, smoke and trails | 2 | 8 s | Same shape, different curve and tint |
| `bigboom/fireSmokeExplosion` | Fire, smoke and trails | 2 | 8 s | Base fireball plus smoke trail |
| `bigboom/fireSmoke_collumnP` | Fire, smoke and trails | 8 | 14 s | Tall multi-emitter smoke column |
| `bigboom/explosionTrail_seeds_mvm` | Fire, smoke and trails | 3 | 2 s | Rolling seed/debris trail (MvM rocket) |
| `bigboom/fireSmoke_Collumn_mvmAcres` | Fire, smoke and trails | 6 | 13 s | Large MvM smoke column |
| `bigboom/fireSmoke_Collumn_mvmAcres_sm` | Fire, smoke and trails | 6 | 13 s | Small variant, same structure |

*Components*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `bigboom/airburst_shockwave` | Components | 2 | 0.2 s | Thin ring flash, airburst |
| `bigboom/Explosions_MA_Dustup_2` | Components | 1 | 1 s | Ground dust kick-up |
| `bigboom/Explosion_ShockWave_01` | Components | 1 | 0.5 s | Flat expanding shock ring |

*Core impacts*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `bigboom/ExplosionCore_Wall_underwater` | Core impacts | 12 | 1.6 s | Underwater wall hit: bubbles and foam |
| `bigboom/ExplosionCore_buildings` | Core impacts | 13 | 1.6 s | Debris-heavy building impact |
| `bigboom/ExplosionCore_MidAir` | Core impacts | 16 | 1.6 s | Full mid-air core: flash, sparks, smoke |
| `bigboom/ExplosionCore_MidAir_Flare` | Core impacts | 10 | 5 s | Long flare streak on the mid-air core |
| `bigboom/ExplosionCore_MidAir_underwater` | Core impacts | 15 | 1.6 s | Mid-air core with bubbles and foam |
| `bigboom/ExplosionCore_sapperdestroyed` | Core impacts | 8 | 1.2 s | Small Sapper-style pop |

### dirty_explode (14)

*Payload set pieces*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `dirty_explode/cinefx_goldrush` | Payload set pieces | 17 | 18 s | Large Goldrush briefcase blowup |
| `dirty_explode/asplode_hoodoo` | Payload set pieces | 14 | 9 s | Hoodoo briefcase blowup |

*Aftermath*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `dirty_explode/cinefx_goldrush_burningbarrel` | Aftermath | 2 | 9 s | Burning barrel fire and smoke |
| `dirty_explode/asplode_hoodoo_smoke` | Aftermath | 1 | 18 s | Lingering smoke plume after the blowup |

*Fire, smoke and trails*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `dirty_explode/explosionTrail_seeds_mvm` | Fire, smoke and trails | 3 | 2 s | Seed/debris trail (dirty variant) |
| `dirty_explode/fireSmoke_Collumn_mvmAcres` | Fire, smoke and trails | 7 | 13 s | MvM smoke column |
| `dirty_explode/fireSmoke_Collumn_mvmAcres_sm` | Fire, smoke and trails | 6 | 8 s | Small MvM column |
| `dirty_explode/fireSmoke_collumnP` | Fire, smoke and trails | 14 | 14 s | Dense smoke column with sub-emitters |
| `dirty_explode/fireSmokeExplosion` | Fire, smoke and trails | 4 | 5 s | Fireball with extra sub-emitters |
| `dirty_explode/fireSmokeExplosion2` | Fire, smoke and trails | 4 | 5 s | Variant |
| `dirty_explode/fireSmokeExplosion3` | Fire, smoke and trails | 4 | 5 s | Variant |
| `dirty_explode/fireSmokeExplosion4` | Fire, smoke and trails | 4 | 5 s | Variant |

*Components*

| Preset | Group | Systems | ≈Duration | Description |
|---|---|---:|---:|---|
| `dirty_explode/fluidSmokeExpl_ring_mvm` | Components | 1 | 13 s | Wide flat smoke ring, long-lived |
| `dirty_explode/explosion_wave` | Components | 1 | 0.6 s | Quick radial wave flash |

### rocket_impact (1, separate scene)

| Scene | Description |
|---|---|
| `effects/rocket_impact/rocket_impact.tscn` | Rocket surface impact from the earlier export. Supplies the procedural shaders the toon presets reuse. |

Some names repeat across packages (for example `fireSmokeExplosion4` and `explosionTrail_seeds_mvm`); the package field disambiguates them and the picker shows the package name.
