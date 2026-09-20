extends Area3D
## HostServer interaction zone in the 3D lobby.
##
## Only the party leader (peer 1) can host: inside the zone they see
## "Press E to host" and E opens a map-list popup.  A joined player instead
## sees "MUST BE PARTY LEADER TO HOST SERVER" and cannot interact.

@onready var prompt_label: Label3D = $PromptLabel

var _players_inside: Array[Player] = []
var _popup_layer: CanvasLayer = null
var _map_option: OptionButton
var _status_label: Label


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	prompt_label.visible = false
	_build_popup()


func _exit_tree() -> void:
	if _popup_layer and is_instance_valid(_popup_layer):
		_popup_layer.queue_free()
		_popup_layer = null


# ─────────────────────────────────────────────
#  Body tracking
# ─────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if body is Player and body not in _players_inside:
		_players_inside.append(body)
		_refresh_prompt()


func _on_body_exited(body: Node3D) -> void:
	_players_inside.erase(body)
	_refresh_prompt()


func _local_player_inside() -> bool:
	var my_id := str(multiplayer.get_unique_id())
	for p in _players_inside:
		if p.name == my_id:
			return true
	return false


func _is_leader() -> bool:
	return multiplayer.get_unique_id() == 1


func _refresh_prompt() -> void:
	if not _local_player_inside():
		prompt_label.visible = false
		return
	prompt_label.visible = true
	prompt_label.text = "Host Server (E)" if _is_leader() else "MUST BE PARTY LEADER"


# ─────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _local_player_inside():
		return
	if _popup_layer and _popup_layer.visible:
		if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
			_close_popup()
		return
	if event.is_action_pressed("interact") and not event.is_echo() and _is_leader():
		_open_popup()


# ─────────────────────────────────────────────
#  Popup
# ─────────────────────────────────────────────

func _build_popup() -> void:
	_popup_layer = CanvasLayer.new()
	_popup_layer.layer = 2
	_popup_layer.visible = false
	get_tree().root.add_child(_popup_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup_layer.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(460, 0)
	_popup_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "HOST SERVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)

	_map_option = OptionButton.new()
	_populate_map_list()
	vbox.add_child(_map_option)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_status_label)

	var start_btn := Button.new()
	start_btn.text = "Start server"
	start_btn.pressed.connect(_on_start_pressed)
	vbox.add_child(start_btn)

	var close_btn := Button.new()
	close_btn.text = "Close (Esc)"
	close_btn.pressed.connect(_close_popup)
	vbox.add_child(close_btn)


func _populate_map_list() -> void:
	_map_option.clear()
	for entry in ConnectionUtils.scan_maps():
		var idx := _map_option.item_count
		_map_option.add_item(entry["display_name"], idx)
		_map_option.set_item_metadata(idx, entry["path"])
	if _map_option.item_count > 0:
		_map_option.selected = 0


func _open_popup() -> void:
	_status_label.text = ""
	_popup_layer.visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _close_popup() -> void:
	if _popup_layer:
		_popup_layer.visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_start_pressed() -> void:
	if not multiplayer.is_server():
		_status_label.text = "Must be party leader to host."
		return
	if _map_option.item_count == 0 or _map_option.selected < 0:
		_status_label.text = "No maps available."
		return
	var map_path: String = _map_option.get_item_metadata(_map_option.selected)
	_close_popup()
	NetworkManager.load_match_map(map_path)
