class_name SegmentedHealthBar
extends Control

## The per-viewer health readout projected above another player's head: a
## translucent gray track spanning MAX health, a white fill spanning CURRENT
## health drawn over it, and a dark divider at every 100 HP — so the viewer reads
## a target's max health by counting sections (350 max HP draws 3.5 sections).
##
## Drawn in _draw() rather than built from ColorRects: the section count is a
## runtime value (max health moves under size effects) and is usually not a whole
## number, so a child-per-section layout could not express the fractional trailing
## section and would need rebuilding whenever it changed.  Same shape as
## AbilityCircle's charge bars; see docs/04-optimization.md.
##
## Purely cosmetic and local — nothing here is networked.  Whether the local
## viewer is ALLOWED to see the bar is Player.set_public_health_visible's
## decision; this widget only decides what it looks like.

## Health per section.  Not a styling knob — the section is the unit the viewer
## counts, so changing this changes what the bar reports.
const SECTION_HEALTH := 100.0
## Screen-space size of one section.  The caller projects the bar with
## unproject_position, so these are pixels on screen, constant with distance.
const SECTION_WIDTH := 20.0
const BAR_HEIGHT := 8.0
const DIVIDER_WIDTH := 2.0

const TRACK_COLOR := Color(0.25, 0.25, 0.25, 0.45)
const FILL_COLOR := Color(1.0, 1.0, 1.0, 0.92)
const DIVIDER_COLOR := Color(0.0, 0.0, 0.0, 0.90)
const BORDER_COLOR := Color(0.0, 0.0, 0.0, 0.70)

## Geometry last pushed to the canvas item, in pixels.  Doubles as the redraw
## gate: set_health() returns unless one of these actually moves, so a
## regenerating target costs a redraw per pixel of fill rather than one per frame,
## and a full-health target costs none.
var _width_px := -1
var _fill_px := -1


func _init() -> void:
	# Nothing lays out a Control parented to a CanvasLayer (no container, no
	# Control parent), so `size` must be assigned explicitly — custom_minimum_size
	# alone leaves it at (0, 0) and Player._update_health_bar's
	# `unproject_position(...) - size * 0.5` would centre on the top-left corner.
	size = Vector2(SECTION_WIDTH, BAR_HEIGHT)
	# These bars project over the loadout / host / join popups; the default
	# MOUSE_FILTER_STOP would swallow clicks on the popup underneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Push the target's current and max health.  Cheap and idempotent — call it every
## frame; it returns immediately while hidden, and while visible only redraws when
## the drawn geometry (in whole pixels) actually changes.
func set_health(current: float, maximum: float) -> void:
	if not visible:
		return
	var width_px := _width_px_for(maximum)
	var fill_px := _fill_px_for(current, maximum, width_px)
	if width_px == _width_px and fill_px == _fill_px:
		return
	_width_px = width_px
	_fill_px = fill_px
	# `size` tracks MAX health — the caller centres with `- size * 0.5`.
	size = Vector2(float(width_px), BAR_HEIGHT)
	queue_redraw()


## How many sections wide [param maximum] draws, as a float: 350 -> 3.5.  This is
## the number the viewer actually reads off the bar.
func section_span(maximum: float) -> float:
	return maximum / SECTION_HEALTH if maximum > 0.0 else 0.0


## Drawn width for [param maximum], one section per 100 HP.
## roundi(), never int(): int() truncates toward zero, so a 3.9-section bar would
## draw 3 sections wide and a full-health 350 HP target would sit short of its own
## track.  Never integer division either — that would collapse 350 HP to 3
## sections and lose the half.
func _width_px_for(maximum: float) -> int:
	return maxi(roundi(section_span(maximum) * SECTION_WIDTH), 1)


## Drawn fill for [param current], clamped to the track.  A live target keeps at
## least 1 px so "alive but nearly dead" never reads as empty; a target with no
## max health draws no fill rather than a stray sliver.
func _fill_px_for(current: float, maximum: float, width_px: int) -> int:
	if maximum <= 0.0 or current <= 0.0:
		return 0
	var fill := roundi(clampf(current, 0.0, maximum) / SECTION_HEALTH * SECTION_WIDTH)
	return clampi(maxi(fill, 1), 0, width_px)


func _draw() -> void:
	if _width_px <= 0:
		return
	var w := float(_width_px)

	# Max health: the translucent gray track.  Drawn even at zero current health —
	# its full width is the thing being read.
	draw_rect(Rect2(0.0, 0.0, w, BAR_HEIGHT), TRACK_COLOR)

	# Current health, over the track.
	if _fill_px > 0:
		draw_rect(Rect2(0.0, 0.0, float(_fill_px), BAR_HEIGHT), FILL_COLOR)

	# Section dividers last, so they stay readable across the fill/track seam.
	# Only boundaries strictly inside the bar — a whole-section bar's last
	# boundary is its own right edge, already covered by the border below.
	for i in range(1, int(w / SECTION_WIDTH) + 1):
		var x := float(i) * SECTION_WIDTH
		if x + DIVIDER_WIDTH * 0.5 >= w:
			break
		draw_rect(Rect2(x - DIVIDER_WIDTH * 0.5, 0.0, DIVIDER_WIDTH, BAR_HEIGHT), DIVIDER_COLOR)

	# Border, so the bar stays legible against a bright sky or a white wall.
	draw_rect(Rect2(0.0, 0.0, w, BAR_HEIGHT), BORDER_COLOR, false, 1.0)
