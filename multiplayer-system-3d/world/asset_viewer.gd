extends CanvasLayer

## Dev asset viewer opened by the lobby's AssetViewer Area3D.
##
## Two tabs share one SubViewport + `LoadoutPreviewRig` (the same 3D viewer and
## orbit/pan/zoom controls as the H loadout screen):
##   EFFECTS — the four live effect scenes plus the toon explosion/trail presets.
##   AGENTS  — any agent, any weapon (or none), locomotion blend preview, every
##             human and weapon animation.
##
## Local-only: no RPC, no synchronizer, and everything renders in an
## `own_world_3d` SubViewport so no preview node ever enters gameplay.

const PREVIEW_SCENE := preload("res://world/character_subviewport_preview.tscn")
const RIG_SCRIPT := preload("res://world/loadout/loadout_preview_rig.gd")
const EFFECT_PREVIEW_SCRIPT := preload("res://world/asset_viewer/effect_preview.gd")
const LOCOMOTION_PAD := preload("res://world/asset_viewer/locomotion_pad.gd")
const MANNEQUIN_SCENE := preload("res://assets/character_models/mannequin/mannequin.tscn")
## Preloaded rather than using the class_name so a cold headless run (where the
## global script-class cache may not yet list this file) still compiles.
const CATALOG := preload("res://world/asset_viewer_catalog.gd")

const MENU_LAYER := 4
const VIEW_SIZE := Vector2i(960, 600)
const SPEED_DEFAULT := 1.0
## Metres the mouse-followed trail plane sits behind the stage point, away from
## the camera.
const TRAIL_DEPTH := 1.5

var _tabs: TabBar
var _effects_panel: Control
var _agents_panel: Control
var _controls_effects: Control
var _controls_agents: Control

var _effect_list: ItemList
var _entries: Array[Dictionary] = []
var _selected_entry := -1

var _agent_list: ItemList
var _agent_rows: Array[Character] = []
var _weapon_list: ItemList
var _weapon_rows: Array[Weapon] = []
var _agents_loaded := false

var _human_anim_list: ItemList
var _weapon_anim_list: ItemList

var _svc: SubViewportContainer
var _viewport: SubViewport
var _rig: LoadoutPreviewRig
var _effects_model: Node3D

var _drag_button := 0
var _mouse_local := Vector2.ZERO

# Shared speed (persists across both tabs).
var _speed_value := SPEED_DEFAULT
var _speed_slider: HSlider
var _speed_label: Label

# Effect controls
var _effect_name: Label
var _effect_scale: HSlider
var _scale_label: Label
var _effect_loop: CheckBox
var _effect_auto_flight_row: Control
var _effect_auto_flight: CheckBox
var _effect_mannequin: CheckBox
var _mannequin_ref: Node3D = null
var _show_mannequin := false
## True once the effect view has been framed.  Switching effects keeps the
## camera; entering the tab from Agents re-frames it.
var _effect_camera_ready := false

# Agent controls
var _agent_name: Label
var _weapon_name: Label
var _human_status: Label
var _weapon_status: Label
var _anim_loop: CheckBox
var _locomotion_pad: Control
var _loco_walk_button: Button
var _loco_reset: Button
var _locomotion_state := 0        # -1 crouch / 0 walk / 1 sprint
var _locomotion_dir := Vector2(0.0, -1.0)
var _current_character: Character = null
var _current_weapon: Weapon = null
var _last_human_anim := ""
var _last_weapon_anim := ""


func _ready() -> void:
	layer = MENU_LAYER
	visible = false
	_build()


# ─────────────────────────────────────────────
#  Frame
# ─────────────────────────────────────────────

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = UITheme.SCRIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("margin_left", 40)
	frame.add_theme_constant_override("margin_right", 40)
	frame.add_theme_constant_override("margin_top", 24)
	frame.add_theme_constant_override("margin_bottom", 20)
	add_child(frame)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	frame.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	vb.add_child(header)
	header.add_child(UITheme.display_label("ASSET VIEWER", UITheme.FS_TITLE, UITheme.TEXT))
	var rule := ColorRect.new()
	rule.color = UITheme.RED
	rule.custom_minimum_size = Vector2(3, 26)
	header.add_child(rule)
	header.add_child(UITheme.badge("DEV", UITheme.TEAL))
	var sub := UITheme.section_label("EFFECTS · AGENTS · WEAPONS", UITheme.MUTED)
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(sub)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close := Button.new()
	close.text = "CLOSE  (Esc)"
	close.pressed.connect(close_menu)
	header.add_child(close)

	vb.add_child(UITheme.accent_bar(UITheme.LINE, 1))

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 14)
	vb.add_child(row)

	row.add_child(_build_left_column())
	row.add_child(_build_preview_panel())
	row.add_child(_build_right_column())

	var footer := UITheme.body_label(
		"LMB ROTATE  ·  RMB PAN  ·  SCROLL ZOOM  ·  ESC CLOSE",
		UITheme.FS_MICRO, UITheme.DIM_TEXT)
	vb.add_child(footer)


func _build_left_column() -> Control:
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(320, 0)
	left.add_theme_constant_override("separation", 8)

	_tabs = TabBar.new()
	_tabs.add_tab("EFFECTS")
	_tabs.add_tab("AGENTS")
	_tabs.tab_changed.connect(_on_tab_changed)
	left.add_child(_tabs)
	left.add_child(UITheme.accent_bar(UITheme.LINE, 1))

	_effects_panel = VBoxContainer.new()
	_effects_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_effects_panel.add_theme_constant_override("separation", 6)
	_effects_panel.add_child(UITheme.section_label("EFFECT LIBRARY", UITheme.MUTED))
	_effect_list = _make_list()
	_effect_list.item_selected.connect(_on_effect_selected)
	_effects_panel.add_child(_effect_list)
	left.add_child(_effects_panel)

	_agents_panel = VBoxContainer.new()
	_agents_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_agents_panel.add_theme_constant_override("separation", 6)
	_agents_panel.visible = false
	_agents_panel.add_child(UITheme.section_label("AGENT", UITheme.MUTED))
	_agent_list = _make_list(180)
	_agent_list.item_selected.connect(_on_agent_selected)
	_agents_panel.add_child(_agent_list)
	_agents_panel.add_child(UITheme.section_label("WEAPON", UITheme.MUTED))
	_weapon_list = _make_list(180)
	_weapon_list.item_selected.connect(_on_weapon_selected)
	_agents_panel.add_child(_weapon_list)
	var hint := UITheme.body_label(
		"Click to equip.  NO WEAPON = empty hands (HoldBlend 0.0).",
		UITheme.FS_MICRO, UITheme.DIM_TEXT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_agents_panel.add_child(hint)
	left.add_child(_agents_panel)

	_build_effect_list()
	return left


func _build_preview_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel",
		UITheme.panel_style(UITheme.INK, UITheme.LINE_HI, 1, 0))

	var frame := Control.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(frame)
	_build_preview(frame)
	return panel


func _build_right_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	scroll.add_child(vb)

	vb.add_child(UITheme.section_label("PREVIEW SPEED", UITheme.MUTED))
	var speed_row := _add_slider_row(vb, "SPEED", 0.1, 3.0, 0.05, _speed_value, "×", 1.0)
	_speed_slider = speed_row["slider"] as HSlider
	_speed_label = speed_row["label"] as Label
	_speed_slider.value_changed.connect(_on_speed_changed)
	vb.add_child(UITheme.accent_bar(UITheme.TEAL, 1))

	_controls_effects = _build_effect_controls()
	vb.add_child(_controls_effects)
	_controls_agents = _build_agent_controls()
	_controls_agents.visible = false
	vb.add_child(_controls_agents)
	return scroll


# ─────────────────────────────────────────────
#  3D preview
# ─────────────────────────────────────────────

func _build_preview(parent: Control) -> void:
	_svc = SubViewportContainer.new()
	_svc.stretch = true
	_svc.mouse_filter = Control.MOUSE_FILTER_STOP
	_svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_svc.gui_input.connect(_on_preview_gui_input)
	parent.add_child(_svc)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	_viewport.size = VIEW_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_svc.add_child(_viewport)

	var env := PREVIEW_SCENE.instantiate()
	_viewport.add_child(env)

	var rig_node := RIG_SCRIPT.new() as LoadoutPreviewRig
	rig_node.name = "PreviewRig"
	env.add_child(rig_node)
	_rig = rig_node
	_rig.set_render_interval(1.0 / 60.0)

	_effects_model = EFFECT_PREVIEW_SCRIPT.new() as Node3D
	_effects_model.name = "EffectPreview"
	_rig.get_effect_root().add_child(_effects_model)
	_effects_model.call("stop")
	_rig.set_active(false)


func _on_preview_gui_input(event: InputEvent) -> void:
	if _rig == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_rig.zoom(1.0)
			_svc.accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_rig.zoom(-1.0)
			_svc.accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_drag_button = mb.button_index if mb.pressed else 0
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse_local = mm.position
		_update_trail_cursor()
		if _drag_button == MOUSE_BUTTON_LEFT:
			_rig.orbit(mm.relative.x, mm.relative.y)
		elif _drag_button == MOUSE_BUTTON_RIGHT:
			_rig.pan(mm.relative.x, mm.relative.y)


func _update_trail_cursor() -> void:
	if _rig == null or _effects_model == null or _svc == null:
		return
	if _svc.size.x <= 0.0 or _svc.size.y <= 0.0:
		return
	var uv := Vector2(_mouse_local.x / _svc.size.x, _mouse_local.y / _svc.size.y)
	var camera := _rig.get_preview_camera()
	var plane_point := Vector3(0.0, 0.6, 0.0)
	if camera != null:
		# Push the trail plane away from the viewer so the effect reads at a
		# comfortable depth instead of right in the camera.
		plane_point += -camera.global_basis.z.normalized() * TRAIL_DEPTH
	var point: Vector3 = _rig.screen_to_stage(uv, plane_point)
	_effects_model.call("set_nozzle_point", point)
	_effects_model.call("set_camera", camera)


# ─────────────────────────────────────────────
#  Effects tab
# ─────────────────────────────────────────────

func _build_effect_list() -> void:
	_entries = CATALOG.effect_entries()
	var group_counts := {}
	for entry in _entries:
		var group := str(entry.get("group", ""))
		group_counts[group] = int(group_counts.get(group, 0)) + 1
	var current_group := ""
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var group := str(entry.get("group", ""))
		if group != current_group:
			current_group = group
			_add_group_header(_effect_list, "%s  ·  %d" % [
				group.to_upper(), int(group_counts.get(group, 0))])
		_add_list_row(_effect_list, str(entry.get("title", "")), i)


func _build_effect_controls() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	vb.add_child(UITheme.section_label("EFFECT", UITheme.MUTED))
	_effect_name = UITheme.display_label("—", 22, UITheme.TEXT)
	vb.add_child(_effect_name)
	vb.add_child(UITheme.accent_bar(UITheme.TEAL, 2))

	var scale_row := _add_slider_row(vb, "SCALE", 0.25, 8.0, 0.05, 1.0, "", 1.0)
	_effect_scale = scale_row["slider"] as HSlider
	_scale_label = scale_row["label"] as Label
	_effect_scale.value_changed.connect(_on_effect_scale_changed)

	_effect_loop = CheckBox.new()
	_effect_loop.text = "LOOP"
	_effect_loop.button_pressed = true
	_effect_loop.toggled.connect(_on_effect_loop_toggled)
	vb.add_child(_effect_loop)

	_effect_auto_flight_row = HBoxContainer.new()
	_effect_auto_flight = CheckBox.new()
	_effect_auto_flight.text = "AUTO FLIGHT"
	_effect_auto_flight.button_pressed = false
	_effect_auto_flight.toggled.connect(_on_trail_auto_toggled)
	_effect_auto_flight_row.add_child(_effect_auto_flight)
	_effect_auto_flight_row.visible = false
	vb.add_child(_effect_auto_flight_row)

	_effect_mannequin = CheckBox.new()
	_effect_mannequin.text = "MANNEQUIN FOR SCALE"
	_effect_mannequin.button_pressed = false
	_effect_mannequin.toggled.connect(_on_mannequin_toggled)
	vb.add_child(_effect_mannequin)

	var restart := Button.new()
	restart.text = "RESTART"
	restart.pressed.connect(_on_effect_restart)
	vb.add_child(restart)

	var hint := UITheme.body_label(
		"Trails follow the cursor over the preview.  AUTO FLIGHT flies a loop.",
		UITheme.FS_MICRO, UITheme.DIM_TEXT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)
	return vb


func _on_effect_selected(index: int) -> void:
	var meta: Variant = _effect_list.get_item_metadata(index)
	if typeof(meta) != TYPE_INT:
		return
	_select_effect(int(meta))


func _select_effect(index: int) -> void:
	if index < 0 or index >= _entries.size() or _rig == null:
		return
	_selected_entry = index
	var entry: Dictionary = _entries[index]
	_effect_name.text = str(entry.get("title", "")).to_upper()

	_rig.enter_effect_view()
	# Frame only on the first effect view after entering the tab.  Changing the
	# effect (and re-showing the tab) keeps the user's orbit, pan and zoom.
	if not _effect_camera_ready:
		_rig.frame_effect(float(entry.get("camera_distance", 3.0)), Vector3(0.0, 0.6, 0.0))
		_effect_camera_ready = true
	_effects_model.call("set_camera", _rig.get_preview_camera())
	_effects_model.call("set_speed", _speed_value)
	_effects_model.call("set_auto", _effect_loop.button_pressed)
	_effects_model.call("set_trail_auto", _effect_auto_flight.button_pressed)
	# Scale is user state, not per-entry: it persists across effect changes.
	_effects_model.call("select", entry, _effect_scale.value)

	_effect_auto_flight_row.visible = str(entry.get("kind", "")) == "toon_trail"


func _on_effect_scale_changed(value: float) -> void:
	if _effects_model == null:
		return
	_effects_model.call("set_effect_scale", value)


func _on_effect_loop_toggled(pressed: bool) -> void:
	if _effects_model == null:
		return
	_effects_model.call("set_auto", pressed)


func _on_trail_auto_toggled(pressed: bool) -> void:
	if _effects_model == null:
		return
	_effects_model.call("set_trail_auto", pressed)


func _on_effect_restart() -> void:
	if _effects_model == null:
		return
	_effects_model.call("restart")


func _on_mannequin_toggled(pressed: bool) -> void:
	_show_mannequin = pressed
	if pressed:
		_ensure_mannequin_ref()
	if _mannequin_ref != null and is_instance_valid(_mannequin_ref):
		_mannequin_ref.visible = pressed and _tabs.current_tab == 0


func _ensure_mannequin_ref() -> void:
	if _mannequin_ref != null and is_instance_valid(_mannequin_ref):
		return
	if _rig == null:
		return
	_mannequin_ref = MANNEQUIN_SCENE.instantiate() as Node3D
	_mannequin_ref.name = "ScaleMannequin"
	# Stand beside the effect stage, feet on the preview floor.
	_mannequin_ref.position = Vector3(0.9, 0.0, 0.15)
	_rig.get_effect_root().add_child(_mannequin_ref)


func _set_mannequin_visible(on: bool) -> void:
	if _mannequin_ref != null and is_instance_valid(_mannequin_ref):
		_mannequin_ref.visible = on


# ─────────────────────────────────────────────
#  Agents tab
# ─────────────────────────────────────────────

func _build_agent_controls() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	vb.add_child(UITheme.section_label("AGENT", UITheme.MUTED))
	_agent_name = UITheme.display_label("—", 22, UITheme.TEXT)
	vb.add_child(_agent_name)
	_weapon_name = UITheme.body_label("WEAPON  ·  NONE", UITheme.FS_SMALL, UITheme.MUTED)
	vb.add_child(_weapon_name)
	vb.add_child(UITheme.accent_bar(UITheme.TEAL, 2))

	vb.add_child(UITheme.section_label("LOCOMOTION", UITheme.MUTED))
	var loco := HBoxContainer.new()
	loco.add_theme_constant_override("separation", 12)
	_locomotion_pad = LOCOMOTION_PAD.new()
	_locomotion_pad.connect(&"direction_changed", _on_locomotion_direction_changed)
	var pad_center := CenterContainer.new()
	pad_center.add_child(_locomotion_pad)
	loco.add_child(pad_center)
	var states := VBoxContainer.new()
	states.add_theme_constant_override("separation", 6)
	var group := ButtonGroup.new()
	states.add_child(_make_state_button("CROUCH", -1, group))
	_loco_walk_button = _make_state_button("WALK", 0, group)
	states.add_child(_loco_walk_button)
	states.add_child(_make_state_button("SPRINT", 1, group))
	loco.add_child(states)
	vb.add_child(loco)
	vb.add_child(UITheme.body_label(
		"Drag the pad to aim (continuous).  Walk/Sprint/Crouch drive the real blend tree.",
		UITheme.FS_MICRO, UITheme.DIM_TEXT))
	_loco_reset = Button.new()
	_loco_reset.text = "RESET"
	_loco_reset.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_loco_reset.visible = false
	_loco_reset.pressed.connect(_reset_locomotion)
	vb.add_child(_loco_reset)

	vb.add_child(UITheme.section_label("HUMAN ANIMATIONS", UITheme.MUTED))
	_human_status = UITheme.body_label("LOCOMOTION", UITheme.FS_MICRO, UITheme.MUTED)
	vb.add_child(_human_status)
	_human_anim_list = _make_list(200)
	_human_anim_list.item_selected.connect(_on_human_anim_selected)
	vb.add_child(_human_anim_list)

	vb.add_child(UITheme.section_label("WEAPON ANIMATIONS", UITheme.MUTED))
	_weapon_status = UITheme.body_label("HOLD POSE", UITheme.FS_MICRO, UITheme.MUTED)
	vb.add_child(_weapon_status)
	_weapon_anim_list = _make_list(140)
	_weapon_anim_list.item_selected.connect(_on_weapon_anim_selected)
	vb.add_child(_weapon_anim_list)

	_anim_loop = CheckBox.new()
	_anim_loop.text = "LOOP"
	_anim_loop.button_pressed = true
	_anim_loop.toggled.connect(_on_anim_loop_toggled)
	vb.add_child(_anim_loop)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	var restart := Button.new()
	restart.text = "RESTART"
	restart.pressed.connect(_on_anim_restart)
	buttons.add_child(restart)
	var stop := Button.new()
	stop.text = "STOP / RESTORE POSE"
	stop.pressed.connect(_on_anim_stop)
	buttons.add_child(stop)
	vb.add_child(buttons)
	vb.add_child(UITheme.body_label(
		"Click a clip to play it.  Weapon clips also play their paired human clip.",
		UITheme.FS_MICRO, UITheme.DIM_TEXT))
	return vb


func _make_state_button(text: String, state: int, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.button_pressed = state == _locomotion_state
	button.custom_minimum_size = Vector2(120, 30)
	button.add_theme_stylebox_override("pressed", UITheme.card_style(UITheme.State.SELECTED))
	button.add_theme_stylebox_override("hover_pressed", UITheme.card_style(UITheme.State.SELECTED))
	button.add_theme_color_override("font_pressed_color", UITheme.TEAL)
	button.pressed.connect(_on_locomotion_state_changed.bind(state))
	return button


func _ensure_agents_loaded() -> void:
	if _agents_loaded:
		return
	_agents_loaded = true

	var class_paths := {}
	for group in UITheme.characters_by_class():
		var cls: Class = group.get("class")
		if cls == null:
			continue
		_add_group_header(_agent_list, "%s  ·  %d" % [
			str(cls.class_display_name).to_upper(), cls.characters.size()])
		for character in cls.characters:
			var char_res: Character = character
			_add_list_row(_agent_list, char_res.character_name, _agent_rows.size())
			_agent_rows.append(char_res)
			class_paths[char_res.resource_path] = true

	var leftovers: Array[Character] = []
	for character in CATALOG.characters():
		if not class_paths.has(character.resource_path):
			leftovers.append(character)
	if not leftovers.is_empty():
		_add_group_header(_agent_list, "OTHER  ·  %d" % leftovers.size())
		for char_res in leftovers:
			_add_list_row(_agent_list, char_res.character_name, _agent_rows.size())
			_agent_rows.append(char_res)

	var weapons := CATALOG.weapons()
	var weapon_counts := {}
	for weapon in weapons:
		var group: String = CATALOG.weapon_group(weapon)
		weapon_counts[group] = int(weapon_counts.get(group, 0)) + 1

	_add_group_header(_weapon_list, "NONE")
	_add_list_row(_weapon_list, "NO WEAPON", -1)

	var last_group := ""
	for weapon in weapons:
		var group: String = CATALOG.weapon_group(weapon)
		if group != last_group:
			last_group = group
			_add_group_header(_weapon_list, "%s  ·  %d" % [
				group, int(weapon_counts.get(group, 0))])
		_add_list_row(_weapon_list, weapon.display_name, _weapon_rows.size())
		_weapon_rows.append(weapon)

	_select_weapon(0)
	_select_agent(0)


func _on_agent_selected(index: int) -> void:
	var meta: Variant = _agent_list.get_item_metadata(index)
	if typeof(meta) != TYPE_INT:
		return
	_select_agent(int(meta))


func _on_weapon_selected(index: int) -> void:
	var meta: Variant = _weapon_list.get_item_metadata(index)
	if typeof(meta) != TYPE_INT:
		return
	_select_weapon(int(meta))


func _select_agent(index: int) -> void:
	if index < 0 or index >= _agent_rows.size() or _rig == null:
		return
	_current_character = _agent_rows[index]
	_agent_name.text = _current_character.character_name.to_upper()
	_rig.show_character(_current_character, _current_weapon)
	_apply_locomotion()
	_refresh_animation_lists()
	_update_weapon_name()
	_update_status_labels()


func _select_weapon(index: int) -> void:
	if _rig == null:
		return
	if index == -1:
		# NO WEAPON: empty hand, HoldBlend 0.0 (pure locomotion pose).
		_current_weapon = null
	elif index >= 0 and index < _weapon_rows.size():
		_current_weapon = _weapon_rows[index]
	else:
		return
	_last_human_anim = ""
	_last_weapon_anim = ""
	# Leave raw playback before the rig re-applies the hold pose.
	_rig.stop_human_animation()
	_rig.stop_weapon_animation()
	_rig.set_weapon(_current_weapon)
	_apply_locomotion()
	_refresh_animation_lists()
	_update_weapon_name()
	_update_status_labels()


func _refresh_animation_lists() -> void:
	if _rig == null:
		return
	_human_anim_list.clear()
	for name in _rig.list_human_animations():
		_add_list_row(_human_anim_list, name, name)
	_weapon_anim_list.clear()
	for name in _rig.list_weapon_animations():
		_add_list_row(_weapon_anim_list, name, name)


func _on_human_anim_selected(index: int) -> void:
	var meta: Variant = _human_anim_list.get_item_metadata(index)
	if meta == null or _rig == null:
		return
	# One animation at a time: a human clip replaces the weapon preview.
	_rig.stop_weapon_animation()
	_last_weapon_anim = ""
	_last_human_anim = str(meta)
	_rig.play_human_animation(StringName(meta), _anim_loop.button_pressed, _speed_value)
	_update_status_labels()


func _on_weapon_anim_selected(index: int) -> void:
	var meta: Variant = _weapon_anim_list.get_item_metadata(index)
	if meta == null or _rig == null:
		return
	# One animation at a time: the weapon clip also drives the paired human clip.
	_rig.stop_human_animation()
	_last_human_anim = ""
	_last_weapon_anim = str(meta)
	_rig.play_weapon_animation(StringName(meta), _anim_loop.button_pressed, _speed_value)
	_update_status_labels()


func _on_locomotion_state_changed(state: int) -> void:
	_locomotion_state = state
	_update_loco_reset()
	_apply_locomotion()


func _on_locomotion_direction_changed(direction: Vector2) -> void:
	_locomotion_dir = direction
	_update_loco_reset()
	_apply_locomotion()


func _reset_locomotion() -> void:
	_locomotion_state = 0
	_locomotion_dir = Vector2(0.0, -1.0)
	if _loco_walk_button != null:
		_loco_walk_button.button_pressed = true
	if _locomotion_pad != null:
		_locomotion_pad.call("set_direction", _locomotion_dir)
	_update_loco_reset()
	_apply_locomotion()


func _update_loco_reset() -> void:
	if _loco_reset == null:
		return
	_loco_reset.visible = _locomotion_state != 0 \
		or _locomotion_dir.distance_to(Vector2(0.0, -1.0)) > 0.05


func _apply_locomotion() -> void:
	if _rig == null:
		return
	_rig.set_locomotion_state(_locomotion_state, _locomotion_dir)
	_last_human_anim = ""
	_last_weapon_anim = ""
	_update_status_labels()


func _on_anim_loop_toggled(_pressed: bool) -> void:
	_replay_last_animation()


func _on_speed_changed(value: float) -> void:
	_speed_value = value
	if _speed_label != null:
		_speed_label.text = _fmt_value(value, "×")
	if _effects_model != null:
		_effects_model.call("set_speed", value)
	if _rig != null:
		_rig.set_animation_speed(value)


func _replay_last_animation() -> void:
	if _rig == null:
		return
	if _last_human_anim != "":
		_rig.play_human_animation(
			StringName(_last_human_anim), _anim_loop.button_pressed, _speed_value)
	elif _last_weapon_anim != "":
		_rig.play_weapon_animation(
			StringName(_last_weapon_anim), _anim_loop.button_pressed, _speed_value)


func _on_anim_restart() -> void:
	_replay_last_animation()


func _on_anim_stop() -> void:
	if _rig == null:
		return
	_rig.stop_human_animation()
	_rig.stop_weapon_animation()
	_apply_locomotion()


func _update_weapon_name() -> void:
	if _weapon_name == null:
		return
	var name := "NONE" if _current_weapon == null else _current_weapon.display_name.to_upper()
	_weapon_name.text = "WEAPON  ·  " + name


func _update_status_labels() -> void:
	if _human_status == null or _weapon_status == null:
		return
	if _last_human_anim != "":
		_human_status.text = "PLAYING  " + _last_human_anim
		_human_status.add_theme_color_override("font_color", UITheme.TEAL)
	elif _last_weapon_anim != "":
		_human_status.text = "SYNCED TO WEAPON"
		_human_status.add_theme_color_override("font_color", UITheme.TEAL)
	else:
		_human_status.text = "LOCOMOTION"
		_human_status.add_theme_color_override("font_color", UITheme.MUTED)
	if _last_weapon_anim != "":
		_weapon_status.text = "PLAYING  " + _last_weapon_anim
		_weapon_status.add_theme_color_override("font_color", UITheme.TEAL)
	else:
		_weapon_status.text = "HOLD POSE"
		_weapon_status.add_theme_color_override("font_color", UITheme.MUTED)


# ─────────────────────────────────────────────
#  Shared helpers
# ─────────────────────────────────────────────

func _make_list(min_height := 0) -> ItemList:
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if min_height > 0:
		list.custom_minimum_size = Vector2(0, min_height)
	list.add_theme_stylebox_override("panel",
		UITheme.panel_style(UITheme.INK_2, UITheme.LINE, 1, 6))
	list.add_theme_stylebox_override("selected", UITheme.card_style(UITheme.State.SELECTED))
	list.add_theme_stylebox_override("selected_focus", UITheme.card_style(UITheme.State.SELECTED))
	list.add_theme_stylebox_override("hovered", UITheme.card_style(UITheme.State.HOVER))
	list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	list.add_theme_constant_override("v_separation", 4)
	list.add_theme_color_override("font_color", UITheme.TEXT)
	list.add_theme_color_override("font_hovered_color", UITheme.TEAL)
	list.add_theme_color_override("font_selected_color", Color.WHITE)
	return list


func _add_group_header(list: ItemList, text: String) -> int:
	var index := list.add_item(text.to_upper())
	list.set_item_disabled(index, true)
	list.set_item_custom_fg_color(index, UITheme.TEAL)
	list.set_item_custom_bg_color(index, UITheme.INK)
	return index


func _add_list_row(list: ItemList, text: String, metadata: Variant) -> int:
	var index := list.add_item(text)
	list.set_item_metadata(index, metadata)
	if index % 2 == 1:
		list.set_item_custom_bg_color(index,
			Color(UITheme.SLATE.r, UITheme.SLATE.g, UITheme.SLATE.b, 0.38))
	return index


func _add_slider_row(parent: VBoxContainer, caption: String, min_value: float,
		max_value: float, step: float, value: float, suffix := "",
		default_value := 1.0) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := UITheme.body_label(caption, UITheme.FS_MICRO, UITheme.MUTED)
	label.custom_minimum_size = Vector2(52, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var slider := UITheme.slider(value, min_value, max_value, step)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	var value_label := UITheme.body_label(_fmt_value(value, suffix), UITheme.FS_SMALL, UITheme.TEAL)
	value_label.custom_minimum_size = Vector2(52, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value_label)
	var reset := Button.new()
	reset.text = "RESET"
	reset.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	reset.visible = not is_equal_approx(value, default_value)
	reset.pressed.connect(func() -> void: slider.value = default_value)
	row.add_child(reset)
	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = _fmt_value(v, suffix)
		reset.visible = not is_equal_approx(v, default_value))
	parent.add_child(row)
	return {"slider": slider, "label": value_label, "reset": reset}


func _fmt_value(value: float, suffix := "") -> String:
	return ("%.2f" % value) + suffix


# ─────────────────────────────────────────────
#  Tabs / lifecycle / input
# ─────────────────────────────────────────────

func _on_tab_changed(tab: int) -> void:
	_show_tab(tab)


func _show_tab(tab: int) -> void:
	if _rig == null:
		return
	_effects_panel.visible = tab == 0
	_agents_panel.visible = tab == 1
	_controls_effects.visible = tab == 0
	_controls_agents.visible = tab == 1
	if tab == 0:
		_effects_model.call("stop")
		_set_mannequin_visible(_show_mannequin)
		var index := _selected_entry if _selected_entry >= 0 else 0
		_select_effect(index)
		return
	_set_mannequin_visible(false)
	# Entering Agents abandons the effect camera framing.  Each tab gets its own
	# default view — camera state never carries between Effects and Agents.
	_effect_camera_ready = false
	_rig.reset_character_view()
	_effects_model.call("stop")
	var already_loaded := _agents_loaded
	_ensure_agents_loaded()
	if already_loaded:
		_rig.show_character(_current_character, _current_weapon)
		_apply_locomotion()
		_refresh_animation_lists()


func open_menu() -> void:
	if PlayerInput.ui_open:
		return
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_rig.set_active(true)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var previous_tab := _tabs.current_tab
	_tabs.current_tab = 0
	if previous_tab == 0:
		# current_tab = 0 did not emit (it was already 0).
		_show_tab(0)
	_rig.render_once()


func close_menu() -> void:
	_effects_model.call("stop")
	_rig.set_active(false)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	visible = false
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
		close_menu()
		get_viewport().set_input_as_handled()
		return
	# Swallow H so world_1.gd's loadout toggle cannot stack on top of this menu.
	if event.is_action_pressed("class_select"):
		get_viewport().set_input_as_handled()
