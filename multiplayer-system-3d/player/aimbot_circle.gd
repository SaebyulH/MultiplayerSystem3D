extends Control
class_name AimbotCircle

## Circle outline centered on the crosshair, sized to the aimbot's max angle and
## the camera's FOV.  The owning player's HUD updates [member radius] each frame
## and toggles visibility while the aimbot is active.

var radius: float = 0.0
var color: Color = Color(0.3, 0.85, 0.95, 0.9)

func _draw() -> void:
	if radius <= 0.0:
		return
	draw_arc(size * 0.5, radius, 0.0, TAU, 64, color, 2.0, true)
