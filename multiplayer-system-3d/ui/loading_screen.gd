extends CanvasLayer
class_name LoadingScreen

## Full-screen loading overlay with a progress bar, a percent readout under the
## bar, and a status label.
## Driven by world/main.gd during boot: set_progress(0.0..1.0) / set_status(text).
## The bar eases toward its target each frame, so the fill moves in many small
## steps instead of jumping between coarse load stages.

## The currently-active loading screen, so any boot-time code (network_manager,
## world_1, etc.) can report progress via LoadingScreen.report() without holding
## a direct reference.
static var current: LoadingScreen = null


@onready var _progress: ProgressBar = $Content/VBox/ProgressBar
@onready var _percent: Label = $Content/VBox/PercentLabel
@onready var _status: Label = $Content/VBox/StatusLabel

var _target: float = 0.0
var _current: float = 0.0

## How quickly the displayed bar catches up to the target (higher = faster).
const LERP_SPEED := 8.0


## Global checkpoint helper: set progress (0..1) and optionally the status text
## on the active loading screen.  No-ops when no loading screen is active.
static func report(v: float, text: String = "") -> void:
	if current:
		current.set_progress(v)
		if text != "":
			current.set_status(text)


func _ready() -> void:
	current = self
	_progress.value = 0.0
	_percent.text = "0%"


func set_progress(v: float) -> void:
	_target = clampf(v, 0.0, 1.0)


func set_status(text: String) -> void:
	_status.text = text


func _process(delta: float) -> void:
	if is_equal_approx(_current, _target):
		return
	_current = lerpf(_current, _target, 1.0 - exp(-LERP_SPEED * delta))
	if absf(_current - _target) < 0.0005:
		_current = _target
	_progress.value = _current * 100.0
	_percent.text = "%d%%" % int(round(_current * 100.0))
