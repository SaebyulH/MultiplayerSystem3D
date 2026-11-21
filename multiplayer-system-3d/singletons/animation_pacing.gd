extends Node
## FrankenFPS — the one place that owns visual update rates.
##
## Two clocks:
## - [constant BASE_FPS] (12) drives every [AnimationPlayer] / [AnimationTree],
##   every untagged particle system, and the procedural toon explosion body.
## - [constant FX_FPS] (48) drives the fast effect elements only: nodes tagged
##   with the [constant FX_TAG_GROUP] group (`fx_rate`), the procedural rocket
##   impact burst, and toon trails.  The result is chunky 12 Hz bodies with
##   smoothly moving sparks/debris/impacts — the eye reads the fast elements
##   and the whole effect looks higher-fps than it is.
##
## This does NOT change animation speed.  Each step advances by the real time
## elapsed since the previous step on that clock, so a 1 s clip still lasts 1 s
## — it just updates 12 (or 48) times per second.
##
## FrankenFPS is OFF by default: [constant ENABLED] is false, so every visual
## runs at the native render rate.  Set it to true (or call
## [method set_enabled]) to switch the two-clock pacing back on; the rates and
## tier tags stay configured either way.
##
## To tune, edit [constant BASE_FPS] / [constant FX_FPS] below, or call
## [method set_fps] / [method set_fx_fps].  Set either to 0 to disable pacing
## on that tier (native processing for those elements).
##
## To tag an effect element for the fast tier:
## - scene-authored nodes: put them in the `fx_rate` group;
## - runtime: call [method mark_fx] on the node or a parent.
## Tagging a parent applies to every mixer/particle system under it.
##
## To opt a subtree out entirely (the loadout preview rig does), call
## [method exempt] from its _ready().
##
## Visual-only: no RPC, no synchronizer state, no effect on gameplay timing.

## Master switch.  false = FrankenFPS disabled, everything renders natively;
## the rates and tier tags below stay configured so it can be turned back on.
const ENABLED := false

## The two FrankenFPS rates.  Change these (or the runtime setters) to tune.
const BASE_FPS := 12.0
const FX_FPS := 48.0

## Group tag that puts an effect element on the [constant FX_FPS] clock.
const FX_TAG_GROUP := &"fx_rate"

const PACED_MIXER_GROUP := &"_anim_paced"
const PACED_FX_MIXER_GROUP := &"_anim_paced_fx"
const PACED_PARTICLE_GROUP := &"_particle_paced"
const PACED_FX_PARTICLE_GROUP := &"_particle_paced_fx"
const EXEMPT_GROUP := &"_anim_pacing_exempt"
const PREV_MODE_META := &"_anim_pacing_prev_mode"
const PREV_FIXED_FPS_META := &"_anim_pacing_prev_fixed_fps"
const PREV_INTERPOLATE_META := &"_anim_pacing_prev_interpolate"

## Runtime switch, initialised from [constant ENABLED].
var enabled: bool = ENABLED
## Base tier (animations, default particles, explosion bodies).
var fps: float = BASE_FPS
## Fast tier (tagged effect elements, impact bursts, trails).
var fx_fps: float = FX_FPS

## Seconds of base visual time advanced so far.  Advances only on base steps
## while pacing is on (every frame while it is off).
var stepped_time := 0.0
## Seconds of fast visual time advanced so far.  Same speed, 4x the update rate.
var fx_stepped_time := 0.0

var _accum := 0.0
var _fx_accum := 0.0


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	if enabled:
		_adopt_all()


func _process(delta: float) -> void:
	if not enabled:
		# Native: both clocks still advance so procedural effects keep running
		# smoothly from stepped_time / fx_stepped_time.
		stepped_time += delta
		fx_stepped_time += delta
		return
	_tick_base(delta)
	_tick_fx(delta)


## Turn FrankenFPS on/off at runtime.  Off restores native processing for every
## paced mixer and the authored fixed_fps for every paced particle system; the
## rates and tier tags are kept, so turning it back on re-adopts them.
func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	if enabled:
		_adopt_all()
	else:
		_restore_all()


func _tick_base(delta: float) -> void:
	if fps <= 0.0:
		stepped_time += delta
		return
	_accum += delta
	var step := 1.0 / fps
	if _accum < step:
		return
	# Advance by whole steps so the cadence never drifts; the leftover stays in
	# the accumulator.  One advance call per tick regardless of step count.
	var steps := int(_accum / step)
	var dt := float(steps) * step
	_accum -= dt
	stepped_time += dt
	_advance_group(PACED_MIXER_GROUP, dt)


func _tick_fx(delta: float) -> void:
	if fx_fps <= 0.0:
		fx_stepped_time += delta
		return
	_fx_accum += delta
	var step := 1.0 / fx_fps
	if _fx_accum < step:
		return
	var steps := int(_fx_accum / step)
	var dt := float(steps) * step
	_fx_accum -= dt
	fx_stepped_time += dt
	_advance_group(PACED_FX_MIXER_GROUP, dt)


func _advance_group(group: StringName, dt: float) -> void:
	for node in get_tree().get_nodes_in_group(group):
		var mixer := node as AnimationMixer
		if mixer != null:
			mixer.advance(dt)


## Change the base pacing rate at runtime.  `<= 0` restores native processing
## for that tier.
func set_fps(value: float) -> void:
	value = maxf(value, 0.0)
	if is_equal_approx(value, fps):
		return
	fps = value
	if enabled:
		_rebuild()


## Change the fast-tier rate at runtime.
func set_fx_fps(value: float) -> void:
	value = maxf(value, 0.0)
	if is_equal_approx(value, fx_fps):
		return
	fx_fps = value
	if enabled:
		_rebuild()


## Put [param node] (and its current subtree) on the fast tier.  New mixers and
## particle systems added under it later are adopted to the fast tier too.
func mark_fx(node: Node) -> void:
	node.add_to_group(FX_TAG_GROUP)
	_refresh_subtree(node)


## Leave [param node] and its existing subtree on native processing.
func exempt(node: Node) -> void:
	node.add_to_group(EXEMPT_GROUP)
	var targets: Array[Node] = [node]
	targets.append_array(node.find_children("*", "AnimationMixer", true, false))
	targets.append_array(node.find_children("*", "GPUParticles3D", true, false))
	targets.append_array(node.find_children("*", "CPUParticles3D", true, false))
	for target in targets:
		_restore(target)


func _rebuild() -> void:
	_restore_all()
	_adopt_all()


func _refresh_subtree(node: Node) -> void:
	var targets: Array[Node] = [node]
	targets.append_array(node.find_children("*", "AnimationMixer", true, false))
	targets.append_array(node.find_children("*", "GPUParticles3D", true, false))
	targets.append_array(node.find_children("*", "CPUParticles3D", true, false))
	for target in targets:
		_restore(target)
		_adopt(target)


func _on_node_added(node: Node) -> void:
	if not enabled:
		return
	_adopt(node)


func _adopt(node: Node) -> void:
	if not enabled:
		return
	if node is AnimationMixer or node is GPUParticles3D or node is CPUParticles3D:
		if not _has_exempt_ancestor(node):
			_adopt_one(node)


func _adopt_all() -> void:
	var root := get_tree().root
	_adopt(root)
	for node in root.find_children("*", "AnimationMixer", true, false):
		_adopt(node)
	for node in root.find_children("*", "GPUParticles3D", true, false):
		_adopt(node)
	for node in root.find_children("*", "CPUParticles3D", true, false):
		_adopt(node)


func _adopt_one(node: Node) -> void:
	if _is_fx(node):
		if _target_rate(node) <= 0.0:
			return
		if node is AnimationMixer:
			_adopt_mixer(node as AnimationMixer, PACED_FX_MIXER_GROUP)
		else:
			_adopt_particle(node, PACED_FX_PARTICLE_GROUP)
		return
	if fps <= 0.0:
		return
	if node is AnimationMixer:
		_adopt_mixer(node as AnimationMixer, PACED_MIXER_GROUP)
	else:
		_adopt_particle(node, PACED_PARTICLE_GROUP)


func _target_rate(node: Node) -> float:
	return fx_fps if _is_fx(node) else fps


func _is_fx(node: Node) -> bool:
	return _has_ancestor_in_group(node, FX_TAG_GROUP)


func _has_exempt_ancestor(node: Node) -> bool:
	return _has_ancestor_in_group(node, EXEMPT_GROUP)


func _has_ancestor_in_group(node: Node, group: StringName) -> bool:
	var current: Node = node
	while current != null:
		if current.is_in_group(group):
			return true
		current = current.get_parent()
	return false


func _adopt_mixer(mixer: AnimationMixer, group: StringName) -> void:
	if mixer.is_in_group(PACED_MIXER_GROUP) or mixer.is_in_group(PACED_FX_MIXER_GROUP):
		return
	mixer.set_meta(PREV_MODE_META, mixer.callback_mode_process)
	mixer.add_to_group(group)
	mixer.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL


func _adopt_particle(particles: Node, group: StringName) -> void:
	if particles.is_in_group(PACED_PARTICLE_GROUP) or particles.is_in_group(PACED_FX_PARTICLE_GROUP):
		return
	var rate := fx_fps if group == PACED_FX_PARTICLE_GROUP else fps
	if rate <= 0.0:
		return
	# A one-shot shorter than a single step would die before it ever rendered at
	# the stepped rate (the muzzle flash is 0.03–0.04 s).  Leave those native.
	if _particle_lifetime(particles) < 1.0 / rate:
		return
	particles.set_meta(PREV_FIXED_FPS_META, particles.get("fixed_fps"))
	particles.add_to_group(group)
	particles.set("fixed_fps", maxi(1, roundi(rate)))
	if particles is GPUParticles3D:
		particles.set_meta(PREV_INTERPOLATE_META, (particles as GPUParticles3D).interpolate)
		(particles as GPUParticles3D).interpolate = false


func _particle_lifetime(particles: Node) -> float:
	var lifetime = particles.get("lifetime")
	return float(lifetime) if lifetime != null else 0.0


func _restore(node: Node) -> void:
	if node is AnimationMixer:
		_restore_mixer(node as AnimationMixer)
	elif node is GPUParticles3D or node is CPUParticles3D:
		_restore_particle(node)


func _restore_mixer(mixer: AnimationMixer) -> void:
	var in_base := mixer.is_in_group(PACED_MIXER_GROUP)
	var in_fx := mixer.is_in_group(PACED_FX_MIXER_GROUP)
	if not in_base and not in_fx:
		return
	mixer.callback_mode_process = int(mixer.get_meta(
		PREV_MODE_META, AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	))
	mixer.remove_from_group(PACED_MIXER_GROUP)
	mixer.remove_from_group(PACED_FX_MIXER_GROUP)
	mixer.remove_meta(PREV_MODE_META)


func _restore_particle(particles: Node) -> void:
	var in_base := particles.is_in_group(PACED_PARTICLE_GROUP)
	var in_fx := particles.is_in_group(PACED_FX_PARTICLE_GROUP)
	if not in_base and not in_fx:
		return
	particles.set("fixed_fps", int(particles.get_meta(PREV_FIXED_FPS_META, 0)))
	if particles is GPUParticles3D:
		(particles as GPUParticles3D).interpolate = bool(
			particles.get_meta(PREV_INTERPOLATE_META, true)
		)
		particles.remove_meta(PREV_INTERPOLATE_META)
	particles.remove_from_group(PACED_PARTICLE_GROUP)
	particles.remove_from_group(PACED_FX_PARTICLE_GROUP)
	particles.remove_meta(PREV_FIXED_FPS_META)


func _restore_all() -> void:
	for node in get_tree().get_nodes_in_group(PACED_MIXER_GROUP):
		_restore_mixer(node as AnimationMixer)
	for node in get_tree().get_nodes_in_group(PACED_FX_MIXER_GROUP):
		_restore_mixer(node as AnimationMixer)
	for node in get_tree().get_nodes_in_group(PACED_PARTICLE_GROUP):
		_restore_particle(node)
	for node in get_tree().get_nodes_in_group(PACED_FX_PARTICLE_GROUP):
		_restore_particle(node)
