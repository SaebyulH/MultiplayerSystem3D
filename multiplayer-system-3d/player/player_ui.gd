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

# -- Built UI nodes --

var _health_bar_bg: ColorRect
var _health_bar_fill: ColorRect
var _health_label: Label

var _health_delta_label: Label
var _team_label: Label
var _character_label: Label

var _ammo_label: Label
var _shield_label: Label
var _reload_bar_bg: ColorRect
var _reload_bar_fill: ColorRect

var _weapon_list: VBoxContainer
var _bg_reload_bars: Array[ProgressBar] = []
var _bg_reload_labels: Array[Label] = []
var _crosshair: ColorRect
var _respawn_label: Label
var _respawn_label_bg: ColorRect

# Ability display (left-side list) and "USING" prompt under the crosshair.
var _ability_list: VBoxContainer
var _ability_use_label: Label

# Stamina / dash indicator
var _stamina_container: HBoxContainer
var _stamina_fills: Array[ColorRect] = []
var _stamina_feedback: Label

# Status effect display
var _effect_container: HBoxContainer
var _effect_labels: Array[Label] = []

# Border overlays — one ColorRect per active effect, full-screen with a shader.
var _border_container: Control
var _border_overlays: Dictionary = {}  # effect_id -> ColorRect

# Side-panel list of active effects (right side, below weapon list).
var _effect_list: VBoxContainer
var _effect_list_labels: Dictionary = {}  # effect_id -> Label

const BLEED_MATERIAL := preload("res://components/status_effect/shaders/bleed_border.tres")
const POISON_MATERIAL := preload("res://components/status_effect/shaders/poison_border.tres")
const STUN_MATERIAL := preload("res://components/status_effect/shaders/stun_border.tres")
const FLAME_SHADER_PATH := "res://components/status_effect/shaders/flame_border.gdshader"
const FALLBACK_BORDER_COLOR := Color(0.7, 0.7, 0.7, 0.5)

# Built in _build_status_effects after the shader file has been loaded.
var _effect_materials: Dictionary = {}

# Accumulated time for driving shader border animations.
var _border_time: float = 0.0

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

# Stamina / dash indicator layout
const DASH_CELL_WIDTH: float = 28.0
const DASH_CELL_HEIGHT: float = 12.0
const DASH_CELL_GAP: float = 6.0
const DASH_BAR_TOP: float = 48.0  # distance from bottom

# --------------------------------------------------
#  Lifecycle
# --------------------------------------------------

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

# --------------------------------------------------
#  UI Building
# --------------------------------------------------

func _build_ui() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_crosshair()
	_build_health()
	_build_ammo()
	_build_shield()
	_build_stamina()
	_build_weapon_list()
	_build_abilities()
	_build_respawn_timer()
	_build_status_effects()

func _build_crosshair() -> void:
	# Black outline
	var outline := ColorRect.new()
	outline.anchor_left   = 0.5
	outline.anchor_right  = 0.5
	outline.anchor_top    = 0.5
	outline.anchor_bottom = 0.5
	outline.offset_left   = -3.0
	outline.offset_top    = -3.0
	outline.offset_right  = 3.0
	outline.offset_bottom = 3.0
	outline.color = Color.BLACK
	add_child(outline)

	# Green center dot
	_crosshair = ColorRect.new()
	_crosshair.anchor_left   = 0.5
	_crosshair.anchor_right  = 0.5
	_crosshair.anchor_top    = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.offset_left   = -2.0
	_crosshair.offset_top    = -2.0
	_crosshair.offset_right  = 2.0
	_crosshair.offset_bottom = 2.0
	_crosshair.color = Color.LIME_GREEN # or Color.GREEN
	add_child(_crosshair)

func _build_health() -> void:
	# -- Container (bottom-left, fixed size) --
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

	# -- Delta label (above bar) --
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

	# -- Team label (above delta) --
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

	# -- Character label (below health bar) --
	_character_label = Label.new()
	_character_label.anchor_left   = 0.0
	_character_label.anchor_right  = 0.0
	_character_label.anchor_top    = 1.0
	_character_label.anchor_bottom = 1.0
	_character_label.offset_left   = MARGIN
	_character_label.offset_top    = -(HEALTH_TOP - 28.0)
	_character_label.offset_right  = MARGIN + BAR_WIDTH
	_character_label.offset_bottom = -(HEALTH_TOP - 48.0)
	_character_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_character_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_character_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_character_label.add_theme_constant_override("outline_size", 4)
	_character_label.add_theme_font_size_override("font_size", 14)
	add_child(_character_label)

func _build_ammo() -> void:
	# -- Ammo count (bottom-right) --
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

	# -- Reload bar (bottom edge of screen) --
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

func _build_shield() -> void:
	_shield_label = Label.new()
	_shield_label.anchor_left   = 0.0
	_shield_label.anchor_right  = 1.0
	_shield_label.anchor_top    = 1.0
	_shield_label.anchor_bottom = 1.0
	_shield_label.offset_left   = 0.0
	_shield_label.offset_top    = -(HEALTH_TOP + 4.0 + 30.0)
	_shield_label.offset_right  = -MARGIN
	_shield_label.offset_bottom = -(HEALTH_TOP + 4.0)
	_shield_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_shield_label.vertical_alignment   = VERTICAL_ALIGNMENT_BOTTOM
	_shield_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_shield_label.add_theme_constant_override("outline_size", 8)
	_shield_label.add_theme_font_size_override("font_size", 22)
	_shield_label.add_theme_color_override("font_color", Color(0.3, 0.85, 0.95))
	_shield_label.visible = false
	add_child(_shield_label)


func _build_stamina() -> void:
	# -- Stamina indicator (bottom-center) --
	var slots: int = Player.MAX_STAMINA
	var total_w: float = slots * DASH_CELL_WIDTH + (slots - 1) * DASH_CELL_GAP

	# Timing feedback text (above the bars).
	_stamina_feedback = Label.new()
	_stamina_feedback.anchor_left   = 0.5
	_stamina_feedback.anchor_right  = 0.5
	_stamina_feedback.anchor_top    = 1.0
	_stamina_feedback.anchor_bottom = 1.0
	_stamina_feedback.offset_left   = -150.0
	_stamina_feedback.offset_right  = 150.0
	_stamina_feedback.offset_top    = -(DASH_BAR_TOP + DASH_CELL_HEIGHT + 26.0)
	_stamina_feedback.offset_bottom = -(DASH_BAR_TOP + DASH_CELL_HEIGHT + 4.0)
	_stamina_feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stamina_feedback.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_stamina_feedback.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	_stamina_feedback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_stamina_feedback.add_theme_constant_override("outline_size", 6)
	_stamina_feedback.add_theme_font_size_override("font_size", 20)
	_stamina_feedback.text = ""
	add_child(_stamina_feedback)

	_stamina_container = HBoxContainer.new()
	_stamina_container.anchor_left   = 0.5
	_stamina_container.anchor_right  = 0.5
	_stamina_container.anchor_top    = 1.0
	_stamina_container.anchor_bottom = 1.0
	_stamina_container.offset_left   = -total_w * 0.5
	_stamina_container.offset_right  = total_w * 0.5
	_stamina_container.offset_top    = -(DASH_BAR_TOP + DASH_CELL_HEIGHT)
	_stamina_container.offset_bottom = -DASH_BAR_TOP
	_stamina_container.add_theme_constant_override("separation", int(DASH_CELL_GAP))
	_stamina_container.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_stamina_container)

	for i in slots:
		var cell := Control.new()
		cell.custom_minimum_size = Vector2(DASH_CELL_WIDTH, DASH_CELL_HEIGHT)
		cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_stamina_container.add_child(cell)

		# Empty slot background.
		var bg := ColorRect.new()
		bg.color = Color(0.08, 0.08, 0.08, 0.80)
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cell.add_child(bg)

		# Fill - anchor_right is driven by the current charge fraction, so a
		# recovering charge renders as a partially filled rectangle.
		var fill := ColorRect.new()
		fill.color = Color(0.30, 0.85, 0.95)
		fill.anchor_left   = 0.0
		fill.anchor_right  = 0.0
		fill.anchor_top    = 0.0
		fill.anchor_bottom = 1.0
		cell.add_child(fill)
		_stamina_fills.append(fill)


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

func _build_abilities() -> void:
	# Left-side ability list (name + cooldown).
	_ability_list = VBoxContainer.new()
	_ability_list.anchor_left   = 0.0
	_ability_list.anchor_right  = 0.0
	_ability_list.anchor_top    = 0.5
	_ability_list.anchor_bottom = 0.5
	_ability_list.offset_left   = MARGIN
	_ability_list.offset_top    = -160.0
	_ability_list.offset_right  = MARGIN + 220.0
	_ability_list.offset_bottom = 160.0
	_ability_list.add_theme_constant_override("separation", 4)
	add_child(_ability_list)

	# "USING X" prompt, shown under the crosshair while an ability is equipped.
	_ability_use_label = Label.new()
	_ability_use_label.anchor_left   = 0.5
	_ability_use_label.anchor_right  = 0.5
	_ability_use_label.anchor_top    = 0.5
	_ability_use_label.anchor_bottom = 0.5
	_ability_use_label.offset_left   = -200.0
	_ability_use_label.offset_top    = 14.0
	_ability_use_label.offset_right  = 200.0
	_ability_use_label.offset_bottom = 44.0
	_ability_use_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ability_use_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.3))
	_ability_use_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_ability_use_label.add_theme_constant_override("outline_size", 6)
	_ability_use_label.add_theme_font_size_override("font_size", 20)
	_ability_use_label.text = ""
	add_child(_ability_use_label)

func _build_respawn_timer() -> void:
	# -- Respawn countdown (center of screen) --
	var container := Control.new()
	container.anchor_left   = 0.5
	container.anchor_right  = 0.5
	container.anchor_top    = 0.5
	container.anchor_bottom = 0.5
	container.offset_left   = -150.0
	container.offset_top    = -30.0
	container.offset_right  = 150.0
	container.offset_bottom = 30.0
	container.visible = false
	add_child(container)

	_respawn_label_bg = ColorRect.new()
	_respawn_label_bg.color = Color(0.0, 0.0, 0.0, 0.55)
	_respawn_label_bg.anchor_left   = 0.0
	_respawn_label_bg.anchor_right  = 1.0
	_respawn_label_bg.anchor_top    = 0.0
	_respawn_label_bg.anchor_bottom = 1.0
	container.add_child(_respawn_label_bg)

	_respawn_label = Label.new()
	_respawn_label.anchor_left   = 0.0
	_respawn_label.anchor_right  = 1.0
	_respawn_label.anchor_top    = 0.0
	_respawn_label.anchor_bottom = 1.0
	_respawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_respawn_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_respawn_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	_respawn_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_respawn_label.add_theme_constant_override("outline_size", 6)
	_respawn_label.add_theme_font_size_override("font_size", 32)
	container.add_child(_respawn_label)

func _build_status_effects() -> void:
	# Build material map (flame is created in code to avoid UID issues).
	_effect_materials = {
		"bleed": BLEED_MATERIAL,
		"poison": POISON_MATERIAL,
		"stun": STUN_MATERIAL,
	}
	var flame_shader := load(FLAME_SHADER_PATH) as Shader
	if flame_shader:
		var flame_mat := ShaderMaterial.new()
		flame_mat.shader = flame_shader
		_effect_materials["burn"] = flame_mat

	# -- Top-center labels (existing) --
	_effect_container = HBoxContainer.new()
	_effect_container.anchor_left   = 0.5
	_effect_container.anchor_right  = 0.5
	_effect_container.anchor_top    = 0.0
	_effect_container.anchor_bottom = 0.0
	_effect_container.offset_left   = -200.0
	_effect_container.offset_top    = 60.0
	_effect_container.offset_right  = 200.0
	_effect_container.offset_bottom = 92.0
	_effect_container.add_theme_constant_override("separation", 8)
	_effect_container.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_effect_container)

	# -- Full-screen container for shader border overlays --
	# Render behind everything else (first child = lowest z-order).
	_border_container = Control.new()
	_border_container.anchor_left   = 0.0
	_border_container.anchor_right  = 1.0
	_border_container.anchor_top    = 0.0
	_border_container.anchor_bottom = 1.0
	_border_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_border_container)
	move_child(_border_container, 0)

	# -- Side-panel effect list (right edge, below weapon list) --
	_effect_list = VBoxContainer.new()
	_effect_list.anchor_left   = 1.0
	_effect_list.anchor_right  = 1.0
	_effect_list.anchor_top    = 0.5
	_effect_list.anchor_bottom = 0.5
	_effect_list.offset_left   = -210.0
	_effect_list.offset_top    = 100.0
	_effect_list.offset_right  = -20.0
	_effect_list.offset_bottom = 280.0
	_effect_list.add_theme_constant_override("separation", 4)
	add_child(_effect_list)

# --------------------------------------------------
#  Updates (called from _process)
# --------------------------------------------------

func _process(delta: float) -> void:
	# Enforce ownership visibility every frame -- parent's show()/hide() overrides
	# our visible flag, so we must re-assert it.
	var should_show := is_multiplayer_authority() and not _owner_player.is_bot
	if visible != should_show:
		visible = should_show
		if not should_show:
			return  # skip all updates when hidden

	_border_time += delta

	_update_health()
	_update_health_delta()
	_update_ammo()
	_update_shield()
	_update_stamina()
	_update_team()
	_update_character()
	_update_abilities()
	_update_respawn_timer()
	_update_bg_reload_bars()
	_update_status_effects()

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

func _update_shield() -> void:
	if not _owner_player or not _shield_label:
		return
	var si := _owner_player.shield_instance
	var fire := _owner_player._active_shield_fire
	# Show shield HP if a shield fire is on the current weapon (even if retracted).
	if fire and fire.shield_hp > 0.0:
		_shield_label.visible = true
		var hp := si.hp if (si and si.active) else fire.shield_current_hp
		var pct := hp / fire.shield_hp
		if si and si.broken:
			_shield_label.text = "Shield  BROKEN"
			_shield_label.add_theme_color_override("font_color", Color(0.85, 0.25, 0.25))
		else:
			_shield_label.text = "Shield  %d / %d" % [int(hp), int(fire.shield_hp)]
			if pct > 0.5:
				_shield_label.add_theme_color_override("font_color", Color(0.3, 0.85, 0.95))
			elif pct > 0.25:
				_shield_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.3))
			else:
				_shield_label.add_theme_color_override("font_color", Color(0.95, 0.3, 0.3))
	else:
		_shield_label.visible = false


func _update_stamina() -> void:
	if not _owner_player or _stamina_fills.is_empty():
		return
	var player := _owner_player
	var charges: float = player.stamina
	for i in _stamina_fills.size():
		# Slot i is full when charges >= i + 1, partial while charges is in
		# (i, i + 1), and empty when charges <= i.
		_stamina_fills[i].anchor_right = clampf(charges - float(i), 0.0, 1.0)

	# Flash blue while the dash-jump window is open.
	var in_window: bool = player.dash_time > 0.0 \
		and player.dash_time >= player.dash_jump_window_start \
		and player.dash_time <= player.dash_jump_window_end
	var fill_color := Color(0.30, 0.85, 0.95)
	if in_window and fmod(_border_time, 0.25) < 0.125:
		fill_color = Color(0.4, 0.7, 1.0)
	for i in _stamina_fills.size():
		_stamina_fills[i].color = fill_color

	# Timing feedback text.
	if _stamina_feedback:
		if player._dash_jump_feedback_timer > 0.0:
			_stamina_feedback.text = player._dash_jump_feedback
		else:
			_stamina_feedback.text = ""


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

func _update_character() -> void:
	if _owner_player and _owner_player._character:
		_character_label.text = _owner_player._character.character_name
		_character_label.modulate = Color(0.7, 0.7, 0.7)
	else:
		_character_label.text = ""

func _update_abilities() -> void:
	var am: AbilityManager = _owner_player.ability_manager if _owner_player else null
	if not am:
		_ability_use_label.text = ""
		return

	# Rebuild the left-side list (name + cooldown).
	for child in _ability_list.get_children():
		child.queue_free()
	var abilities: Array[Ability] = am.get_abilities()
	for i in abilities.size():
		var ability: Ability = abilities[i]
		if ability == null:
			continue
		var label := Label.new()
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		label.add_theme_constant_override("outline_size", 4)
		label.add_theme_font_size_override("font_size", 16)
		var remaining := am.get_cooldown_remaining(i)
		var cd_text := "Ready" if remaining <= 0.0 else "%.1fs" % remaining
		label.text = "%d  %s   (%s)" % [i + 1, ability.ability_name, cd_text]
		label.modulate = Color(0.6, 0.6, 0.6) if remaining > 0.0 else Color(0.9, 0.9, 0.9)
		_ability_list.add_child(label)

	# "USING X" prompt while an ability is in progress — either an equipped
	# (non-instant) ability, or a burst fire that is still firing its shots.
	if am.is_equipped() and am.equipped_index >= 0 and am.equipped_index < abilities.size():
		var equipped: Ability = abilities[am.equipped_index]
		if equipped:
			_ability_use_label.text = "USING %s" % equipped.ability_name.to_upper()
			return
	if weapon_controller:
		var active_name: String = weapon_controller.get_active_ability_name()
		if not active_name.is_empty():
			_ability_use_label.text = "USING %s" % active_name.to_upper()
			return
	_ability_use_label.text = ""

func _update_respawn_timer() -> void:
	var container := _respawn_label.get_parent() as Control
	if not container or not _owner_player:
		return

	if not _owner_player.spawned and _owner_player.respawn_timer > 0.0:
		container.visible = true
		var seconds := ceili(_owner_player.respawn_timer)
		_respawn_label.text = "Spawning in %d..." % seconds
	else:
		container.visible = false

# --------------------------------------------------
#  Signal handlers
# --------------------------------------------------

func _on_ammo_updated(_current = null, _max = null) -> void:
	_update_ammo()
	_update_weapon_list()

func _update_bg_reload_bars() -> void:
	if not weapon_controller:
		return
	var weapons := weapon_controller.get_weapons()
	var current_index := weapon_controller.current_weapon_index
	for i in _bg_reload_bars.size():
		if i >= weapons.size():
			break
		var info: Dictionary = weapon_controller.get_reload_info(i)
		if info["active"] and i != current_index:
			_bg_reload_bars[i].visible = true
			_bg_reload_bars[i].value = clamp(info["progress"], 0.0, 1.0)
			_bg_reload_labels[i].modulate = Color(0.3, 0.7, 1.0, 0.9)
		else:
			_bg_reload_bars[i].visible = false
		if i != current_index and not info["active"]:
			# Reset non-active label color (not gold, not blue — just grey).
			_bg_reload_labels[i].modulate = Color(0.65, 0.65, 0.65)

func _update_status_effects() -> void:
	var sem: StatusEffectManager = _owner_player.status_effect_manager if _owner_player else null
	if not sem:
		_clear_all_borders()
		_clear_effect_list()
		return
	var times: Dictionary = sem.get_active_effect_times()
	var ids: Array = times.keys()

	# ---- Top-center labels (existing) ----
	while _effect_labels.size() > ids.size():
		var lbl: Label = _effect_labels.pop_back()
		lbl.queue_free()

	var visible_index := 0
	for i in ids.size():
		var id: String = ids[i]
		var remaining: float = times[id]

		var label: Label
		if visible_index < _effect_labels.size():
			label = _effect_labels[visible_index]
		else:
			label = Label.new()
			label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
			label.add_theme_constant_override("outline_size", 6)
			label.add_theme_font_size_override("font_size", 16)
			label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_effect_container.add_child(label)
			_effect_labels.append(label)
		label.text = "%s %.1fs" % [id.capitalize(), remaining]
		label.visible = true
		visible_index += 1

	# ---- Shader border overlays ----
	# Remove borders for effects that are no longer active.
	var stale_borders: Array[String] = []
	for border_id: String in _border_overlays:
		if not times.has(border_id):
			stale_borders.append(border_id)
	for border_id: String in stale_borders:
		var cr: Control = _border_overlays[border_id]
		cr.queue_free()
		_border_overlays.erase(border_id)

	# Add / update borders for currently active effects.
	for id in ids:
		var mat = _effect_materials.get(id, null)
		if not mat:
			# Fallback: if we don't have a custom shader, still show a plain border.
			var cr: ColorRect
			if _border_overlays.has(id):
				cr = _border_overlays[id]
			else:
				cr = _create_border_overlay(FALLBACK_BORDER_COLOR)
				_border_overlays[id] = cr
			cr.material = null
			cr.color = FALLBACK_BORDER_COLOR
			cr.visible = true
			continue

		var cr: ColorRect
		if _border_overlays.has(id):
			cr = _border_overlays[id]
		else:
			cr = _create_border_overlay()
			cr.material = mat.duplicate()  # unique instance so multiple effects don't share uniforms
			_border_overlays[id] = cr
			cr.visible = true
		# Push elapsed time to every visible border shader.
		for bcr: ColorRect in _border_overlays.values():
			if bcr.visible and bcr.material is ShaderMaterial:
				(bcr.material as ShaderMaterial).set_shader_parameter("u_time", _border_time)

	# ---- Side-panel effect list ----
	# Remove stale entries.
	for list_id in _effect_list_labels:
		if not list_id in times:
			var lbl: Label = _effect_list_labels[list_id]
			lbl.queue_free()
			_effect_list_labels.erase(list_id)

	# Add / update entries.
	for id in ids:
		var remaining: float = times[id]
		var lbl: Label
		if _effect_list_labels.has(id):
			lbl = _effect_list_labels[id]
		else:
			lbl = Label.new()
			lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
			lbl.add_theme_constant_override("outline_size", 4)
			lbl.add_theme_font_size_override("font_size", 14)
			_effect_list.add_child(lbl)
			_effect_list_labels[id] = lbl
		lbl.text = "■ %s  %.1fs" % [id.capitalize(), remaining]
		# Color the label to match the effect.
		match id:
			"bleed":   lbl.modulate = Color(1.0, 0.3, 0.3)
			"burn":    lbl.modulate = Color(1.0, 0.55, 0.1)
			"poison":  lbl.modulate = Color(0.7, 0.4, 1.0)
			"stun":    lbl.modulate = Color(1.0, 0.9, 0.2)
			_:         lbl.modulate = Color(0.8, 0.8, 0.8)
		lbl.visible = true


func _create_border_overlay(col := Color.WHITE) -> ColorRect:
	"""Create a full-screen ColorRect inside _border_container for a border effect."""
	var cr := ColorRect.new()
	cr.anchor_left   = 0.0
	cr.anchor_right  = 1.0
	cr.anchor_top    = 0.0
	cr.anchor_bottom = 1.0
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cr.color = col
	_border_container.add_child(cr)
	return cr


func _clear_all_borders() -> void:
	for cr: ColorRect in _border_overlays.values():
		cr.queue_free()
	_border_overlays.clear()


func _clear_effect_list() -> void:
	for lbl: Label in _effect_list_labels.values():
		lbl.queue_free()
	_effect_list_labels.clear()

func _on_weapon_changed(_index = null, _weapon = null) -> void:
	_update_weapon_list()
	_update_bg_reload_bars()

func _update_weapon_list() -> void:
	if not weapon_controller:
		return
	for child in _weapon_list.get_children():
		child.queue_free()
	_bg_reload_bars.clear()
	_bg_reload_labels.clear()

	var weapons := weapon_controller.get_weapons()
	var current_index := weapon_controller.current_weapon_index

	for i in weapons.size():
		var entry := VBoxContainer.new()
		entry.add_theme_constant_override("separation", 2)

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
		entry.add_child(label)
		_bg_reload_labels.append(label)

		# Progress bar for background reload (hidden by default).
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(0, 8)
		bar.size_flags_horizontal = Control.SIZE_FILL
		bar.max_value = 1.0
		bar.value = 0.0
		bar.modulate = Color(0.3, 0.7, 1.0, 0.8)
		bar.visible = false
		entry.add_child(bar)
		_bg_reload_bars.append(bar)

		_weapon_list.add_child(entry)
