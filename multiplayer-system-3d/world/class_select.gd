extends Control
class_name ClassSelectUI

## Clean, professional class-selection screen.
## Uses a CanvasLayer added directly to the root viewport so it renders
## above all other UI.

@onready var spawn_parent := %SpawnParent
@onready var world := $"../../.."

var player_id: String
var available_classes: Array[Class] = []
var selected_class: Class = null

# ── Built nodes ──────────────────────────────

var _canvas: CanvasLayer
var _team_option: OptionButton
var _class_option: OptionButton
var _primary_option: OptionButton
var _secondary_option: OptionButton
var _character_option: OptionButton
var _confirm_button: Button
var _mode_label: Label

var _primary_viewport: SubViewport
var _secondary_viewport: SubViewport

var _primary_stats: RichTextLabel
var _secondary_stats: RichTextLabel
var _character_stats: RichTextLabel

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())

	# Nuke ALL old scene children so the VBoxContainer shows nothing.
	for child in get_children():
		child.queue_free()

	# Build everything in a dedicated CanvasLayer attached to the root window.
	_canvas = CanvasLayer.new()
	_canvas.layer = 2
	_canvas.name = "ClassSelectCanvas"
	get_tree().root.add_child(_canvas)
	_build_ui_in(_canvas)

	# Start hidden (synced with self.visible below).
	_canvas.visible = false

	# Load classes
	var loaded_classes: Array[Class] = []
	for path in [
		"res://player/player_classes/assault.tres",
		"res://player/player_classes/assasin.tres",
		"res://player/player_classes/assistance.tres",
	]:
		var c := load(path) as Class
		if c:
			loaded_classes.append(c)
	load_classes(loaded_classes)

	_class_option.item_selected.connect(_on_class_selected)
	_character_option.item_selected.connect(_on_character_selected)
	_primary_option.item_selected.connect(_on_primary_selected)
	_secondary_option.item_selected.connect(_on_secondary_selected)
	_confirm_button.pressed.connect(_on_confirm_pressed)

func _process(_delta: float) -> void:
	# world_1.gd toggles self.visible to show/hide the class select.
	# Since we moved the real UI into _canvas, sync its visibility.
	if _canvas:
		_canvas.visible = visible

# ─────────────────────────────────────────────
#  UI Building  (target: a CanvasLayer)
# ─────────────────────────────────────────────

func _build_ui_in(cl: CanvasLayer) -> void:
	# Dim backdrop
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.06, 0.78)
	dim.anchor_left   = 0.0
	dim.anchor_right  = 1.0
	dim.anchor_top    = 0.0
	dim.anchor_bottom = 1.0
	cl.add_child(dim)

	# HBox master — left/right spacers, column in center
	var master := HBoxContainer.new()
	master.anchor_left   = 0.0
	master.anchor_right  = 1.0
	master.anchor_top    = 0.0
	master.anchor_bottom = 1.0
	cl.add_child(master)

	master.add_child(_spacer_h())

	# Main column  (needs scroll for small windows)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(800, 0)
	scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	scroll.follow_focus = true
	master.add_child(scroll)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	scroll.add_child(col)

	master.add_child(_spacer_h())

	# ── Title ────────────────────────────────
	var title := _title()
	col.add_child(title)
	col.add_child(_sep())

	# Game-mode info
	_mode_label = Label.new()
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_mode_label.add_theme_constant_override("outline_size", 4)
	_mode_label.add_theme_font_size_override("font_size", 15)
	_mode_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.5))
	_mode_label.text = ""
	col.add_child(_mode_label)
	col.add_child(_sep())
	# Update mode text once GMC is available (deferred to avoid nulls).
	_populate_mode_info.call_deferred()

	# ── Team / Class row ─────────────────────
	var top_row := CenterContainer.new()
	col.add_child(top_row)
	var opt_row := HBoxContainer.new()
	opt_row.add_theme_constant_override("separation", 20)
	top_row.add_child(opt_row)

	_team_option = _opt()
	_team_option.add_item("FFA", 0)
	_team_option.add_item("SPI", 1)
	_team_option.add_item("SCI", 2)
	
	opt_row.add_child(_labeled("TEAM", _team_option))

	_class_option = _opt()
	_class_option.add_item("-- Select Class --", 0)
	_class_option.item_count = 1
	opt_row.add_child(_labeled("CLASS", _class_option))

	col.add_child(_sep())

	# ── Character row ─────────────────────────
	var char_row := CenterContainer.new()
	col.add_child(char_row)
	_character_option = _opt()
	_character_option.add_item("-- Select Character --", 0)
	char_row.add_child(_labeled("CHARACTER", _character_option))

	_character_stats = _stat_label()
	_character_stats.visible = false
	col.add_child(_character_stats)
	col.add_child(_sep())

	# ── Preview row ──────────────────────────
	var preview_row := HBoxContainer.new()
	preview_row.add_theme_constant_override("separation", 16)
	col.add_child(preview_row)

	# Primary
	var p_col := _preview_column("PRIMARY")
	_primary_viewport = _vp()
	_primary_container(p_col).add_child(_primary_viewport)
	_primary_option = _opt(); _primary_option.visible = false
	_primary_stats = _stat_label()
	p_col.add_child(_primary_option)
	p_col.add_child(_primary_stats)
	preview_row.add_child(p_col)

	# Secondary
	var s_col := _preview_column("SECONDARY")
	_secondary_viewport = _vp()
	_secondary_container(s_col).add_child(_secondary_viewport)
	_secondary_option = _opt(); _secondary_option.visible = false
	_secondary_stats = _stat_label()
	s_col.add_child(_secondary_option)
	s_col.add_child(_secondary_stats)
	preview_row.add_child(s_col)

	# ── Confirm ──────────────────────────────
	var btn_row := CenterContainer.new()
	col.add_child(btn_row)
	_confirm_button = Button.new()
	_confirm_button.text = "  CONFIRM BUILD  "
	_confirm_button.add_theme_font_size_override("font_size", 22)
	_confirm_button.disabled = true
	btn_row.add_child(_confirm_button)

	# Main Menu button
	var menu_row: CenterContainer = CenterContainer.new()
	col.add_child(menu_row)
	var menu_btn: Button = Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.add_theme_font_size_override("font_size", 18)
	menu_btn.pressed.connect(func():
		_canvas.queue_free()
		NetworkManager.terminate_connection_load_main_menu()
	)
	menu_row.add_child(menu_btn)

# ─────────────────────────────────────────────
#  Tiny helpers
# ─────────────────────────────────────────────

func _stat_label() -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.add_theme_font_size_override("normal_font_size", 13)
	rtl.add_theme_color_override("default_color", Color(0.82, 0.82, 0.82))
	rtl.visible = false
	return rtl

func _spacer_h() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c



func _populate_mode_info() -> void:
	if not _mode_label: return
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
func _sep() -> ColorRect:
	var c := ColorRect.new()
	c.custom_minimum_size = Vector2(0, 2)
	c.color = Color(0.35, 0.35, 0.35, 0.5)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _title() -> Label:
	var l := Label.new()
	l.text = "—  SELECT YOUR BUILD  —"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_font_size_override("font_size", 30)
	l.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	return l

func _opt() -> OptionButton:
	var o := OptionButton.new()
	o.add_theme_font_size_override("font_size", 18)
	o.custom_minimum_size = Vector2(180, 32)
	return o

func _labeled(text: String, child: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = text
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl.custom_minimum_size = Vector2(52, 0)
	row.add_child(lbl)
	row.add_child(child)
	return row

func _preview_column(name: String) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_theme_constant_override("separation", 4)
	var l := Label.new()
	l.text = name
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	c.add_child(l)
	return c

func _vp() -> SubViewport:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.handle_input_locally = false
	vp.size = Vector2i(340, 200)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Instantiate the exact preview scene that worked in the old .tscn setup.
	var preview_scene := load("res://world/weapon_subviewport_preview.tscn") as PackedScene
	if preview_scene:
		vp.add_child(preview_scene.instantiate())
	return vp

func _primary_container(parent: VBoxContainer) -> SubViewportContainer:
	var svc := SubViewportContainer.new()
	svc.custom_minimum_size = Vector2(340, 200)
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.stretch = true
	parent.add_child(svc)
	return svc

func _secondary_container(parent: VBoxContainer) -> SubViewportContainer:
	var svc := SubViewportContainer.new()
	svc.custom_minimum_size = Vector2(340, 200)
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.stretch = true
	parent.add_child(svc)
	return svc

# ─────────────────────────────────────────────
#  Preview
# ─────────────────────────────────────────────

func _clear_viewport(vp: SubViewport) -> void:
	var pr: Node = vp.get_node_or_null("Node3D/PreviewRoot")
	if not pr:
		return
	for child in pr.get_children():
		child.queue_free()

func _spawn_weapon_preview(weapon: Weapon, vp: SubViewport) -> void:
	if weapon == null or weapon.weapon_model == null:
		return
	_clear_viewport(vp)
	var model: Node3D = weapon.weapon_model.instantiate()
	model.position = Vector3.ZERO
	model.rotation = weapon.weapon_rotation
	model.scale = weapon.weapon_scale
	var pr: Node = vp.get_node_or_null("Node3D/PreviewRoot")
	if not pr:
		return
	pr.add_child(model)
	await get_tree().process_frame
	var camera := vp.get_node_or_null("Node3D/Camera3D") as Camera3D
	if not camera:
		return
	var muzzle_node: Node = model.get_node_or_null("Muzzle")
	if muzzle_node is Node3D:
		camera.position.x = maxf((muzzle_node as Node3D).position.length() * 2.7 + 0.4, 2.0)

# ─────────────────────────────────────────────
#  Classes
# ─────────────────────────────────────────────

func load_classes(classes: Array[Class]) -> void:
	available_classes = classes
	_class_option.clear()
	_class_option.add_item("-- Select Class --", 0)
	for c in classes:
		if c:
			_class_option.add_item(c.class_display_name)

# ─────────────────────────────────────────────
#  Selection handlers
# ─────────────────────────────────────────────

func _on_class_selected(index: int) -> void:
	if index <= 0 or index - 1 >= available_classes.size():
		selected_class = null
		_primary_option.visible = false
		_secondary_option.visible = false
		_confirm_button.disabled = true
		_primary_stats.visible = false
		_secondary_stats.visible = false
		_character_stats.visible = false
		return

	selected_class = available_classes[index - 1]

	_character_option.clear()
	_character_option.add_item("-- Select Character --", 0)
	if selected_class.characters.size() > 0:
		for char in selected_class.characters:
			if char:
				_character_option.add_item(char.character_name)
		_character_option.select(1)
	_refresh_character_stats()

	_primary_option.clear()
	for w in selected_class.primary_weapons:
		_primary_option.add_item(w.display_name)

	_secondary_option.clear()
	for w in selected_class.secondary_weapons:
		_secondary_option.add_item(w.display_name)

	_primary_option.visible = true
	_secondary_option.visible = true
	_confirm_button.disabled = false

	if selected_class.primary_weapons.size() > 0:
		_primary_option.select(0)
		_primary_option.item_selected.emit(0)
	if selected_class.secondary_weapons.size() > 0:
		_secondary_option.select(0)
		_secondary_option.item_selected.emit(0)

func _on_primary_selected(index: int) -> void:
	if selected_class == null or index < 0 or index >= selected_class.primary_weapons.size():
		return
	_spawn_weapon_preview(selected_class.primary_weapons[index], _primary_viewport)
	_refresh_stats()

func _on_secondary_selected(index: int) -> void:
	if selected_class == null or index < 0 or index >= selected_class.secondary_weapons.size():
		return
	_spawn_weapon_preview(selected_class.secondary_weapons[index], _secondary_viewport)
	_refresh_stats()

func _on_character_selected(_index: int) -> void:
	_refresh_character_stats()

# ─────────────────────────────────────────────
#  Stats
# ─────────────────────────────────────────────

func _refresh_stats() -> void:
	var pi := _primary_option.selected
	var si := _secondary_option.selected

	if pi >= 0 and pi < selected_class.primary_weapons.size():
		var w := selected_class.primary_weapons[pi]
		_primary_stats.text = "[b]%s[/b]\n%s" % [w.display_name, _weapon_stats(w)]
		_primary_stats.visible = true
	else:
		_primary_stats.visible = false

	if si >= 0 and si < selected_class.secondary_weapons.size():
		var w := selected_class.secondary_weapons[si]
		_secondary_stats.text = "[b]%s[/b]\n%s" % [w.display_name, _weapon_stats(w)]
		_secondary_stats.visible = true
	else:
		_secondary_stats.visible = false

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

func _refresh_character_stats() -> void:
	var ci := _character_option.selected - 1
	if ci < 0 or selected_class == null or ci >= selected_class.characters.size():
		_character_stats.text = ""
		_character_stats.visible = false
		return
	var char: Character = selected_class.characters[ci]
	if not char:
		_character_stats.text = ""
		_character_stats.visible = false
		return
	var parts: PackedStringArray = []
	parts.append("[b]%s[/b]" % char.character_name)
	if not char.description.is_empty():
		parts.append("[i]%s[/i]" % char.description)
	var stat_lines: PackedStringArray = _char_stat_lines(char)
	if stat_lines.size() > 0:
		parts.append("")
		parts.append_array(stat_lines)
	_character_stats.text = "\n".join(parts)
	_character_stats.visible = true

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
		# Additive stats: skip when 0.  Multiplicative: skip when 1.0.
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
#  Confirm
# ─────────────────────────────────────────────

func _get_selected_team() -> Player.Team:
	match _team_option.selected:
		0:  return Player.Team.FFA
		1:  return Player.Team.SPI
		2:  return Player.Team.SCI
	return Player.Team.FFA

func _on_confirm_pressed() -> void:
	if selected_class == null:
		return

	var pi := _primary_option.selected
	var si := _secondary_option.selected
	if pi < 0 or si < 0:
		return

	var primary: Weapon = selected_class.primary_weapons[pi]
	var secondary: Weapon = selected_class.secondary_weapons[si]
	var ci := _character_option.selected - 1
	var character_path := ""
	if ci >= 0 and ci < selected_class.characters.size():
		var char: Character = selected_class.characters[ci]
		if char:
			character_path = char.resource_path
	var team := _get_selected_team()

	# Hide our canvas (don't free — user can re-open with E later)
	visible = false  # triggers _process() → _canvas.visible = false

	world.class_selected = true
	PlayerInput.ui_open = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if multiplayer.is_server():
		_request_loadout(player_id, primary.resource_path, secondary.resource_path, team, character_path)
	else:
		_request_loadout.rpc_id(1, player_id, primary.resource_path, secondary.resource_path, team, character_path)

# ─────────────────────────────────────────────
#  RPCs
# ─────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _request_loadout(tpid: String, pp: String, sp: String, team: Player.Team, cp: String = "") -> void:
	if not multiplayer.is_server():
		return
	var sid := multiplayer.get_remote_sender_id()
	if sid != 0 and str(sid) != tpid and not tpid.begins_with("bot_"):
		return
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	if primary == null or secondary == null:
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon]
	ctrl.set_weapons(nw)
	ctrl.current_weapon_index = 0
	player.team = team
	# Apply character if one was selected.
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			player.set_character(char_res)
			player._loadout_character_path = cp
	# Store paths so late-joining peers can be synced.
	player._loadout_primary_path = pp
	player._loadout_secondary_path = sp
	_apply_loadout.rpc(tpid, pp, sp, team, cp)
	player.rpc_reset.rpc(player._get_spawn_position())

@rpc("authority", "call_remote", "reliable")
func _apply_loadout(tpid: String, pp: String, sp: String, team: Player.Team, cp: String = "") -> void:
	var primary: Weapon = load(pp) as Weapon
	var secondary: Weapon = load(sp) as Weapon
	if primary == null or secondary == null:
		return
	var player := GameManager.find_player(tpid)
	if player == null:
		return
	var ctrl: WeaponController = player.get_node("WeaponController")
	if ctrl == null:
		return
	var nw: Array[Weapon] = [primary.duplicate(true) as Weapon, secondary.duplicate(true) as Weapon]
	ctrl.set_weapons(nw)
	ctrl.current_weapon_index = 0
	player.team = team
	# Apply character on all peers.
	if not cp.is_empty():
		var char_res: Character = load(cp) as Character
		if char_res:
			player.set_character(char_res)
			player._loadout_character_path = cp
