extends CanvasLayer
class_name InteractionPrompt

## Small interaction prompt shown just below the crosshair.
##
## Replaces the billboard `Label3D` prompts the lobby zones used to carry in the
## world.  Each zone owns one instance, built in code and parented to the tree
## root, so the prompt is local HUD and is never part of the replicated map.
##
## An actionable prompt shows a keycap plus an uppercase action label
## ("E  MATCH MENU").  A state prompt drops the keycap and renders the label in
## MUTED ("RUN IN PROGRESS").  The prompt hides itself while any menu owns input
## (`PlayerInput.ui_open`) and fades in/out instead of popping.
##
## Colours, fonts and panel chrome all come from `UITheme`; nothing here
## declares a local palette.  See docs/DESIGN_STYLE_GUIDE.txt.

const FADE_IN := 0.14
const FADE_OUT := 0.10

var _panel: PanelContainer
var _key_panel: PanelContainer
var _key_label: Label
var _action_label: Label
var _detail_label: Label
var _want_visible := false
var _shown := false
var _tween: Tween


func _ready() -> void:
	# Above the default canvas (the player HUD); below the full-screen menus,
	# which live on their own root CanvasLayers.
	layer = 2
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Slot centred horizontally, sitting below the crosshair (screen centre) and
	# clear of the player HUD's own centre column: "USING X" occupies +14..+44
	# and the active-ability disc +46..+118.
	var slot := Control.new()
	slot.name = "Slot"
	slot.anchor_left = 0.5
	slot.anchor_right = 0.5
	slot.anchor_top = 0.5
	slot.anchor_bottom = 0.5
	slot.offset_left = -320.0
	slot.offset_right = 320.0
	slot.offset_top = 124.0
	slot.offset_bottom = 208.0
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(slot)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(center)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel",
		UITheme.panel_style(Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.94), UITheme.LINE, 1, 10))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.modulate.a = 0.0
	center.add_child(_panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(row)

	# Keycap: square, accent border + 14% accent fill (0 corner radius, per the
	# style guide — only the ability discs are round).
	_key_panel = PanelContainer.new()
	_key_panel.custom_minimum_size = Vector2(26, 26)
	_key_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_key_panel)

	var key_center := CenterContainer.new()
	key_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key_panel.add_child(key_center)

	_key_label = UITheme.body_label("E", UITheme.FS_BODY, UITheme.TEAL)
	_key_label.add_theme_font_override("font", UITheme.FONT_BOLD)
	key_center.add_child(_key_label)

	var text_box := VBoxContainer.new()
	text_box.add_theme_constant_override("separation", 1)
	text_box.alignment = BoxContainer.ALIGNMENT_CENTER
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_box)

	_action_label = UITheme.section_label("", UITheme.TEXT)
	_action_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.add_child(_action_label)

	_detail_label = UITheme.body_label("", UITheme.FS_MICRO, UITheme.MUTED)
	_detail_label.visible = false
	_detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.add_child(_detail_label)

	_set_key_style(UITheme.TEAL)


# ─────────────────────────────────────────────
#  Public API
# ─────────────────────────────────────────────

## Actionable prompt: keycap + uppercase action label.
func show_action(text: String, key := "E", accent := UITheme.TEAL, detail := "") -> void:
	_configure(text, key, accent, detail, false)


## State-only prompt (run in progress, cooldown, creating…).  No keycap, muted.
func show_note(text: String, detail := "") -> void:
	_configure(text, "", UITheme.MUTED, detail, true)


func hide_prompt() -> void:
	_want_visible = false
	_apply_visibility()


# ─────────────────────────────────────────────
#  Internals
# ─────────────────────────────────────────────

func _configure(text: String, key: String, accent: Color, detail: String, is_note: bool) -> void:
	_action_label.text = text.to_upper()
	_action_label.add_theme_color_override("font_color", UITheme.MUTED if is_note else UITheme.TEXT)

	_key_panel.visible = key != ""
	if key != "":
		_key_label.text = key
		_key_label.add_theme_color_override("font_color", accent)
		_set_key_style(accent)

	_detail_label.text = detail.to_upper()
	_detail_label.visible = detail != ""

	_want_visible = true
	_apply_visibility()


func _set_key_style(accent: Color) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(accent.r, accent.g, accent.b, 0.14)
	s.border_color = accent
	s.set_border_width_all(1)
	s.content_margin_left = 5
	s.content_margin_right = 5
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	_key_panel.add_theme_stylebox_override("panel", s)


func _process(_delta: float) -> void:
	_apply_visibility()


## Reconciles the request with the menu state.  Cheap: one bool compare per
## frame and a tween only on a transition.
func _apply_visibility() -> void:
	var want := _want_visible and not PlayerInput.ui_open
	if want == _shown:
		return
	_shown = want

	if _tween != null and _tween.is_valid():
		_tween.kill()
	if want:
		visible = true
		_panel.modulate.a = 0.0
		_tween = create_tween()
		_tween.tween_property(_panel, "modulate:a", 1.0, FADE_IN)
	else:
		_tween = create_tween()
		_tween.tween_property(_panel, "modulate:a", 0.0, FADE_OUT)
		_tween.tween_callback(_finish_hide)


func _finish_hide() -> void:
	if not is_instance_valid(self):
		return
	visible = false
