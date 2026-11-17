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
	bg.color = UITheme.INK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# Full-bleed map art.  A dimmed overview reads as a tactical backdrop and
	# reuses the same thumbnail pipeline the staging room uses.
	var art := TextureRect.new()
	var map_data := UITheme.map_data_for_name("2fort")
	if map_data == null:
		var all := ConnectionUtils.scan_map_data()
		map_data = all[0] if not all.is_empty() else null
	if map_data:
		art.texture = map_data.map_image
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.modulate = Color(1, 1, 1, 0.38)
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)

	var gradient := TextureRect.new()
	gradient.texture = _vertical_fade()
	gradient.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gradient.stretch_mode = TextureRect.STRETCH_SCALE
	gradient.set_anchors_preset(Control.PRESET_FULL_RECT)
	gradient.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(gradient)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vb)

	var kicker := UITheme.section_label("TACTICAL TEAM SHOOTER", UITheme.MUTED)
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(kicker)

	var title := UITheme.display_label("MULTIPLAYER\nSYSTEM 3D", 62, UITheme.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_constant_override("line_spacing", -6)
	vb.add_child(title)

	var rule := ColorRect.new()
	rule.color = UITheme.RED
	rule.custom_minimum_size = Vector2(240, 3)
	rule.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(rule)

	var hint := UITheme.section_label("CLICK TO DEPLOY", UITheme.TEAL)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.custom_minimum_size = Vector2(0, 44)
	hint.size_flags_vertical = Control.SIZE_SHRINK_END
	var pulse := create_tween().set_loops()
	pulse.tween_property(hint, "modulate:a", 0.3, 1.1).set_trans(Tween.TRANS_SINE)
	pulse.tween_property(hint, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	add_child(_anchored_bottom(hint))

	var build := UITheme.body_label("DEV BUILD", UITheme.FS_MICRO, UITheme.DIM_TEXT)
	build.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_anchored_corner(build, true))
	var credit := UITheme.body_label("Icons: game-icons.net (CC BY 3.0)", UITheme.FS_MICRO, UITheme.DIM_TEXT)
	add_child(_anchored_corner(credit, false))

	set_process_input(true)


func _vertical_fade() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.35))
	gradient.set_color(1, Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 0.98))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	tex.width = 8
	tex.height = 256
	return tex


func _anchored_bottom(control: Control) -> Control:
	var wrapper := MarginContainer.new()
	wrapper.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	wrapper.offset_top = -120
	wrapper.offset_bottom = -48
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_theme_constant_override("margin_left", 32)
	wrapper.add_theme_constant_override("margin_right", 32)
	wrapper.add_child(control)
	return wrapper


func _anchored_corner(control: Control, top_right: bool) -> Control:
	# Full-rect wrapper: MINSIZE presets derive from the parent's anchorable
	# rect, so the label must be anchored against the viewport, not a container
	# whose own size is still zero.
	var wrapper := Control.new()
	wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(control)
	var preset := Control.PRESET_TOP_RIGHT if top_right else Control.PRESET_BOTTOM_RIGHT
	control.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE, 18)
	return wrapper


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
