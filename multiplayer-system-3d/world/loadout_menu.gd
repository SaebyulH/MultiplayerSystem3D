extends Control
class_name LoadoutMenuUI

## Clean, professional loadout-selection screen.
## Mirrors ClassSelectUI: a CanvasLayer added to the root viewport renders
## above all other UI.  Class is inferred from the selected character, so
## there is no separate class-selection step.

## Disable the 3D character-preview SubViewport entirely.  Set to true to skip
## spawning the preview model (the separate World3D is the expensive part).
const PREVIEW_DISABLED := false

## Whether the initial random character/loadout selection has already been made.
## The menu is re-instantiated on return-to-lobby; we only want to randomize on
## the very first load, not on subsequent loads.
static var _initial_selection_done := false

@onready var world := $"../../.."

var player_id: String
var available_classes: Array[Class] = []
var _char_to_class: Dictionary = {}      # character.resource_path -> Class
var _all_characters: Array[Dictionary] = []  # [{ "char": Character, "class": Class }]

# ── Selection state ─────────────────────────
var selected_class: Class = null
var selected_character: Character = null
var selected_primary: Weapon = null
var selected_secondary: Weapon = null
var selected_melee: Weapon = null

# ── Scene templates (instantiated for repeated elements) ──
const _weapon_card_scene := preload("res://world/loadout/weapon_card.tscn")
const _ability_slot_scene := preload("res://world/loadout/ability_slot.tscn")
const _character_button_scene := preload("res://world/loadout/character_button.tscn")

# ── Scene nodes (defined in loadout_menu.tscn) ──
@onready var _canvas: CanvasLayer = $LoadoutMenuCanvas
@onready var _team_option: OptionButton = $LoadoutMenuCanvas/Root/Col/ActionBar/TeamRow/TeamOption
@onready var _confirm_button: Button = $LoadoutMenuCanvas/Root/Col/ActionBar/ConfirmButton
@onready var _randomize_once_button: Button = $LoadoutMenuCanvas/Root/Col/ActionBar/RandomizeOnceButton
@onready var _randomize_on_death_check: CheckBox = $LoadoutMenuCanvas/Root/Col/ActionBar/RandomizeOnDeathCheck
@onready var _leave_party_button: Button = $LoadoutMenuCanvas/Root/Col/ActionBar/LeavePartyButton
@onready var _mode_label: Label = $LoadoutMenuCanvas/Root/Col/ModeLabel
@onready var _info_label: RichTextLabel = $LoadoutMenuCanvas/Root/Col/MainRow/InfoPanel/VBox/InfoLabel

# Character panel
@onready var _character_viewport: SubViewport = $LoadoutMenuCanvas/Root/Col/MainRow/CharacterPanel/VBox/Wrap/Svc/CharacterViewport
@onready var _character_wrap: Panel = $LoadoutMenuCanvas/Root/Col/MainRow/CharacterPanel/VBox/Wrap
@onready var _character_svc: SubViewportContainer = $LoadoutMenuCanvas/Root/Col/MainRow/CharacterPanel/VBox/Wrap/Svc
@onready var _change_agent_overlay: Label = $LoadoutMenuCanvas/Root/Col/MainRow/CharacterPanel/VBox/Wrap/ChangeAgentOverlay
@onready var _character_name_label: Label = $LoadoutMenuCanvas/Root/Col/MainRow/CharacterPanel/VBox/CharacterNameLabel
@onready var _loadout_class_label: Label = $LoadoutMenuCanvas/Root/Col/MainRow/CharacterPanel/VBox/LoadoutClassLabel
@onready var _loadout_class_label_title: Label = $LoadoutMenuCanvas/Root/Col/MainRow/LoadoutPanel/VBox/LoadoutClassLabelTitle
@onready var _character_picker: PopupPanel = $LoadoutMenuCanvas/CharacterPicker

# Ability strip
@onready var _ability_slots_hbox: HBoxContainer = $LoadoutMenuCanvas/Root/Col/AbilitySection/AbilitySlotsHbox

var _character_preview_root: Node3D = null
var _character_preview_model: Node3D = null
var _character_dragging: bool = false
var _character_drag_moved: bool = false
var _character_wrap_style: StyleBoxFlat = null

var _column_lists: Dictionary = {}       # column key -> inner card VBoxContainer
var _card_style: Dictionary = {}         # card -> StyleBoxFlat
var _selected_card: Dictionary = {}      # column key -> selected card
var _ability_style: Dictionary = {}      # slot -> StyleBoxFlat

# ── Card style colours ───────────────────────
const CARD_BG_NORMAL := Color(0.10, 0.11, 0.15, 1)
const CARD_BG_HOVER := Color(0.16, 0.18, 0.24, 1)
const CARD_BG_SELECTED := Color(0.15, 0.20, 0.22, 1)
const CARD_BORDER_NORMAL := Color(0.30, 0.32, 0.38, 1)
const CARD_BORDER_HOVER := Color(0.65, 0.85, 1.0, 1)
const CARD_BORDER_SELECTED := Color(1.0, 0.80, 0.25, 1)

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())

	# Grab the character-panel border stylebox so hover can tween it.
	_character_wrap_style = _character_wrap.get_theme_stylebox("panel") as StyleBoxFlat

	if PREVIEW_DISABLED:
		_character_svc.visible = false
		_character_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# Weapon cards get instantiated into these per-column list containers.
	_column_lists = {
		"secondary": $LoadoutMenuCanvas/Root/Col/MainRow/LoadoutPanel/VBox/Cols/SecondaryColumn/Scroll/List,
		"primary":   $LoadoutMenuCanvas/Root/Col/MainRow/LoadoutPanel/VBox/Cols/PrimaryColumn/Scroll/List,
		"melee":     $LoadoutMenuCanvas/Root/Col/MainRow/LoadoutPanel/VBox/Cols/MeleeColumn/Scroll/List,
	}

	# Sync canvas visibility immediately (menu starts visible, matching self.visible).
	_canvas.visible = visible
	visibility_changed.connect(_on_visibility_changed)

	# Load classes
	var loaded_classes: Array[Class] = []
	for path in [
		"res://player/player_classes/assault.tres",
		"res://player/player_classes/assassin.tres",
		"res://player/player_classes/assistance.tres",
	]:
		var c := load(path) as Class
		if c:
			loaded_classes.append(c)
	load_classes(loaded_classes)

	_build_character_picker()
	_populate_mode_info.call_deferred()

	_confirm_button.pressed.connect(_on_confirm_pressed)
	_randomize_once_button.pressed.connect(_on_randomize_once_pressed)
	_leave_party_button.pressed.connect(_on_leave_party_pressed)

	_character_svc.gui_input.connect(_on_character_gui_input)
	_character_svc.mouse_entered.connect(_on_character_hover_enter)
	_character_svc.mouse_exited.connect(_on_character_hover_exit)

	_character_picker.popup_hide.connect(_on_picker_closed)
	_character_picker.about_to_popup.connect(_on_picker_opened)

	# Populate the menu. The first load picks a random character + loadout; later
	# loads fall back to the first character (assault) so we don't re-randomize.
	if not _all_characters.is_empty():
		if not _initial_selection_done:
			_initial_selection_done = true
			randomize()
			_select_random_loadout()
		else:
			_select_character(_all_characters[0]["char"])


func _on_visibility_changed() -> void:
	# world_1.gd toggles self.visible to show/hide the loadout menu.
	#
	# Deliberately do NOT free/re-spawn the character preview here.  Re-spawning
	# forced a fresh SubViewport 3D render on every open (own_world_3d renders a
	# separate world) — the multi-second freeze netfox logs as "Game stalled".
	# The model has no per-frame work (process_mode disabled, animation paused,
	# no physics), so keeping it alive + rendered once is free.
	if not _canvas:
		return
	if _canvas.visible == visible:
		return
	_canvas.visible = visible
	if OS.is_debug_build():
		print("[DEBUG] loadout menu %s" % ("opened" if visible else "closed"))


func _on_leave_party_pressed() -> void:
	_canvas.queue_free()
	NetworkManager.return_to_lobby()

# ─────────────────────────────────────────────
#  Character picker
# ─────────────────────────────────────────────

func _build_character_picker() -> void:
	# Group characters by class, one labelled section per class.  The PopupPanel
	# and its title are defined in loadout_menu.tscn; sections are data-driven.
	var vb := _character_picker.get_node("VBox") as VBoxContainer
	for cls in available_classes:
		if not cls or cls.characters.is_empty():
			continue
		var accent := _class_accent(cls.class_display_name)

		var header := Label.new()
		header.text = cls.class_display_name.to_upper()
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_theme_font_size_override("font_size", 16)
		header.add_theme_color_override("font_color", accent)
		vb.add_child(header)

		var sep := ColorRect.new()
		sep.custom_minimum_size = Vector2(0, 1)
		sep.color = Color(accent.r, accent.g, accent.b, 0.4)
		sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_child(sep)

		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 10)
		vb.add_child(row)

		for char in cls.characters:
			if not char:
				continue
			var btn := _character_button_scene.instantiate() as Button
			btn.text = char.character_name
			btn.pressed.connect(_on_pick_character.bind(char))
			row.add_child(btn)


func _class_accent(display_name: String) -> Color:
	match display_name.to_lower():
		"assault":
			return Color(1.0, 0.55, 0.25)
		"assassin":
			return Color(0.72, 0.45, 1.0)
		"assistance":
			return Color(0.35, 0.8, 0.6)
		_:
			return Color(0.7, 0.7, 0.7)


func _on_picker_opened() -> void:
	# Pause the character model while the picker covers it — its jigglebones /
	# physics are the main lag source behind the popup.
	if _character_preview_model and is_instance_valid(_character_preview_model):
		_character_preview_model.process_mode = Node.PROCESS_MODE_DISABLED


func _on_picker_closed() -> void:
	if _character_preview_model and is_instance_valid(_character_preview_model):
		_character_preview_model.process_mode = Node.PROCESS_MODE_INHERIT


func _on_pick_character(char: Character) -> void:
	_select_character(char)
	_character_picker.hide()


# ─────────────────────────────────────────────
#  Weapon cards
# ─────────────────────────────────────────────

func _make_weapon_card(weapon: Weapon, key: String) -> Button:
	var card := _weapon_card_scene.instantiate() as Button
	card.set_meta("weapon", weapon)
	card.set_meta("column", key)
	card.set_meta("selected", false)
	_card_style[card] = card.get_theme_stylebox("normal") as StyleBoxFlat

	var icon: TextureRect = card.get_node("Margin/VBox/Icon") as TextureRect
	var placeholder: ColorRect = card.get_node("Margin/VBox/Placeholder") as ColorRect
	var name_label: Label = card.get_node("Margin/VBox/NameLabel") as Label
	if weapon.killfeed_icon:
		icon.texture = weapon.killfeed_icon
		icon.visible = true
		placeholder.visible = false
	else:
		icon.visible = false
		placeholder.visible = true
	name_label.text = weapon.display_name

	card.mouse_entered.connect(_on_card_hover.bind(card))
	card.pressed.connect(_on_card_pressed.bind(card))

	return card


func _apply_card_state(card: Button) -> void:
	var style: StyleBoxFlat = _card_style.get(card)
	if style == null:
		return
	var selected: bool = card.get_meta("selected", false)
	style.bg_color = CARD_BG_SELECTED if selected else CARD_BG_NORMAL
	style.border_color = CARD_BORDER_SELECTED if selected else CARD_BORDER_NORMAL


func _on_card_hover(card: Button) -> void:
	var weapon: Weapon = card.get_meta("weapon")
	_show_weapon_info(weapon)


func _on_card_pressed(card: Button) -> void:
	_select_card(card)


func _select_card(card: Button) -> void:
	var weapon: Weapon = card.get_meta("weapon")
	var key: String = card.get_meta("column")

	var prev: Button = _selected_card.get(key)
	if prev and prev != card:
		prev.set_meta("selected", false)
		_apply_card_state(prev)

	card.set_meta("selected", true)
	_selected_card[key] = card

	match key:
		"primary":
			selected_primary = weapon
		"secondary":
			selected_secondary = weapon
		"melee":
			selected_melee = weapon

	_apply_card_state(card)
	_show_weapon_info(weapon)

# ─────────────────────────────────────────────
#  Ability slots
# ─────────────────────────────────────────────

func _make_ability_slot(index: int, ability: Ability) -> PanelContainer:
	var slot := _ability_slot_scene.instantiate() as PanelContainer
	_ability_style[slot] = slot.get_theme_stylebox("panel") as StyleBoxFlat

	var lbl: Label = slot.get_node("Label") as Label
	if ability:
		lbl.text = ability.ability_name
		lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	else:
		lbl.text = "UNASSIGNED"
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))

	slot.set_meta("ability", ability)
	slot.set_meta("index", index)
	slot.mouse_entered.connect(_on_ability_hover.bind(slot))
	slot.mouse_exited.connect(_on_ability_unhover.bind(slot))

	return slot


func _on_ability_hover(slot: PanelContainer) -> void:
	var style: StyleBoxFlat = _ability_style.get(slot)
	if style:
		var tw := slot.create_tween()
		tw.tween_property(style, "border_color", Color(0.65, 0.85, 1.0, 1), 0.12)
		tw.parallel().tween_property(style, "bg_color", Color(0.16, 0.18, 0.24, 1), 0.12)
	var ability: Ability = slot.get_meta("ability")
	if ability:
		_show_ability_info(ability)
	else:
		_show_info("Unassigned", "No ability is assigned to this slot.")


func _on_ability_unhover(slot: PanelContainer) -> void:
	var style: StyleBoxFlat = _ability_style.get(slot)
	if style:
		var tw := slot.create_tween()
		tw.tween_property(style, "border_color", Color(0.30, 0.32, 0.38, 1), 0.12)
		tw.parallel().tween_property(style, "bg_color", Color(0.10, 0.11, 0.15, 1), 0.12)

# ─────────────────────────────────────────────
#  Info panel
# ─────────────────────────────────────────────

func _show_info(title: String, body: String) -> void:
	if _info_label == null:
		return
	if title == "":
		_info_label.text = body
	else:
		_info_label.text = "[b][font_size=18]%s[/font_size][/b]\n\n%s" % [title, body]


func _show_weapon_info(weapon: Weapon) -> void:
	if weapon == null:
		return
	_show_info(weapon.display_name, _weapon_stats(weapon))


func _show_ability_info(ability: Ability) -> void:
	# Passive abilities are informational only — show just their description.
	if ability is PassiveAbility:
		_show_info(ability.ability_name, ability.description)
		return
	var parts: PackedStringArray = []
	if not ability.description.is_empty():
		parts.append(ability.description)
	parts.append("Cooldown %.1fs" % ability.cooldown)
	var cast := "Instant" if ability.cast_type == Ability.CastType.INSTANT else "Equip"
	parts.append("Cast: %s" % cast)
	_show_info(ability.ability_name, "  • %s" % "\n  • ".join(parts))


func _show_character_info(char: Character) -> void:
	if char == null:
		return
	var parts: PackedStringArray = []
	if not char.description.is_empty():
		parts.append("[i]%s[/i]" % char.description)
	var stat_lines: PackedStringArray = _char_stat_lines(char)
	if stat_lines.size() > 0:
		parts.append("")
		parts.append_array(stat_lines)
	if char.abilities.size() > 0:
		parts.append("")
		parts.append("[b]Abilities[/b]")
		for a in char.abilities:
			if a:
				parts.append("  %s" % a.ability_name)
	_show_info(char.character_name, "\n".join(parts))

# ─────────────────────────────────────────────
#  Selection
# ─────────────────────────────────────────────

func _select_character(char: Character) -> void:
	selected_character = char
	selected_class = null
	if char:
		selected_class = _char_to_class.get(char.resource_path) as Class

	_refresh_character_preview()

	if _character_name_label:
		_character_name_label.text = char.character_name if char else ""
	if _loadout_class_label:
		_loadout_class_label.text = selected_class.class_display_name if selected_class else ""
	if _loadout_class_label_title:
		_loadout_class_label_title.text = "LOADOUT — %s" % (selected_class.class_display_name if selected_class else "")

	_rebuild_weapon_columns()
	_refresh_abilities()

	_confirm_button.disabled = selected_class == null
	if selected_class == null:
		_show_info("", "No class found for this character.")
	else:
		_show_character_info(char)


func _rebuild_weapon_columns() -> void:
	_selected_card.clear()
	_card_style.clear()
	selected_primary = null
	selected_secondary = null
	selected_melee = null

	var primaries: Array[Weapon] = []
	var secondaries: Array[Weapon] = []
	var melees: Array[Weapon] = []
	if selected_class:
		primaries = selected_class.primary_weapons
		secondaries = selected_class.secondary_weapons
		melees = selected_class.melee_weapons

	_populate_column("primary", primaries)
	_populate_column("secondary", secondaries)
	_populate_column("melee", melees)

	if selected_class:
		_auto_select_first("primary", primaries)
		_auto_select_first("secondary", secondaries)
		_auto_select_first("melee", melees)


func _populate_column(key: String, weapons: Array[Weapon]) -> void:
	var list: VBoxContainer = _column_lists.get(key)
	if list == null:
		return
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	if weapons.is_empty():
		var empty := Label.new()
		empty.text = "—"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		list.add_child(empty)
		return
	for w in weapons:
		list.add_child(_make_weapon_card(w, key))


func _auto_select_first(key: String, weapons: Array[Weapon]) -> void:
	if weapons.is_empty():
		return
	var list: VBoxContainer = _column_lists.get(key)
	if list == null or list.get_child_count() == 0:
		return
	var first_card: Button = list.get_child(0) as Button
	_select_card(first_card)


func _refresh_abilities() -> void:
	if _ability_slots_hbox == null:
		return
	for c in _ability_slots_hbox.get_children():
		_ability_slots_hbox.remove_child(c)
		c.queue_free()
	_ability_style.clear()
	for i in 4:
		var ability: Ability = null
		if selected_character and i < selected_character.abilities.size():
			ability = selected_character.abilities[i]
		_ability_slots_hbox.add_child(_make_ability_slot(i, ability))


# ─────────────────────────────────────────────
#  Character preview
# ─────────────────────────────────────────────

func _on_character_hover_enter() -> void:
	if _character_wrap_style:
		var tw := create_tween()
		tw.tween_property(_character_wrap_style, "border_color", Color(1.0, 0.85, 0.4, 1), 0.15)
	_change_agent_overlay.visible = true


func _on_character_hover_exit() -> void:
	if _character_wrap_style:
		var tw := create_tween()
		tw.tween_property(_character_wrap_style, "border_color", Color(0.35, 0.4, 0.5, 1), 0.15)
	_change_agent_overlay.visible = false


## Drag to spin the character; click (press+release without dragging) opens the picker.
func _on_character_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_character_dragging = true
				_character_drag_moved = false
			else:
				_character_dragging = false
				if not _character_drag_moved:
					_character_picker.popup_centered()
	elif event is InputEventMouseMotion and _character_dragging:
		var mm := event as InputEventMouseMotion
		if absf(mm.relative.x) > 0.01:
			_character_drag_moved = true
		if _character_preview_root:
			_character_preview_root.rotation.y += mm.relative.x * 0.01
			_character_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _refresh_character_preview() -> void:
	_spawn_character_preview(selected_character)


func _spawn_character_preview(char: Character) -> void:
	if PREVIEW_DISABLED:
		return
	if _character_viewport == null:
		return
	_clear_viewport(_character_viewport)
	if char == null or char.character_scene == null:
		return
	var pr := _character_viewport.get_node_or_null("Node3D/PreviewRoot") as Node3D
	if pr == null:
		return
	_character_preview_root = pr
	var t0 := Time.get_ticks_usec()
	var model := char.character_scene.instantiate() as Node3D
	_character_preview_model = model
	# The preview is a static pose — disable processing entirely so nothing on
	# the model (animations, jigglebones, scripts) ticks while it sits in the menu.
	model.process_mode = Node.PROCESS_MODE_DISABLED
	pr.add_child(model)

	var box := _visual_aabb(model)
	if box.size.length_squared() <= 0.0001:
		box = AABB(Vector3(-0.5, -0.9, -0.5), Vector3(1.0, 1.8, 1.0))
	model.position = -box.get_center()

	var anims := model.find_children("*", "AnimationPlayer", true, false)
	var anim: AnimationPlayer = anims[0] if not anims.is_empty() else null
	if anim:
		var anim_name := ""
		if anim.has_animation("walk/idle"):
			anim_name = "walk/idle"
		elif anim.has_animation("walk/walk_w"):
			anim_name = "walk/walk_w"
		if anim_name != "":
			anim.play(anim_name)
			# The preview renders once (UPDATE_ONCE), so a looping animation only
			# burns CPU.  Freeze it on a mid-cycle pose instead.
			anim.seek(anim.current_animation_length * 0.5, true)
			anim.pause()

	var camera := _character_viewport.get_node_or_null("Node3D/Camera3D") as Camera3D
	if camera:
		var radius := box.size.length() * 0.5
		var fov := deg_to_rad(camera.fov)
		var distance := radius / tan(fov * 0.5)
		distance = maxf(distance * 1.15, radius + 0.5)
		camera.position = Vector3(0, 0, -distance)
		camera.look_at(Vector3.ZERO)
	_character_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	if OS.is_debug_build():
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var meshes := model.find_children("*", "MeshInstance3D", true, false).size()
		var phys := model.find_children("*", "PhysicsBody3D", true, false).size()
		var skel := model.find_child("Skeleton3D", true, false) as Skeleton3D
		var bones := skel.get_bone_count() if skel else 0
		print("[DEBUG PREVIEW] spawned '%s' in %.2f ms | meshes=%d bones=%d physics_bodies=%d" % [char.character_name, ms, meshes, bones, phys])

# ─────────────────────────────────────────────
#  Preview helpers (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

func _clear_viewport(vp: SubViewport) -> void:
	var pr: Node = vp.get_node_or_null("Node3D/PreviewRoot")
	if not pr:
		return
	for child in pr.get_children():
		child.queue_free()


func _visual_aabb(root: Node3D) -> AABB:
	var box := AABB()
	if root is VisualInstance3D:
		var aabb := (root as VisualInstance3D).get_aabb()
		if aabb.size.length_squared() > 0.0:
			box = box.merge(aabb)
	for child in root.get_children():
		if not child is Node3D:
			continue
		var child_box := _visual_aabb(child as Node3D)
		if child_box.size.length_squared() > 0.0:
			box = box.merge(_aabb_transformed(child_box, (child as Node3D).transform))
	return box


func _aabb_transformed(aabb: AABB, xform: Transform3D) -> AABB:
	var out := AABB()
	out = out.expand(xform * aabb.position)
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, 0, 0)))
	out = out.expand(xform * (aabb.position + Vector3(0, aabb.size.y, 0)))
	out = out.expand(xform * (aabb.position + Vector3(0, 0, aabb.size.z)))
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, aabb.size.y, 0)))
	out = out.expand(xform * (aabb.position + Vector3(aabb.size.x, 0, aabb.size.z)))
	out = out.expand(xform * (aabb.position + Vector3(0, aabb.size.y, aabb.size.z)))
	out = out.expand(xform * (aabb.position + aabb.size))
	return out

# ─────────────────────────────────────────────
#  Classes
# ─────────────────────────────────────────────

func load_classes(classes: Array[Class]) -> void:
	available_classes = classes
	_char_to_class.clear()
	_all_characters.clear()
	for cls in classes:
		if not cls:
			continue
		for char in cls.characters:
			if char:
				_char_to_class[char.resource_path] = cls
				_all_characters.append({"char": char, "class": cls})

# ─────────────────────────────────────────────
#  Stats (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

func _weapon_stats(weapon: Weapon) -> String:
	var parts: PackedStringArray = []

	if not weapon.has_infinite_ammo:
		parts.append("Mag %d" % weapon.mag_size)
		parts.append("Reload %.1fs%s" % [weapon.reload_time,
			" per shell" if weapon.reload_individually else ""])

	for fire in weapon.weapon_fires:
		if fire.action_type != WeaponFire.ActionType.SHOOT:
			continue

		if fire.bullet_type == WeaponFire.BulletType.HITSCAN:
			parts.append("Hitscan · DMG %d" % fire.hitscan_damage)
			if fire.headshot_multiplier != 1.0:
				parts.append("Head ×%.1f" % fire.headshot_multiplier)
			if fire.has_damage_falloff:
				parts.append("Falloff %.0f–%.0f" % [fire.falloff_start, fire.falloff_end])
		else:
			parts.append("Projectile")
			if fire.projectile_scene != null:
				var proj := fire.projectile_scene.instantiate()
				var hb_node: Node = proj.get_node_or_null("HitboxComponent")
				if hb_node and hb_node is HitboxComponent:
					var hb := hb_node as HitboxComponent
					parts.append("DMG %d" % abs(hb.health_delta))
					if hb.headshot_multiplier != 1.0:
						parts.append("Head ×%.1f" % hb.headshot_multiplier)
				proj.queue_free()

		if fire.post_shoot_delay > 0.0:
			parts.append("%.1f/s" % (1.0 / fire.post_shoot_delay))
		else:
			parts.append("Semi")

		if fire.automatic:
			parts.append("Auto")

		if fire.ammo_cost > 1:
			parts.append("Cost %d" % fire.ammo_cost)

		if fire.multishot_data.size() > 1:
			match fire.multishot_mode:
				WeaponFire.MultishotMode.SHOTGUN:
					parts.append("×%d pellets" % fire.multishot_data.size())
				WeaponFire.MultishotMode.BURST:
					parts.append("Burst %d" % fire.multishot_data.size())
				WeaponFire.MultishotMode.SHAPE:
					parts.append("Melee ×%d" % fire.multishot_data.size())

	if not is_equal_approx(weapon.player_speed_multiplier, 1.0):
		var pct := int((weapon.player_speed_multiplier - 1.0) * 100.0)
		parts.append("Speed %s%d%%" % ["+" if pct > 0 else "", pct])

	return "  • %s" % "\n  • ".join(parts)


func _char_stat_lines(char: Character) -> PackedStringArray:
	var lines: PackedStringArray = []
	_add_stat_group(lines, "Movement", [
		["Speed", char.speed_mult, false],
		["Acceleration", char.acceleration_mult, false],
		["Friction", char.friction_mult, false],
		["Crouch Speed", char.crouch_speed_mult, false],
	])
	_add_stat_group(lines, "Air", [
		["Air Accel", char.air_accel_mult, false],
		["Air Speed Cap", char.air_speed_cap_mult, false],
		["Jump", char.jump_mult, false],
	])
	_add_stat_group(lines, "Slide", [
		["Slide Friction", char.slide_friction_mult, false],
		["Entry Boost", char.slide_entry_boost_mult, false],
		["Slope Gravity", char.slope_gravity_mult, false],
	])
	_add_stat_group(lines, "Combat", [
		["Damage", char.damage_amp_mult, false],
		["Reload Speed", char.reload_speed_mult, false],
		["Fire Rate", char.shoot_delay_mult, true],
	])
	_add_stat_group(lines, "Defense", [
		["Health", char.health_mult, false, false],
		["Lifesteal", char.lifesteal_percent, false],
		["Regen / sec", char.regen_per_sec, false, true],
		["Regen Delay", char.regen_delay, false, true],
		["Heal on Kill", char.heal_on_kill, false, true],
	])
	return lines


func _add_stat_group(lines: PackedStringArray, title: String, stats: Array) -> void:
	var group_lines: PackedStringArray = []
	for stat in stats:
		var label: String = stat[0]
		var value: float = stat[1]
		var invert: bool = stat[2] if stat.size() > 2 else false
		var additive: bool = stat[3] if stat.size() > 3 else false
		if additive:
			if is_equal_approx(value, 0.0):
				continue
			var sign: String = "+" if value >= 0.0 else ""
			group_lines.append("  %s %s%.1f" % [label, sign, value])
		elif label == "Lifesteal":
			if is_equal_approx(value, 0.0):
				continue
			group_lines.append("  %s +%.0f%%" % [label, value * 100.0])
		else:
			if is_equal_approx(value, 1.0):
				continue
			if invert:
				var effective: float = 1.0 / maxf(value, 0.01)
				var pct: int = int(round((effective - 1.0) * 100.0))
				var sign: String = "+" if pct >= 0 else ""
				group_lines.append("  %s %s%d%%" % [label, sign, pct])
			else:
				var pct: int = int(round((value - 1.0) * 100.0))
				var sign: String = "+" if pct >= 0 else ""
				group_lines.append("  %s %s%d%%" % [label, sign, pct])
	if group_lines.size() > 0:
		lines.append("[b]%s[/b]" % title)
		lines.append_array(group_lines)

# ─────────────────────────────────────────────
#  Randomize / Confirm
# ─────────────────────────────────────────────

func _get_selected_team() -> Player.Team:
	match _team_option.selected:
		0:  return Player.Team.FFA
		1:  return Player.Team.SPI
		2:  return Player.Team.SCI
	return Player.Team.FFA


## Pick a random character and a random weapon in each column, so the menu
## doesn't always open on assault + the first weapon of each category.
func _select_random_loadout() -> void:
	var entry: Dictionary = _all_characters[randi() % _all_characters.size()]
	var char: Character = entry["char"]
	_select_character(char)
	if selected_class == null:
		return
	_randomize_column("primary", selected_class.primary_weapons)
	_randomize_column("secondary", selected_class.secondary_weapons)
	_randomize_column("melee", selected_class.melee_weapons)


func _on_randomize_once_pressed() -> void:
	if selected_class == null:
		return
	_randomize_column("primary", selected_class.primary_weapons)
	_randomize_column("secondary", selected_class.secondary_weapons)
	_randomize_column("melee", selected_class.melee_weapons)


func _randomize_column(key: String, weapons: Array[Weapon]) -> void:
	if weapons.is_empty():
		return
	var list: VBoxContainer = _column_lists.get(key)
	if list == null or list.get_child_count() == 0:
		return
	var idx := randi() % weapons.size()
	if idx >= 0 and idx < list.get_child_count():
		var card: Button = list.get_child(idx) as Button
		_select_card(card)


func _on_confirm_pressed() -> void:
	if selected_class == null or selected_character == null:
		return
	if selected_primary == null or selected_secondary == null or selected_melee == null:
		return

	var team := _get_selected_team()
	var rand_on_death := _randomize_on_death_check.button_pressed
	var character_path := selected_character.resource_path

	# Hide our canvas (don't free — user can re-open with H later).
	visible = false  # triggers _process() → _canvas.visible = false

	world.class_selected = true
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if multiplayer.is_server():
		_request_loadout(player_id, selected_primary.resource_path, selected_secondary.resource_path, selected_melee.resource_path, team, character_path, selected_class.resource_path, rand_on_death)
	else:
		_request_loadout.rpc_id(1, player_id, selected_primary.resource_path, selected_secondary.resource_path, selected_melee.resource_path, team, character_path, selected_class.resource_path, rand_on_death)

# ─────────────────────────────────────────────
#  RPCs (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _request_loadout(tpid: String, pp: String, sp: String, mp: String, team: Player.Team, cp: String = "", class_path := "", rand_on_death := false) -> void:
	if not multiplayer.is_server():
		return
	var sid := multiplayer.get_remote_sender_id()
	if sid != 0 and str(sid) != tpid and not tpid.begins_with("bot_"):
		return
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if primary == null or secondary == null or melee == null:
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	ctrl.set_weapons(nw)
	ctrl.current_weapon_index = 0
	player.team = team
	# Apply character.
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			player.set_character(char_res)
			player._loadout_character_path = cp
	# Store paths so late-joining peers can be synced.
	player._loadout_primary_path = pp
	player._loadout_secondary_path = sp
	player._loadout_melee_path = mp
	player._loadout_class_path = class_path
	player.set_randomize_on_death(rand_on_death)
	_apply_loadout.rpc(tpid, pp, sp, mp, team, cp)
	player.rpc_reset.rpc(player._get_spawn_position())

@rpc("authority", "call_remote", "reliable")
func _apply_loadout(tpid: String, pp: String, sp: String, mp: String, team: Player.Team, cp: String = "") -> void:
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if primary == null or secondary == null or melee == null:
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	ctrl.set_weapons(nw)
	ctrl.current_weapon_index = 0
	player.team = team
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			player.set_character(char_res)
			player._loadout_character_path = cp

# ─────────────────────────────────────────────
#  Mode info (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

func _populate_mode_info() -> void:
	if not _mode_label:
		return
	_mode_label.text = _get_mode_description()


func _get_mode_description() -> String:
	var gmc: GameModeComponent = GameManager.game_mode_component
	if not gmc:
		return ""
	match gmc.game_mode:
		GameModeComponent.GameMode.KOTH:
			return "King of the Hill -- Hold the point to win"
		GameModeComponent.GameMode.CONTROL:
			return "Control -- Best of 3, hold the point"
		GameModeComponent.GameMode.DOMINATION:
			return "Domination -- Hold the most points to score"
		GameModeComponent.GameMode.ESCORT:
			return "Escort -- Push the payload to the end"
		GameModeComponent.GameMode.HYBRID:
			return "Hybrid -- Capture the point, then escort"
		GameModeComponent.GameMode.DEATHMATCH:
			return "Deathmatch -- First to 20 kills wins"
		_:
			return ""
