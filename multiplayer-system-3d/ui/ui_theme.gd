extends Node

## Single source of truth for the game's UI look.
##
## Autoloaded as `UITheme` (after GameManager).  `_ready()` installs one Theme on
## the root Window, which cascades to every Control in the game — including the
## children of CanvasLayers.  Menus then use the palette constants and the
## style/widget builders below instead of declaring their own colours.
##
## The written spec lives in docs/DESIGN_STYLE_GUIDE.txt.  If you change a token
## here, change it there too.

# ─────────────────────────────────────────────
#  Palette
# ─────────────────────────────────────────────
const INK := Color("0b0e13")
const INK_2 := Color("11161d")
const SLATE := Color("1a2029")
const SLATE_HI := Color("232b36")
const LINE := Color("2a323d")
const LINE_HI := Color("3a4452")
const TEXT := Color("edf1f5")
const MUTED := Color("8a94a3")
const DIM_TEXT := Color("5c6572")

const RED := Color("ff4655")
const RED_DEEP := Color("c22b39")
const TEAL := Color("2dd4bf")
const TEAL_DEEP := Color("1f8f80")
const AMBER := Color("ffc24b")
const GREEN := Color("6ee7a8")

const PANEL_BG := Color(0.067, 0.086, 0.114, 0.97)   # INK_2
const SCRIM := Color(0.02, 0.03, 0.045, 0.86)

# ─────────────────────────────────────────────
#  Typography
# ─────────────────────────────────────────────
## UI text is Switzer (Helvetica-class neo-grotesque): Medium for everything,
## Bold for numbers and emphasis.  Titles and all-caps display use Anton, a
## condensed poster black.  See docs/DESIGN_STYLE_GUIDE.txt §3.
const FONT_MEDIUM := preload("res://assets/fonts/Switzer/Switzer-Medium.otf")
const FONT_BOLD := preload("res://assets/fonts/Switzer/Switzer-Bold.otf")
const FONT_DISPLAY := preload("res://assets/fonts/Anton/Anton-Regular.ttf")

# Aliases kept so existing call sites keep compiling; every non-display weight
# resolves to one of the two Switzer files.
const FONT_REGULAR := FONT_MEDIUM
const FONT_SEMIBOLD := FONT_MEDIUM
const FONT_EXTRABOLD := FONT_BOLD
const FONT_BLACK := FONT_DISPLAY

const FS_DISPLAY := 44
const FS_TITLE := 28
const FS_SECTION := 15
const FS_BODY := 14
const FS_SMALL := 12
const FS_MICRO := 11

var _theme: Theme
var _font_track_wide: FontVariation
var _font_track_section: FontVariation
var _map_by_path: Dictionary = {}
var _map_by_name: Dictionary = {}
var _char_cache: Dictionary = {}


func _ready() -> void:
	_font_track_wide = _tracked(FONT_DISPLAY, 3)
	_font_track_section = _tracked(FONT_MEDIUM, 2)
	_theme = _build_theme()
	var root := get_tree().root
	if root:
		root.theme = _theme


func _tracked(base: Font, spacing: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = spacing
	return fv


# ─────────────────────────────────────────────
#  Theme
# ─────────────────────────────────────────────
func _build_theme() -> Theme:
	var t := Theme.new()
	t.default_font = FONT_REGULAR
	t.default_font_size = FS_BODY
	t.default_base_scale = 1.0

	# Labels -------------------------------------------------------------
	t.set_font("font", "Label", FONT_REGULAR)
	t.set_font_size("font_size", "Label", FS_BODY)
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.7))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)

	# Panels -------------------------------------------------------------
	var panel := panel_style()
	t.set_stylebox("panel", "Panel", panel)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "PopupPanel", panel)
	t.set_stylebox("panel", "TooltipPanel", panel_style(Color(0.04, 0.05, 0.07, 0.98), LINE_HI, 1, 10))

	# Buttons ------------------------------------------------------------
	var button_types := ["Button", "OptionButton", "MenuButton"]
	for type_name in button_types:
		t.set_font("font", type_name, FONT_SEMIBOLD)
		t.set_font_size("font_size", type_name, FS_BODY)
		t.set_stylebox("normal", type_name, button_style(Kind.SECONDARY))
		t.set_stylebox("hover", type_name, button_style(Kind.SECONDARY, true))
		t.set_stylebox("pressed", type_name, button_style(Kind.SECONDARY, false, true))
		t.set_stylebox("disabled", type_name, button_style(Kind.DISABLED))
		t.set_stylebox("focus", type_name, focus_style())
		t.set_color("font_color", type_name, TEXT)
		t.set_color("font_hover_color", type_name, Color.WHITE)
		t.set_color("font_pressed_color", type_name, TEAL)
		t.set_color("font_disabled_color", type_name, DIM_TEXT)
		t.set_color("font_focus_color", type_name, TEXT)
		t.set_color("font_outline_color", type_name, Color(0, 0, 0, 0))
		t.set_constant("outline_size", type_name, 0)
		t.set_constant("h_separation", type_name, 6)

	# Text input ---------------------------------------------------------
	t.set_font("font", "LineEdit", FONT_REGULAR)
	t.set_font_size("font_size", "LineEdit", FS_BODY)
	t.set_stylebox("normal", "LineEdit", input_style(false))
	t.set_stylebox("focus", "LineEdit", input_style(true))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", DIM_TEXT)
	t.set_color("caret_color", "LineEdit", TEAL)
	t.set_color("selection_color", "LineEdit", Color(TEAL.r, TEAL.g, TEAL.b, 0.28))
	t.set_constant("minimum_character_width", "LineEdit", 4)

	# Item lists ---------------------------------------------------------
	t.set_font("font", "ItemList", FONT_REGULAR)
	t.set_font_size("font_size", "ItemList", FS_BODY)
	t.set_stylebox("panel", "ItemList", panel_style(INK, LINE, 1, 6))
	t.set_stylebox("selected", "ItemList", card_style(State.SELECTED))
	t.set_stylebox("selected_focus", "ItemList", card_style(State.SELECTED))
	t.set_stylebox("hovered", "ItemList", card_style(State.HOVER))
	t.set_stylebox("cursor", "ItemList", focus_style())
	t.set_stylebox("focus", "ItemList", focus_style())
	t.set_color("font_color", "ItemList", TEXT)
	t.set_color("font_selected_color", "ItemList", Color.WHITE)
	t.set_color("font_hovered_color", "ItemList", Color.WHITE)
	t.set_constant("v_separation", "ItemList", 4)

	# Tabs ---------------------------------------------------------------
	for type_name in ["TabContainer", "TabBar"]:
		t.set_font("font", type_name, _font_track_section)
		t.set_font_size("font_size", type_name, FS_SECTION)
		t.set_stylebox("panel", type_name, StyleBoxEmpty.new())
		t.set_stylebox("tab_selected", type_name, tab_style(true))
		t.set_stylebox("tab_unselected", type_name, tab_style(false))
		t.set_stylebox("tab_hovered", type_name, tab_style(false, true))
		t.set_stylebox("tab_disabled", type_name, tab_style(false))
		t.set_color("font_selected_color", type_name, Color.WHITE)
		t.set_color("font_unselected_color", type_name, MUTED)
		t.set_color("font_hovered_color", type_name, TEXT)
		t.set_color("font_disabled_color", type_name, DIM_TEXT)
		t.set_constant("h_separation", type_name, 4)
		t.set_constant("side_margin", type_name, 0)

	# Scroll bars --------------------------------------------------------
	for type_name in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", type_name, panel_style(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 0))
		t.set_stylebox("grabber", type_name, flat_style(LINE, 2))
		t.set_stylebox("grabber_highlight", type_name, flat_style(LINE_HI, 2))
		t.set_stylebox("grabber_pressed", type_name, flat_style(TEAL_DEEP, 2))

	# Popups / tooltips --------------------------------------------------
	t.set_stylebox("hover", "PopupMenu", card_style(State.HOVER))
	t.set_stylebox("separator", "PopupMenu", flat_style(LINE, 1))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_color("font_disabled_color", "PopupMenu", DIM_TEXT)
	t.set_color("font_color", "TooltipLabel", TEXT)

	# Progress / sliders -------------------------------------------------
	t.set_stylebox("background", "ProgressBar", panel_style(Color(0, 0, 0, 0.35), LINE, 1, 0))
	t.set_stylebox("fill", "ProgressBar", flat_style(TEAL))
	t.set_color("font_color", "ProgressBar", TEXT)

	# Rich text ----------------------------------------------------------
	t.set_font("normal_font", "RichTextLabel", FONT_REGULAR)
	t.set_font("bold_font", "RichTextLabel", FONT_SEMIBOLD)
	t.set_font_size("normal_font_size", "RichTextLabel", FS_BODY)
	t.set_font_size("bold_font_size", "RichTextLabel", FS_BODY)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())

	# Container spacing --------------------------------------------------
	t.set_constant("separation", "HBoxContainer", 8)
	t.set_constant("separation", "VBoxContainer", 8)
	t.set_constant("h_separation", "GridContainer", 8)
	t.set_constant("v_separation", "GridContainer", 8)

	return t


# ─────────────────────────────────────────────
#  Style builders
# ─────────────────────────────────────────────
enum State { NORMAL, HOVER, SELECTED, DISABLED }
enum Kind { PRIMARY, SECONDARY, GHOST, DANGER, DISABLED }


func flat_style(color: Color, radius := 0, margins := 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.content_margin_left = margins
	s.content_margin_right = margins
	s.content_margin_top = margins
	s.content_margin_bottom = margins
	return s


func panel_style(bg := PANEL_BG, border := LINE, border_width := 1, margins := 16) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.content_margin_left = margins
	s.content_margin_right = margins
	s.content_margin_top = margins
	s.content_margin_bottom = margins
	return s


func card_style(state: State = State.NORMAL) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	match state:
		State.HOVER:
			s.bg_color = Color(SLATE_HI.r, SLATE_HI.g, SLATE_HI.b, 0.94)
			s.border_color = LINE_HI
			s.set_border_width_all(1)
		State.SELECTED:
			s.bg_color = Color(TEAL.r, TEAL.g, TEAL.b, 0.14)
			s.border_color = TEAL
			s.set_border_width_all(2)
		State.DISABLED:
			s.bg_color = Color(SLATE.r, SLATE.g, SLATE.b, 0.5)
			s.border_color = LINE
			s.set_border_width_all(1)
		_:
			s.bg_color = Color(SLATE.r, SLATE.g, SLATE.b, 0.88)
			s.border_color = LINE
			s.set_border_width_all(1)
	return s


func button_style(kind: Kind, hover := false, pressed := false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	match kind:
		Kind.PRIMARY:
			s.bg_color = RED_DEEP if pressed else (RED.lightened(0.08) if hover else RED)
			s.border_color = RED
			s.set_border_width_all(1)
		Kind.DANGER:
			s.bg_color = RED_DEEP if not hover else Color(RED_DEEP.r, RED_DEEP.g, RED_DEEP.b, 0.85)
			s.border_color = RED
			s.set_border_width_all(1)
		Kind.GHOST:
			s.bg_color = Color(1, 1, 1, 0.06 if hover else 0.0)
			s.border_color = Color(0, 0, 0, 0)
			s.set_border_width_all(0)
		Kind.DISABLED:
			s.bg_color = Color(SLATE.r, SLATE.g, SLATE.b, 0.35)
			s.border_color = LINE
			s.set_border_width_all(1)
		_:
			s.bg_color = Color(1, 1, 1, 0.07) if hover else Color(1, 1, 1, 0.025)
			s.border_color = TEAL if hover else LINE
			s.set_border_width_all(1)
	return s


func focus_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = TEAL
	s.set_border_width_all(1)
	s.draw_center = false
	return s


func input_style(focused: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0.42)
	s.border_color = TEAL if focused else LINE
	s.set_border_width_all(1)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s


## HSlider styled from the shared palette.  The grabber icon still comes from
## the engine default theme; the track and fill are TEAL on LINE like the
## other selection chrome.
func slider(value := 0.5, min_value := 0.0, max_value := 1.0, step := 0.01) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(0, 22)
	s.add_theme_stylebox_override("slider", flat_style(LINE, 2))
	s.add_theme_stylebox_override("grabber_area", flat_style(TEAL, 2))
	s.add_theme_stylebox_override("grabber_area_highlight", flat_style(TEAL.lightened(0.15), 2))
	return s


func tab_style(selected: bool, hovered := false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	if selected:
		s.border_color = RED
		s.border_width_bottom = 3
	else:
		s.border_color = LINE_HI if hovered else LINE
		s.border_width_bottom = 1
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


func accent_bar(color: Color, height := 3) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = color
	bar.custom_minimum_size = Vector2(0, height)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bar


# ─────────────────────────────────────────────
#  Typography helpers
# ─────────────────────────────────────────────
## Screen/panel title.  Always Anton (+3 px tracking) — `size` changes the
## point size only, never the face, so a 20 px heading like the staging team
## names stays a display title instead of falling back to Switzer.
func display_label(text: String, size := FS_DISPLAY, color := TEXT) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_override("font", _font_track_wide)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func section_label(text: String, color := MUTED) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_override("font", _font_track_section)
	label.add_theme_font_size_override("font_size", FS_SECTION)
	label.add_theme_color_override("font_color", color)
	return label


func body_label(text: String, size := FS_BODY, color := TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func badge(text: String, color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(color.r, color.g, color.b, 0.16)
	s.border_color = Color(color.r, color.g, color.b, 0.75)
	s.set_border_width_all(1)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", s)
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_override("font", _font_track_section)
	label.add_theme_font_size_override("font_size", FS_MICRO)
	label.add_theme_color_override("font_color", color)
	panel.add_child(label)
	return panel


func stat_row(label_text: String, value_text: String, accent := TEXT) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style(Color(0, 0, 0, 0.28), LINE, 1, 8))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	var left := body_label(label_text.to_upper(), FS_MICRO, MUTED)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_font_override("font", _font_track_section)
	row.add_child(left)
	var right := body_label(value_text, FS_SMALL, accent)
	right.add_theme_font_override("font", FONT_SEMIBOLD)
	right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(right)
	return panel


# ─────────────────────────────────────────────
#  Data helpers
# ─────────────────────────────────────────────
func mode_name(mode: int) -> String:
	match mode:
		GameModeComponent.GameMode.ESCORT: return "ESCORT"
		GameModeComponent.GameMode.DOMINATION: return "DOMINATION"
		GameModeComponent.GameMode.KOTH: return "KOTH"
		GameModeComponent.GameMode.HYBRID: return "HYBRID"
		GameModeComponent.GameMode.CONTROL: return "CONTROL"
		GameModeComponent.GameMode.DEATHMATCH: return "DEATHMATCH"
		GameModeComponent.GameMode.MAIN_MENU: return "LOBBY"
		_: return ""


func mode_description(mode: int) -> String:
	match mode:
		GameModeComponent.GameMode.KOTH: return "Hold the point to win."
		GameModeComponent.GameMode.CONTROL: return "Best of three. Hold the point."
		GameModeComponent.GameMode.DOMINATION: return "Hold the most points to score."
		GameModeComponent.GameMode.ESCORT: return "Push the payload to the end."
		GameModeComponent.GameMode.HYBRID: return "Capture the point, then escort."
		GameModeComponent.GameMode.DEATHMATCH: return "First to 20 kills wins."
		_: return ""


func team_name(team: int) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return "FFA"


func team_color(team: int) -> Color:
	match team:
		Player.Team.SPI: return RED
		Player.Team.SCI: return TEAL
		_: return AMBER


func _load_map_cache() -> void:
	if not _map_by_path.is_empty():
		return
	for md in ConnectionUtils.scan_map_data():
		if md == null:
			continue
		_map_by_path[md.map_scene_path] = md
		_map_by_name[md.display_name.to_lower()] = md


func map_data_for_path(path: String) -> MapData:
	_load_map_cache()
	return _map_by_path.get(path, null) as MapData


func map_data_for_name(name: String) -> MapData:
	_load_map_cache()
	var key := name.to_lower()
	if key.ends_with(".tscn") or key.ends_with(".scn"):
		key = key.get_basename()
	return _map_by_name.get(key, null) as MapData


func character_for_path(path: String) -> Character:
	if path.is_empty():
		return null
	if _char_cache.has(path):
		return _char_cache[path] as Character
	var char_res := load(path) as Character
	if char_res:
		_char_cache[path] = char_res
	return char_res


func characters_by_class() -> Array[Dictionary]:
	## [{ "class": Class, "characters": Array[Character] }] in canonical order.
	var out: Array[Dictionary] = []
	for cls in LoadoutProfile.load_classes():
		if cls and not cls.characters.is_empty():
			out.append({"class": cls, "characters": cls.characters})
	return out


# ─────────────────────────────────────────────
#  Shared widgets
# ─────────────────────────────────────────────
## 16:9 map card.  `selected` gives it the teal selection frame; the caller
## connects `pressed`.
func map_card(map_data: MapData, selected := false, card_size := Vector2(232, 168)) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = card_size
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_stylebox_override("normal", card_style(State.SELECTED if selected else State.NORMAL))
	btn.add_theme_stylebox_override("hover", card_style(State.SELECTED if selected else State.HOVER))
	btn.add_theme_stylebox_override("pressed", card_style(State.SELECTED))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	if map_data:
		btn.set_meta("map_scene_path", map_data.map_scene_path)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	btn.add_child(vb)

	var image := TextureRect.new()
	image.custom_minimum_size = Vector2(0, card_size.y - 34)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.texture = map_data.map_image if map_data else null
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(image)

	# The mode badge sits over the art, not in the text row: a long mode name
	# ("DEATHMATCH") would otherwise squeeze the map name to a few characters.
	if map_data:
		var mode_badge := badge(mode_name(map_data.game_mode), TEAL)
		mode_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		image.add_child(mode_badge)
		mode_badge.position = Vector2(6, 6)

	var name_label := body_label(
		map_data.display_name.to_upper() if map_data else "—", FS_SMALL, TEXT)
	name_label.add_theme_font_override("font", FONT_SEMIBOLD)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vb.add_child(name_label)

	return btn


## Character portrait card.  `state` is "normal", "selected", "locked" or "dim".
func character_card(char_res: Character, class_res: Class, state := "normal",
		card_size := Vector2(96, 128)) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = card_size
	btn.focus_mode = Control.FOCUS_NONE
	var style_state := State.NORMAL
	var border_color := LINE
	match state:
		"selected":
			style_state = State.SELECTED
			border_color = TEAL
		"locked":
			border_color = RED
		"dim":
			style_state = State.DISABLED
	var normal := card_style(style_state)
	normal.border_color = border_color
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", card_style(State.HOVER if state == "normal" else style_state))
	btn.add_theme_stylebox_override("pressed", normal)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.tooltip_text = char_res.character_name if char_res else ""
	if char_res:
		btn.set_meta("character", char_res)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 4)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 5)
	btn.add_child(vb)

	var portrait := TextureRect.new()
	portrait.custom_minimum_size = Vector2(0, card_size.y - 40)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.texture = char_res.portrait if char_res else null
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.modulate = Color(1, 1, 1, 1) if state != "dim" else Color(1, 1, 1, 0.45)
	vb.add_child(portrait)

	var name_label := body_label(
		char_res.character_name if char_res else "EMPTY", FS_MICRO,
		Color.WHITE if state == "selected" else TEXT)
	name_label.add_theme_font_override("font", _font_track_section)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vb.add_child(name_label)

	if state == "locked":
		var lock := body_label("LOCKED", FS_MICRO, RED)
		lock.add_theme_font_override("font", _font_track_section)
		lock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.add_child(lock)
		lock.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		lock.position.y = 4

	return btn


## Roster row used by the staging screen and the scoreboard.
func roster_card(player: Player, is_host: bool, is_ready: bool, is_local: bool,
		team: int) -> Control:
	var panel := PanelContainer.new()
	var style := card_style(State.NORMAL)
	style.border_color = Color(team_color(team).r, team_color(team).g, team_color(team).b, 0.55)
	if is_local:
		style = card_style(State.SELECTED)
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)

	var accent := ColorRect.new()
	accent.color = team_color(team)
	accent.custom_minimum_size = Vector2(3, 0)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(accent)

	var portrait := TextureRect.new()
	portrait.custom_minimum_size = Vector2(38, 38)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var char_res := character_for_path(str(player._loadout_character_path)) if player else null
	portrait.texture = char_res.portrait if char_res else null
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(portrait)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)

	var name_text := str(player.name) if player else "—"
	if char_res:
		name_text = "%s  ·  %s" % [str(player.name), char_res.character_name]
	var name_label := body_label(name_text, FS_SMALL, TEXT)
	name_label.add_theme_font_override("font", FONT_SEMIBOLD)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_label)

	var tags: PackedStringArray = []
	if is_host: tags.append("HOST")
	if player and player.is_bot: tags.append("BOT")
	if is_local: tags.append("YOU")
	var sub := body_label("  ·  ".join(tags), FS_MICRO, MUTED)
	info.add_child(sub)

	var status := Label.new()
	status.add_theme_font_override("font", _font_track_section)
	status.add_theme_font_size_override("font_size", FS_MICRO)
	if is_ready:
		status.text = "READY"
		status.add_theme_color_override("font_color", TEAL)
	else:
		status.text = "WAITING"
		status.add_theme_color_override("font_color", DIM_TEXT)
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(status)

	return panel


func player_character(player: Player) -> Character:
	if player == null:
		return null
	var path := str(player._loadout_character_path)
	if path.is_empty():
		var direct := player.get_character()
		return direct
	return character_for_path(path)
