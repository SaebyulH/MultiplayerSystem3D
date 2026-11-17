extends CanvasLayer

## Server browser for the C lobby (`lobbyd`).
##
## Built in code and parented to `get_tree().root`, like the other lobby
## popups, so it is not part of the replicated map and is not duplicated by the
## spawner.  It only handles metadata; joining hands off to
## `NetworkManager.join_match()` for the ENet connection.

const REFRESH_SECONDS := 3.0

var _list: ItemList
var _code: LineEdit
var _status: Label
var _timer: Timer
var _joining := false


func _ready() -> void:
	layer = 2
	visible = false
	_build()
	_timer = Timer.new()
	_timer.wait_time = REFRESH_SECONDS
	_timer.one_shot = false
	_timer.timeout.connect(_refresh)
	add_child(_timer)


func open() -> void:
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_timer.start()
	_refresh()


func close() -> void:
	visible = false
	_joining = false
	if _timer:
		_timer.stop()
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") \
			or (event.is_action_pressed("interact") and not event.is_echo()):
		close()
		get_viewport().set_input_as_handled()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = UITheme.SCRIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(600, 0)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 24))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := UITheme.display_label("FIND A MATCH", 28, UITheme.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	vbox.add_child(UITheme.accent_bar(UITheme.RED, 3))

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(520, 260)
	_list.item_selected.connect(_on_item_selected)
	vbox.add_child(_list)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	_code = LineEdit.new()
	_code.placeholder_text = "Join code"
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code.text_submitted.connect(func(_t): _on_join_pressed())
	row.add_child(_code)

	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.PRIMARY))
	join_btn.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.PRIMARY, true))
	join_btn.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.PRIMARY, false, true))
	join_btn.pressed.connect(_on_join_pressed)
	row.add_child(join_btn)

	var refresh_btn := Button.new()
	refresh_btn.text = "REFRESH"
	refresh_btn.pressed.connect(_refresh)
	row.add_child(refresh_btn)

	var close_btn := Button.new()
	close_btn.text = "CLOSE  (Esc)"
	close_btn.pressed.connect(close)
	vbox.add_child(close_btn)

	_status = UITheme.body_label("", UITheme.FS_SMALL, UITheme.MUTED)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status)


func _on_item_selected(index: int) -> void:
	var code := str(_list.get_item_metadata(index))
	if code != "":
		_code.text = code


func _refresh() -> void:
	if not visible or _joining or not LobbyClient.is_enabled():
		return
	_status.text = "Refreshing…"
	var matches: Array = await LobbyClient.list_matches()
	if not visible:
		return
	_list.clear()
	for entry in matches:
		if not entry is Dictionary:
			continue
		var m := entry as Dictionary
		var code := str(m.get("code", ""))
		if code == "":
			continue
		var index := _list.add_item("%s    %d/%d    %s" % [
			code, int(m.get("players", 0)), int(m.get("max_players", 0)),
			str(m.get("state", "?"))])
		_list.set_item_metadata(index, code)
	_status.text = ("%d match(es)" % matches.size()) if not matches.is_empty() \
		else "No matches — create one at the Host zone."


func _on_join_pressed() -> void:
	if _joining:
		return
	var code := _code.text.strip_edges().to_upper()
	if code == "":
		var selected := _list.get_selected_items()
		if selected.size() > 0:
			code = str(_list.get_item_metadata(selected[0]))
	if code == "":
		_status.text = "Pick a match or enter a code."
		return
	_joining = true
	_status.text = "Joining %s…" % code
	var result: Dictionary = await LobbyClient.join_by_code(code)
	if not result.has("endpoint") or not result.has("grant"):
		_status.text = "Join failed: %s" % result.get("error", "unknown")
		_joining = false
		return
	close()
	await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))
