class_name CalligraphyAbility
extends Ability

## Trace a character on a canvas around your head, then throw the element you drew.
##
## ## Three phases, carried by two status effects
##
## The ability key cycles: **raise** the canvas → **hold** what you drew → and
## either throw it (LMB, which is not an ability press) or **cancel** it (the key
## again).  Each phase is a permanent marker effect, and the effect *is* the state —
## the same shape noclip uses, and the reason [CalligraphySphere] can drive its
## whole visual state off the replicated effect mirror alone:
##
## | Phase  | Effect                | What the player sees        |
## |--------|-----------------------|-----------------------------|
## | raise  | `CalligraphyEffect`   | the canvas, drawing enabled |
## | hold   | `CalligraphyHoldEffect` | the drawing, carried in view |
## | —      | neither               | nothing                     |
##
## Both effects are named by [method StatusEffectManager.is_fire_blocked], so the
## gun stays locked from the moment the canvas goes up until the throw lands — the
## player cannot shoot their way out of a hold.
##
## ## Why not MeteredAbility
##
## There is no timer here.  Noclip's meter exists to bound how long you fly; the
## canvas stays up until you dismiss it, so a meter would inject a limit nobody
## asked for.  See the class doc of the original implementation in
## docs/02-netcode.md §7.
##
## ## Direction is derived server-side, not sent
##
## The toggle direction comes from the server's own effect state rather than a
## client-supplied `want_on`, so a press the server refuses cannot invert the
## sequence.  The only thing the client sends is the *release* — a glyph index and
## a score, both validated server-side (see WeaponController.calligraphy_release).

const RAISED_ID := "calligraphy"
const HOLD_ID := "calligraphy_hold"

## The drawable characters, each paired with the projectile it casts.  Index into
## this array is the whole of what crosses the wire when a throw is released.
@export var glyphs: Array[CalligraphyGlyph] = []


func _init() -> void:
	cast_type = CastType.INSTANT
	cast_mode = CastMode.SERVER
	max_charges = 1
	# The toggle delay: the floor on how fast the phases can be cycled.  Same role
	# as MeteredAbility's pinned cooldown, shorter because this is a multi-press
	# sequence rather than a dwell.
	cooldown = 0.4


## Runs on the server only.  Advances the sequence one phase.
func activate(player: Player) -> void:
	var sem := player.status_effect_manager
	if sem == null:
		return
	if sem.has_effect(HOLD_ID):
		# Cancel: drop what you drew, no throw.  The escape hatch for a hold the
		# player no longer wants — without it, the only way out would be to throw.
		sem.remove_effect(HOLD_ID)
	elif sem.has_effect(RAISED_ID):
		# Dismiss the canvas and start carrying the drawing.  Removing first then
		# applying means the mirror passes through "neither" in between, which is
		# what tells CalligraphySphere to score the drawing and stash it.
		sem.remove_effect(RAISED_ID)
		sem.apply_effect(CalligraphyHoldEffect.new(), player.name)
	else:
		sem.apply_effect(CalligraphyEffect.new(), player.name)
