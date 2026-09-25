class_name AbilityCircle
extends Control

## Circular ability indicator with a fill-up cooldown pie, and one strip above it
## showing the ability's pool: a row of charge bars for an ability that holds more
## than one charge, or a single meter bar for a metered ability (see MeteredAbility).
##
## The ability name is drawn via a child Label (set its font from the caller).
## The circle background, the clockwise cooldown pie, and the bars are all
## drawn in _draw().
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

var name_label: Label

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

	_draw_charge_bars(center, radius)
	_draw_meter_bar(center, radius)


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
