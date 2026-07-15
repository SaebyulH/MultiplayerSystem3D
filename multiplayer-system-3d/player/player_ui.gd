extends Control
class_name PlayerBodyUI

## Visual HUD for the owning player.
## Builds all UI elements in code.  Removes old scene children on init.

@export var attribute_component: AttributeComponent
@export var weapon_controller: WeaponController

@onready var _owner_player: Player = $"../.."

# Public UI (visible above the player model for other players)
@onready var _ammo_bar_public: Label3D = $"../AmmoBarPublic"
@onready var _health_bar_public: Label3D = $"../HealthBarPublic"
@onready var _health_delta_bar_public: Label3D = $"../HealthDeltaBarPublic"
@onready var _name_public: Label3D = %NamePublic

# ── Built UI nodes ───────────────────────────

var _health_bar_bg: ColorRect
var _health_bar_fill: ColorRect
var _health_label: Label

var _health_delta_label: Label
var _team_label: Label

var _ammo_label: Label
var _reload_bar_bg: ColorRect
var _reload_bar_fill: ColorRect

var _weapon_list: VBoxContainer
var _crosshair: ColorRect

# Health delta tracking
var _last_health: float = 0.0
var _last_change: float = 0.0
var _last_change_time: float = 0.0

const HIDE_TIME: float = 2.0
const MIN_DISPLAY_DELTA: float = 0.5

# Layout constants
const MARGIN: float = 20.0
const BAR_WIDTH: float = 260.0
const BAR_HEIGHT: float = 28.0
const HEALTH_TOP: float = 120.0  # distance from bottom

# ─────────────────────────────────────────────
#  Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	# Nuke all old scene children so they don't overlap
	for child in get_children():
		child.queue_free()

	_build_ui()

	var is_owner := is_multiplayer_authority()
	visible = is_owner and not _owner_player.is_bot

	if attribute_component:
		_last_health = attribute_component.health

	# Broadcast display name to all peers (authority only)
	if is_owner:
		var display_name := ("Host" if (name.to_int() == 1) else "Client") + ", NetID: " + str(name)
		_set_name_label.rpc(display_name)

	_connect_signals()

@rpc("authority", "call_local", "reliable")
func _set_name_label(display_name: String) -> void:
	_name_public.text = display_name

func _connect_signals() -> void:
	if not weapon_controller:
		return
	weapon_controller.mag_changed.connect(_on_ammo_updated)
	weapon_controller.weapon_changed.connect(_on_weapon_changed)
	_on_ammo_updated()
	_on_weapon_changed()

# ─────────────────────────────────────────────
#  UI Building
# ─────────────────────────────────────────────

func _build_ui() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_crosshair()
	_build_health()
	_build_ammo()
	_build_weapon_list()

func _build_crosshair() -> void:
	# Small dot at screen centre
	_crosshair = ColorRect.new()
	_crosshair.anchor_left   = 0.5
	_crosshair.anchor_right  = 0.5
	_crosshair.anchor_top    = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.offset_left   = -2.0
	_crosshair.offset_top    = -2.0
	_crosshair.offset_right  = 2.0
	_crosshair.offset_bottom = 2.0
	_crosshair.color = Color.WHITE
	add_child(_crosshair)

func _build_health() -> void:
	# ── Container (bottom-left, fixed size) ──
	var container := Control.new()
	container.anchor_left   = 0.0
	container.anchor_right  = 0.0
	container.anchor_top    = 1.0
	container.anchor_bottom = 1.0
	container.offset_left   = MARGIN
	container.offset_top    = -(HEALTH_TOP + BAR_HEIGHT + 4.0)
	container.offset_right  = MARGIN + BAR_WIDTH
	container.offset_bottom = -HEALTH_TOP
	add_child(container)

	# Background
	_health_bar_bg = ColorRect.new()
	_health_bar_bg.color = Color(0.08, 0.08, 0.08, 0.80)
	_health_bar_bg.anchor_left   = 0.0
	_health_bar_bg.anchor_right  = 1.0
	_health_bar_bg.anchor_top    = 0.0
	_health_bar_bg.anchor_bottom = 1.0
	container.add_child(_health_bar_bg)

	# Fill
	_health_bar_fill = ColorRect.new()
	_health_bar_fill.color = Color(0.25, 0.75, 0.25)
	_health_bar_fill.anchor_left   = 0.0
	_health_bar_fill.anchor_right  = 1.0
	_health_bar_fill.anchor_top    = 0.0
	_health_bar_fill.anchor_bottom = 1.0
	container.add_child(_health_bar_fill)

	# Number overlay
	_health_label = Label.new()
	_health_label.anchor_left   = 0.0
	_health_label.anchor_right  = 1.0
	_health_label.anchor_top    = 0.0
	_health_label.anchor_bottom = 1.0
	_health_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_health_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_health_label.add_theme_constant_override("outline_size", 6)
	_health_label.add_theme_font_size_override("font_size", 22)
	container.add_child(_health_label)

	# ── Delta label (above bar) ─────────────
	_health_delta_label = Label.new()
	_health_delta_label.anchor_left   = 0.0
	_health_delta_label.anchor_right  = 0.0
	_health_delta_label.anchor_top    = 1.0
	_health_delta_label.anchor_bottom = 1.0
	_health_delta_label.offset_left   = MARGIN
	_health_delta_label.offset_top    = -(HEALTH_TOP + BAR_HEIGHT + 4.0 + 34.0)
	_health_delta_label.offset_right  = MARGIN + BAR_WIDTH
	_health_delta_label.offset_bottom = -(HEALTH_TOP + BAR_HEIGHT + 4.0)
	_health_delta_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_health_delta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_health_delta_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_health_delta_label.add_theme_constant_override("outline_size", 8)
	_health_delta_label.add_theme_font_size_override("font_size", 24)
	add_child(_health_delta_label)

	# ── Team label (above delta) ────────────
	_team_label = Label.new()
	_team_label.anchor_left   = 0.0
	_team_label.anchor_right  = 0.0
	_team_label.anchor_top    = 1.0
	_team_label.anchor_bottom = 1.0
	_team_label.offset_left   = MARGIN
	_team_label.offset_top    = -(HEALTH_TOP + BAR_HEIGHT + 4.0 + 34.0 + 28.0)
	_team_label.offset_right  = MARGIN + BAR_WIDTH
	_team_label.offset_bottom = -(HEALTH_TOP + BAR_HEIGHT + 4.0 + 34.0)
	_team_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_team_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_team_label.add_theme_constant_override("outline_size", 6)
	_team_label.add_theme_font_size_override("font_size", 18)
	_update_team()
	add_child(_team_label)

func _build_ammo() -> void:
	# ── Ammo count (bottom-right) ───────────
	_ammo_label = Label.new()
	_ammo_label.anchor_left   = 0.0
	_ammo_label.anchor_right  = 1.0
	_ammo_label.anchor_top    = 1.0
	_ammo_label.anchor_bottom = 1.0
	_ammo_label.offset_left   = 0.0
	_ammo_label.offset_top    = -(HEALTH_TOP + 4.0)
	_ammo_label.offset_right  = -MARGIN
	_ammo_label.offset_bottom = 0.0
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ammo_label.vertical_alignment   = VERTICAL_ALIGNMENT_BOTTOM
	_ammo_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_ammo_label.add_theme_constant_override("outline_size", 12)
	_ammo_label.add_theme_font_size_override("font_size", 56)
	add_child(_ammo_label)

	# ── Reload bar (bottom edge of screen) ──
	var reload_container := Control.new()
	reload_container.anchor_left   = 0.0
	reload_container.anchor_right  = 1.0
	reload_container.anchor_top    = 1.0
	reload_container.anchor_bottom = 1.0
	reload_container.offset_left   = 0.0
	reload_container.offset_top    = -6.0
	reload_container.offset_right  = 0.0
	reload_container.offset_bottom = 0.0
	reload_container.visible = false
	add_child(reload_container)
	_reload_bar_bg = ColorRect.new()
	_reload_bar_bg.color = Color(0.08, 0.08, 0.08, 0.60)
	_reload_bar_bg.anchor_left   = 0.0
	_reload_bar_bg.anchor_right  = 1.0
	_reload_bar_bg.anchor_top    = 0.0
	_reload_bar_bg.anchor_bottom = 1.0
	reload_container.add_child(_reload_bar_bg)
	_reload_bar_fill = ColorRect.new()
	_reload_bar_fill.color = Color(0.85, 0.85, 0.30)
	_reload_bar_fill.anchor_left   = 0.0
	_reload_bar_fill.anchor_right  = 1.0
	_reload_bar_fill.anchor_top    = 0.0
	_reload_bar_fill.anchor_bottom = 1.0
	reload_container.add_child(_reload_bar_fill)

func _build_weapon_list() -> void:
	_weapon_list = VBoxContainer.new()
	_weapon_list.anchor_left   = 1.0
	_weapon_list.anchor_right  = 1.0
	_weapon_list.anchor_top    = 0.5
	_weapon_list.anchor_bottom = 0.5
	_weapon_list.offset_left   = -200.0
	_weapon_list.offset_top    = -160.0
	_weapon_list.offset_right  = -MARGIN
	_weapon_list.offset_bottom = 160.0
	_weapon_list.add_theme_constant_override("separation", 4)
	add_child(_weapon_list)

# ─────────────────────────────────────────────
#  Updates (called from _process)
# ─────────────────────────────────────────────

func _process(_delta: float) -> void:
	# Enforce ownership visibility every frame — parent's show()/hide() overrides
	# our visible flag, so we must re-assert it.
	var should_show := is_multiplayer_authority() and not _owner_player.is_bot
	if visible != should_show:
		visible = should_show
		if not should_show:
			return  # skip all updates when hidden

	_update_health()
	_update_health_delta()
	_update_ammo()
	_update_team()

func _update_health() -> void:
	if not attribute_component or not is_inside_tree():
		return
	var hp := attribute_component.health
	var max_hp := attribute_component.starting_health
	var pct := clampf(hp / max_hp, 0.0, 1.0)

	_health_bar_fill.anchor_right = pct
	_health_label.text = "%d" % int(hp)

	if pct > 0.6:
		_health_bar_fill.color = Color(0.25, 0.75, 0.25)
	elif pct > 0.3:
		_health_bar_fill.color = Color(0.85, 0.75, 0.15)
	else:
		_health_bar_fill.color = Color(0.85, 0.20, 0.20)

	# Public health bar
	if _health_bar_public:
		_health_bar_public.text = "%d" % int(hp)
		# Color by enemy/ally
		var local_id := str(multiplayer.get_unique_id())
		var local := GameManager.find_player(local_id)
		if local and _owner_player:
			if _owner_player.team != local.team:
				_health_bar_public.modulate = Color(0.85, 0.20, 0.20)
			else:
				_health_bar_public.modulate = Color(0.25, 0.85, 0.25)

func _update_health_delta() -> void:
	if not attribute_component:
		return
	var current := attribute_component.health
	if not is_equal_approx(current, _last_health):
		var change := current - _last_health
		_last_health = current
		if abs(change) >= MIN_DISPLAY_DELTA:
			_last_change = change
			_last_change_time = Time.get_ticks_msec() / 1000.0

	var now := Time.get_ticks_msec() / 1000.0
	var elapsed := now - _last_change_time

	if elapsed > HIDE_TIME:
		_health_delta_label.text = ""
		if _health_delta_bar_public:
			_health_delta_bar_public.text = ""
		return

	if _last_change < 0:
		_health_delta_label.modulate = Color(0.85, 0.15, 0.15)
		_health_delta_label.text = "-%d" % int(abs(_last_change))
	elif _last_change > 0:
		_health_delta_label.modulate = Color(0.25, 0.85, 0.25)
		_health_delta_label.text = "+%d" % int(_last_change)
	else:
		_health_delta_label.text = ""

	# Public delta
	if _health_delta_bar_public:
		_health_delta_bar_public.text = _health_delta_label.text
		_health_delta_bar_public.modulate = _health_delta_label.modulate

	if elapsed > HIDE_TIME * 0.5:
		var alpha := clampf(1.0 - (elapsed - HIDE_TIME * 0.5) / (HIDE_TIME * 0.5), 0.0, 1.0)
		var c := _health_delta_label.modulate
		c.a = alpha
		_health_delta_label.modulate = c

func _update_ammo() -> void:
	if not weapon_controller:
		return
	var weapons := weapon_controller.get_weapons()
	var index := weapon_controller.current_weapon_index
	if index < 0 or index >= weapons.size():
		return

	var weapon := weapons[index]

	if weapon_controller._is_reloading:
		_show_reload(weapon)
	else:
		_hide_reload()
		if weapon.has_infinite_ammo:
			_ammo_label.text = "INF"
		else:
			_ammo_label.text = "%d / %d" % [weapon.mag_current, weapon.mag_size]

	# Public ammo
	if _ammo_bar_public:
		_ammo_bar_public.text = _ammo_label.text

func _show_reload(weapon: Weapon) -> void:
	_ammo_label.text = "%d / %d" % [weapon.mag_current, weapon.mag_size]

	var parent := _reload_bar_fill.get_parent() as Control
	if parent:
		parent.visible = true

	# Reload timer = time remaining / total reload time
	var t := weapon_controller._reload_timer
	var total := weapon.reload_time
	var pct := t / total if total > 0.0 else 0.0
	_reload_bar_fill.anchor_right = pct

func _hide_reload() -> void:
	var parent := _reload_bar_fill.get_parent() as Control
	if parent:
		parent.visible = false

func _update_team() -> void:
	var player := _owner_player
	if not player:
		return
	var col: Color
	var txt: String
	match player.team:
		Player.Team.SPI:
			txt = "SPI"
			col = Color(0.88, 0.24, 0.24)
		Player.Team.SCI:
			txt = "SCI"
			col = Color(0.25, 0.65, 0.90)
		Player.Team.FFA:
			txt = "FFA"
			col = Color(0.70, 0.70, 0.70)
	_team_label.text = txt
	_team_label.modulate = col

# ─────────────────────────────────────────────
#  Signal handlers
# ─────────────────────────────────────────────

func _on_ammo_updated(_current = null, _max = null) -> void:
	_update_ammo()
	_update_weapon_list()

func _on_weapon_changed(_index = null, _weapon = null) -> void:
	_update_weapon_list()

func _update_weapon_list() -> void:
	if not weapon_controller:
		return
	for child in _weapon_list.get_children():
		child.queue_free()

	var weapons := weapon_controller.get_weapons()
	var current_index := weapon_controller.current_weapon_index

	for i in weapons.size():
		var label := Label.new()
		label.text = weapons[i].display_name
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		label.add_theme_constant_override("outline_size", 4)
		label.add_theme_font_size_override("font_size", 20)
		if i == current_index:
			label.modulate = Color(1.0, 0.85, 0.20)
			label.add_theme_font_size_override("font_size", 24)
		else:
			label.modulate = Color(0.65, 0.65, 0.65)
		_weapon_list.add_child(label)
