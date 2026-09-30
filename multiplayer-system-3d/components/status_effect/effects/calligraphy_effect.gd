extends StatusEffect
class_name CalligraphyEffect

## Marker for the calligraphy canvas: the sphere is up and the owner's weapon is
## locked.  Nothing reads this effect for gameplay beyond that — the visual is
## owner-only and driven off the synced effect mirror by CalligraphySphere.
##
## Unlike NoclipEffect there is deliberately NO _on_remove.  Noclip's exit pulse
## wants to fire on *every* removal, including death; calligraphy's rocket must
## not, because it can only be launched by the player dismissing the canvas.  So
## the rocket lives in CalligraphyAbility.activate() instead, and dying mid-draw
## just tears the canvas down (clear_all_effects → the sphere hides itself).
##
## The weapon lock comes from StatusEffectManager.is_fire_blocked(), which names
## this effect id directly — blocks_actions would be the ready-made mechanism but
## it also locks movement and the ability keys, and blocking the ability keys would
## make the canvas impossible to dismiss.

func _init() -> void:
	effect_id = "calligraphy"
	display_name = "Calligraphy"
	is_negative = false
	is_permanent = true
	tick_interval = 0.0
