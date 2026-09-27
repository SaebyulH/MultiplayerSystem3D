class_name TargetedAbilityIcon
extends Control

## The small disc the targeted-ability preview projects beside a candidate enemy:
## the ability's icon on a dark disc with a coloured rim, in place of the
## ability-name text this used to draw (see PlayerBodyUI._update_targeted_previews).
##
## Deliberately NOT an AbilityCircle.  That widget is the HUD's cooldown
## indicator: disc colours keyed to cooldown/charge/meter, a BASE -> ACTIVE resize
## that also means "equipped", charge and meter strips, a name label.  A preview
## has none of that — it has one colour meaning "this target would be hit", and a
## fixed small size.
##
## The disc stays dark whatever the ability's colour is, and the colour lives in
## the rim.  That is not just style: the icons are white paths, and
## TargetedAbility.preview_color defaults to near-white, so a colour-filled disc
## would swallow the icon in exactly the unlocked state that is most common.

const DIAMETER := 30.0
## Icon box as a fraction of the diameter.  Smaller than the HUD circle's 0.66
## because the rim has to stay legible at 30 px.
const ICON_FRACTION := 0.58
const RING_WIDTH := 2.0
## Disc base — the HUD's cooldown disc, so the two read as the same family.
const DISC_COLOR := Color(0.12, 0.12, 0.12, 0.72)
## How much of the ability's colour is washed over the disc, under the rim.
const DISC_WASH_ALPHA := 0.40
const ICON_COLOR := Color(1.0, 1.0, 1.0, 0.95)

var icon: Texture2D = null
## The ability's colour: locked_color when this candidate would actually be hit,
## preview_color when it is only a candidate.
var rim_color := Color(0.85, 0.85, 0.85, 1.0)


func _init() -> void:
	# Nothing lays out a Control parented to a CanvasLayer, so `size` must be
	# assigned explicitly — custom_minimum_size alone would leave it at (0, 0).
	size = Vector2(DIAMETER, DIAMETER)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Push this candidate's ability icon and colour.  Idempotent, and called every
## frame for every visible entry from the preview loop.
func set_preview(tex: Texture2D, color: Color) -> void:
	if tex == icon and color == rim_color:
		return
	icon = tex
	rim_color = color
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - RING_WIDTH * 0.5

	# Dark base, then the ability colour as a wash, then the rim.  The base is what
	# keeps the white icon readable; the rim is what carries the locked/unlocked
	# read at a glance.
	draw_circle(center, radius, DISC_COLOR)
	draw_circle(center, radius, Color(rim_color.r, rim_color.g, rim_color.b, DISC_WASH_ALPHA))
	draw_arc(center, radius, 0.0, TAU, 32, rim_color, RING_WIDTH, true)

	var rect := _fit_rect(icon, center, radius * 2.0 * ICON_FRACTION)
	if rect.size.x > 0.0:
		draw_texture_rect(icon, rect, false, ICON_COLOR)


## Contain-fit [param tex] into a square of [param box] px centred on
## [param center], preserving aspect.  A zero-size Rect2 means nothing to draw.
##
## This duplicates AbilityCircle's `icon_rect` arithmetic on purpose.  An earlier
## revision shared it via `AbilityCircle.fit_icon_rect()`, declared static, and
## the editor still reported "Cannot call non-static function fit_icon_rect() on
## the class AbilityCircle directly" — while a fresh Godot process parsed the very
## same file clean.  Cross-script calls into a class_name widget turned out not to
## be worth the failure mode; six lines of arithmetic are.  **If you change the
## fit here, change it in AbilityCircle.icon_rect too.**
func _fit_rect(tex: Texture2D, center: Vector2, box: float) -> Rect2:
	if tex == null:
		return Rect2()
	var tex_w: int = tex.get_width()
	var tex_h: int = tex.get_height()
	if tex_w <= 0 or tex_h <= 0:
		return Rect2()
	var fit: float = minf(box / float(tex_w), box / float(tex_h))
	var draw_size: Vector2 = Vector2(float(tex_w), float(tex_h)) * fit
	return Rect2(center - draw_size * 0.5, draw_size)
