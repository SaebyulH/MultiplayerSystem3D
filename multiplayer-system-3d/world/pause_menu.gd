extends CanvasLayer

## Small in-match pause menu.  There is no settings system yet, so this exposes
## only the paths that exist: resume, loadout, leave, and host end-match.

const BLUE := Color(0.35, 0.65, 1.0, 1.0)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.97)
const PANEL_BORDER := Color(0.3, 0.3, 0.4, 0.8)
const DIM := Color(0.0, 0.02, 0.06, 0.82)

var world: Node = null
var _end_btn: Button


func _ready() -> void:
	layer = 6
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(2)
	style.content_margin_left = 24
	style.content_margin_top = 18
	style.content_margin_right = 24
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(title)

	vb.add_child(_button("RESUME", _on_resume))
	vb.add_child(_button("LOADOUT", _on_loadout))
	vb.add_child(_button("LEAVE MATCH", _on_leave))
	_end_btn = _button("END MATCH", _on_end_match)
	vb.add_child(_end_btn)


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(handler)
	return b


func open(world_node: Node) -> void:
	world = world_node
	var host := MatchSession.local_is_host()
	_end_btn.visible = host
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


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
