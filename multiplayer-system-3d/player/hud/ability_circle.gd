class_name AbilityCircle
extends Control

## Circular ability indicator with a fill-up cooldown pie, and one strip above it
## showing the ability's pool: a row of charge bars for an ability that holds more
## than one charge, or a single meter bar for a metered ability (see MeteredAbility).
##
## The ability is identified by a child Label holding its name (set its font from
## the caller) — or, when the ability has an [member icon], by that icon drawn in
## the disc instead, and the label is hidden.  The circle background, the clockwise
## cooldown pie, the icon, and the bars are all drawn in _draw().
##
## Cooldown semantics are "fill up": while on cooldown the circle is dimmed and
## a bright pie wedge grows clockwise with the elapsed fraction; when the
## cooldown is complete (fraction == 1) the circle reads as ready (bright).  The
## caller decides WHICH gate that fraction represents — see
## AbilityManager.get_cast_progress.
##
## Charge bars mirror the stamina bar (player_ui.gd _build_stamina): one slot per
## charge, a partial-width fill inside it, and a colour change once a slot is full.
## The meter bar is the same idea for a single continuous pool.  They are drawn
## rather than built from ColorRects because _draw already derives the disc's
## `center` and `radius` from `size` — so the bars stay welded to the disc through
## the BASE_DIAMETER -> ACTIVE_DIAMETER resize for free, with no child nodes and
## no layout bookkeeping.
##
## A slot is charged or metered, never both, so the two share one strip: charge
## bars split it per charge, the meter bar uses all of it.

const BASE_DIAMETER := 64.0
const ACTIVE_DIAMETER := 76.0

# Charge bar layout.  The strip sits just above the disc's top edge, inset from
# its full width, and splits that span evenly between the charges.
const CHARGE_BAR_HEIGHT := 5.0
const CHARGE_BAR_GAP := 2.0
const CHARGE_BAR_INSET := 4.0
const CHARGE_BAR_CLEARANCE := 2.0
## Slot background — the stamina bar's, so the two read as the same widget family.
const CHARGE_SLOT_COLOR := Color(0.08, 0.08, 0.08, 0.80)
## A charge still regenerating.
const CHARGE_FILL_COLOR := Color(0.70, 0.70, 0.70, 0.55)
## A banked charge — and, by the same meaning, a meter that is running or full.
## Amber rather than the stamina bar's cyan: that colour is the stamina bar's
## identity, and this one already means "ready" on this HUD (_ability_use_label,
## the shield readout).
const CHARGE_FULL_COLOR := Color(0.95, 0.85, 0.30)

## Icon box, as a fraction of the disc's diameter.  Derived from `radius` at draw
## time rather than stored, so it rides the BASE_DIAMETER -> ACTIVE_DIAMETER resize
## for free like the bars do.  Not larger: the icon is drawn over the cooldown pie,
## so this leaves a ring around it for the sweep's angle to still be read off.
const ICON_FRACTION := 0.66
## Icon tints, one per disc state (see _icon_color).  The game-icons set is white
## paths on transparent, so the bright `active` disc needs a dark icon or the icon
## disappears into it.  The cooling tint is a near-opaque grey rather than a
## dimmed white: the cooldown wedge is drawn *under* the icon, and a translucent
## white icon would composite to a different brightness inside the swept region.
const ICON_COLOR_IDLE := Color(1.0, 1.0, 1.0, 0.95)
const ICON_COLOR_COOLING := Color(0.72, 0.72, 0.72, 0.95)
const ICON_COLOR_BRIGHT := Color(0.10, 0.10, 0.10, 0.95)

var name_label: Label

## Icon drawn in the middle of the disc in place of `name_label`.  Null means
## "text circle" — the label is shown, which is what every ability without an
## authored icon and the loadout screen's "UNASSIGNED" slots rely on.
var icon: Texture2D = null

## 0..1 elapsed cooldown fraction (1 = ready).
var cooldown_fraction := 0.0
var on_cooldown := false
## This slot is the *equipped* ability.  Drives the disc's bright state AND the
## BASE_DIAMETER -> ACTIVE_DIAMETER resize, so nothing else may write it — the
## meter keeps its own flag below for exactly that reason.
var active := false

## Number of charge bars to draw; 0 or 1 means "not a charged ability" and draws
## nothing, which is what every existing ability (and the loadout screen) gets.
var charge_count := 0
## Charge pool, `0..charge_count`: bar `i` is full at `>= i + 1` and partially
## filled in between.
var charge_bank := 0.0

## Meter bar: one continuous pool for a MeteredAbility.  `meter_enabled` is the
## "this slot has a meter at all" flag — without it a recycled circle would keep
## drawing the previous ability's bar, since a meter fraction of 0.0 is a
## perfectly valid thing to draw.
var meter_enabled := false
## 0..1 of MeteredAbility.max_meter remaining.
var meter_fraction := 0.0
## The meter is currently draining (the ability is running).
var meter_active := false


func _init() -> void:
	custom_minimum_size = Vector2(BASE_DIAMETER, BASE_DIAMETER)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	name_label = Label.new()
	name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_constant_override("outline_size", 0)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(name_label)


func set_ability_name(text: String) -> void:
	name_label.text = text


## Show [param tex] in the middle of the disc instead of the name text, or restore
## the label with null.
##
## The label's visibility is owned here rather than by the callers, so a circle can
## never be left showing both.  Note that set_ability_name() deliberately does NOT
## touch it — that is what makes the two setters order-independent.
##
## Idempotent, like the other setters: _update_ability_cooldowns clears every empty
## slot's icon on every frame, exactly as it does the meter.
func set_icon(tex: Texture2D) -> void:
	if tex == icon:
		return
	icon = tex
	name_label.visible = tex == null
	queue_redraw()


func set_cooldown(fraction: float, is_cd: bool) -> void:
	cooldown_fraction = clampf(fraction, 0.0, 1.0)
	on_cooldown = is_cd
	queue_redraw()


## Set the charge pool shown above the circle.  [param count] is the ability's
## max_charges; 1 or less means an uncharged ability, which draws no bars at all.
## Idempotent — _rebuild_abilities runs more than once at startup.
func set_charges(bank: float, count: int) -> void:
	var bars: int = count if count > 1 else 0
	if bars == charge_count and is_equal_approx(bank, charge_bank):
		return
	charge_count = bars
	charge_bank = bank
	queue_redraw()


## Set the meter bar for this slot.  [param enabled] is "this ability is a
## MeteredAbility"; when it is false no meter bar is drawn whatever the fraction
## says.  Idempotent — _rebuild_abilities runs more than once at startup, and this
## is called for every slot on every frame.
##
## The meter is deliberately **not** routed through set_active(): that field also
## drives the 64 -> 76 px resize, so sharing it would resize the disc every time
## the player switched noclip on.
func set_meter(fraction: float, is_active: bool, enabled: bool) -> void:
	var f := clampf(fraction, 0.0, 1.0)
	if enabled == meter_enabled and is_active == meter_active and is_equal_approx(f, meter_fraction):
		return
	meter_enabled = enabled
	meter_fraction = f
	meter_active = is_active
	queue_redraw()


func set_active(a: bool) -> void:
	active = a
	var d := ACTIVE_DIAMETER if a else BASE_DIAMETER
	custom_minimum_size = Vector2(d, d)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 2.0

	# Background disc: dim while cooling, bright when ready/active.  A running
	# meter reads as "in use" the same way an equipped ability does.
	if on_cooldown:
		draw_circle(center, radius, Color(0.12, 0.12, 0.12, 0.55))
	elif active or meter_active:
		draw_circle(center, radius, Color(1.0, 1.0, 1.0, 0.9))
	else:
		draw_circle(center, radius, Color(0.30, 0.30, 0.30, 0.55))

	# Fill-up pie: bright wedge grows clockwise from the top as it readies.
	if on_cooldown and cooldown_fraction > 0.0 and cooldown_fraction < 1.0:
		var from := -PI * 0.5
		var sweep := cooldown_fraction * TAU
		var pts := PackedVector2Array([center])
		var steps := 32
		for i in steps + 1:
			var ang := from + sweep * float(i) / float(steps)
			pts.append(center + Vector2(cos(ang), sin(ang)) * radius)
		draw_colored_polygon(pts, Color(1.0, 1.0, 1.0, 0.35))

	_draw_icon(center, radius)
	_draw_charge_bars(center, radius)
	_draw_meter_bar(center, radius)


## The icon's rect in local coordinates, or a zero-size Rect2 when there is nothing
## to draw (no icon, or a texture with no size).  Split out of _draw for the same
## reason charge_bar_geometry is: a sign error here is invisible in gameplay and
## only shows up as an icon off the disc.
##
## Contain-fit: a square texture (every game-icons SVG) fills the box, a non-square
## one letterboxes inside it rather than stretching.
func icon_rect(center: Vector2, radius: float) -> Rect2:
	if icon == null:
		return Rect2()
	var tex_w: int = icon.get_width()
	var tex_h: int = icon.get_height()
	if tex_w <= 0 or tex_h <= 0:
		return Rect2()
	var box: float = radius * 2.0 * ICON_FRACTION
	var fit: float = minf(box / float(tex_w), box / float(tex_h))
	var draw_size: Vector2 = Vector2(float(tex_w), float(tex_h)) * fit
	return Rect2(center - draw_size * 0.5, draw_size)


## Icon tint for the current disc state.  Deliberately repeats the disc's own
## precedence from _draw() — on_cooldown wins over active — so the icon and the disc
## can never disagree about which state the slot is in.
func _icon_color() -> Color:
	if on_cooldown:
		return ICON_COLOR_COOLING
	if active or meter_active:
		return ICON_COLOR_BRIGHT
	return ICON_COLOR_IDLE


## The ability icon, centred on the disc.  Drawn after the cooldown pie and before
## the bars: the pie is a sector from `center`, so with the icon on top its angular
## span is still read off the outer ring, whereas drawing the icon underneath would
## wash it out inside the swept region and not outside it — an icon that changes
## shape as the cooldown runs.
##
## A _draw call rather than a TextureRect child on purpose: a child would sit on top
## of the parent's whole _draw(), would need its rect recomputed on every 64 -> 76 px
## resize, and would default to MOUSE_FILTER_STOP — which would eat the loadout
## screen's hover tooltip.
func _draw_icon(center: Vector2, radius: float) -> void:
	var rect := icon_rect(center, radius)
	if rect.size.x <= 0.0:
		return
	draw_texture_rect(icon, rect, false, _icon_color())


## Y of the bar strip: normally clear of the disc's top edge, clamped so a short
## layout overlays the disc's rim instead of drawing off the top of the Control.
## Shared by the charge bars and the meter bar so the two line up when one slot
## has charges and another has a meter.
func _bar_top(center: Vector2, radius: float) -> float:
	return maxf(1.0, center.y - radius - CHARGE_BAR_HEIGHT - CHARGE_BAR_CLEARANCE)


## The charge bar strip for the current [member charge_count], as
## `(x, y, bar_width, bar_height)` in local coordinates — the left edge and top
## of the first bar, then the size of one bar.  A `bar_width` of 0.0 means there
## is nothing to draw (uncharged, or so many charges that a bar would be
## sub-pixel and illegible).
##
## Split out from the drawing so the layout can be asserted without a renderer:
## a sign error here is invisible in gameplay and only shows up on screen.
func charge_bar_geometry(center: Vector2, radius: float) -> Vector4:
	if charge_count < 2:
		return Vector4.ZERO
	var span := radius * 2.0 - CHARGE_BAR_INSET * 2.0
	var bar_w := (span - CHARGE_BAR_GAP * float(charge_count - 1)) / float(charge_count)
	if bar_w < 1.0:
		return Vector4.ZERO
	return Vector4(center.x - radius + CHARGE_BAR_INSET, _bar_top(center, radius), bar_w, CHARGE_BAR_HEIGHT)


## The meter bar's rect as `(x, y, width, height)`, in the same strip the charge
## bars use but spanning all of it.  A `width` of 0.0 means there is nothing to
## draw — no meter on this slot, or a disc too small to fit a legible bar.
##
## Split out from the drawing for the same reason charge_bar_geometry is.
func meter_bar_geometry(center: Vector2, radius: float) -> Vector4:
	if not meter_enabled:
		return Vector4.ZERO
	var span := radius * 2.0 - CHARGE_BAR_INSET * 2.0
	if span < 1.0:
		return Vector4.ZERO
	return Vector4(center.x - radius + CHARGE_BAR_INSET, _bar_top(center, radius), span, CHARGE_BAR_HEIGHT)


## One bar per charge, above the disc.  Each slot keeps the stamina bar's
## dark-track-plus-partial-fill shape; a full slot switches to CHARGE_FULL_COLOR
## so a banked charge reads differently from one still regenerating.
func _draw_charge_bars(center: Vector2, radius: float) -> void:
	var geom := charge_bar_geometry(center, radius)
	if geom.z <= 0.0:
		return
	var x := geom.x
	for i in charge_count:
		var slot := Rect2(Vector2(x, geom.y), Vector2(geom.z, geom.w))
		draw_rect(slot, CHARGE_SLOT_COLOR)
		var frac := clampf(charge_bank - float(i), 0.0, 1.0)
		if frac >= 1.0:
			draw_rect(slot, CHARGE_FULL_COLOR)
		elif frac > 0.0:
			draw_rect(Rect2(slot.position, Vector2(geom.z * frac, geom.w)), CHARGE_FILL_COLOR)
		x += geom.z + CHARGE_BAR_GAP


## The meter bar: one slot, filled from the left by the remaining pool.  Same
## language as the charge bars — grey while it is still coming back, amber once
## there is something to spend (running, or banked full).
func _draw_meter_bar(center: Vector2, radius: float) -> void:
	var geom := meter_bar_geometry(center, radius)
	if geom.z <= 0.0:
		return
	draw_rect(Rect2(Vector2(geom.x, geom.y), Vector2(geom.z, geom.w)), CHARGE_SLOT_COLOR)
	if meter_fraction <= 0.0:
		return
	var fill_color := CHARGE_FULL_COLOR if (meter_active or meter_fraction >= 1.0) else CHARGE_FILL_COLOR
	draw_rect(Rect2(Vector2(geom.x, geom.y), Vector2(geom.z * meter_fraction, geom.w)), fill_color)
