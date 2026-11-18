extends PanelContainer
class_name WeaponPopover

## Weapon list opened from a LOADOUT slot on the character-select screen.
##
## The popover owns only presentation.  The screen listens to `weapon_hovered`
## (preview the weapon in the held model) and `weapon_selected` (commit the
## pick), and drives open/close plus the click-catcher behind it.

signal weapon_hovered(weapon: Weapon, key: String)
signal weapon_selected(weapon: Weapon, key: String)

const WIDTH := 320.0
const MAX_HEIGHT := 360.0
const ROW_HEIGHT := 52.0
const SCREEN_MARGIN := 16.0
const GAP := 8.0

var _header: Label
var _scroll: ScrollContainer
var _list: VBoxContainer
var _rows: Array[Button] = []
var _key := ""


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.98),
		UITheme.LINE, 1, 12))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	add_child(vb)

	_header = UITheme.section_label("WEAPONS", UITheme.MUTED)
	vb.add_child(_header)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	_scroll.add_child(_list)


## Fill the popover for [param key]'s column.  [param selected] marks the
## weapon that currently owns the slot.
func open_for(key: String, weapons: Array[Weapon], selected: Weapon) -> void:
	_key = key
	_header.text = key.to_upper()
	_clear_rows()

	for weapon in weapons:
		if weapon == null:
			continue
		var row := _make_row(weapon, weapon == selected)
		_list.add_child(row)
		_rows.append(row)

	var list_height := float(_rows.size()) * (ROW_HEIGHT + 4.0)
	var height := 12.0 * 2.0 + 20.0 + 8.0 + minf(list_height, MAX_HEIGHT)
	_scroll.custom_minimum_size = Vector2(0, minf(list_height, MAX_HEIGHT))
	custom_minimum_size = Vector2(WIDTH, height)
	size = custom_minimum_size
	visible = true


## Open below [param anchor], flipping above it when there is no room and
## clamping to the viewport edges.
func position_near(anchor: Control) -> void:
	if anchor == null:
		return
	var rect := anchor.get_global_rect()
	var vp := get_viewport_rect().size
	var box := custom_minimum_size
	var pos := Vector2(rect.position.x, rect.position.y + rect.size.y + GAP)
	if pos.x + box.x > vp.x - SCREEN_MARGIN:
		pos.x = vp.x - SCREEN_MARGIN - box.x
	if pos.y + box.y > vp.y - SCREEN_MARGIN:
		pos.y = rect.position.y - box.y - GAP
	pos.x = maxf(SCREEN_MARGIN, pos.x)
	pos.y = maxf(SCREEN_MARGIN, pos.y)
	position = pos


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


## Repaint the selected row without reopening (randomize or a committed pick).
func set_selected(weapon: Weapon) -> void:
	for row in _rows:
		_apply_row_state(row, row.get_meta("weapon") == weapon)


func _make_row(weapon: Weapon, selected: bool) -> Button:
	var row := Button.new()
	row.custom_minimum_size = Vector2(WIDTH, ROW_HEIGHT)
	row.focus_mode = Control.FOCUS_NONE
	row.set_meta("weapon", weapon)
	row.set_meta("selected", selected)
	row.pressed.connect(_on_row_pressed.bind(weapon))
	row.mouse_entered.connect(_on_row_hovered.bind(weapon))
	_apply_row_state(row, selected)

	var content := HBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 10)
	content.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	row.add_child(content)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(64, 36)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	icon.texture = weapon.killfeed_icon
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(icon)

	var name_label := UITheme.body_label(weapon.display_name, UITheme.FS_SMALL,
		UITheme.TEAL if selected else UITheme.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(name_label)
	return row


func _apply_row_state(row: Button, selected: bool) -> void:
	row.set_meta("selected", selected)
	row.add_theme_stylebox_override("normal", UITheme.card_style(
		UITheme.State.SELECTED if selected else UITheme.State.NORMAL))
	row.add_theme_stylebox_override("hover", UITheme.card_style(
		UITheme.State.SELECTED if selected else UITheme.State.HOVER))
	row.add_theme_stylebox_override("pressed", UITheme.card_style(UITheme.State.SELECTED))
	row.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _on_row_hovered(weapon: Weapon) -> void:
	weapon_hovered.emit(weapon, _key)


func _on_row_pressed(weapon: Weapon) -> void:
	set_selected(weapon)
	weapon_selected.emit(weapon, _key)


func _clear_rows() -> void:
	for row in _rows:
		if is_instance_valid(row):
			_list.remove_child(row)
			row.queue_free()
	_rows.clear()
