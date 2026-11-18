class_name MuzzleFlash extends Node3D
const DEFAULT_COLOR := Color(1.331, 0.735, 0.0)

## Color used when the shooter belongs to team SCI.
const SCI_COLOR := Color(0.3, 0.55, 1.0)


func set_color(color: Color) -> void:
	$MuzzlePlanes.material_override.albedo_color = color
	$MuzzleCone.material_override.albedo_color = color
	$Sparks.material_override.albedo_color = color
	$OmniLight3D.light_color = color

## Wall-clock ms at which the muzzle light goes out.  A newer shot can only
## extend it, so overlapping automatic-fire shots never hide each other early.
var _light_until_msec: int = 0


func _ready() -> void:
	set_color(DEFAULT_COLOR)
	set_process(false)


## Fires the muzzle flash effect.
## [param flash_color] — optional override; defaults to the warm-orange
##   DEFAULT_COLOR.  Pass [constant SCI_COLOR] for team‑SCI shooters.
func fire(flash_color: Color = DEFAULT_COLOR) -> void:
	set_color(flash_color)

	$MuzzlePlanes.emitting = true
	$MuzzleCone.emitting = true
	$Sparks.emitting = true
	$OmniLight3D.show()

	var until := Time.get_ticks_msec() + int($MuzzlePlanes.lifetime * 1000.0)
	_light_until_msec = maxi(_light_until_msec, until)
	set_process(true)


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() < _light_until_msec:
		return
	$OmniLight3D.hide()
	set_process(false)
