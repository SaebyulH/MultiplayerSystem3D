extends Node3D
class_name PlayerShield

## Attached to a shield scene instantiated by WeaponController.
## Manages HP, damage absorption, break / regen, and visual feedback.
##
## The shield scene should contain:
##   - An Area3D named "ShieldArea" (collision layer 2 for hitscan, 4 for
##     projectiles).  The script adds a HurtboxComponent so the existing
##     hitbox / hitscan systems can detect the shield.
##   - A MeshInstance3D (anywhere in the tree) for the visual.
##
## Damage flow:
##   Hitscan ray / projectile hits ShieldArea → hurt_or_heal fires →
##   shield absorbs the hit.  Overflow passes to the player via
##   Player.change_health().

signal shield_broken
signal shield_depleted   ## HP reached 0 this frame
signal shield_repaired   ## regen brought HP back above 0

## Cached reference to the owning WeaponFire resource.
var fire: WeaponFire = null
## The Player that owns this shield — set by Player.deploy_shield().
var player: Player = null

## Current hit-points (mirrored to fire.shield_current_hp).
var hp: float = 100.0

## Is the shield currently deployed?
var active: bool = false

## Is the shield broken (hp <= 0)?
var broken: bool = false

var _time_since_hit: float = 0.0
var _broken_cooldown: float = 0.0


func _ready() -> void:
	_setup_shield_area()
	# Self-test: if the scene runs with this script but nobody calls setup(),
	# make the shield visible anyway so we can tell it's rendering.
	if not Engine.is_editor_hint() and not active:
		_apply_material(self, 1.0)
		show()
		print("[PlayerShield] _ready – self-test visibility applied")


## Configures the ShieldArea for hit detection.  Called from _ready() and
## also from deploy() as a safety net (in case _ready hasn't fired yet).
func _setup_shield_area() -> void:
	var area := $ShieldArea as Area3D if has_node("ShieldArea") else null
	if not area:
		return
	# Same collision layer as the player's HeadHurtbox / BodyHurtbox so
	# hitscan rays and projectile hitboxes detect the shield.
	area.collision_layer = 1 << 2
	area.collision_mask = 0

	# Connect to the HurtboxComponent's hurt_or_heal signal so we can
	# absorb damage from projectiles / melee directly.
	if area is HurtboxComponent:
		var hb := area as HurtboxComponent
		if not hb.hurt_or_heal.is_connected(_on_hurt_or_heal):
			hb.hurt_or_heal.connect(_on_hurt_or_heal)

	if not area.area_entered.is_connected(_on_area_entered):
		area.area_entered.connect(_on_area_entered)


func setup(p_fire: WeaponFire) -> void:
	fire = p_fire
	hp = fire.shield_current_hp
	active = false
	broken = false
	_time_since_hit = 0.0
	_broken_cooldown = 0.0
	_update_visual()


func deploy() -> void:
	if broken:
		return
	active = true
	show()
	_setup_shield_area()
	var area := $ShieldArea as Area3D if has_node("ShieldArea") else null
	if area:
		area.monitoring = true
		area.monitorable = true


func retract() -> void:
	active = false
	hide()
	var area := $ShieldArea as Area3D if has_node("ShieldArea") else null
	if area:
		area.monitoring = false
		area.monitorable = false


## Apply `amount` damage.  Returns overflow that the shield couldn't absorb.
func absorb_damage(amount: float) -> float:
	if amount <= 0.0 or broken or not active:
		return amount

	_time_since_hit = 0.0

	var absorbed := minf(amount, hp)
	hp -= absorbed

	if hp <= 0.0:
		hp = 0.0
		broken = true
		_broken_cooldown = fire.shield_break_regen_delay if fire else 3.0
		shield_depleted.emit()
		shield_broken.emit()
		hide()
		var area := $ShieldArea as Area3D if has_node("ShieldArea") else null
		if area:
			area.monitoring = false
			area.monitorable = false

	_sync_hp_to_fire()
	_update_visual()
	return amount - absorbed


func _process(delta: float) -> void:
	if not active or not fire:
		return

	_time_since_hit += delta

	if broken:
		_broken_cooldown -= delta
		if _broken_cooldown <= 0.0:
			broken = false
			hp = 1.0
			shield_repaired.emit()
			show()
			var area := $ShieldArea as Area3D if has_node("ShieldArea") else null
			if area:
				area.monitoring = true
				area.monitorable = true
			_update_visual()
		return

	if hp < fire.shield_hp and _time_since_hit >= fire.shield_regen_delay:
		hp = minf(hp + fire.shield_regen_per_sec * delta, fire.shield_hp)
		_sync_hp_to_fire()
		_update_visual()


## Write current HP back to the WeaponFire resource.
func _sync_hp_to_fire() -> void:
	if fire:
		fire.shield_current_hp = hp


## Reset shield HP to full (called on player death / respawn).
func reset_hp() -> void:
	if fire:
		fire.shield_current_hp = fire.shield_hp
		hp = fire.shield_hp
	broken = false
	_broken_cooldown = 0.0
	_update_visual()


# ── visual ───────────────────────────────────────────────────────────


func _update_visual() -> void:
	var ratio: float = hp / fire.shield_hp if fire and fire.shield_hp > 0.0 else 1.0
	_apply_material(self, ratio)


func _apply_material(node: Node, ratio: float) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override == null:
			var smat := StandardMaterial3D.new()
			mi.material_override = smat
		var smat := mi.material_override as StandardMaterial3D
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.disable_receive_shadows = true
		smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Always transparent — fades from 0.35 (full HP) down to 0.1 (low HP).
		smat.albedo_color = Color(0.3, 0.85, 0.95, lerpf(0.1, 0.35, ratio))

	for child in node.get_children():
		_apply_material(child, ratio)


# ── hit detection ────────────────────────────────────────────────────


## Called when the shield's HurtboxComponent is hit by a HitboxComponent
## (projectile / melee).  Absorbs the damage before it reaches the player.
func _on_hurt_or_heal(hitbox: HitboxComponent, _is_ally: bool) -> void:
	if not active or broken:
		return
	# Only absorb damage (negative health_delta).  Healing (positive) passes
	# through to the player.
	if hitbox.health_delta < 0.0:
		absorb_damage(-hitbox.health_delta)


func _on_area_entered(area: Area3D) -> void:
	if not active or broken:
		return
	if area is HitboxComponent:
		var hb := area as HitboxComponent
		if hb.health_delta < 0.0:
			absorb_damage(-hb.health_delta)
