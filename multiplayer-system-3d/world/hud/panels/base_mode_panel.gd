extends Control
class_name BaseModePanel

## Abstract base class for game-mode-specific HUD panels.
##
## Each game mode gets its own panel that extends this.  The HUD controller
## calls update_display() every frame so panels stay in sync with server
## state.  Override update_display() to consume the data dictionary and
## refresh your visual children.
##
## To add a new game mode:
##   1. Create a new script extending BaseModePanel
##   2. Implement update_display()
##   3. Register it in HUDController._create_panel_registry()

# ─────────────────────────────────────────────
#  Virtual
# ─────────────────────────────────────────────

## Called every frame by HUDController.  'data' contains mode-specific keys
## gathered by HUDController._build_mode_data().
func update_display(_data: Dictionary) -> void:
	pass

## Human-readable panel name (used for debugging / panel switching).
func get_panel_name() -> String:
	return "BaseModePanel"
