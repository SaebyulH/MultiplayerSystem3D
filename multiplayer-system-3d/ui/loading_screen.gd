extends CanvasLayer
class_name LoadingScreen

## Full-screen loading overlay with a progress bar + status label.
## Driven by world/main.gd during boot: set_progress(0.0..1.0) / set_status(text).

@onready var _progress: ProgressBar = $Content/VBox/ProgressBar
@onready var _status: Label = $Content/VBox/StatusLabel


func set_progress(v: float) -> void:
	_progress.value = clampf(v, 0.0, 1.0) * 100.0


func set_status(text: String) -> void:
	_status.text = text
