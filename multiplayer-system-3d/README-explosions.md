# Godot explosion and trail guide

Choose the explosion from the **detonation point**. Two things matter: whether the blast is against a solid surface and whether the blast center is submerged. The projectile trail follows the **exhaust nozzle** during flight, so its final segment can be in a different medium from the explosion.

## Choose the explosion

| Detonation | Explosion preset ID | Placement |
|---|---|---|
| Rocket hits a wall, floor, ceiling, or solid prop in air | `bigboom/ExplosionCore_Wall` | Use the world-space contact point and the outward surface normal. The same preset works on floors and slopes. |
| Rocket bursts in air away from a solid surface | `bigboom/ExplosionCore_MidAir` | Use the detonation point and local up. Use this for a timed detonation or an intercepted rocket. |
| Rocket hits a solid surface underwater | `bigboom/ExplosionCore_Wall_underwater` | Use the submerged contact point and the outward surface normal. The preset includes impact bubbles. |
| Rocket bursts in open water | `bigboom/ExplosionCore_MidAir_underwater` | Use the submerged detonation point and local up. The preset includes bubbles and a pressure wave. |
| Flare bursts in air | `bigboom/ExplosionCore_MidAir_Flare` | Use the burst point and local up. This preset has firework arcs and sparkles. |
| A building is destroyed | `bigboom/ExplosionCore_buildings` | Place it at the building's destruction point. The full effect includes the lightning layer. |
| A sapper is destroyed | `bigboom/ExplosionCore_sapperdestroyed` | Place it at the sapper. The full effect includes the cyan spark burst and flying embers. |

For a surface preset, pass its outward normal as the third argument to `play()` and local gravity-up as the fourth. For an open-air or open-water burst, pass local up for both. On a spherical planet, calculate local up from gravity at the detonation point. The effect uses that direction for its up axis while the surface normal sets the impact direction.

Crossing the waterline without detonating is a trail change. If the rocket detonates at the waterline, use the water volume that contains the blast center. Use the surface preset when the rocket hits a solid object there. The exported collection has no dedicated water-entry splash.

## Pair the trail and the burst

| Projectile in flight | Trail preset ID | At detonation |
|---|---|---|
| Standard rocket | `rockettrail` | Choose the surface or midair explosion from the table above. |
| Submerged rocket | `rockettrail_underwater` | Choose the underwater surface or open-water explosion. The full trail already emits bubbles. |
| Critical rocket in air | `critical_rocket_red_combined` or `critical_rocket_blue_combined` | Use the usual rocket explosion for the contact and medium. The team-colored electricity is part of the flight trail. |
| Air Strike or sentry rocket in air | `rockettrail_airstrike` or `sentry_rocket` | Use the usual rocket explosion for the contact and medium. The full Air Strike preset already includes its secondary ribbon. |
| Flare or Scorch Shot | `flaregun_trail_red` / `flaregun_trail_blue` or `scorchshot_trail_red` / `scorchshot_trail_blue` | For a visible flare detonation in air, use the flare burst above. Critical and Pyrovision trail variants are listed in the trail pack's `catalog.json`. |

1. Add the trail to a world effects node that outlives the projectile. Start it with `trail.start(trail_id, nozzle)` after the trail and nozzle enter the scene tree. Put the nozzle marker at the exhaust, with its local **−Z** pointing toward the projectile nose.
2. On detonation, call `trail.stop()` and play **one** explosion at the hit point or burst center in the same update. Then free the projectile. The old trail stays in world space and fades on its own.
3. If a rocket crosses into water and keeps flying, stop the dry trail and start a **new** underwater trail on the same nozzle. Switch back on exit. Reusing the old trail node would clear the particles you want to fade out.

The flight streak follows the incoming path. The blast's own sparks and debris fly outward from the impact. The full explosion already includes those outward layers. Use isolated spark, smoke, and shockwave presets when composing a custom blast. Likewise, use the critical overlays, bubble-only trail, or Air Strike secondary ribbon when building a custom trail. Adding them to their corresponding full presets doubles layers already present.

## Set pieces and aftermath

- `dirty_explode/cinefx_goldrush` and `dirty_explode/asplode_hoodoo` are large scripted destruction effects for set pieces. Use them at the event origin. `cinefx_goldrush_burningbarrel` and `asplode_hoodoo_smoke` in the same package are aftermath presets for locations that should continue burning or smoking.
- The `fireSmokeExplosion*` and smoke column entries are for lingering fire or smoke. The `explosionTrail_seeds_mvm` entries are explosion components. For exhaust attached to a moving projectile, use the trail pack instead.
- The isolated building lightning and two sapper spark presets are available for custom effects or for previewing the layers by themselves.

## Godot setup and example

In Godot 4.7, open either pack's `godot/project.godot` and press **F5** to browse its presets. For frame stepping, open the explosion pack's `godot/rocket_impact_viewer.tscn` and press **F6**. Use **Wall** to change the contact orientation.

To integrate both packs, copy the explosion pack's `godot/effects/` into your project's `res://effects/`, then copy the trail pack's `godot/effects/toon_trail/` into `res://effects/toon_trail/`. Keep the explosion pack's `rocket_impact/` folder because the explosion scene loads shaders from it. Each pack's `catalog.json` lists its stable preset IDs.

This example handles the four standard rocket impacts. Pass `Vector3.ZERO` as the surface normal for a free burst. Keep `effects_root` in the world scene and call this once per detonation.

```gdscript
const EXPLOSION := preload("res://effects/toon_explosions/toon_explosion.tscn")
const TRAIL := preload("res://effects/toon_trail/toon_trail.tscn")

func start_rocket_trail(effects_root: Node3D, nozzle: Node3D, in_water: bool) -> Node3D:
	var trail := TRAIL.instantiate()
	effects_root.add_child(trail)
	var preset := "rockettrail_underwater" if in_water else "rockettrail"
	if trail.start(preset, nozzle):
		return trail
	trail.queue_free()
	return null

func detonate_rocket(
	effects_root: Node3D,
	trail: Node3D,
	point: Vector3,
	surface_normal: Vector3,
	local_up: Vector3,
	submerged: bool
) -> void:
	if is_instance_valid(trail):
		trail.stop()

	var on_surface := not surface_normal.is_zero_approx()
	var preset := "bigboom/ExplosionCore_Wall" if on_surface else "bigboom/ExplosionCore_MidAir"
	if submerged:
		preset += "_underwater"

	var explosion := EXPLOSION.instantiate()
	effects_root.add_child(explosion)
	var direction := surface_normal if on_surface else local_up
	explosion.play(preset, point, direction, local_up)
```

Both scenes free themselves when their particles finish by default. Keep gameplay damage and collision in the projectile logic. These scenes handle visuals.
