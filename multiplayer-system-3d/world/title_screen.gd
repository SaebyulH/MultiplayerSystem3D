extends CanvasLayer

## One-per-process title gate for the local shell.
##
## The lobby world is already built behind this layer.  Showing the title
## before spawning keeps the first click as the entry gesture and avoids the
## old mandatory Loadout screen.  No 3D content is created or moved here.

signal start_requested

var _done := false


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.025, 0.04, 0.94)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 18)
	center.add_child(vb)

	var title := Label.new()
	title.text = "MULTIPLAYER SYSTEM 3D"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	vb.add_child(title)

	var hint := Label.new()
	hint.text = "Click anywhere to start"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.35, 0.65, 1.0))
	vb.add_child(hint)

	var pulse := create_tween().set_loops()
	pulse.tween_property(hint, "modulate:a", 0.35, 1.1).set_trans(Tween.TRANS_SINE)
	pulse.tween_property(hint, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)

	set_process_input(true)


func _input(event: InputEvent) -> void:
	if _done:
		return
	var accepted := false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		accepted = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	elif event.is_action_pressed("ui_accept"):
		accepted = true
	if not accepted:
		return
	_done = true
	get_viewport().set_input_as_handled()
	start_requested.emit()
	queue_free()
