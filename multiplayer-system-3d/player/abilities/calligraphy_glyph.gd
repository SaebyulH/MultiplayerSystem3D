class_name CalligraphyGlyph
extends Resource

## One drawable character: the template the player traces, and the projectile that
## tracing it casts.
##
## The two live in a single resource on purpose.  On release, the *only* thing that
## crosses the wire is this entry's index into CalligraphyAbility.glyphs — the
## server resolves the index against its own copy — so image and projectile have to
## stay in step, and pairing them here is what guarantees it.  Two parallel arrays
## on the ability would be one careless reorder away from launching fire for water.

## Shown on the held card next to the score.
@export var display_name: String = ""
## The template: black strokes on transparent, traced by the player.  Its alpha is
## both the overlay and the scoring mask (see CalligraphySphere), so it should stay
## a clean two-tone image — no grey anti-aliasing halo, no background.
@export var image: Texture2D
## Fired when this glyph is released.  A standalone WeaponFire, so the ability does
## not depend on what the player is holding.
@export var weapon_fire: WeaponFire
