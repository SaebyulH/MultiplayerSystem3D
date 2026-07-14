extends AnimatableBody3D
class_name PayloadNode

# ─────────────────────────────────────────────
#  EXPORTS
# ─────────────────────────────────────────────

@export var game_mode_component: GameModeComponent
@export var path_follower: PathFollow3D
@export var checkpoints: Array[Marker3D] = []
@export var attacking_team: Player.Team = Player.Team.SPI

@export var push_radius: float = 3.0
## Base push speed with 1 attacker (progress 0..1 per second)
@export var push_speed_base: float = 0.035
## Speed multiplier per pusher count (diminishing returns)
## Index 0 = 1 pusher, index 1 = 2 pushers, etc.
@export var push_speed_curve: Array[float] = [1.0, 1.6, 2.0, 2.3, 2.5]
@export var max_push_players: int = 3

@export var return_speed: float = 0.005
@export var return_delay: float = 10.0
@export var vertical_offset: Vector3 = Vector3.ZERO
@export var heal_per_second: float = 10.0

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal checkpoint_reached(index: int)
signal payload_delivered()
signal push_started()
signal push_stopped()

# ─────────────────────────────────────────────
#  STATE
# ─────────────────────────────────────────────

enum PayloadState {
	LOCKED,
	IDLE,
	PUSHING,
	CONTESTED,
	RETURNING,
	AT_CHECKPOINT,
	DELIVERED,
}

var payload_state: PayloadState = PayloadState.LOCKED
var progress: float = 0.0
var is_delivered: bool = false
var is_locked: bool = true

## Read by GameModeComponent / HybridMode for overtime/contested checks
var is_contested: bool = false
var is_being_pushed: bool = false

var _return_countdown: float = 0.0
var _next_checkpoint_index: int = 0
var _pushers: Array = []

var _checkpoint_progresses: Array[float] = []

@onready var push_zone: Area3D = $PushZone
@onready var label: Label3D = $Label3D
@onready var mesh: MeshInstance3D = $MeshInstance3D

var _mesh_mat: StandardMaterial3D

# ─────────────────────────────────────────────
#  READY
# ─────────────────────────────────────────────

func _ready() -> void:
	if not path_follower:
		push_error("PayloadNode: path_follower export is not set!")
		return
	if not game_mode_component:
		push_error("PayloadNode: game_mode_component export is not set!")
		return

	_mesh_mat = StandardMaterial3D.new()
	mesh.set_surface_override_material(0, _mesh_mat)

	_bake_checkpoint_progresses()

	push_zone.body_entered.connect(_on_body_entered)
	push_zone.body_exited.connect(_on_body_exited)

	game_mode_component.phase_changed.connect(_on_phase_changed)
	game_mode_component.round_won.connect(_on_round_won)

	if game_mode_component.game_mode == GameModeComponent.GameMode.HYBRID:
		game_mode_component.hybrid_point_captured_signal.connect(_on_hybrid_point_captured)

	game_mode_component.register_payload(self)

	_apply_position_to_path()
	_set_state(PayloadState.LOCKED)

func _bake_checkpoint_progresses() -> void:
	_checkpoint_progresses.clear()
	for cp in checkpoints:
		_checkpoint_progresses.append(_world_pos_to_path_progress(cp.global_position))

# ─────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────

func set_locked(locked: bool) -> void:
	is_locked = locked
	if is_locked:
		_set_state(PayloadState.LOCKED)

# ─────────────────────────────────────────────
#  PROCESS
# ─────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if is_delivered or is_locked:
		return

	_tick_healing(delta)

	var attackers := _count_team(attacking_team)
	var defenders := _count_team(_get_defending_team())

	# ── Update readable flags ─────────────────
	is_being_pushed = attackers > 0 and defenders == 0
	is_contested    = attackers > 0 and defenders > 0

	# ── Determine new state ───────────────────
	var new_state: PayloadState

	if attackers > 0 and defenders == 0:
		new_state = PayloadState.PUSHING
	elif attackers > 0 and defenders > 0:
		new_state = PayloadState.CONTESTED
	else:
		is_being_pushed = false
		is_contested    = false
		if _return_countdown > 0.0:
			_return_countdown -= delta
			new_state = PayloadState.IDLE
		else:
			var checkpoint_floor := _get_checkpoint_floor()
			if progress > checkpoint_floor + 0.0005:
				new_state = PayloadState.RETURNING
			else:
				new_state = PayloadState.AT_CHECKPOINT

	# ── Apply movement ────────────────────────
	match new_state:
		PayloadState.PUSHING:
			_return_countdown = return_delay
			var speed_mult := _get_speed_multiplier(attackers)
			progress += push_speed_base * speed_mult * delta
			progress = minf(progress, 1.0)
			_check_checkpoints()
			if progress >= 1.0:
				_on_delivered()
				return

		PayloadState.CONTESTED:
			_return_countdown = return_delay

		PayloadState.RETURNING:
			var checkpoint_floor := _get_checkpoint_floor()
			progress -= return_speed * delta
			if progress <= checkpoint_floor:
				progress = checkpoint_floor
				new_state = PayloadState.AT_CHECKPOINT

		PayloadState.AT_CHECKPOINT:
			progress = _get_checkpoint_floor()

	if new_state != payload_state:
		_set_state(new_state)

	# Server drives physics position with move_and_collide so players
	# are carried rather than shoved
	_sync_position_to_path()
	_update_label()
	_rpc_sync.rpc(progress, payload_state, _return_countdown)

# ─────────────────────────────────────────────
#  SPEED CURVE
# ─────────────────────────────────────────────

func _get_speed_multiplier(attacker_count: int) -> float:
	if attacker_count <= 0:
		return 0.0
	var idx := mini(attacker_count, push_speed_curve.size()) - 1
	idx = mini(idx, max_push_players - 1)
	return push_speed_curve[idx]

# ─────────────────────────────────────────────
#  STATE SETTER
# ─────────────────────────────────────────────

func _set_state(new_state: PayloadState) -> void:
	payload_state = new_state
	_update_visuals()

# ─────────────────────────────────────────────
#  HEALING
# ─────────────────────────────────────────────

func _tick_healing(delta: float) -> void:
	# Server only — called after the is_server() guard in _physics_process
	for p in _pushers:
		if p is Player and p.team == attacking_team:
			p.change_health(heal_per_second * delta, p.name)

# ─────────────────────────────────────────────
#  PATH POSITION
# ─────────────────────────────────────────────

## Server: use move_and_collide so CharacterBody3D players are carried by
## the cart rather than shoved away from it.
func _sync_position_to_path() -> void:
	path_follower.progress_ratio = progress
	var target_pos := path_follower.global_position + vertical_offset
	#move_and_collide(target_pos - global_position)
	global_basis = path_follower.global_basis
	global_transform = path_follower.global_transform

func _apply_position_to_path() -> void:
	path_follower.progress_ratio = progress
	global_position = path_follower.global_position + vertical_offset
	global_basis    = path_follower.global_basis

# ─────────────────────────────────────────────
#  CHECKPOINTS
# ─────────────────────────────────────────────

func _check_checkpoints() -> void:
	if _next_checkpoint_index >= _checkpoint_progresses.size():
		return
	var cp_progress := _checkpoint_progresses[_next_checkpoint_index]
	if progress >= cp_progress:
		checkpoint_reached.emit(_next_checkpoint_index)
		_rpc_checkpoint_reached.rpc(_next_checkpoint_index)
		_next_checkpoint_index += 1

func _get_checkpoint_floor() -> float:
	if _next_checkpoint_index == 0:
		return 0.0
	return _checkpoint_progresses[_next_checkpoint_index - 1]

func _world_pos_to_path_progress(world_pos: Vector3) -> float:
	if not path_follower:
		return 0.0
	var path: Path3D = path_follower.get_parent()
	if not path or not path.curve:
		return 0.0
	var closest := path.curve.get_closest_offset(path.to_local(world_pos))
	return closest / path.curve.get_baked_length()

# ─────────────────────────────────────────────
#  DELIVERY
# ─────────────────────────────────────────────

func _on_delivered() -> void:
	is_delivered    = true
	is_being_pushed = false
	is_contested    = false
	progress        = 1.0
	payload_delivered.emit()
	_set_state(PayloadState.DELIVERED)
	_rpc_delivered.rpc()
	if game_mode_component:
		game_mode_component.on_payload_delivered(attacking_team)

# ─────────────────────────────────────────────
#  ROUND RESET
# ─────────────────────────────────────────────

func _on_round_won(_winning_team: Player.Team) -> void:
	pass

# ─────────────────────────────────────────────
#  PHASE HANDLER
# ─────────────────────────────────────────────

func _on_phase_changed(new_phase: GameModeComponent.PhaseState) -> void:
	if new_phase == GameModeComponent.PhaseState.SETUP:
		_rpc_reset.rpc()

	var is_hybrid := game_mode_component and \
		game_mode_component.game_mode == GameModeComponent.GameMode.HYBRID

	if is_hybrid:
		if not game_mode_component.hybrid_mode or \
				not game_mode_component.hybrid_mode.point_is_captured:
			is_locked = true
			_set_state(PayloadState.LOCKED)
		return

	is_locked = not game_mode_component.is_objective_unlocked()
	if is_locked:
		_set_state(PayloadState.LOCKED)

func _on_hybrid_point_captured() -> void:
	is_locked = false

# ─────────────────────────────────────────────
#  TEAM HELPERS
# ─────────────────────────────────────────────

func _get_defending_team() -> Player.Team:
	match attacking_team:
		Player.Team.SPI: return Player.Team.SCI
		Player.Team.SCI: return Player.Team.SPI
		_:               return Player.Team.FFA

func _count_team(team: Player.Team) -> int:
	var count := 0
	for p in _pushers:
		if p is Player and p.team == team:
			count += 1
	return count

func get_push_progress() -> float:
	return progress

func get_attackers_on_point() -> int:
	return _count_team(attacking_team)

func get_defenders_on_point() -> int:
	return _count_team(_get_defending_team())

# ─────────────────────────────────────────────
#  AREA TRACKING
# ─────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if body is Player and body not in _pushers:
		_pushers.append(body)

func _on_body_exited(body: Node3D) -> void:
	_pushers.erase(body)

# ─────────────────────────────────────────────
#  VISUALS
# ─────────────────────────────────────────────

func _update_visuals() -> void:
	_update_color()
	_update_label()

func _update_color() -> void:
	if not _mesh_mat:
		return
	match payload_state:
		PayloadState.PUSHING:       _mesh_mat.albedo_color = Color.RED
		PayloadState.CONTESTED:     _mesh_mat.albedo_color = Color.ORANGE
		PayloadState.RETURNING:     _mesh_mat.albedo_color = Color.CORNFLOWER_BLUE
		PayloadState.AT_CHECKPOINT: _mesh_mat.albedo_color = Color.YELLOW
		PayloadState.DELIVERED:     _mesh_mat.albedo_color = Color.GREEN
		PayloadState.LOCKED:        _mesh_mat.albedo_color = Color.DARK_GRAY
		_:                          _mesh_mat.albedo_color = Color.WHITE

func _update_label() -> void:
	if not label:
		return
	match payload_state:
		PayloadState.DELIVERED:
			label.text = "DELIVERED"
		PayloadState.AT_CHECKPOINT:
			label.text = "CHECKPOINT\n%d%%" % int(progress * 100)
		PayloadState.CONTESTED:
			label.text = "CONTESTED\n%d%%" % int(progress * 100)
		PayloadState.PUSHING:
			var attackers := _count_team(attacking_team)
			var mult      := _get_speed_multiplier(attackers)
			label.text = "PUSHING x%.1f\n%d%%" % [mult, int(progress * 100)]
		PayloadState.RETURNING:
			label.text = "RETURNING\n%d%%" % int(progress * 100)
		PayloadState.IDLE:
			label.text = "%.1fs\n%d%%" % [_return_countdown, int(progress * 100)]
		PayloadState.LOCKED:
			label.text = "LOCKED"
		_:
			label.text = "%d%%" % int(progress * 100)

# ─────────────────────────────────────────────
#  RPC
# ─────────────────────────────────────────────

@rpc("authority", "call_local", "unreliable")
func _rpc_sync(p_progress: float, p_state: PayloadState, p_countdown: float) -> void:
	if multiplayer.is_server():
		return
	progress          = p_progress
	payload_state     = p_state
	_return_countdown = p_countdown
	# Clients use direct assignment — no physics involvement
	_apply_position_to_path()
	_update_visuals()

@rpc("authority", "call_local", "reliable")
func _rpc_reset() -> void:
	progress              = 0.0
	is_delivered          = false
	is_being_pushed       = false
	is_contested          = false
	_return_countdown     = 0.0
	_next_checkpoint_index = 0
	_pushers.clear()
	var is_hybrid := game_mode_component and \
		game_mode_component.game_mode == GameModeComponent.GameMode.HYBRID
	is_locked = is_hybrid
	_apply_position_to_path()
	_set_state(PayloadState.LOCKED)

@rpc("authority", "call_local", "reliable")
func _rpc_checkpoint_reached(index: int) -> void:
	checkpoint_reached.emit(index)

@rpc("authority", "call_local", "reliable")
func _rpc_push_started() -> void:
	push_started.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_push_stopped() -> void:
	push_stopped.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_delivered() -> void:
	if multiplayer.is_server():
		return
	is_delivered = true
	payload_delivered.emit()
	_update_visuals()
