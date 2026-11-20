extends Node3D
class_name ExplosionComponent

var exploded := false

## Damage (negative) or healing (positive) applied to each player in the blast.
## Deliberately `float`: declared as `:= -75` this infers `int`, and every
## fractional multiplier applied to it -- the travel-time falloff and the
## shooter's `damage_amp_mult` (see WeaponController._spawn_projectile) -- would
## be truncated.  The `.tscn` values stay written as integers and coerce fine.
@export var splash_health_delta: float = -75.0
@export var splash_radius := 3.0
@export var explosion_color := Color.WHITE

## Optional toon explosion preset id from `effects/toon_explosions/explosion_profiles.gd`
## (for example `bigboom/ExplosionCore_MidAir`).  This is the dry air-burst
## preset.  Empty keeps the legacy rocket_impact burst, so existing projectiles
## are unchanged until they opt in.
@export var effect_preset: String = ""
## Preset for a dry detonation against a solid surface.  Empty reuses
## [member effect_preset].  See `README-explosions.md`: a surface impact wants
## the contact point, the outward surface normal and the `ExplosionCore_Wall`
## family.
@export var surface_effect_preset: String = ""
## Preset for a detonation whose blast centre is inside a water volume.  Empty
## reuses [member effect_preset].
@export var underwater_effect_preset: String = ""
## Preset for a submerged detonation against a solid surface.  Empty falls back
## to [member underwater_effect_preset].
@export var underwater_surface_effect_preset: String = ""
## Multiplies the burst footprint derived from [member splash_radius].  The toon
## presets carry their own absolute sizes, so use this to tune a preset's read
## without touching its data.
@export var effect_scale_multiplier := 1.0

## Optional one-shot played at the blast point.  Played from `_explode_visual`,
## which is `call_local`, so every peer hears it without an extra RPC.
@export var explosion_sound: AudioStream
@export_range(-40.0, 12.0, 0.5) var explosion_sound_volume_db := -10.0
## 3D attenuation size in metres; larger carries further.
@export_range(1.0, 60.0, 0.5) var explosion_sound_unit_size := 12.0

## Status effects applied to every player hit by the explosion blast.
## Set in the scene or copied from WeaponFire.status_effects at spawn time.
@export var status_effects: Array[StatusEffect] = []

@export var min_knockback_percent := 0.5 ##For distance based knockball falloff

#Technically rather redunant, but useful to avoid confusuion
@export var self_health_delta_multiplier := 0.25
@export var team_health_delta_multiplier := 0.0
@export var enemy_health_delta_multiplier := 1.0

@export var self_knockback_multiplier := 1.0
@export var team_knockback_multiplier := 0.0
@export var enemy_knockback_multiplier := 1.0


@export var knockback_force := 5.0

## Number of damage ticks this explosion applies.  1 = single blast
## (default, backward-compatible).  Values > 1 create pulsing AoE effects
## (gas clouds, napalm, etc.).
@export var tick_count: int = 1

## Seconds to wait between ticks.  Ignored when tick_count is 1.
@export var time_between_ticks: float = 0.5

## Preloaded explosion scene — spawned on-demand instead of sitting
## idle as a child on every projectile.
static var _explosion_scene: PackedScene = null
static var _toon_explosion_scene: PackedScene = null
const TOON_EXPLOSION_SCRIPT := preload("res://effects/toon_explosions/toon_explosion.gd")
const ROCKET_IMPACT_SCRIPT := preload("res://effects/rocket_impact/rocket_impact.gd")


# ----------------------------------------------------
# ENTRY POINT (called only once by whoever triggers it)
# ----------------------------------------------------
## @param falloff_multiplier — travel-time damage scalar from the projectile
##   (1.0 = full damage).  Multiplied with the existing distance-based falloff
##   so rockets that have been in flight longer deal less damage across their
##   entire blast radius.
## @param impact_normal — outward surface normal for a solid-surface detonation;
##   [constant Vector3.ZERO] for an air burst (the guide then uses local up).
## @param impact_point — world-space contact point for a surface detonation, or
##   the burst centre in air.  Only the visual uses it; damage still measures
##   from this component's origin.
## @param submerged — true when the blast centre is inside a `WaterVolume`.
## @param world_up — local gravity-up at the detonation; the effect uses it as
##   the up axis (and as the normal itself for an air burst).
func explode(falloff_multiplier: float = 1.0, impact_normal: Vector3 = Vector3.ZERO,
		impact_point: Vector3 = Vector3.ZERO, submerged: bool = false,
		world_up: Vector3 = Vector3.UP) -> void:
	if exploded:
		return
	exploded = true

	var shooter_name: String = get_parent().shooter_name if ("shooter_name" in get_parent()) else "NONE"
	var shooter_team: Player.Team = get_parent().shooter_team if ("shooter_name" in get_parent()) else "NONE"
	# Read once: the projectile is frozen on the first tick, so the contact
	# information is already latched by SimpleProjectile.start_explode().
	var on_surface := not impact_normal.is_zero_approx()
	var up := world_up.normalized() if not world_up.is_zero_approx() else Vector3.UP
	var direction := impact_normal.normalized() if on_surface else up
	var point := impact_point if not impact_point.is_zero_approx() else global_position
	var preset := _resolve_preset(on_surface, submerged)

	for i in range(tick_count):
		if i > 0:
			await get_tree().create_timer(time_between_ticks).timeout

		# Guard against the parent projectile being freed mid-tick
		# (e.g. the projectile collided with geometry and auto-deleted).
		if not is_instance_valid(self) or not is_inside_tree():
			return

		_apply_explosion_tick(shooter_name, shooter_team, falloff_multiplier)
		_explode_visual.rpc(point, direction, up, preset, i == 0)


# ----------------------------------------------------
# PER-TICK LOGIC
# ----------------------------------------------------
## Scans all players in range (re-evaluated each tick so players who
## enter / leave the radius between ticks are handled correctly).
func _apply_explosion_tick(shooter_name: String, shooter_team: Player.Team, falloff_multiplier: float) -> void:
	var explosion_origin := global_position

	var space := get_world_3d().direct_space_state
	var players := get_tree().get_nodes_in_group("players")

	if players.is_empty():
		if OS.is_debug_build():
			print('NO PLAYERS in group "players"')

	for player in players:

		if not player is Player:
			continue

		var attr: AttributeComponent = player.attribute_component

		var to_player: Vector3 = player.global_position - explosion_origin
		var dist := to_player.length()

		if dist > splash_radius:
			continue

		# Line of sight check (NOTE: can be removed for full determinism)
		var ray := PhysicsRayQueryParameters3D.new()
		ray.from = explosion_origin
		ray.to = player.global_position + Vector3(0, 0.5, 0)
		ray.collision_mask = 1
		ray.exclude = [self]

		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			continue

		# Distance falloff: 100 % at centre, min_knockback_percent at max range.
		var dist_ratio: float = clamp(dist / splash_radius, 0.0, 1.0)
		var dist_falloff: float = 1.0 - dist_ratio * (1.0 - min_knockback_percent)

		# Combine distance-based and travel-time-based falloff.
		var combined_falloff: float = dist_falloff * falloff_multiplier
		var damage: float = splash_health_delta * combined_falloff


		var has_hit_team = player.team == shooter_team

		# self damage scaling
		if player.name == shooter_name:
			damage *= self_health_delta_multiplier
		else:
			#Only check for other people after checking self
			if has_hit_team and shooter_team != Player.Team.FFA:
				damage *= team_health_delta_multiplier
			else:
				damage *= enemy_health_delta_multiplier

		attr.apply_health_delta(damage, shooter_name, player.name, false, falloff_multiplier)

		# Knockback (deterministic impulse)
		var dir: Vector3 = to_player.normalized()
		var force: Vector3 = dir * knockback_force * combined_falloff

		# self knockback scaling
		if player.name == shooter_name:
			force *= self_knockback_multiplier
		else:
			if has_hit_team and shooter_team != Player.Team.FFA:
				force *= team_knockback_multiplier
			else:
				force *= enemy_knockback_multiplier

		player.apply_knockback(force)

		if not status_effects.is_empty() and player.status_effect_manager:
			for effect in status_effects:
				if effect:
					player.status_effect_manager.apply_effect(effect, shooter_name)

	# Knock back any ragdoll corpses within the blast radius.
	for corpse in get_tree().get_nodes_in_group("ragdolls"):
		var to_corpse: Vector3 = (corpse as Node3D).global_position - explosion_origin
		var corpse_dist := to_corpse.length()
		if corpse_dist > splash_radius:
			continue
		var corpse_falloff: float = 1.0 - clamp(corpse_dist / splash_radius, 0.0, 1.0) * (1.0 - min_knockback_percent)
		GameManager.rpc_ragdoll_blast.rpc(corpse.name, explosion_origin, knockback_force * corpse_falloff * falloff_multiplier *0.1)


# ----------------------------------------------------
# VISUAL EFFECT (replicated locally)
# ----------------------------------------------------
## Pick the preset for the detonation context.  The four authored slots keep
## scenes explicit; empty slots fall back to the drier/less specific one.
func _resolve_preset(on_surface: bool, submerged: bool) -> String:
	if submerged:
		if on_surface and not underwater_surface_effect_preset.is_empty():
			return underwater_surface_effect_preset
		if not underwater_effect_preset.is_empty():
			return underwater_effect_preset
		return effect_preset
	if on_surface and not surface_effect_preset.is_empty():
		return surface_effect_preset
	return effect_preset


@rpc("call_local", "reliable")
func _explode_visual(point: Vector3, normal: Vector3, up: Vector3,
		preset: String = "", play_sound: bool = true) -> void:
	var host := _effect_host()
	if host == null:
		return
	# Pulsing explosions (molotov, poison) call this once per tick; the sound is
	# a single blast, so only the first tick plays it.
	if explosion_sound and play_sound:
		AudioPool.play(host, explosion_sound, Transform3D(Basis(), point),
			1.0, explosion_sound_volume_db, explosion_sound_unit_size)
	# The burst footprint rides the splash radius; play() orients it from the
	# hit normal and the world's up vector.  `effect_scale` is a uniform metre
	# multiplier inside the effect (no node scale), so this is a true scale.
	var footprint: float = maxf(splash_radius * 0.5, 0.2) * effect_scale_multiplier

	if not preset.is_empty():
		var toon: Node3D = TOON_EXPLOSION_SCRIPT.acquire()
		if toon == null:
			if _toon_explosion_scene == null:
				_toon_explosion_scene = load("res://effects/toon_explosions/toon_explosion.tscn")
			if _toon_explosion_scene:
				toon = _toon_explosion_scene.instantiate()
		if toon != null:
			toon.set("auto_free", true)
			toon.set("effect_scale", footprint)
			toon.set("tint", explosion_color)
			host.add_child(toon)
			if not bool(toon.call("play", preset, point, normal, up)):
				if OS.is_debug_build():
					push_warning("ExplosionComponent: unknown toon preset '%s'" % preset)
				toon.call("_recycle")
			return

	var explosion: Node3D = ROCKET_IMPACT_SCRIPT.acquire()
	if explosion == null:
		if _explosion_scene == null:
			_explosion_scene = load("res://effects/rocket_impact/rocket_impact.tscn")
		explosion = _explosion_scene.instantiate()
	explosion.set("auto_free", true)
	explosion.set("effect_scale", footprint)
	explosion.set("tint", explosion_color)
	host.add_child(explosion)
	explosion.call("play", point, normal, up)


## The effect must outlive the projectile (which is freed 10 s after
## detonating) and must not sit under the ProjectilesParent, whose
## MultiplayerSpawner replicates every direct child and only knows projectile
## scenes.  The world node above that parent is safe on every peer.
##
## `self` is a child of the projectile, so the chain is
## component -> projectile -> ProjectilesParent -> world.  This is the same host
## `SimpleProjectile._effect_host()` resolves for the trail.
func _effect_host() -> Node:
	var projectile := get_parent()
	if projectile == null:
		return null
	var projectile_parent := projectile.get_parent()
	if projectile_parent == null:
		return projectile
	var world := projectile_parent.get_parent()
	return world if world != null else projectile_parent
