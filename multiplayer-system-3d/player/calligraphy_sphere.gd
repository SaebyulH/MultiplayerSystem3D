class_name CalligraphySphere
extends Node3D

## The calligraphy canvas: a transparent bubble around the player's head with a
## square sheet on it, a guide character to trace, and — once the canvas is
## dismissed — the drawing itself carried in view until it is thrown.
##
## ## Owner-only, and not networked
##
## Player._ready() creates this for the local model alone (`_is_own_model()`), the
## same way the wallhack outline and the segmented health bar work.  Nothing here
## crosses the wire *except* the throw: the glyph index and the drawing's score are
## sent to the server by WeaponController.calligraphy_release, which validates the
## index against its own copy of the ability and clamps the score.  Everything else
## — which character was drawn, how well it was traced — only ever exists on this
## peer, which is why this node can carry all of it as plain local state.
##
## ## Three phases, driven off the effect mirror
##
## The ability cycles raise → hold → (throw or cancel), and each phase is a
## permanent status effect on the server.  This node reads *which* effect is
## present and nothing else — never its own input history — so the visuals cannot
## desync from the state that actually locks the gun:
##
##   - `RAISED` — bubble, sheet and guide up; `primary_fire_held` paints.
##   - `HOLD`   — the drawing carried in view; a fresh left click throws it.
##   - `NONE`   — nothing.
##
## The raise→hold transition passes through "neither" (the server removes one
## effect before applying the other), and that transient is load-bearing: it is
## where the drawing is scored and stashed, before the held card appears.
##
## ## Position follows the camera; orientation does not
##
## The canvas is re-centred on the camera's global position every tick
## (`_follow_camera`) and its transform **basis is never written**, so it tracks the
## viewpoint exactly while staying world-aligned.  That split *is* the "does not
## move with the head rotation" requirement, and it is what makes sweeping the view
## a drawing motion rather than a no-op.  The held card is the opposite case — it is
## meant to follow the view, so `_follow_view` writes both position and basis from
## the camera.
##
## Centring on the camera rather than on the head is deliberate.  The first-person
## camera's position is snapped every frame to an animated bone
## (`player/camera_3d.gd`), so it drifts with walk bob, crouch and recoil — an
## offset centre is a moving one.
##
## ## Two meshes on the canvas: the bubble and the sheet
##
## `_bubble` is the whole sphere — untextured, a faint film.  `_patch` is the
## drawable square, a spherical section carrying the ink; `_guide` is a second copy
## of the same section, scaled fractionally outward so it sorts behind the ink, and
## textured with the character being traced.
##
## The sheet is its own mesh rather than a slice of the bubble because the ink needs
## its own resolution: a 15° patch on a map of the whole sphere is ~21x21 px at any
## sane map size, which cannot hold a character.  Scoping the map to the patch gives
## it the full CANVAS_SIZE instead.  The upshot is that the sheet's texcoords come
## from the *same* tangent-space mapping `_patch_uv` inverts, so ink lands where it
## was painted by construction — no equirectangular projection, no seam, no UV
## convention to get wrong (see docs/05-known-issues.md #78/#79).

## The phases the ability cycles through, mirrored from the two status effects.
enum Phase { NONE, RAISED, HOLD }

## Where the canvas sits on the frames before a camera is resolvable.  A live
## canvas is re-centred on the camera every tick, so this is only ever a seed.
const FALLBACK_OFFSET := Vector3(0.0, 1.75, 0.0)
## Bubble radius in metres.  Comfortably clear of the camera's near plane.
const SPHERE_RADIUS := 0.75
## Bubble tessellation.
const SEGMENTS := 64
const RINGS := 32
## The sheet's angular width and height, in degrees — a square, centred on wherever
## the player was looking when the canvas was raised.  At SPHERE_RADIUS this spans
## roughly 0.2 m of arc, about a sixth of the screen height at the default 90° FOV.
const PATCH_DEGREES := 15.0
## Quads per side of the sheet's grid.
const PATCH_SEGMENTS := 32
## The sheet rides fractionally inside the bubble, and the guide fractionally
## outside the sheet: all three are the same surface, so exactly coincident
## geometry would z-fight.  Sorting is by distance from the eye, so a larger radius
## also puts the guide *behind* the ink, which is the order they should blend in.
const PATCH_RADIUS_SCALE := 0.995
const GUIDE_RADIUS_SCALE := 1.01

## The ink map.  Mapped 1:1 onto the sheet, so this is the drawing's resolution.
## The whole image is re-uploaded on every painted frame — see
## docs/04-optimization.md.
const CANVAS_SIZE := Vector2i(256, 256)
## Brush radius in image pixels.
const BRUSH_RADIUS_PX := 3.0
## The un-drawn sheet: a faint white film, transparent enough to see through.
const CANVAS_COLOR := Color(1.0, 1.0, 1.0, 0.10)
## Ink.  Opaque black, so the strokes read as writing on the sheet.
const INK_COLOR := Color(0.0, 0.0, 0.0, 1.0)
## The sheet's edge, painted into the map once per activation so the player can see
## where the drawable area ends.
const BORDER_COLOR := Color(1.0, 1.0, 1.0, 0.45)
const BORDER_WIDTH_PX := 2.0
## A pixel counts as the player's ink above this alpha.  Clear of the sheet film
## (0.10) and the border (0.45), and below the ink's 1.0.
const INK_ALPHA_MIN := 0.7
## A pixel counts as part of the traced character above this alpha.  The glyphs are
## pure black on transparent — no anti-aliasing — so the exact threshold barely
## matters.
const GLYPH_ALPHA_MIN := 0.5
## How far, in glyph pixels, the player's ink may sit from the character's strokes
## and still count as "on" them — used symmetrically by both halves of the score.
##
## Tracing with a crosshair on a 15° patch has no sub-pixel precision, so some
## tolerance is needed or every score would be ~0.  It is kept small on purpose:
## measured over the five glyphs, a 3 px band covers 21–34% of the sheet, where the
## 8 px band it replaced covered 34–51% — enough that scribbling anywhere in the
## character's neighbourhood scored well.
const SCORE_TOLERANCE_PX := 3

## Longest run of dabs drawn to bridge the gap between two physics frames.
const MAX_STROKE_STEPS := 64

## Colour of the guide overlay.  Pale and translucent so the player's own black ink
## reads on top of it and the two are never confused.
const GUIDE_COLOR := Color(0.85, 0.85, 0.85, 0.30)

## The carried drawing: where it sits in camera space, and how big.  Down-right of
## centre, as though held up in front of the chest.
const HELD_OFFSET := Vector3(0.20, -0.17, -0.42)
const HELD_SIZE := Vector2(0.30, 0.30)

## Derived per-glyph data, built once per glyph per process and reused across casts.
## Decoding a PNG and dilating ~3500 stroke pixels over a 150x150 mask is far too
## much work to redo on every cast, and every peer can draw every glyph.
static var _glyph_cache: Dictionary = {}

var _player: Player
var _ink: Image
var _ink_texture: ImageTexture
var _patch: MeshInstance3D
var _guide: MeshInstance3D
var _guide_material: StandardMaterial3D
var _bubble: MeshInstance3D
var _held: MeshInstance3D
var _held_label: Label3D
## The sheet's half-extent in its own tangent plane: tan(half its angular width).
var _patch_half := tan(deg_to_rad(PATCH_DEGREES * 0.5))

var _phase: int = Phase.NONE

## The character drawn this cast, and what came of it.
var _glyph_index: int = -1
var _glyph_name: String = ""
var _glyph_mask: PackedByteArray = PackedByteArray()
## The character's strokes *undilated* — the target the recall half of the score
## asks "did the ink reach this part of the character?" about.
var _glyph_strokes: PackedByteArray = PackedByteArray()
var _glyph_mask_size := Vector2i.ZERO
var _held_score: float = 0.0

## The previous sample in canvas UV space.
var _last_uv := Vector2.ZERO
var _has_last_uv := false
## Set by a paint, cleared when the texture has been re-uploaded.
var _dirty := false
## Previous frame's fire button, for edge-detecting the throw.
var _was_fire_held := false


func _ready() -> void:
	_player = get_parent() as Player
	position = FALLBACK_OFFSET

	_ink = Image.create(CANVAS_SIZE.x, CANVAS_SIZE.y, false, Image.FORMAT_RGBA8)
	_ink.fill(CANVAS_COLOR)
	_ink_texture = ImageTexture.create_from_image(_ink)

	var sheet := _build_patch_mesh()

	_bubble = _build_bubble()
	add_child(_bubble)

	_patch = MeshInstance3D.new()
	_patch.mesh = sheet
	_patch.material_override = _make_ink_material()
	_patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_patch)

	_guide = MeshInstance3D.new()
	_guide.mesh = sheet
	_guide_material = _make_guide_material()
	_guide.material_override = _guide_material
	_guide.scale = Vector3.ONE * GUIDE_RADIUS_SCALE
	_guide.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_guide)

	_held = _build_held()
	add_child(_held)
	_held_label = Label3D.new()
	# Above the drawing, not below it: the card sits low-right in view, so a label
	# underneath crowds the bottom edge of the screen.
	_held_label.position = Vector3(0.0, HELD_SIZE.y * 0.5 + 0.035, 0.0)
	_held_label.pixel_size = 0.0008
	_held_label.outline_size = 6
	_held.add_child(_held_label)

	_set_phase(Phase.NONE)

	if _player != null and _player.status_effect_manager != null:
		_player.status_effect_manager.client_effects_changed.connect(_on_effects_changed)
		_on_effects_changed()


# region meshes

## The whole sphere, as a faint untextured film.  A stock SphereMesh is fine here
## precisely because it is untextured — nothing reads its texcoords.  (The ink has
## its own mesh and its own mapping; see the class doc.)
func _build_bubble() -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = SPHERE_RADIUS
	sphere.height = SPHERE_RADIUS * 2.0
	sphere.radial_segments = SEGMENTS
	sphere.rings = RINGS

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Unshaded so the bubble reads as a film over the world rather than as a lit
	# object, the same choice the shield and the tracer make.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The camera is inside the sphere, so every face it can see is a back face.
	# The default CULL_BACK would render nothing at all.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = CANVAS_COLOR
	sphere.material = material

	var instance := MeshInstance3D.new()
	instance.mesh = sphere
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


## The drawable sheet: a square section of the sphere.  Vertices span the tangent
## square |x|, |y| <= _patch_half in the mesh's own frame, where the sheet faces
## -Z, each pushed back out onto the sphere's surface so it stays a *section of the
## sphere* rather than a flat billboard.
##
## Texcoords are the tangent coordinates remapped to [0, 1] by the same function
## _patch_uv inverts, so the painting and the drawing agree by construction.
##
## Carries no material: `_patch` and `_guide` share this one ArrayMesh with
## different `material_override`s, and a surface material here would be common to
## both.
func _build_patch_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in PATCH_SEGMENTS:
		for col in PATCH_SEGMENTS:
			var x0 := _patch_axis(col)
			var x1 := _patch_axis(col + 1)
			var y0 := _patch_axis(row)
			var y1 := _patch_axis(row + 1)
			# Vertices are emitted per-face rather than indexed into a shared
			# grid: that is the shape of func_godot's own SurfaceTool use
			# (addons/func_godot/src/util/func_godot_util.gd:447-460).
			_add_patch_vertex(st, x0, y0)
			_add_patch_vertex(st, x1, y0)
			_add_patch_vertex(st, x0, y1)

			_add_patch_vertex(st, x0, y1)
			_add_patch_vertex(st, x1, y0)
			_add_patch_vertex(st, x1, y1)
	return st.commit()


## Tangent coordinate of grid line [param step], from -_patch_half to +_patch_half.
func _patch_axis(step: int) -> float:
	return _patch_half * (2.0 * float(step) / float(PATCH_SEGMENTS) - 1.0)


func _add_patch_vertex(st: SurfaceTool, x: float, y: float) -> void:
	var dir := Vector3(x, y, -1.0).normalized()
	st.set_uv(_tangent_to_uv(x, y))
	st.set_normal(dir)
	st.add_vertex(dir * SPHERE_RADIUS * PATCH_RADIUS_SCALE)


func _make_ink_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# White, so the whole alpha budget lives in the painted map: the sheet's low
	# alpha and the ink's full alpha both come from the texture.
	material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	material.albedo_texture = _ink_texture
	return material


func _make_guide_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# The guide image is recoloured white so this can tint it; see _glyph_data.
	material.albedo_color = GUIDE_COLOR
	return material


## The carried card: a flat quad showing the drawing, positioned in camera space by
## _follow_view.
func _build_held() -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = HELD_SIZE

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	material.albedo_texture = _ink_texture
	quad.material = material

	var instance := MeshInstance3D.new()
	instance.mesh = quad
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance

# endregion


## Tangent coordinates -> canvas UV.  x runs left to right like u; y runs bottom to
## top, which is why v is inverted (image row 0 is the top of the sheet).
func _tangent_to_uv(x: float, y: float) -> Vector2:
	return Vector2((x / _patch_half + 1.0) * 0.5, (1.0 - y / _patch_half) * 0.5)


## The effect mirror is the single source of truth for which phase we are in.
##
## Pushed, not polled: apply_effect and remove_effect both call _sync_to_clients(),
## which emits this on the server and (via _rpc_sync_effects) on every client, and
## a permanent effect is never re-broadcast in between.  A raise→hold transition
## therefore arrives as two signals — "neither", then "hold" — and the "neither"
## step is where the drawing gets scored.
func _on_effects_changed() -> void:
	var sem := _player.status_effect_manager if _player != null else null
	var phase := Phase.NONE
	if sem != null:
		if sem.has_effect(CalligraphyAbility.RAISED_ID):
			phase = Phase.RAISED
		elif sem.has_effect(CalligraphyAbility.HOLD_ID):
			phase = Phase.HOLD
	if phase == _phase:
		return
	var previous := _phase
	_phase = phase

	# Closing the canvas scores what was drawn and stashes it for the card.  Runs
	# on the transient "neither", so it is finished before the card appears.
	if previous == Phase.RAISED and phase != Phase.RAISED:
		_stash_drawing()

	if phase == Phase.RAISED:
		_follow_camera()
		_frame_patch()
		_begin_drawing()
	elif phase == Phase.HOLD:
		_follow_view()
		# A button already down must not throw the instant the card appears —
		# the player was very likely still holding it to draw with.  Seed the
		# edge detector from the live state so only a fresh press counts.
		_was_fire_held = _fire_held()

	_set_phase(phase)


func _set_phase(phase: int) -> void:
	visible = phase != Phase.NONE
	_bubble.visible = phase == Phase.RAISED
	_patch.visible = phase == Phase.RAISED
	_guide.visible = phase == Phase.RAISED
	_held.visible = phase == Phase.HOLD
	set_physics_process(phase != Phase.NONE)


# region drawing

func _begin_drawing() -> void:
	_ink.fill(CANVAS_COLOR)
	_draw_border()
	_ink_texture.update(_ink)
	_last_uv = Vector2.ZERO
	_has_last_uv = false
	_dirty = false
	_pick_glyph()


## Choose the character to trace at random, for this cast only.
##
## Picked here, on the owner, rather than on the server: only this peer ever draws
## it, and the glyph index is sent to the server with the throw anyway — so
## replicating the choice would be a round trip for something nobody else can see.
func _pick_glyph() -> void:
	_glyph_index = -1
	_glyph_name = ""
	_glyph_mask = PackedByteArray()
	_glyph_strokes = PackedByteArray()
	_glyph_mask_size = Vector2i.ZERO
	_guide_material.albedo_texture = null

	var ability := _calligraphy_ability()
	if ability == null or ability.glyphs.is_empty():
		_guide.visible = false
		return
	var index := randi() % ability.glyphs.size()
	var glyph: CalligraphyGlyph = ability.glyphs[index]
	if glyph == null or glyph.image == null:
		_guide.visible = false
		return
	var data := _glyph_data(glyph.image)
	if data.is_empty():
		_guide.visible = false
		return

	_glyph_index = index
	_glyph_name = glyph.display_name
	_glyph_mask = data["mask"]
	_glyph_strokes = data["strokes"]
	_glyph_mask_size = data["size"]
	_guide_material.albedo_texture = data["guide"]


func _clear_stroke_anchor() -> void:
	_has_last_uv = false


func _physics_process(_delta: float) -> void:
	if _phase == Phase.HOLD:
		# The card follows the view; a fresh click throws it.
		_follow_view()
		var pressed := _fire_held()
		if pressed and not _was_fire_held:
			_throw()
		_was_fire_held = pressed
		return

	_follow_camera()
	if not _fire_held():
		# Releasing the button ends the stroke: the next press starts a new one
		# rather than dragging a line in from wherever the crosshair used to be.
		_clear_stroke_anchor()
		return
	var uv := _crosshair_uv()
	if not uv.is_finite():
		# Off the sheet — which includes crossing its edge mid-stroke, so
		# re-entering starts a fresh stroke instead of a line across the gap.
		_clear_stroke_anchor()
		return
	_paint_to(uv)
	if _dirty:
		_dirty = false
		# One upload per frame at most, however many dabs landed in it.
		_ink_texture.update(_ink)


func _fire_held() -> bool:
	return _player != null and _player.player_input != null and _player.player_input.primary_fire_held


## Score the drawing and prepare the card.  Runs on the transient "neither" of the
## raise→hold transition.
func _stash_drawing() -> void:
	_ink_texture.update(_ink)
	_held_score = _compute_score() if _glyph_index >= 0 else 0.0
	print("[Calligraphy] traced ", _glyph_name, " — score ", snappedf(_held_score, 0.001))
	if _held_label != null:
		_held_label.text = "%s  %d%%" % [_glyph_name, int(roundf(_held_score * 100.0))]


func _throw() -> void:
	if _glyph_index < 0 or _player == null or _player.weapon_controller == null:
		return
	# The server validates both values against its own copy of the ability and
	# refuses outright unless the hold effect is up; this is a request, not a shot.
	if multiplayer.is_server():
		_player.weapon_controller.calligraphy_release(_glyph_index, _held_score)
	else:
		_player.weapon_controller.calligraphy_release.rpc_id(1, _glyph_index, _held_score)


## The calligraphy ability this player has equipped, or null.  Scanned rather than
## cached: AbilityManager.set_abilities replaces the list wholesale.
func _calligraphy_ability() -> CalligraphyAbility:
	if _player == null or _player.ability_manager == null:
		return null
	for a in _player.ability_manager.abilities:
		if a is CalligraphyAbility:
			return a
	return null


## How well the drawing matched the character, 0..1 — the **F1** of two halves:
##
##   precision — of the ink the player laid down, how much landed on the character
##   recall    — of the character's strokes, how many the ink reached
##
## Precision alone was the original rule ("all my lines inside = 100%"), and it is
## degenerate: one small dab on a single stroke scores 100%, because the amount of
## ink drawn never enters into it.  Recall alone rewards flooding the sheet.  The
## harmonic mean only goes high when the ink both stayed on the character *and*
## covered it — which is what "you traced this character" actually means.
##
## Both halves use the same SCORE_TOLERANCE_PX; they are the same question asked
## from opposite sides.
func _compute_score() -> float:
	if _glyph_mask.is_empty() or _glyph_strokes.is_empty():
		return 0.0
	var w := CANVAS_SIZE.x
	var h := CANVAS_SIZE.y
	var gw := _glyph_mask_size.x
	var gh := _glyph_mask_size.y
	# One bulk read rather than per-pixel get_pixel: this walks 65k pixels.
	var raw := _ink.get_data()
	var threshold := int(INK_ALPHA_MIN * 255.0)
	var r := SCORE_TOLERANCE_PX
	var rr := r * r

	# Pass 1 over the ink: count it and score the precision half, building the
	# dilated ink mask the recall half tests against on the way.
	var ink_mask := PackedByteArray()
	ink_mask.resize(w * h)
	var ink_total := 0
	var ink_inside := 0
	for y in h:
		for x in w:
			if raw[(y * w + x) * 4 + 3] <= threshold:
				continue
			ink_total += 1
			# Both images are squares mapped to the same sheet, so the glyph
			# coordinates are a straight rescale of the canvas ones.
			var gx := mini(x * gw / w, gw - 1)
			var gy := mini(y * gh / h, gh - 1)
			if _glyph_mask[gy * gw + gx] != 0:
				ink_inside += 1
			for dy in range(-r, r + 1):
				var my := y + dy
				if my < 0 or my >= h:
					continue
				for dx in range(-r, r + 1):
					var mx := x + dx
					if mx < 0 or mx >= w or dx * dx + dy * dy > rr:
						continue
					ink_mask[my * w + mx] = 1
	if ink_total == 0:
		return 0.0

	# Pass 2 over the character: how much of it the ink reached.  A stroke pixel
	# counts as covered when the dilated ink reaches its canvas pixel.
	var strokes_total := 0
	var strokes_covered := 0
	for gy in gh:
		var cy := mini(gy * h / gh, h - 1)
		for gx in gw:
			if _glyph_strokes[gy * gw + gx] == 0:
				continue
			strokes_total += 1
			if ink_mask[cy * w + mini(gx * w / gw, w - 1)] != 0:
				strokes_covered += 1
	if strokes_total == 0:
		return 0.0

	var precision := float(ink_inside) / float(ink_total)
	var recall := float(strokes_covered) / float(strokes_total)
	if precision + recall <= 0.0:
		return 0.0
	return 2.0 * precision * recall / (precision + recall)


## Paint from the previous sample to [param uv], filling the gap in rather than
## leaving a dotted trail.
func _paint_to(uv: Vector2) -> void:
	if not _has_last_uv:
		_stamp(uv, INK_COLOR)
		_last_uv = uv
		_has_last_uv = true
		return
	var span := (uv - _last_uv).length()
	var steps := clampi(int(ceilf(span * float(CANVAS_SIZE.x))), 1, MAX_STROKE_STEPS)
	for i in steps + 1:
		_stamp(_last_uv.lerp(uv, float(i) / float(steps)), INK_COLOR)
	_last_uv = uv


## The drawable edge, painted into the map.  The map *is* the sheet, so this is a
## plain rectangle in image space.
func _draw_border() -> void:
	var w := CANVAS_SIZE.x
	var h := CANVAS_SIZE.y
	for i in int(maxf(BORDER_WIDTH_PX, 1.0)):
		for x in w:
			_set_px(x, i, BORDER_COLOR)
			_set_px(x, h - 1 - i, BORDER_COLOR)
		for y in h:
			_set_px(i, y, BORDER_COLOR)
			_set_px(w - 1 - i, y, BORDER_COLOR)
	_dirty = true


## Stamp the brush at [param uv] in [param color].
func _stamp(uv: Vector2, color: Color) -> void:
	var px := int(roundf(uv.x * float(CANVAS_SIZE.x - 1)))
	var py := int(roundf(uv.y * float(CANVAS_SIZE.y - 1)))
	var r := int(ceilf(BRUSH_RADIUS_PX))
	var rr := BRUSH_RADIUS_PX * BRUSH_RADIUS_PX
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if float(dx * dx + dy * dy) > rr:
				continue
			_set_px(px + dx, py + dy, color)
	_dirty = true


## Write one pixel, ignoring anything off the map.  The map is not periodic — its
## edges are the sheet's edges — so this clips rather than wraps.
func _set_px(x: int, y: int, color: Color) -> void:
	if x < 0 or x >= CANVAS_SIZE.x or y < 0 or y >= CANVAS_SIZE.y:
		return
	_ink.set_pixel(x, y, color)

# endregion


# region camera

## Re-centre the canvas on the camera, **without touching its basis**.  This is the
## only writer of the canvas' position, and it deliberately never touches
## `global_transform.basis` — that is what keeps the canvas world-aligned while the
## player looks around, so sweeping the view moves the crosshair across it.
func _follow_camera() -> void:
	if _player == null:
		return
	var cam := _active_camera()
	if cam != null:
		global_position = cam.global_position


## Hold the drawn card in view: position *and* basis come from the camera, because
## unlike the canvas this one is meant to follow the view.
func _follow_view() -> void:
	if _player == null:
		return
	var cam := _active_camera()
	if cam == null:
		return
	var cam_transform := cam.global_transform
	_held.global_transform = Transform3D(cam_transform.basis, cam.global_position + cam_transform.basis * HELD_OFFSET)


## Aim the sheet at the direction the player is looking, once per activation.
##
## Deliberately NOT called again while the canvas is up: a sheet that tracked the
## view would keep the crosshair stationary relative to it, and sweeping would stop
## drawing.  Fixing it here is what makes the view a brush.
func _frame_patch() -> void:
	var target := Vector3.FORWARD
	var cam := _active_camera()
	if cam != null:
		target = (-cam.global_transform.basis.z).normalized()

	# The sheet's own -Z must look along `target`, so its +Z is -target.  Build the
	# rest of the frame from a reference "up", which is degenerate when the view
	# points at a pole — pick a different reference there.
	var z_axis := -target
	var reference := Vector3.UP
	if absf(z_axis.dot(reference)) > 0.99:
		reference = Vector3.RIGHT
	var y_axis := (reference - z_axis * reference.dot(z_axis)).normalized()
	var x_axis := y_axis.cross(z_axis)
	_patch.basis = Basis(x_axis, y_axis, z_axis)
	_guide.basis = _patch.basis


## The camera the local player is looking through: the orbiting third-person rig
## when it is up, the head camera otherwise.  Mirrors Player._movement_basis() —
## the crosshair follows whichever camera is live, and so does the canvas centre.
func _active_camera() -> Camera3D:
	if _player == null:
		return null
	if _player.third_person and _player.third_person_camera != null:
		return _player.third_person_camera
	return _player.camera as Camera3D

# endregion


# region mapping

## Where the crosshair meets the sheet, in canvas UV space.  Vector2.INF when the
## ray misses the bubble, or hits it outside the drawable square.
func _crosshair_uv() -> Vector2:
	var cam := _active_camera()
	if cam == null:
		return Vector2.INF
	var origin := cam.global_position
	var dir := -cam.global_transform.basis.z

	# Analytic ray/sphere against the bubble, purely to get the *direction* of the
	# point under the crosshair — the radius only sets how far along that direction
	# the hit is, and nothing below reads the distance.  Nearest root in front of
	# the camera: the camera is normally centre-inside, so the near root is behind
	# it and the far root is the point aimed at, but the canvas can be a tick behind
	# the camera after it is raised, and then the near root is right.
	var to_center := origin - global_position
	var b := dir.dot(to_center)
	var c := to_center.length_squared() - SPHERE_RADIUS * SPHERE_RADIUS
	var disc := b * b - c
	if disc <= 0.0:
		return Vector2.INF
	var t_near := -b - sqrt(disc)
	var t := t_near if t_near > 0.0 else -b + sqrt(disc)
	if t <= 0.0:
		return Vector2.INF

	return _patch_uv(origin + dir * t - global_position)


## Canvas UV for a direction from the canvas' centre, or Vector2.INF when it falls
## outside the drawable square.  This is the exact inverse of _tangent_to_uv —
## keeping the two inverse is what puts ink under the crosshair.
func _patch_uv(world_dir: Vector3) -> Vector2:
	# Into the sheet's own frame, where it faces -Z and its tangent square is
	# |x|, |y| <= _patch_half at z = -1.
	var d := _patch.global_transform.basis.inverse() * world_dir.normalized()
	if d.z >= 0.0:
		return Vector2.INF                       # behind the sheet
	var depth := -d.z
	var x := d.x / depth
	var y := d.y / depth
	if absf(x) > _patch_half or absf(y) > _patch_half:
		return Vector2.INF
	return _tangent_to_uv(x, y)

# endregion


# region glyph data

## Per-glyph derived data, built once per glyph per process: the decoded image, the
## dilated stroke mask the score tests against, and the white-recoloured copy the
## overlay draws.  Cached because the dilation alone is a few hundred thousand
## operations on a 150x150 mask.
static func _glyph_data(texture: Texture2D) -> Dictionary:
	if texture == null:
		return {}
	if _glyph_cache.has(texture):
		return _glyph_cache[texture]

	var image := texture.get_image()
	if image == null:
		return {}
	image.convert(Image.FORMAT_RGBA8)
	var w := image.get_width()
	var h := image.get_height()
	if w <= 0 or h <= 0:
		return {}

	# The mask is sourced from the alpha channel in one bulk read rather than
	# per-pixel get_pixel calls.
	var src := image.get_data()
	var stroke_alpha := int(GLYPH_ALPHA_MIN * 255.0)

	# Dilated strokes: every character pixel plus everything within
	# SCORE_TOLERANCE_PX of one.  This is the "ink landed on the character" test —
	# the precision half of the score.  Built alongside the undilated strokes the
	# recall half needs, in the same pass over the image.
	var mask := PackedByteArray()
	mask.resize(w * h)
	var strokes := PackedByteArray()
	strokes.resize(w * h)
	var r := SCORE_TOLERANCE_PX
	var rr := r * r
	for y in h:
		for x in w:
			if src[(y * w + x) * 4 + 3] <= stroke_alpha:
				continue
			strokes[y * w + x] = 1
			for dy in range(-r, r + 1):
				var my := y + dy
				if my < 0 or my >= h:
					continue
				for dx in range(-r, r + 1):
					var mx := x + dx
					if mx < 0 or mx >= w or dx * dx + dy * dy > rr:
						continue
					mask[my * w + mx] = 1

	# The overlay copy: the same strokes recoloured white.  albedo_color
	# *multiplies* the texture, so the black source could only ever render black —
	# indistinguishable from the player's own ink, which is the one thing the guide
	# must never be.
	var guide := Image.create(w, h, false, Image.FORMAT_RGBA8)
	guide.fill(Color(1.0, 1.0, 1.0, 0.0))
	for y in h:
		for x in w:
			guide.set_pixel(x, y, Color(1.0, 1.0, 1.0, src[(y * w + x) * 4 + 3] / 255.0))

	var data := {
		"mask": mask,
		"strokes": strokes,
		"size": Vector2i(w, h),
		"guide": ImageTexture.create_from_image(guide),
	}
	_glyph_cache[texture] = data
	return data

# endregion
