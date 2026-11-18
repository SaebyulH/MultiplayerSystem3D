extends Node3D

## World-space status-effect visuals for one Player.
##
## Replaces the old text status bar above the player's head.  Effects that a
## player cannot already read off the model get a small GPUParticles3D burst —
## fire for burn, red droplets for bleed, a green mist for poison, and so on.
## Effects that are already visually obvious (invisible, enlarge/shrink,
## noclip, wallhack, aimbot) deliberately have no entry here.
##
## Cosmetic and local to every peer: driven by the StatusEffectManager's
## replicated effect mirror (`client_effects_changed`), so it needs no RPC and
## no network state of its own.  Players only pay for what is active — a
## particle system is built the first time its effect appears and its process
## loop stops when the last one expires.

## One-flame sprite from effects/ (public-domain pngimg asset already in use
## nowhere else).  Reused textures keep the effect folder small.
const FLAME_TEX := preload("res://effects/pngimg.com - flame_PNG13246.png")
const CLOUD_TEX := preload("res://effects/cloud.png")
const SMOKE_TEX := preload("res://effects/smoke2.png")
const DEBRIS_TEX := preload("res://effects/debris.png")
const FLASH_TEX := preload("res://effects/ExplodeFlash.png")

## Per-effect particle tuning.  Amounts stay in the low teens: these play on
## every visible player and the GPU emits them at 30 fixed FPS.
const CONFIGS := {
	# Fire wrapping the torso, rising and slightly spreading.
	"burn": {
		"texture": FLAME_TEX, "color": Color(2.6, 0.9, 0.2), "additive": true,
		"amount": 18, "lifetime": 0.65, "offset": Vector3(0.0, 1.0, 0.0),
		"box": Vector3(0.32, 0.5, 0.28), "direction": Vector3.UP, "spread": 35.0,
		"velocity_min": 0.35, "velocity_max": 0.9,
		"gravity": Vector3(0.0, 1.6, 0.0),
		"scale_min": 0.35, "scale_max": 0.7, "quad": 0.6,
		"local": true, "preprocess": 0.5,
	},
	# Blood spraying and dripping off the body.  Bright and large enough to read
	# at gameplay distance; a dim mix-blend droplet set disappeared against the
	# toon floors.
	"bleed": {
		"texture": DEBRIS_TEX, "color": Color(2.4, 0.06, 0.05), "additive": true,
		"amount": 26, "lifetime": 1.0, "offset": Vector3(0.0, 1.05, 0.0),
		"box": Vector3(0.4, 0.6, 0.32), "direction": Vector3.DOWN, "spread": 35.0,
		"velocity_min": 0.4, "velocity_max": 1.2,
		"gravity": Vector3(0.0, -6.0, 0.0),
		"scale_min": 0.3, "scale_max": 0.62, "quad": 0.6,
		"local": false, "preprocess": 0.3,
	},
	# Sickly green bubbles seeping upward.
	"poison": {
		"texture": CLOUD_TEX, "color": Color(0.55, 1.6, 0.35), "additive": true,
		"amount": 10, "lifetime": 1.2, "offset": Vector3(0.0, 1.0, 0.0),
		"box": Vector3(0.35, 0.6, 0.3), "direction": Vector3.UP, "spread": 40.0,
		"velocity_min": 0.15, "velocity_max": 0.45,
		"gravity": Vector3(0.0, 0.5, 0.0),
		"scale_min": 0.3, "scale_max": 0.6, "quad": 0.55,
		"local": true, "preprocess": 0.6,
	},
	# Cold blue haze hugging the legs.
	"slow": {
		"texture": SMOKE_TEX, "color": Color(0.5, 0.9, 1.6, 0.75), "additive": true,
		"amount": 8, "lifetime": 1.0, "offset": Vector3(0.0, 0.6, 0.0),
		"box": Vector3(0.4, 0.35, 0.35), "direction": Vector3.UP, "spread": 60.0,
		"velocity_min": 0.05, "velocity_max": 0.25,
		"gravity": Vector3(0.0, 0.15, 0.0),
		"scale_min": 0.4, "scale_max": 0.7, "quad": 0.7,
		"local": true, "preprocess": 0.5,
	},
	# Yellow sparks orbiting the head.
	"stun": {
		"texture": FLASH_TEX, "color": Color(2.2, 1.8, 0.4), "additive": true,
		"amount": 8, "lifetime": 0.5, "offset": Vector3(0.0, 1.9, 0.0),
		"box": Vector3(0.3, 0.1, 0.3), "direction": Vector3.UP, "spread": 70.0,
		"velocity_min": 0.4, "velocity_max": 0.8,
		"gravity": Vector3(0.0, 0.2, 0.0),
		"scale_min": 0.12, "scale_max": 0.25, "quad": 0.3,
		"local": true, "preprocess": 0.3,
	},
	# Gentle green sparkles rising off the body.
	"heal_over_time": {
		"texture": FLASH_TEX, "color": Color(0.5, 2.0, 0.7), "additive": true,
		"amount": 8, "lifetime": 0.9, "offset": Vector3(0.0, 1.0, 0.0),
		"box": Vector3(0.35, 0.6, 0.3), "direction": Vector3.UP, "spread": 20.0,
		"velocity_min": 0.3, "velocity_max": 0.7,
		"gravity": Vector3(0.0, 0.8, 0.0),
		"scale_min": 0.1, "scale_max": 0.22, "quad": 0.26,
		"local": true, "preprocess": 0.3,
	},
	# Golden shimmer while invincible.
	"invincible": {
		"texture": FLASH_TEX, "color": Color(2.0, 1.5, 0.3), "additive": true,
		"amount": 6, "lifetime": 0.7, "offset": Vector3(0.0, 1.0, 0.0),
		"box": Vector3(0.45, 0.8, 0.35), "direction": Vector3.UP, "spread": 40.0,
		"velocity_min": 0.1, "velocity_max": 0.35,
		"gravity": Vector3(0.0, 0.3, 0.0),
		"scale_min": 0.2, "scale_max": 0.45, "quad": 0.5,
		"local": true, "preprocess": 0.4,
	},
}

var _player: Player = null
var _sem: StatusEffectManager = null
## effect_id -> GPUParticles3D, built lazily.
var _nodes: Dictionary = {}
## effect_id -> bool, the mirror state last seen on the manager.
var _active: Dictionary = {}
## Shared across every player: the configs are identical per effect id and none
## of these resources is mutated after construction.  Only the GPUParticles3D
## node itself (visibility/emitting/transform) stays per player.
static var _fade_curve: CurveTexture = null
static var _shared: Dictionary = {}


func _ready() -> void:
	_player = get_parent() as Player
	_sem = get_node_or_null("../StatusEffectManager") as StatusEffectManager
	if _sem:
		_sem.client_effects_changed.connect(_refresh)
	set_process(false)
	_refresh()


func _process(_delta: float) -> void:
	# Only runs while at least one effect is active.  Re-evaluated every frame
	# because the local third-person toggle is not a signal.
	_update_visibility()


func _refresh() -> void:
	var any := false
	for id: String in CONFIGS:
		var active := _sem != null and _sem.has_effect(id)
		_active[id] = active
		if active:
			any = true
			if not _nodes.has(id):
				_nodes[id] = _build(id, CONFIGS[id])
	_update_visibility()
	set_process(any)


## Hide the local player's own world effects in first person — the HUD border
## already tells them what they have, and fire in your own face is noise.
## Remote players, bots, spectators and our own third-person view all show it.
func _update_visibility() -> void:
	var hide_all := _player != null \
		and _player.is_owned_by_local_peer() \
		and not _player.third_person
	for id: String in _nodes:
		var p: GPUParticles3D = _nodes[id]
		var on: bool = _active.get(id, false) and not hide_all
		p.visible = on
		p.emitting = on


func _build(id: String, cfg: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = id.capitalize()
	p.amount = cfg["amount"]
	p.lifetime = cfg["lifetime"]
	p.local_coords = cfg.get("local", true)
	p.fixed_fps = 30
	p.preprocess = cfg.get("preprocess", 0.0)
	p.position = cfg["offset"]
	p.emitting = false
	p.visible = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles rise/fall out of the emitter's own box; the default 1 m AABB
	# culls the top of tall effects.  Bleeding sprays downward, so it needs the
	# extra room below.
	var dir: Vector3 = cfg["direction"]
	var down: float = 3.0 if dir.y < 0.0 else 1.5
	p.visibility_aabb = AABB(Vector3(-1.5, -down, -1.5), Vector3(3.0, down + 2.5, 3.0))
	var shared := _shared_resources(id, cfg)
	p.process_material = shared["process"]
	p.draw_pass_1 = shared["quad"]
	p.material_override = shared["material"]
	add_child(p)
	return p


## Builds (once per effect id) the resources every player's systems share.
static func _shared_resources(id: String, cfg: Dictionary) -> Dictionary:
	if _shared.has(id):
		return _shared[id]
	var entry := {
		"process": _build_process(cfg),
		"quad": _build_quad(cfg.get("quad", 0.4)),
		"material": _build_material(cfg),
	}
	_shared[id] = entry
	return entry


static func _build_process(cfg: Dictionary) -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = cfg["box"]
	m.direction = cfg["direction"]
	m.spread = cfg["spread"]
	m.initial_velocity_min = cfg["velocity_min"]
	m.initial_velocity_max = cfg["velocity_max"]
	m.gravity = cfg["gravity"]
	m.scale_min = cfg["scale_min"]
	m.scale_max = cfg["scale_max"]
	m.color = cfg["color"]
	m.alpha_curve = _get_fade_curve()
	return m


static func _build_quad(size: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	return q


static func _build_material(cfg: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if cfg["additive"] else BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = cfg["texture"]
	mat.albedo_color = Color.WHITE
	return mat


## One shared fade curve: hold briefly, then fall to zero.  Shared by every
## effect so the curve resource is not duplicated per particle system.
static func _get_fade_curve() -> CurveTexture:
	if _fade_curve == null:
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 0.0))
		curve.add_point(Vector2(0.15, 1.0))
		curve.add_point(Vector2(0.7, 0.7))
		curve.add_point(Vector2(1.0, 0.0))
		_fade_curve = CurveTexture.new()
		_fade_curve.curve = curve
	return _fade_curve
