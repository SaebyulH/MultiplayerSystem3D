extends Control

var class_selected := false
@export var leaderboard: ItemList
@export var class_select: Panel

func hide_main_menu():
	$MainMenu.hide()

func show_main_menu():
	$MainMenu.show()

func _ready() -> void:
	#hide_ui()
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_pressed("leaderboard"):
		leaderboard.show()
		
	else:
		leaderboard.hide()
		
	if Input.is_action_just_pressed("class_select"):
		if class_selected == false:
			return
		class_select.visible = not class_select.visible
		PlayerInput.ui_open = class_select.visible or $GameMenu.visible
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if PlayerInput.ui_open else Input.MOUSE_MODE_CAPTURED)
