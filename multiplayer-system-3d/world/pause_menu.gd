extends CanvasLayer

## Small in-match pause menu.  There is no settings system yet, so this exposes
## only the paths that exist: resume, loadout, leave, and host end-match.

var world: Node = null
var _end_btn: Button
var _agent_portrait: TextureRect
var _agent_name: Label


func _ready() -> void:
	layer = 6
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = UITheme.SCRIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 26))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := UITheme.display_label("PAUSED", 34, UITheme.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	vb.add_child(UITheme.accent_bar(UITheme.RED, 3))
	vb.add_child(_spacer(8))

	# Local agent identity, so the pause screen matches the staging/loadout look.
	var agent_row := HBoxContainer.new()
	agent_row.add_theme_constant_override("separation", 12)
	vb.add_child(agent_row)
	_agent_portrait = TextureRect.new()
	_agent_portrait.custom_minimum_size = Vector2(52, 52)
	_agent_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_agent_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	agent_row.add_child(_agent_portrait)
	var agent_info := VBoxContainer.new()
	agent_info.add_theme_constant_override("separation", 0)
	agent_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agent_row.add_child(agent_info)
	var kicker := UITheme.section_label("YOUR AGENT", UITheme.MUTED)
	agent_info.add_child(kicker)
	_agent_name = UITheme.body_label("—", UITheme.FS_BODY, UITheme.TEXT)
	_agent_name.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	agent_info.add_child(_agent_name)

	vb.add_child(_spacer(6))
	vb.add_child(_button("RESUME", _on_resume, UITheme.Kind.PRIMARY))
	vb.add_child(_button("CHANGE AGENT / LOADOUT", _on_loadout, UITheme.Kind.SECONDARY))
	_end_btn = _button("END MATCH", _on_end_match, UITheme.Kind.SECONDARY)
	vb.add_child(_end_btn)
	vb.add_child(_spacer(4))
	vb.add_child(_button("LEAVE MATCH", _on_leave, UITheme.Kind.DANGER))

	var hint := UITheme.body_label("Esc to resume", UITheme.FS_MICRO, UITheme.DIM_TEXT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)


func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _button(text: String, handler: Callable, kind := UITheme.Kind.SECONDARY) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_stylebox_override("normal", UITheme.button_style(kind))
	b.add_theme_stylebox_override("hover", UITheme.button_style(kind, true))
	b.add_theme_stylebox_override("pressed", UITheme.button_style(kind, false, true))
	b.pressed.connect(handler)
	return b


func open(world_node: Node) -> void:
	world = world_node
	var host := MatchSession.local_is_host()
	_end_btn.visible = host
	_refresh_agent()
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _refresh_agent() -> void:
	var player := GameManager.find_player(MatchSession.local_id_string())
	var char_res := UITheme.player_character(player)
	_agent_portrait.texture = char_res.portrait if char_res else null
	_agent_name.text = char_res.character_name if char_res else str(player.name) if player else "—"


func close() -> void:
	visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_resume() -> void:
	close()


func _on_loadout() -> void:
	close()
	if world != null:
		world.open_loadout()


func _on_leave() -> void:
	close()
	NetworkManager.return_to_lobby()


func _on_end_match() -> void:
	close()
	if multiplayer.is_server():
		NetworkManager.end_match()
	else:
		MatchSession.request_end_match.rpc_id(1)
