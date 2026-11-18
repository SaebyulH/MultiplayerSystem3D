extends Control
class_name LoadoutMenuUI

## Clean, professional character-select screen: YOUR TEAM roster on the left, a
## rotating 3D agent in the centre, agent details / abilities / loadout on the
## right, and a class-grouped agent strip along the bottom.  Class is inferred
## from the selected character, so there is no separate class-selection step.
##
## A CanvasLayer added to the root viewport renders above all other UI.  The
## screen keeps one 3D preview alive for its whole lifetime and renders it only
## on change (see LoadoutPreviewRig).

## Disable the 3D character-preview SubViewport entirely.  Set to true to skip
## spawning the preview model (the separate World3D is the expensive part).
const PREVIEW_DISABLED := false

## Whether the initial random character/loadout selection has already been made.
## The menu is re-instantiated on return-to-lobby; we only want to randomize on
## the very first load, not on subsequent loads.
static var _initial_selection_done := false

const WEAPON_KEYS: Array[String] = ["primary", "secondary", "melee"]
const PREVIEW_SWAP_DELAY := 0.08

@onready var world := $"../../.."

## Emitted after a bot-edit session ends (confirm or cancel).  The dev menu
## listens and reopens itself on the Bots tab.
signal bot_edit_finished

var player_id: String

## True while this screen is retargeted at a bot (dev menu).  In this mode
## `player_id` is the bot's name, the local player's pending selection is
## snapshotted/restored around the session, and confirm never sets
## `world.class_selected` or captures the mouse.
var bot_edit_mode := false
## True while opened from the staging room.  Confirm returns to staging with the
## mouse visible instead of capturing input for gameplay.
var staging_mode := false
var _bot_name := ""
## Set while the confirm RPC is in flight so the visibility handler does not
## restore `player_id` before _request_loadout has read it.
var _bot_applying := false
var _bot_snapshot: Dictionary = {}
var available_classes: Array[Class] = []
var _char_to_class: Dictionary = {}      # character.resource_path -> Class
var _all_characters: Array[Dictionary] = []  # [{ "char": Character, "class": Class }]

# ── Selection state ─────────────────────────
var selected_class: Class = null
var selected_character: Character = null
var selected_primary: Weapon = null
var selected_secondary: Weapon = null
var selected_melee: Weapon = null

# ── Scene nodes (defined in loadout_menu.tscn) ──
@onready var _canvas: CanvasLayer = $LoadoutMenuCanvas
@onready var _title: Label = $LoadoutMenuCanvas/Root/Col/Header/Title
@onready var _mode_label: Label = $LoadoutMenuCanvas/Root/Col/Header/ModeLabel
@onready var _team_vbox: VBoxContainer = $LoadoutMenuCanvas/Root/Col/MainRow/TeamPanel/VBox
@onready var _operative_label: Label = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/OperativeLabel
@onready var _preview_svc: SubViewportContainer = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/Svc
@onready var _character_viewport: SubViewport = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/Svc/CharacterViewport
@onready var _preview_rig: LoadoutPreviewRig = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/Svc/CharacterViewport/Node3D/PreviewRig
@onready var _brackets: Control = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/Brackets
@onready var _drag_hint: Label = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/DragHint
@onready var _preview_mode_button: Button = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/PreviewModeButton
@onready var _detail_vbox: VBoxContainer = $LoadoutMenuCanvas/Root/Col/MainRow/DetailPanel/VBox
@onready var _agent_groups: HBoxContainer = $LoadoutMenuCanvas/Root/Col/MainRow/PreviewPanel/PreviewFrame/AgentStripPanel/AgentStrip/AgentGroups
@onready var _popover: WeaponPopover = $LoadoutMenuCanvas/WeaponPopover
@onready var _popover_catcher: Control = $LoadoutMenuCanvas/PopoverCatcher

# ── Detail-panel widgets (built in code) ─────
var _class_label: Label
var _hover_label: Label
var _name_label: Label
var _info_scroll: ScrollContainer
var _info_box: VBoxContainer
var _ability_row: HBoxContainer
var _ability_panel: PanelContainer
var _ability_collapse_button: Button
var _abilities_collapsed := false
var _hovered_character: Character = null
var _loadout_row: VBoxContainer
var _confirm_button: Button
var _randomize_once_button: Button
var _randomize_on_death_check: CheckBox
var _leave_party_button: Button

# ── Team panel ──────────────────────────────
var _team_list: VBoxContainer
var _team_signature := ""
var _roster_timer: Timer
var _operative_index := 1
var _operative_total := 1

# ── Agent strip ─────────────────────────────
var _agent_buttons: Dictionary = {}      # character resource_path -> Button
var _class_labels: Dictionary = {}       # class resource_path -> Label

# ── Loadout slots / abilities ───────────────
var _weapon_slots: Dictionary = {}       # key -> Button
var _weapon_slot_labels: Dictionary = {} # key -> Label
var _weapon_slot_thumbs: Dictionary = {} # key -> TextureRect
var _weapon_slot_missing: Dictionary = {} # key -> Control (shown when no icon)
var _ability_tiles: Array[Control] = []

# ── Preview / popover ───────────────────────
var _drag_button := 0
var _preview_mode := 1   # 0 standing, 1 walking, 2 running
var _bracket_lines: Array[ColorRect] = []
var _displayed_weapon: Weapon = null
var _pending_preview_weapon: Weapon = null
var _preview_timer: Timer

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	player_id = MatchSession.local_id_string()

	_style_layout()
	_build_team_panel()
	_build_detail_panel()
	_build_ability_overlay()
	_style_action_buttons()
	_build_bracket_lines()
	_setup_preview()
	_setup_popover()
	_preview_rig.set_active(visible)

	if PREVIEW_DISABLED:
		_preview_svc.visible = false
		_character_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# Sync canvas visibility immediately (menu starts visible, matching self.visible).
	_canvas.visible = visible
	visibility_changed.connect(_on_visibility_changed)

	# Load classes
	var loaded_classes: Array[Class] = []
	for path in LoadoutProfile.CLASS_PATHS:
		var c := load(path) as Class
		if c:
			loaded_classes.append(c)
	load_classes(loaded_classes)

	_build_agent_strip()
	_build_icon_credit()
	_populate_mode_info.call_deferred()

	_confirm_button.pressed.connect(_on_confirm_pressed)
	_randomize_once_button.pressed.connect(_on_randomize_once_pressed)
	_leave_party_button.pressed.connect(_on_leave_party_pressed)

	# Populate the menu.  A stored process build wins; otherwise the first load
	# rolls once and later loads fall back to the first character.
	if not _restore_saved_build() and not _all_characters.is_empty():
		if not _initial_selection_done:
			_initial_selection_done = true
			_select_random_loadout()
		else:
			_select_character(_all_characters[0]["char"])

	_refresh_team_list()
	_roster_timer.start()

	# A match-server join assigns the stable player id in `welcome`, which lands
	# after this menu's `_ready`.  Without this the confirm RPC would carry the
	# transport peer id and the server's ownership check would reject it.
	if not MatchSession.welcomed.is_connected(_on_match_welcomed):
		MatchSession.welcomed.connect(_on_match_welcomed)

	# Test hook for headless/automated cross-process runs: confirm the initial
	# random loadout so the player actually spawns without a mouse.  Never runs
	# on a dedicated server, which has no local player.
	if not NetworkManager.is_dedicated_server() and "--auto-loadout" in OS.get_cmdline_user_args():
		_auto_confirm_when_ready.call_deferred()


func _style_layout() -> void:
	_title.add_theme_font_override("font", UITheme.FONT_DISPLAY)
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", UITheme.TEXT)

	_mode_label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	_mode_label.add_theme_color_override("font_color", UITheme.MUTED)

	_operative_label.add_theme_font_override("font", UITheme.FONT_MEDIUM)
	_operative_label.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_operative_label.add_theme_color_override("font_color", UITheme.MUTED)

	_drag_hint.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_drag_hint.add_theme_color_override("font_color", UITheme.DIM_TEXT)

	_preview_mode_button.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_preview_mode_button.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.SECONDARY))
	_preview_mode_button.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.SECONDARY, true))
	_preview_mode_button.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.SECONDARY, false, true))
	_update_preview_mode_label()

	var team_panel := _team_vbox.get_parent() as PanelContainer
	if team_panel:
		team_panel.add_theme_stylebox_override("panel", UITheme.panel_style(
			Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.86),
			UITheme.LINE, 1, 12))
	var detail_panel := _detail_vbox.get_parent() as PanelContainer
	if detail_panel:
		detail_panel.add_theme_stylebox_override("panel", UITheme.panel_style(
			Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.9),
			UITheme.LINE, 1, 16))


func _style_action_buttons() -> void:
	_confirm_button.add_theme_font_override("font", UITheme.FONT_EXTRABOLD)
	_confirm_button.add_theme_font_size_override("font_size", 18)
	_confirm_button.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.PRIMARY))
	_confirm_button.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.PRIMARY, true))
	_confirm_button.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.PRIMARY, false, true))
	_confirm_button.add_theme_stylebox_override("disabled", UITheme.button_style(UITheme.Kind.DISABLED))

	_randomize_once_button.add_theme_font_size_override("font_size", 13)
	_randomize_once_button.add_theme_stylebox_override("normal", UITheme.button_style(UITheme.Kind.SECONDARY))
	_randomize_once_button.add_theme_stylebox_override("hover", UITheme.button_style(UITheme.Kind.SECONDARY, true))
	_randomize_once_button.add_theme_stylebox_override("pressed", UITheme.button_style(UITheme.Kind.SECONDARY, false, true))

	# Danger as an outline, not a fill: LOCK IN is the screen's only filled RED
	# element (DESIGN_STYLE_GUIDE §2).
	_leave_party_button.add_theme_font_size_override("font_size", 13)
	_leave_party_button.add_theme_stylebox_override("normal", _danger_outline(false))
	_leave_party_button.add_theme_stylebox_override("hover", _danger_outline(true))
	_leave_party_button.add_theme_stylebox_override("pressed", _danger_outline(true))


func _danger_outline(hover: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	s.bg_color = Color(UITheme.RED.r, UITheme.RED.g, UITheme.RED.b, 0.12 if hover else 0.0)
	s.border_color = UITheme.RED
	s.set_border_width_all(1)
	return s


## Restore the process-local build saved by the title flow or a previous confirm.
func _restore_saved_build() -> bool:
	var build: Dictionary = GameManager.local_loadout
	if not LoadoutProfile.is_valid(build):
		return false
	var char_res := load(str(build.get("character_path", ""))) as Character
	if char_res == null:
		return false
	_initial_selection_done = true
	_select_character(char_res)
	_select_card_matching("primary", load(str(build.get("primary_path", ""))) as Weapon)
	_select_card_matching("secondary", load(str(build.get("secondary_path", ""))) as Weapon)
	_select_card_matching("melee", load(str(build.get("melee_path", ""))) as Weapon)
	_randomize_on_death_check.button_pressed = bool(build.get("randomize_on_death", false))
	_set_displayed_weapon(selected_primary)
	return true


func _on_match_welcomed(_info: Dictionary) -> void:
	if not bot_edit_mode:
		player_id = MatchSession.local_id_string()


## Headless test hook.  The loadout RPC must not be sent until the stable player
## id has arrived *and* the replicated Player node exists on this client;
## otherwise the server's effect-sync RPCs address a node that is not there yet
## (docs/05-known-issues.md #124).
func _auto_confirm_when_ready() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		var local := MatchSession.local_id_string()
		if MatchSession.local_player_id > 0 and GameManager.find_player(local) != null:
			break
		await get_tree().process_frame
	if not bot_edit_mode:
		player_id = MatchSession.local_id_string()
	_on_confirm_pressed()


## Credit for the ability icons, tucked into the bottom-right corner.  The
## game-icons.net set is CC BY 3.0, so the attribution has to be visible in the
## build, not just in a licence file — see docs/05-known-issues.md #56.
##
## Built in code rather than in loadout_menu.tscn because it is decoration with no
## references: nothing needs to find it by node path.  Parented to the CanvasLayer
## rather than to `Root`, which is a MarginContainer and would stretch this label
## across its whole margin rect instead of letting it hug the corner.
func _build_icon_credit() -> void:
	var credit := Label.new()
	credit.text = "Icons: game-icons.net (CC BY 3.0)"
	credit.add_theme_color_override("font_color", Color(0.62, 0.62, 0.62, 0.85))
	credit.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	credit.add_theme_constant_override("outline_size", 3)
	credit.add_theme_font_size_override("font_size", 11)
	credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(credit)
	# Added before the preset is applied: BOTTOM_RIGHT/MINSIZE derives its offsets
	# from the parent's anchorable rect, which is the viewport size — zero until
	# this label is in the tree, which would park it off-screen.
	credit.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 8)


## Staging opens this screen above its own CanvasLayer (staging is layer 5).
func set_staging_mode(on: bool) -> void:
	staging_mode = on
	if _canvas:
		_canvas.layer = 8 if on else 2


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
	if _canvas.visible != visible:
		_canvas.visible = visible
	if visible:
		_refresh_team_list()
		_refresh_agent_selection()
		if _roster_timer:
			_roster_timer.start()
		if _preview_rig:
			_preview_rig.set_active(true)
			_preview_rig.render_once()
	else:
		if _roster_timer:
			_roster_timer.stop()
		if _preview_rig:
			_preview_rig.set_active(false)
		_close_weapon_popover()
	# Bot-edit mode is cancelled by hiding the screen (Esc / H / the dev menu
	# closing).  `_bot_applying` suppresses this during confirm, where the hide
	# happens before the loadout RPC reads player_id.
	if not visible and bot_edit_mode and not _bot_applying:
		_finish_bot_edit()
	if OS.is_debug_build():
		print("[DEBUG] loadout menu %s" % ("opened" if visible else "closed"))


# ─────────────────────────────────────────────
#  Bot editing (dev menu)
# ─────────────────────────────────────────────

## Retarget this screen at [param bot_name].  Reuses the single menu instance:
## a second copy would create another SubViewport with its own World3D, which is
## the expensive part this menu deliberately keeps alive between opens.
func open_for_bot(bot_name: String) -> bool:
	if bot_edit_mode:
		return false
	var bot := GameManager.find_player(bot_name)
	if bot == null or not bot.is_bot:
		return false
	_bot_name = bot_name
	_bot_applying = false
	_snapshot_local_selection()
	bot_edit_mode = true
	player_id = bot_name
	_leave_party_button.visible = false
	_randomize_on_death_check.visible = false
	_mode_label.text = "EDITING BOT: %s" % bot_name
	_confirm_button.text = "APPLY TO BOT"
	_select_character(bot.get_character())
	_select_bot_weapons(bot)
	_set_displayed_weapon(selected_primary)
	visible = true
	PlayerInput.ui_open = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	return true


func _snapshot_local_selection() -> void:
	# Store the resources, not nodes: _select_character() rebuilds the slots.
	_bot_snapshot = {
		"character": selected_character,
		"primary": selected_primary,
		"secondary": selected_secondary,
		"melee": selected_melee,
		"randomize_on_death": _randomize_on_death_check.button_pressed,
	}


func _select_bot_weapons(bot: Player) -> void:
	var weapons: Array[Weapon] = []
	if bot.weapon_controller:
		weapons = bot.weapon_controller.get_weapons()
	for i in mini(weapons.size(), WEAPON_KEYS.size()):
		_select_card_matching(WEAPON_KEYS[i], weapons[i])


## Select the slot in [param key] that shows [param weapon].  Bot weapons are
## deep copies, so match their resource path when they have one and fall back to
## the display name.
func _select_card_matching(key: String, weapon: Weapon) -> bool:
	if weapon == null or selected_class == null:
		return false
	for candidate in _weapons_for(key):
		if candidate.resource_path != "" and candidate.resource_path == weapon.resource_path:
			_apply_weapon_selection(key, candidate, false)
			return true
	for candidate in _weapons_for(key):
		if candidate.display_name == weapon.display_name:
			_apply_weapon_selection(key, candidate, false)
			return true
	return false


## Leave bot-edit mode and restore the local player's pending selection.
func _finish_bot_edit() -> void:
	if not bot_edit_mode:
		return
	var snap := _bot_snapshot
	bot_edit_mode = false
	_bot_applying = false
	_bot_name = ""
	player_id = MatchSession.local_id_string()
	_leave_party_button.visible = true
	_randomize_on_death_check.visible = true
	_mode_label.text = _get_mode_description()
	_confirm_button.text = "LOCK IN"

	var ch: Character = snap.get("character", null)
	if ch:
		_select_character(ch)
		_select_card_matching("primary", snap.get("primary", null) as Weapon)
		_select_card_matching("secondary", snap.get("secondary", null) as Weapon)
		_select_card_matching("melee", snap.get("melee", null) as Weapon)
	_randomize_on_death_check.button_pressed = bool(snap.get("randomize_on_death", false))
	_bot_snapshot = {}
	_set_displayed_weapon(selected_primary)
	bot_edit_finished.emit()


func _on_leave_party_pressed() -> void:
	_canvas.queue_free()
	NetworkManager.return_to_lobby()


# ─────────────────────────────────────────────
#  Team panel
# ─────────────────────────────────────────────

func _build_team_panel() -> void:
	_team_vbox.add_child(UITheme.display_label("YOUR TEAM", 24, UITheme.TEXT))
	_team_vbox.add_child(UITheme.accent_bar(UITheme.LINE, 1))

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_team_vbox.add_child(scroll)

	_team_list = VBoxContainer.new()
	_team_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_team_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_team_list)

	_roster_timer = Timer.new()
	_roster_timer.wait_time = 1.0
	_roster_timer.timeout.connect(_refresh_team_list)
	add_child(_roster_timer)


func _refresh_team_list() -> void:
	if _team_list == null or not is_instance_valid(GameManager.spawn_parent):
		return
	var local_id := MatchSession.local_id_string()
	var local := GameManager.find_player(local_id)
	var players: Array[Player] = []
	for child in GameManager.spawn_parent.get_children():
		if not child is Player:
			continue
		var p := child as Player
		if p.is_practice_target:
			continue
		# "Your team": in a team match the roster is the local player's team;
		# in FFA (or before a team exists) everyone is your opponent.
		if local != null and local.team != Player.Team.FFA and p.team != local.team \
				and str(p.name) != local_id:
			continue
		players.append(p)
	players.sort_custom(func(a: Player, b: Player) -> bool:
		var a_local := str(a.name) == local_id
		var b_local := str(b.name) == local_id
		if a_local != b_local:
			return a_local
		if a.is_bot != b.is_bot:
			return not a.is_bot
		return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)

	_operative_index = 1
	for i in players.size():
		if str(players[i].name) == local_id:
			_operative_index = i + 1
			break
	_operative_total = maxi(players.size(), 1)
	_update_operative_label()

	var parts: PackedStringArray = []
	for p in players:
		parts.append("%s|%d|%s|%s|%s" % [p.name, p.team, p.is_bot,
			p._loadout_character_path,
			selected_character.resource_path if p.name == local_id and selected_character else ""])
	var signature := "\n".join(parts)
	if signature == _team_signature:
		return
	_team_signature = signature

	for child in _team_list.get_children():
		_team_list.remove_child(child)
		child.queue_free()
	if players.is_empty():
		var empty := UITheme.body_label("— NO PLAYERS —", UITheme.FS_MICRO, UITheme.DIM_TEXT)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.custom_minimum_size = Vector2(0, 30)
		_team_list.add_child(empty)
		return
	for p in players:
		_team_list.add_child(_make_team_row(p, str(p.name) == local_id))


func _make_team_row(p: Player, is_local: bool) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.card_style(UITheme.State.SELECTED if is_local else UITheme.State.NORMAL))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)

	var accent := ColorRect.new()
	accent.color = UITheme.TEAL if is_local else UITheme.team_color(p.team)
	accent.custom_minimum_size = Vector2(3, 0)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(accent)

	var char_res: Character = selected_character if is_local else UITheme.player_character(p)
	var portrait := TextureRect.new()
	portrait.custom_minimum_size = Vector2(40, 40)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.texture = char_res.portrait if char_res else null
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(portrait)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)

	var name_label := UITheme.body_label(str(p.name), UITheme.FS_SMALL, UITheme.TEXT)
	name_label.add_theme_font_override("font", UITheme.FONT_BOLD)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_label)

	var char_label := UITheme.body_label(
		char_res.character_name if char_res else "—", UITheme.FS_MICRO, UITheme.MUTED)
	char_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(char_label)

	var tag := ""
	var tag_color := UITheme.MUTED
	if is_local:
		tag = "YOU"
		tag_color = UITheme.TEAL
	elif MatchSession.is_player_host(str(p.name).to_int()):
		tag = "HOST"
	if tag != "":
		var tag_label := UITheme.body_label(tag, UITheme.FS_MICRO, tag_color)
		tag_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(tag_label)
	return panel


func _update_operative_label() -> void:
	if _operative_label:
		_operative_label.text = "OPERATIVE %02d / %02d" % [_operative_index, _operative_total]


# ─────────────────────────────────────────────
#  Detail panel
# ─────────────────────────────────────────────

func _build_detail_panel() -> void:
	# Shown only while hovering an agent card that is not the current pick.
	_hover_label = UITheme.section_label("SWITCHING TO", UITheme.TEAL)
	_hover_label.add_theme_font_size_override("font_size", 10)
	_hover_label.visible = false
	_detail_vbox.add_child(_hover_label)

	# Fixed-height name block: a long name changes the font size, never the
	# panel layout (the label is clipped to this rect).
	_name_label = UITheme.display_label("—", 56, UITheme.TEXT)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.custom_minimum_size = Vector2(0, 64)
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail_vbox.add_child(_name_label)

	_class_label = UITheme.section_label("AGENT", UITheme.TEAL)
	_class_label.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_class_label.custom_minimum_size = Vector2(0, 14)
	_detail_vbox.add_child(_class_label)

	# The infographic owns all remaining vertical space; loadout and the action
	# stack sit at the bottom of the panel, abilities float over the preview.
	_info_scroll = ScrollContainer.new()
	_info_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_info_scroll.custom_minimum_size = Vector2(0, 160)
	_info_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_vbox.add_child(_info_scroll)

	_info_box = VBoxContainer.new()
	_info_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_box.add_theme_constant_override("separation", 8)
	_info_scroll.add_child(_info_box)

	_detail_vbox.add_child(UITheme.section_label("LOADOUT", UITheme.MUTED))
	_loadout_row = VBoxContainer.new()
	_loadout_row.add_theme_constant_override("separation", 8)
	_detail_vbox.add_child(_loadout_row)

	_confirm_button = Button.new()
	_confirm_button.text = "LOCK IN"
	_confirm_button.custom_minimum_size = Vector2(0, 48)
	_confirm_button.focus_mode = Control.FOCUS_NONE
	_confirm_button.disabled = true
	_detail_vbox.add_child(_confirm_button)

	var randomize_row := HBoxContainer.new()
	randomize_row.add_theme_constant_override("separation", 12)
	_detail_vbox.add_child(randomize_row)

	_randomize_once_button = Button.new()
	_randomize_once_button.text = "RANDOMIZE"
	_randomize_once_button.focus_mode = Control.FOCUS_NONE
	randomize_row.add_child(_randomize_once_button)

	_randomize_on_death_check = CheckBox.new()
	_randomize_on_death_check.text = "Randomize on death"
	_randomize_on_death_check.focus_mode = Control.FOCUS_NONE
	_randomize_on_death_check.add_theme_color_override("font_color", UITheme.MUTED)
	_randomize_on_death_check.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	randomize_row.add_child(_randomize_on_death_check)

	_leave_party_button = Button.new()
	_leave_party_button.text = "LEAVE PARTY"
	_leave_party_button.custom_minimum_size = Vector2(0, 36)
	_leave_party_button.focus_mode = Control.FOCUS_NONE
	_detail_vbox.add_child(_leave_party_button)


## Ability discs float over the bottom of the preview (above the agent strip)
## so they cost the detail panel no vertical space.  Collapsible.
const ABILITY_PANEL_HEIGHT := 124.0
const ABILITY_PANEL_COLLAPSED := 40.0


func _build_ability_overlay() -> void:
	var frame := _preview_svc.get_parent() as Control
	if frame == null:
		return
	_ability_panel = PanelContainer.new()
	_ability_panel.add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(UITheme.INK_2.r, UITheme.INK_2.g, UITheme.INK_2.b, 0.82),
		UITheme.LINE, 1, 8))
	_ability_panel.anchor_left = 0.0
	_ability_panel.anchor_right = 1.0
	_ability_panel.anchor_top = 1.0
	_ability_panel.anchor_bottom = 1.0
	_ability_panel.offset_left = 0.0
	_ability_panel.offset_right = 0.0
	_ability_panel.offset_bottom = -180.0
	_ability_panel.offset_top = -180.0 - ABILITY_PANEL_HEIGHT
	frame.add_child(_ability_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_ability_panel.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vb.add_child(header)
	header.add_child(UITheme.section_label("ABILITIES", UITheme.MUTED))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_ability_collapse_button = Button.new()
	_ability_collapse_button.text = "▾"
	_ability_collapse_button.custom_minimum_size = Vector2(30, 0)
	_ability_collapse_button.focus_mode = Control.FOCUS_NONE
	_ability_collapse_button.add_theme_font_size_override("font_size", 12)
	_ability_collapse_button.pressed.connect(_on_ability_collapse_pressed)
	header.add_child(_ability_collapse_button)

	_ability_row = HBoxContainer.new()
	_ability_row.add_theme_constant_override("separation", 8)
	_ability_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_ability_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_ability_row)
	_set_abilities_collapsed(false)


func _on_ability_collapse_pressed() -> void:
	_set_abilities_collapsed(not _abilities_collapsed)


func _set_abilities_collapsed(collapsed: bool) -> void:
	_abilities_collapsed = collapsed
	if _ability_row:
		_ability_row.visible = not collapsed
	if _ability_panel:
		var height := ABILITY_PANEL_COLLAPSED if collapsed else ABILITY_PANEL_HEIGHT
		_ability_panel.offset_top = _ability_panel.offset_bottom - height
	if _ability_collapse_button:
		_ability_collapse_button.text = "▸" if collapsed else "▾"


func _update_detail_header() -> void:
	if _class_label:
		_class_label.text = selected_class.class_display_name.to_upper() if selected_class else "AGENT"
	if _name_label:
		_set_name_text(selected_character.character_name if selected_character else "—")
	if _hover_label:
		_hover_label.visible = false


## Long names shrink instead of reflowing the panel: the block height is fixed.
func _set_name_text(text: String) -> void:
	if _name_label == null:
		return
	_name_label.text = text.to_upper()
	var length := _name_label.text.length()
	var size := 56
	if length > 9:
		size = 48
	if length > 13:
		size = 40
	if length > 17:
		size = 34
	if length > 22:
		size = 28
	_name_label.add_theme_font_size_override("font_size", size)


# ─────────────────────────────────────────────
#  Agent strip
# ─────────────────────────────────────────────

func _build_agent_strip() -> void:
	for entry in UITheme.characters_by_class():
		var cls: Class = entry.get("class", null)
		var characters: Array = entry.get("characters", [])
		if cls == null or characters.is_empty():
			continue
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 6)
		group.alignment = BoxContainer.ALIGNMENT_CENTER
		_agent_groups.add_child(group)

		var header := UITheme.section_label(cls.class_display_name, UITheme.MUTED)
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		group.add_child(header)
		_class_labels[cls.resource_path] = header

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		group.add_child(row)

		for char_res in characters:
			var char := char_res as Character
			if char == null:
				continue
			row.add_child(_make_agent_card(char, cls))


func _make_agent_card(char: Character, cls: Class) -> Button:
	var btn := UITheme.character_card(char, cls, "normal", Vector2(92, 124))
	btn.mouse_entered.connect(_on_agent_card_hover.bind(char))
	btn.mouse_exited.connect(_on_agent_card_unhover)
	btn.pressed.connect(_on_agent_card_pressed.bind(char))
	_agent_buttons[char.resource_path] = btn
	return btn


func _refresh_agent_selection() -> void:
	var selected_path := selected_character.resource_path if selected_character else ""
	for path in _agent_buttons:
		var btn: Button = _agent_buttons[path]
		var is_selected: bool = path == selected_path
		btn.add_theme_stylebox_override("normal", UITheme.card_style(
			UITheme.State.SELECTED if is_selected else UITheme.State.NORMAL))
		btn.add_theme_stylebox_override("hover", UITheme.card_style(
			UITheme.State.SELECTED if is_selected else UITheme.State.HOVER))
		btn.add_theme_stylebox_override("pressed", UITheme.card_style(UITheme.State.SELECTED))
	for path in _class_labels:
		var label: Label = _class_labels[path]
		var is_selected_class: bool = selected_class != null and path == selected_class.resource_path
		label.add_theme_color_override("font_color",
			UITheme.TEAL if is_selected_class else UITheme.MUTED)


## Hover previews the agent in the detail panel ("SWITCHING TO …") without
## committing the pick; the card still applies it on click.
func _on_agent_card_hover(char: Character) -> void:
	_show_character_info(char)
	if _name_label == null or char == null:
		return
	var hovering_other := char != selected_character
	_hover_label.visible = hovering_other
	if _class_label:
		var cls := _char_to_class.get(char.resource_path) as Class
		_class_label.text = cls.class_display_name.to_upper() if cls else "AGENT"
	_set_name_text(char.character_name)

	# Ghost the hovered agent in the preview to show it is not selected yet.
	# The weapon must belong to the hovered agent's class, not the previous
	# preview's class.
	if char != selected_character and char != _hovered_character:
		_hovered_character = char
		if _preview_rig:
			_preview_rig.show_character(char, _weapon_for_character(char), true)


## Keep the displayed weapon if the target class offers it; otherwise take that
## class's first primary so a ghost never holds the previous agent's gun.
func _weapon_for_character(char: Character) -> Weapon:
	var cls := _char_to_class.get(char.resource_path) as Class
	if cls == null:
		return _displayed_weapon
	if _displayed_weapon != null:
		for weapons in [cls.primary_weapons, cls.secondary_weapons, cls.melee_weapons]:
			for weapon in weapons:
				if weapon == _displayed_weapon:
					return weapon
				if weapon.resource_path != "" \
						and weapon.resource_path == _displayed_weapon.resource_path:
					return weapon
	if not cls.primary_weapons.is_empty():
		return cls.primary_weapons[0]
	return _displayed_weapon


func _on_agent_card_unhover() -> void:
	_update_detail_header()
	if selected_character:
		_show_character_info(selected_character)
	if _hovered_character != null:
		_hovered_character = null
		if _preview_rig and selected_character:
			_preview_rig.show_character(selected_character, _displayed_weapon, false)


func _on_agent_card_pressed(char: Character) -> void:
	_select_character(char)


# ─────────────────────────────────────────────
#  Loadout slots
# ─────────────────────────────────────────────

func _build_loadout_slots() -> void:
	for child in _loadout_row.get_children():
		_loadout_row.remove_child(child)
		child.queue_free()
	_weapon_slots.clear()
	_weapon_slot_labels.clear()
	_weapon_slot_thumbs.clear()
	_weapon_slot_missing.clear()
	for key in WEAPON_KEYS:
		var slot := Button.new()
		slot.custom_minimum_size = Vector2(0, 86)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.focus_mode = Control.FOCUS_NONE
		slot.add_theme_stylebox_override("normal", UITheme.card_style(UITheme.State.NORMAL))
		slot.add_theme_stylebox_override("hover", UITheme.card_style(UITheme.State.HOVER))
		slot.add_theme_stylebox_override("pressed", UITheme.card_style(UITheme.State.SELECTED))
		slot.pressed.connect(_on_weapon_slot_pressed.bind(key, slot))
		slot.mouse_entered.connect(_on_weapon_slot_hover.bind(key))
		slot.mouse_exited.connect(_on_weapon_slot_unhover)
		_loadout_row.add_child(slot)

		var content := HBoxContainer.new()
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_theme_constant_override("separation", 8)
		content.set_anchors_and_offsets_preset(
			Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
		slot.add_child(content)

		# Killfeed thumbnail, same 16:9 silhouette art the old weapon cards drew.
		var thumb := TextureRect.new()
		thumb.custom_minimum_size = Vector2(112, 63)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(thumb)
		_weapon_slot_thumbs[key] = thumb

		var missing := ColorRect.new()
		missing.color = Color(UITheme.SLATE.r, UITheme.SLATE.g, UITheme.SLATE.b, 0.8)
		missing.custom_minimum_size = Vector2(112, 63)
		missing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(missing)
		_weapon_slot_missing[key] = missing

		var text_col := VBoxContainer.new()
		text_col.add_theme_constant_override("separation", 2)
		text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(text_col)

		var caption := UITheme.section_label(key, UITheme.MUTED)
		caption.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_col.add_child(caption)

		var name_label := UITheme.body_label("—", 14, UITheme.TEXT)
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_col.add_child(name_label)

		_weapon_slots[key] = slot
		_weapon_slot_labels[key] = name_label


## Re-pick each slot from the selected class, keeping the previous weapon when
## the new class still offers it.
func _rebuild_loadout_slots() -> void:
	var previous := {
		"primary": selected_primary,
		"secondary": selected_secondary,
		"melee": selected_melee,
	}
	selected_primary = _pick_weapon(_weapons_for("primary"), previous["primary"] as Weapon)
	selected_secondary = _pick_weapon(_weapons_for("secondary"), previous["secondary"] as Weapon)
	selected_melee = _pick_weapon(_weapons_for("melee"), previous["melee"] as Weapon)
	for key in WEAPON_KEYS:
		_update_weapon_slot_label(key)


func _pick_weapon(weapons: Array[Weapon], previous: Weapon) -> Weapon:
	if weapons.is_empty():
		return null
	if previous != null:
		for weapon in weapons:
			if weapon == previous or (previous.resource_path != "" \
					and weapon.resource_path == previous.resource_path):
				return weapon
	return weapons[0]


func _weapons_for(key: String) -> Array[Weapon]:
	if selected_class == null:
		return []
	match key:
		"primary":
			return selected_class.primary_weapons
		"secondary":
			return selected_class.secondary_weapons
		"melee":
			return selected_class.melee_weapons
	return []


func _selected_weapon_for(key: String) -> Weapon:
	match key:
		"primary":
			return selected_primary
		"secondary":
			return selected_secondary
		"melee":
			return selected_melee
	return null


func _apply_weapon_selection(key: String, weapon: Weapon, preview := true) -> void:
	match key:
		"primary":
			selected_primary = weapon
		"secondary":
			selected_secondary = weapon
		"melee":
			selected_melee = weapon
	_update_weapon_slot_label(key)
	if _popover and _popover.is_open():
		_popover.set_selected(weapon)
	if preview:
		_set_displayed_weapon(weapon)


func _update_weapon_slot_label(key: String) -> void:
	var label: Label = _weapon_slot_labels.get(key)
	if label == null:
		return
	var weapon := _selected_weapon_for(key)
	label.text = weapon.display_name if weapon else "—"

	var thumb: TextureRect = _weapon_slot_thumbs.get(key)
	var missing: Control = _weapon_slot_missing.get(key)
	var icon: Texture2D = weapon.killfeed_icon if weapon else null
	if thumb:
		thumb.texture = icon
		thumb.visible = icon != null
	if missing:
		missing.visible = icon == null

	var slot: Button = _weapon_slots.get(key)
	if slot:
		slot.tooltip_text = label.text


func _on_weapon_slot_pressed(key: String, slot: Button) -> void:
	_open_weapon_popover(key, slot)


func _on_weapon_slot_hover(key: String) -> void:
	var weapon := _selected_weapon_for(key)
	if weapon:
		_show_weapon_info(weapon)
		_set_displayed_weapon(weapon)


func _on_weapon_slot_unhover() -> void:
	if selected_character:
		_show_character_info(selected_character)


# ─────────────────────────────────────────────
#  Weapon popover
# ─────────────────────────────────────────────

func _setup_popover() -> void:
	_popover.weapon_hovered.connect(_on_popover_weapon_hovered)
	_popover.weapon_selected.connect(_on_popover_weapon_selected)
	_popover_catcher.gui_input.connect(_on_popover_catcher_input)

	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = PREVIEW_SWAP_DELAY
	_preview_timer.timeout.connect(_flush_pending_preview_weapon)
	add_child(_preview_timer)


func _input(event: InputEvent) -> void:
	if _popover == null or not _popover.is_open() or not is_visible_in_tree():
		return
	if event.is_action_pressed("ui_cancel"):
		_close_weapon_popover()
		get_viewport().set_input_as_handled()


func _open_weapon_popover(key: String, slot: Button) -> void:
	var weapons := _weapons_for(key)
	if weapons.is_empty():
		return
	_popover.open_for(key, weapons, _selected_weapon_for(key))
	_popover.position_near(slot)
	_popover_catcher.visible = true
	_popover.move_to_front()


func _close_weapon_popover() -> void:
	if _preview_timer and not _preview_timer.is_stopped():
		_preview_timer.stop()
		_flush_pending_preview_weapon()
	if _popover_catcher:
		_popover_catcher.visible = false
	if _popover:
		_popover.close()


func _on_popover_catcher_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_close_weapon_popover()


func _on_popover_weapon_hovered(weapon: Weapon, _key: String) -> void:
	if weapon == null:
		return
	_show_weapon_info(weapon)
	_pending_preview_weapon = weapon
	_preview_timer.start()


func _on_popover_weapon_selected(weapon: Weapon, key: String) -> void:
	_apply_weapon_selection(key, weapon, true)
	_close_weapon_popover()


func _flush_pending_preview_weapon() -> void:
	if _pending_preview_weapon == null:
		return
	_set_displayed_weapon(_pending_preview_weapon)
	_pending_preview_weapon = null


## Put [param weapon] in the preview model's hand.  The last shown weapon stays
## until the next call, so leaving a row or closing the popover never reverts it.
func _set_displayed_weapon(weapon: Weapon) -> void:
	_displayed_weapon = weapon
	if PREVIEW_DISABLED or _preview_rig == null:
		return
	_preview_rig.set_weapon(weapon)


# ─────────────────────────────────────────────
#  Ability tiles
# ─────────────────────────────────────────────

func _make_ability_tile(index: int, ability: Ability) -> Control:
	var tile := VBoxContainer.new()
	tile.add_theme_constant_override("separation", 4)
	tile.custom_minimum_size = Vector2(108, 0)
	tile.set_meta("ability", ability)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(108, 96)
	# The hover handler reads the meta off the box, not the tile row.
	box.set_meta("ability", ability)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	box.add_theme_stylebox_override("panel", UITheme.card_style(
		UITheme.State.DISABLED if ability == null else UITheme.State.NORMAL))
	box.mouse_entered.connect(_on_ability_hover.bind(box, true))
	box.mouse_exited.connect(_on_ability_hover.bind(box, false))
	tile.add_child(box)

	var body := VBoxContainer.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", 2)
	box.add_child(body)

	var number := UITheme.body_label(str(index + 1), UITheme.FS_MICRO, UITheme.MUTED)
	number.add_theme_font_override("font", UITheme.FONT_BOLD)
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(number)

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(center)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(44, 44)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = ability.icon if ability else null
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(icon)

	var name_label := UITheme.body_label(
		ability.ability_name if ability else "—", UITheme.FS_MICRO,
		UITheme.MUTED if ability else UITheme.DIM_TEXT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(name_label)
	return tile


func _on_ability_hover(box: PanelContainer, entered: bool) -> void:
	var ability: Ability = box.get_meta("ability")
	box.add_theme_stylebox_override("panel", UITheme.card_style(
		UITheme.State.HOVER if entered and ability != null
		else (UITheme.State.DISABLED if ability == null else UITheme.State.NORMAL)))
	if not entered:
		if selected_character:
			_show_character_info(selected_character)
		return
	if ability:
		_show_ability_info(ability)
	else:
		_show_info("Unassigned", "No ability is assigned to this slot.")


func _refresh_ability_tiles() -> void:
	if _ability_row == null:
		return
	for child in _ability_row.get_children():
		_ability_row.remove_child(child)
		child.queue_free()
	_ability_tiles.clear()
	for i in 4:
		var ability: Ability = null
		if selected_character and i < selected_character.abilities.size():
			ability = selected_character.abilities[i]
		var tile := _make_ability_tile(i, ability)
		_ability_row.add_child(tile)
		_ability_tiles.append(tile)


# ─────────────────────────────────────────────
#  Info panel
# ─────────────────────────────────────────────

## The info panel is an infographic, not a text dump: description, trait
## badges and pip bars on the same dark surface, in the theme's accent colours.

func _clear_info() -> void:
	if _info_box == null:
		return
	for child in _info_box.get_children():
		_info_box.remove_child(child)
		child.queue_free()


func _info_title(text: String) -> void:
	if _info_box == null:
		return
	var label := UITheme.body_label(text, 18, UITheme.TEXT)
	label.add_theme_font_override("font", UITheme.FONT_SEMIBOLD)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_box.add_child(label)


func _info_section(text: String) -> void:
	if _info_box == null:
		return
	var label := UITheme.section_label(text, UITheme.MUTED)
	label.add_theme_font_size_override("font_size", UITheme.FS_MICRO)
	_info_box.add_child(label)


func _info_body(text: String) -> void:
	if _info_box == null or text.is_empty():
		return
	var label := UITheme.body_label(text, UITheme.FS_SMALL, Color(0.82, 0.84, 0.86, 1))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_box.add_child(label)


func _info_chips(items: Array) -> void:
	if _info_box == null or items.is_empty():
		return
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	for item in items:
		flow.add_child(UITheme.badge(str(item[0]), item[1]))
	_info_box.add_child(flow)


func _stat_color(mult: float) -> Color:
	if mult > 1.02:
		return UITheme.TEAL
	if mult < 0.98:
		return UITheme.AMBER
	return UITheme.MUTED


func _stat_text(mult: float) -> String:
	var pct := int(round((mult - 1.0) * 100.0))
	if pct == 0:
		return "BASE"
	return ("+%d%%" % pct) if pct > 0 else ("%d%%" % pct)


## Label + signed value + a 20-pip bar on a 0.5x..1.5x scale (base = half full).
func _make_stat_bar(label_text: String, mult: float) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)

	var head := HBoxContainer.new()
	var name_label := UITheme.body_label(label_text, UITheme.FS_MICRO, UITheme.MUTED)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	var value := UITheme.body_label(_stat_text(mult), UITheme.FS_SMALL, _stat_color(mult))
	value.add_theme_font_override("font", UITheme.FONT_BOLD)
	head.add_child(value)
	row.add_child(head)

	const PIPS := 20
	var filled := int(round(clampf((mult - 0.5) / 1.0, 0.0, 1.0) * PIPS))
	var fill_color := _stat_color(mult)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	for i in PIPS:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(0, 7)
		pip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.color = fill_color if i < filled else Color(UITheme.LINE.r, UITheme.LINE.g, UITheme.LINE.b, 0.35)
		bar.add_child(pip)
	row.add_child(bar)
	return row


func _show_info(title: String, body: String) -> void:
	_clear_info()
	if title != "":
		_info_title(title)
	_info_body(body)


func _show_weapon_info(weapon: Weapon) -> void:
	if weapon == null or _info_box == null:
		return
	_clear_info()
	_info_title(weapon.display_name)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(150, 84)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = weapon.killfeed_icon
	if icon.texture != null:
		_info_box.add_child(icon)

	_info_section("WEAPON")
	for fire in weapon.weapon_fires:
		if fire.action_type != WeaponFire.ActionType.SHOOT:
			continue
		if fire.bullet_type == WeaponFire.BulletType.HITSCAN:
			_info_box.add_child(UITheme.stat_row("DAMAGE", str(fire.hitscan_damage), UITheme.TEAL))
			if fire.headshot_multiplier != 1.0:
				_info_box.add_child(UITheme.stat_row("HEADSHOT", "×%.1f" % fire.headshot_multiplier, UITheme.TEAL))
		else:
			_info_box.add_child(UITheme.stat_row("DAMAGE", "PROJECTILE", UITheme.TEAL))
			if fire.projectile_scene != null:
				var proj := fire.projectile_scene.instantiate()
				var hb_node: Node = proj.get_node_or_null("HitboxComponent")
				if hb_node is HitboxComponent:
					var hb := hb_node as HitboxComponent
					_info_box.add_child(UITheme.stat_row("IMPACT", str(abs(hb.health_delta)), UITheme.TEAL))
				proj.queue_free()
		if fire.post_shoot_delay > 0.0:
			_info_box.add_child(UITheme.stat_row("FIRE RATE",
				"%d RPM" % int(round(60.0 / fire.post_shoot_delay)), UITheme.TEAL))
		if fire.ammo_cost > 1:
			_info_box.add_child(UITheme.stat_row("AMMO COST", str(fire.ammo_cost), UITheme.AMBER))
		break
	if not weapon.has_infinite_ammo:
		_info_box.add_child(UITheme.stat_row("MAGAZINE", str(weapon.mag_size), UITheme.MUTED))
		_info_box.add_child(UITheme.stat_row("RELOAD", "%.1fs" % weapon.reload_time, UITheme.MUTED))
	if not is_equal_approx(weapon.player_speed_multiplier, 1.0):
		var pct := int(round((weapon.player_speed_multiplier - 1.0) * 100.0))
		var speed_text := ("+%d%%" % pct) if pct > 0 else ("%d%%" % pct)
		_info_box.add_child(UITheme.stat_row("MOVE SPEED",
			speed_text, _stat_color(weapon.player_speed_multiplier)))


func _show_ability_info(ability: Ability) -> void:
	if ability == null or _info_box == null:
		return
	_clear_info()
	if ability.icon != null:
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(56, 56)
		icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = ability.icon
		_info_box.add_child(icon)
	_info_title(ability.ability_name)
	_info_body(ability.description)
	if ability is PassiveAbility:
		_info_chips([["PASSIVE", UITheme.AMBER]])
		return
	_info_box.add_child(UITheme.stat_row("COOLDOWN", "%.1fs" % ability.cooldown, UITheme.TEAL))
	var cast := "INSTANT" if ability.cast_type == Ability.CastType.INSTANT else "EQUIP"
	_info_box.add_child(UITheme.stat_row("CAST", cast, UITheme.MUTED))


func _show_character_info(char: Character) -> void:
	if char == null or _info_box == null:
		return
	_clear_info()
	_info_body(char.description)

	var chips: Array = []
	if char.passive_see_enemy_health:
		chips.append(["SEES HEALTH", UITheme.AMBER])
	if char.heal_on_kill > 0.0:
		chips.append(["HEAL ON KILL %d" % int(char.heal_on_kill), UITheme.TEAL])
	if char.regen_per_sec > 0.0:
		chips.append(["REGEN %.1f/s" % char.regen_per_sec, UITheme.TEAL])
	if char.lifesteal_percent > 0.0:
		chips.append(["LIFESTEAL %.0f%%" % (char.lifesteal_percent * 100.0), UITheme.TEAL])
	if char.air_jumps > 1:
		chips.append(["AIR JUMPS %d" % char.air_jumps, UITheme.TEAL])
	_info_chips(chips)

	_info_section("ATTRIBUTES")
	_info_box.add_child(_make_stat_bar("SPEED", char.speed_mult))
	_info_box.add_child(_make_stat_bar("HEALTH", char.health_mult))
	_info_box.add_child(_make_stat_bar("DAMAGE", char.damage_amp_mult))
	_info_box.add_child(_make_stat_bar("FIRE RATE", 1.0 / maxf(char.shoot_delay_mult, 0.01)))
	_info_box.add_child(_make_stat_bar("AIR CONTROL", char.air_accel_mult))
	_info_box.add_child(_make_stat_bar("RELOAD", char.reload_speed_mult))


# ─────────────────────────────────────────────
#  Selection
# ─────────────────────────────────────────────

func _select_character(char: Character) -> void:
	_hovered_character = null
	selected_character = char
	selected_class = null
	if char:
		selected_class = _char_to_class.get(char.resource_path) as Class

	_ensure_loadout_slots()
	_rebuild_loadout_slots()
	_refresh_ability_tiles()
	_refresh_agent_selection()
	_update_detail_header()
	_update_operative_label()

	_confirm_button.disabled = selected_class == null
	if selected_class == null:
		_show_info("", "No class found for this character.")
	else:
		_show_character_info(char)

	_refresh_character_preview()
	_refresh_team_list()


## The slots live in the tscn detail panel and are built once.
func _ensure_loadout_slots() -> void:
	if _weapon_slots.is_empty():
		_build_loadout_slots()


# ─────────────────────────────────────────────
#  Character preview
# ─────────────────────────────────────────────

func _setup_preview() -> void:
	if PREVIEW_DISABLED:
		return
	_preview_svc.gui_input.connect(_on_character_gui_input)
	_preview_svc.mouse_entered.connect(_on_character_hover_enter)
	_preview_svc.mouse_exited.connect(_on_character_hover_exit)
	_preview_svc.resized.connect(_on_preview_resized)
	_preview_mode_button.pressed.connect(_on_preview_mode_pressed)
	_on_preview_resized()


## SubViewportContainer with `stretch` owns the viewport size; only the
## render pass needs a nudge after a layout change.
func _on_preview_resized() -> void:
	if _preview_rig:
		_preview_rig.render_once()


func _on_character_hover_enter() -> void:
	_set_bracket_color(UITheme.TEAL)
	if selected_character:
		_show_character_info(selected_character)


func _on_character_hover_exit() -> void:
	_set_bracket_color(UITheme.LINE_HI)


## LMB drag = turntable in both axes; RMB drag = pan; wheel = zoom.  Agents are
## chosen from the bottom strip, so a click no longer opens a picker.
func _on_character_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _preview_rig:
				_preview_rig.zoom(1.0)
			_preview_svc.accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _preview_rig:
				_preview_rig.zoom(-1.0)
			_preview_svc.accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_drag_button = mb.button_index if mb.pressed else 0
	elif event is InputEventMouseMotion and _drag_button != 0:
		var mm := event as InputEventMouseMotion
		if _preview_rig == null:
			return
		if _drag_button == MOUSE_BUTTON_LEFT:
			_preview_rig.orbit(mm.relative.x, mm.relative.y)
		else:
			_preview_rig.pan(mm.relative.x, mm.relative.y)


func _on_preview_mode_pressed() -> void:
	_preview_mode = (_preview_mode + 1) % 3
	_update_preview_mode_label()
	if _preview_rig:
		_preview_rig.set_preview_mode(_preview_mode)


func _update_preview_mode_label() -> void:
	if _preview_mode_button == null:
		return
	var names := ["STANDING", "WALKING", "RUNNING"]
	_preview_mode_button.text = "PREVIEW: %s" % names[_preview_mode]


func _refresh_character_preview() -> void:
	if PREVIEW_DISABLED or _preview_rig == null:
		return
	_preview_rig.set_preview_mode(_preview_mode)
	_preview_rig.show_character(selected_character, selected_primary)
	_displayed_weapon = selected_primary


func _build_bracket_lines() -> void:
	if _brackets == null:
		return
	var arms := [
		# [left, top, right, bottom, h-origin, v-origin]
		[0.0, 0.0, 0.0, 0.0, Vector2(0, 0)],
		[1.0, 0.0, 1.0, 0.0, Vector2(28, 0)],
		[0.0, 1.0, 0.0, 1.0, Vector2(0, 28)],
		[1.0, 1.0, 1.0, 1.0, Vector2(28, 28)],
	]
	var length := 28.0
	for spec in arms:
		var ax: float = spec[0]
		var ay: float = spec[1]
		var origin: Vector2 = spec[4]
		var hline := ColorRect.new()
		hline.color = UITheme.LINE_HI
		hline.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hline.anchor_left = ax
		hline.anchor_right = ax
		hline.anchor_top = ay
		hline.anchor_bottom = ay
		hline.offset_left = -origin.x if ax > 0.5 else 0.0
		hline.offset_right = 0.0 if ax > 0.5 else length
		hline.offset_top = -1.0 if ay > 0.5 else 0.0
		hline.offset_bottom = 0.0 if ay > 0.5 else 1.0
		_brackets.add_child(hline)
		_bracket_lines.append(hline)

		var vline := ColorRect.new()
		vline.color = UITheme.LINE_HI
		vline.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vline.anchor_left = ax
		vline.anchor_right = ax
		vline.anchor_top = ay
		vline.anchor_bottom = ay
		vline.offset_left = -1.0 if ax > 0.5 else 0.0
		vline.offset_right = 0.0 if ax > 0.5 else 1.0
		vline.offset_top = -length if ay > 0.5 else 0.0
		vline.offset_bottom = 0.0 if ay > 0.5 else length
		_brackets.add_child(vline)
		_bracket_lines.append(vline)


func _set_bracket_color(color: Color) -> void:
	for line in _bracket_lines:
		if is_instance_valid(line):
			line.color = color


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
	_set_displayed_weapon(selected_primary)


func _on_randomize_once_pressed() -> void:
	if selected_class == null:
		return
	_randomize_column("primary", selected_class.primary_weapons)
	_randomize_column("secondary", selected_class.secondary_weapons)
	_randomize_column("melee", selected_class.melee_weapons)
	_set_displayed_weapon(selected_primary)


func _randomize_column(key: String, weapons: Array[Weapon]) -> void:
	if weapons.is_empty():
		return
	var weapon := weapons[randi() % weapons.size()]
	_apply_weapon_selection(key, weapon, false)


## Bounded retry count for the deferred confirm above; ~10 s at 60 fps.
var _confirm_defer_count: int = 0


func _on_confirm_pressed() -> void:
	if selected_class == null or selected_character == null:
		return
	if selected_primary == null or selected_secondary == null or selected_melee == null:
		return

	# On a match client, the stable player id arrives with `welcome` and the
	# Player node arrives via the spawner afterwards.  Defer until both exist;
	# sending earlier puts the id or the node out of step with the server.
	if not multiplayer.is_server():
		var local := MatchSession.local_id_string()
		if MatchSession.role == MatchSession.Role.CLIENT \
				and (MatchSession.local_player_id == 0 or GameManager.find_player(local) == null):
			_confirm_defer_count += 1
			if _confirm_defer_count < 600:
				_on_confirm_pressed.call_deferred()
			else:
				push_error("Loadout confirm timed out waiting for the local Player node.")
			return
		_confirm_defer_count = 0
		player_id = local

	# Capture everything before hiding: in bot mode the hide triggers the
	# visibility handler, and player_id must not be restored before the RPC.
	var target_id := player_id
	var character_path := selected_character.resource_path
	var primary_path := selected_primary.resource_path
	var secondary_path := selected_secondary.resource_path
	var melee_path := selected_melee.resource_path
	var class_path := selected_class.resource_path

	if bot_edit_mode:
		# A bot never randomizes on death.  Suppress the restore until the RPC
		# has been issued, then restore explicitly.
		_bot_applying = true
		visible = false
		if multiplayer.is_server():
			_request_loadout(target_id, primary_path, secondary_path, melee_path, Player.Team.FFA, character_path, class_path, false)
		else:
			_request_loadout.rpc_id(1, target_id, primary_path, secondary_path, melee_path, Player.Team.FFA, character_path, class_path, false)
		_finish_bot_edit()
		return

	var rand_on_death := _randomize_on_death_check.button_pressed
	var respawn := true
	if world != null and world.has_method("should_loadout_respawn"):
		respawn = bool(world.should_loadout_respawn())

	GameManager.local_loadout = {
		"character_path": character_path,
		"class_path": class_path,
		"primary_path": primary_path,
		"secondary_path": secondary_path,
		"melee_path": melee_path,
		"randomize_on_death": rand_on_death,
	}

	# Hide our canvas (don't free — user can re-open with H later).  Opened from
	# staging, control returns to the staging overlay rather than to gameplay.
	var was_staging := staging_mode
	set_staging_mode(false)
	visible = false  # triggers _process() → _canvas.visible = false

	world.class_selected = true
	if was_staging:
		PlayerInput.ui_open = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		PlayerInput.ui_open = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if multiplayer.is_server():
		_request_loadout(target_id, primary_path, secondary_path, melee_path, Player.Team.FFA, character_path, class_path, rand_on_death, respawn)
	else:
		_request_loadout.rpc_id(1, target_id, primary_path, secondary_path, melee_path, Player.Team.FFA, character_path, class_path, rand_on_death, respawn)

# ─────────────────────────────────────────────
#  RPCs (mirrors ClassSelectUI)
# ─────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _request_loadout(tpid: String, pp: String, sp: String, mp: String, team: Player.Team, cp: String = "", class_path := "", rand_on_death := false, respawn := true) -> void:
	if not multiplayer.is_server():
		return
	var sid := multiplayer.get_remote_sender_id()
	# `tpid` is a stable player id; map the sending peer to its player before
	# comparing.  Legacy P2P falls back to the peer id, matching the old check.
	if sid != 0 and MatchSession.player_id_string_for_peer(sid) != tpid and not tpid.begins_with("bot_"):
		return
	# Path allowlists: never let a client ask the server to load an arbitrary
	# resource path as a weapon/character/class.
	for path in [pp, sp, mp]:
		if not str(path).begins_with("res://weapon/"):
			push_warning("_request_loadout: rejected weapon path %s" % path)
			return
	if not cp.is_empty() and not cp.begins_with("res://player/characters/"):
		push_warning("_request_loadout: rejected character path %s" % cp)
		return
	if not class_path.is_empty() and not class_path.begins_with("res://player/player_classes/"):
		push_warning("_request_loadout: rejected class path %s" % class_path)
		return
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if primary == null or secondary == null or melee == null:
		# A dropped loadout is indistinguishable from a successful one further
		# down, so say so here instead of returning in silence.
		push_error("_request_loadout: unresolvable weapon path (pp=%s sp=%s mp=%s) — loadout not applied" % [pp, sp, mp])
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	# apply_loadout, not set_weapons: it also lands on slot 0 with that slot's
	# model in hand.  A bare set_weapons() + index write leaves the swap pending
	# on a put-away timer that the rpc_reset() below cancels — see the doc comment
	# on WeaponController.apply_loadout.
	ctrl.apply_loadout(nw)
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
	if respawn:
		player.rpc_reset.rpc(player._get_spawn_transform())
	# Keep the persistent manual-bot roster in step so a dev-menu edit survives
	# return_to_lobby.  Autofill bots have no entry (no-op).
	if tpid.begins_with("bot_") and GameManager.spawn_manager:
		GameManager.spawn_manager.update_lobby_bot_entry(tpid)

@rpc("authority", "call_remote", "reliable")
func _apply_loadout(tpid: String, pp: String, sp: String, mp: String, team: Player.Team, cp: String = "") -> void:
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	var melee: Weapon = load(mp) as Weapon
	if primary == null or secondary == null or melee == null:
		# Silent bail here desyncs this peer from the server permanently: the
		# server already applied the loadout it broadcast.
		push_error("_apply_loadout: unresolvable weapon path (pp=%s sp=%s mp=%s) — peer keeps its previous weapons" % [pp, sp, mp])
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon, melee.duplicate(true) as Weapon]
	ctrl.apply_loadout(nw)
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
