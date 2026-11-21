# Projectile trail and explosion inventory

Running table of every projectile in `weapon/projectiles/scenes/`. **Update this file whenever a projectile's trail or explosion preset changes.** Explosion context is picked from the detonation: air burst vs solid contact, then water at the blast centre (`SimpleProjectile.start_explode()` / `ExplosionComponent._resolve_preset()`). A surface counts only when the collision hull is **touching** it: the contact is latched each physics step (`_integrate_forces`) and by `_attach_to()` for sticky projectiles. No contact → air burst; a grenade that stopped short of a wall is an air burst.

Preset shorthand (all under `bigboom/` unless noted):

- `MidAir` = `ExplosionCore_MidAir`, `Wall` = `ExplosionCore_Wall`
- `MidAir_uw` = `ExplosionCore_MidAir_underwater`, `Wall_uw` = `ExplosionCore_Wall_underwater`
- `MidAir_Flare` = `ExplosionCore_MidAir_Flare`, `Wall_Flare` = `ExplosionCore_Wall_Flare`
- `MidAir_Flare_uw` = `ExplosionCore_MidAir_Flare_underwater`, `Wall_Flare_uw` = `ExplosionCore_Wall_Flare_underwater`
- `Nuke_MidAir`, `Nuke_Underwater`, `Nuke_MidAir_underwater` = the project composites
- `goldrush` = `dirty_explode/cinefx_goldrush`, `CarpetBomb_Flare` = `ExplosionCore_CarpetBomb_Flare`

All trails are local-only (`toon_trail`); every projectile now sets both `trail_preset` and `underwater_trail_preset`, and the trail swaps when the projectile enters a `WaterVolume`.

| Projectile | Used by | Detonation | Trail | Underwater trail | Explosion (air) | Explosion (surface) | Underwater explosion (air) | Underwater explosion (surface) |
|---|---|---|---|---|---|---|---|---|
| `rocket.tscn` | Rocket Launcher, Gravity Rocket Launcher | Contact | `rockettrail` | `rockettrail_underwater` | `MidAir` | `Wall` | `MidAir_uw` | `Wall_uw` |
| `gravity_rocket.tscn` | Gravity Rocket Launcher | Contact | `rockettrail` | `rockettrail_underwater` | `MidAir_Flare` | `Wall_Flare` | `MidAir_Flare_uw` | `Wall_Flare_uw` |
| `redirectable_rocket.tscn` | Redirectable Rocket Launcher | Contact, SIGNAL redirect | `rockettrail` | `rockettrail_underwater` | `MidAir` (yellow tint) | `Wall` (yellow tint) | `MidAir_uw` (yellow tint) | `Wall_uw` (yellow tint) |
| `rocket_carpet.tscn` | Breacher / Blast Charges | Contact | `rockettrail_lite` | `rockettrail_underwater_lite` | `CarpetBomb_Flare` | `CarpetBomb_Flare` | `CarpetBomb_Flare` — **FIX** no underwater variant | `CarpetBomb_Flare` — **FIX** no underwater variant |
| `nuke.tscn` | Breacher / Davy Crockett | Contact | `grenade_smoke` | `rockettrail_underwater` | `Nuke_MidAir` | `goldrush` | `Nuke_MidAir_underwater` | `Nuke_Underwater` |
| `grenade.tscn` | Grenade Launcher, Explodable Grenade Launcher | Fuse 2.3 s, hurtbox contact | `grenade_ribbon` | `rockettrail_underwater` | `MidAir` | `Wall` | `MidAir_uw` | `Wall_uw` |
| `heal_grenade.tscn` | Heal Grenade Launcher | Contact, fuse 2.3 s | `grenade_ribbon` | `rockettrail_underwater` | `MidAir` (green tint) | `Wall` (green tint) | `MidAir_uw` (green tint) | `Wall_uw` (green tint) |
| `poison_jar.tscn` | Poison Jar | Contact, fuse 2.3 s | `grenade_ribbon` | `rockettrail_underwater` | `MidAir` (purple tint) | `Wall` (purple tint) | `MidAir_uw` (purple tint) | `Wall_uw` (purple tint) |
| `molotov.tscn` | Molotov | Fuse 2.3 s, hurtbox contact | `grenade_ribbon` | `rockettrail_underwater` | `MidAir` (orange tint) | `Wall` (orange tint) | `MidAir_uw` (orange tint) | `Wall_uw` (orange tint) |
| `mine.tscn` | Mine Layer | SIGNAL (sticky; trail stops on stick) | `grenade_ribbon` | `rockettrail_underwater` | `MidAir` (proximity probe may select `Wall`) | `Wall` | `MidAir_uw` | `Wall_uw` |
| `arrow.tscn` | Bow, Calligraphy Metal | Sticks | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `shuriken_projectile.tscn` | Shurikens | Sticks (hurtbox), world despawn | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `syringe.tscn` | Syringe Gun | Sticks | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `ball.tscn` | Ball Gun | Sticks to players, passes world | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `rock.tscn` | Calligraphy Earth | Sticks | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `water.tscn` | Calligraphy Water | Sticks, lifetime 4 s | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `wood.tscn` | Calligraphy Wood | Passes world, lifetime 20 s | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `flame.tscn` | Flamethrower, Calligraphy Fire | Sticks world, lifetime 4 s | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `healthpack.tscn` | Medpack Launcher | Heals on hit | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `poisoned_healthpack.tscn` | Medpack Launcher | Damages on hit | `generic_trail` | `rockettrail_underwater` | NA | NA | NA | NA |
| `simple_projectile.tscn` | Base scene, not fired | — | none | none | NA | NA | NA | NA |

**Shooting a projectile.** Every projectile gets a code-built, oversized `ShotHurtbox` (1 m sphere, `shot_hurtbox_radius`); the scene's own collision shape is untouched. Every projectile has `health = 1` (`SimpleProjectile.health`), so one bullet takes it out: **explosive** projectiles detonate in the air, everything else is **deflected** along the direction of the shot (`SimpleProjectile.take_bullet_hit()`; anyone may do it, including the owner). "Explosive" is derived from the scenes — `world_hit_mode`/`hurtbox_hit_mode == EXPLODE` or `explode_on_timeout` — and every row with an explosion above is explosive. The **mine** is the one override (`shot_behaviour = EXPLODE`) because its contact mode is STICK. All arrows-like rows (arrow, shuriken, syringe, ball, rock, water, wood, flame, health packs) deflect.

Notes:

- `carpet_trail` was removed. Blast Charges fires 15 rockets per cast, so the carpet rocket uses `rockettrail_lite` / `rockettrail_underwater_lite`: the rocket trail with the long smoke ribbon and spark layer dropped, half the emission, capped samples and 3 subdivisions. Other rockets keep the full `rockettrail`.
- `generic_trail` is the neutral ribbon used by every non-explosive projectile. `rockettrail_underwater` is the shared underwater bubble trail.
- `rocket_carpet` is the only explosive still using a single all-context preset and therefore the only missing underwater explosion.
