extends Node3D
class_name ControlPoint

@export var game_mode_component: GameModeComponent
@export var default_owner: Player.Team = Player.Team.FFA
@export var capture_time: float = 4.0
@export var contest_slow_multiplier: float = 0.0
@export var color_neutral: Color = Color.GRAY
@export var color_spi: Color = Color.RED
@export var color_sci: Color = Color.SKY_BLUE

signal captured(team: Player.Team)
signal contested(is_contested: bool)
signal capture_progress_changed(team: Player.Team, progress: float)

var owning_team: Player.Team
var capture_team: Player.Team
var capture_progress: float = 0.0

var is_contested: bool = false
var is_locked: bool = true
var _players_on_point: Array = []

@onready var area: Area3D = $Area3D
@onready var csg_color := $Color
@onready var progress_mesh: MeshInstance3D = $CaptureUI/ProgressMesh
@onready var capture_label: Label3D = $CaptureUI/Label3D

func _ready() -> void:
	owning_team = default_owner
	capture_team = default_owner

	# --- Ensure unique materials (only once) ---
	if csg_color.material_override:
		csg_color.material_override = csg_color.material_override.duplicate(true)

	if progress_mesh.material_override:
		progress_mesh.material_override = progress_mesh.material_override.duplicate(true)

	var surf_mat := progress_mesh.get_active_material(0)
	if surf_mat:
		progress_mesh.set_surface_override_material(0, surf_mat.duplicate(true))
	# ------------------------------------------

	_update_color()
	_update_capture_ui()

	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)

	if game_mode_component:
		game_mode_component.register_control_point(self)
		game_mode_component.phase_changed.connect(_on_phase_changed)

func reset_for_new_round() -> void:
	owning_team = default_owner
	capture_team = default_owner
	capture_progress = 0.0
	is_contested = false
	_players_on_point.clear()

	_update_color()
	_update_capture_ui()

	_rpc_sync_state.rpc(owning_team, capture_team, capture_progress, is_contested)

func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if is_locked:
		return

	var spi_count := _count_team(Player.Team.SPI)
	var sci_count := _count_team(Player.Team.SCI)

	var new_contested := spi_count > 0 and sci_count > 0
	if new_contested != is_contested:
		is_contested = new_contested
		contested.emit(is_contested)

	var pushing_team := Player.Team.FFA
	if spi_count > 0 and sci_count == 0:
		pushing_team = Player.Team.SPI
	elif sci_count > 0 and spi_count == 0:
		pushing_team = Player.Team.SCI

	if pushing_team == Player.Team.FFA:
		return

	var effective_delta := delta
	if is_contested:
		effective_delta *= contest_slow_multiplier

	# DEFENDING
	if pushing_team == owning_team:
		if capture_team != owning_team:
			capture_progress += effective_delta / capture_time
			if capture_progress >= 1.0:
				capture_progress = 1.0
				capture_team = owning_team
		return

	# ATTACKING
	if capture_team != pushing_team:
		capture_progress -= effective_delta / capture_time
		if capture_progress <= 0.0:
			capture_progress = 0.0
			owning_team = Player.Team.FFA
			capture_team = pushing_team
	else:
		capture_progress += effective_delta / capture_time
		if capture_progress >= 1.0:
			capture_progress = 1.0
			_capture(pushing_team)

	capture_progress_changed.emit(capture_team, capture_progress)
	_rpc_sync_state.rpc(owning_team, capture_team, capture_progress, is_contested)

func _capture(team: Player.Team) -> void:
	owning_team = team
	capture_team = team
	capture_progress = 1.0

	captured.emit(team)
	_update_color()
	_update_capture_ui()

	_rpc_on_captured.rpc(team)

# -----------------------------
# Player tracking
# -----------------------------

func _on_body_entered(body: Node3D) -> void:
	if body is Player and body not in _players_on_point:
		_players_on_point.append(body)

func _on_body_exited(body: Node3D) -> void:
	_players_on_point.erase(body)

func _count_team(team: Player.Team) -> int:
	var count := 0
	for p in _players_on_point:
		if p is Player and _player_team_to_gmc(p.team) == team:
			count += 1
	return count

func _player_team_to_gmc(t: Player.Team) -> Player.Team:
	match t:
		Player.Team.SPI: return Player.Team.SPI
		Player.Team.SCI: return Player.Team.SCI
		_: return Player.Team.FFA

func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	is_locked = not game_mode_component.is_objective_unlocked()

# -----------------------------
# Visuals
# -----------------------------

func _update_color() -> void:
	if csg_color.material_override and csg_color.material_override is StandardMaterial3D:
		var mat := csg_color.material_override as StandardMaterial3D
		mat.albedo_color = _team_color(owning_team)

func _update_capture_ui() -> void:
	_refresh_progress_mesh()
	_refresh_label()

func _refresh_progress_mesh() -> void:
	var fill := capture_progress
	progress_mesh.scale = Vector3(fill, 1.0, fill)

	var col := _team_color(capture_team if capture_progress > 0.0 else owning_team)

	var mat := progress_mesh.get_active_material(0)
	if mat and mat is StandardMaterial3D:
		var smat := mat as StandardMaterial3D
		smat.albedo_color = Color.WHITE if is_contested else col

func _refresh_label() -> void:
	if is_contested:
		capture_label.text = "CONTESTED"
		capture_label.modulate = Color.WHITE
	elif capture_progress > 0.0:
		capture_label.text = "%d%%" % int(capture_progress * 100)
		capture_label.modulate = _team_color(capture_team)
	elif owning_team != Player.Team.FFA:
		capture_label.text = _team_name(owning_team)
		capture_label.modulate = _team_color(owning_team)
	else:
		capture_label.text = ""

func _team_color(team: Player.Team) -> Color:
	match team:
		Player.Team.SPI: return color_spi
		Player.Team.SCI: return color_sci
		_: return color_neutral

func _team_name(team: Player.Team) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return ""

# -----------------------------
# RPC
# -----------------------------

@rpc("authority", "call_local", "unreliable")
func _rpc_sync_state(p_owning, p_cap_team, p_progress, p_contested) -> void:
	owning_team = p_owning
	capture_team = p_cap_team
	capture_progress = p_progress
	is_contested = p_contested

	capture_progress_changed.emit(capture_team, capture_progress)
	_update_color()
	_update_capture_ui()

@rpc("authority", "call_local", "reliable")
func _rpc_on_captured(team: Player.Team) -> void:
	owning_team = team
	capture_team = team
	capture_progress = 1.0

	captured.emit(team)
	_update_color()
	_update_capture_ui()
