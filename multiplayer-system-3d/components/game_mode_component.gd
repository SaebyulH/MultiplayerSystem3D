extends Node
class_name GameModeComponent

# ─────────────────────────────────────────────
#  ENUMS
# ─────────────────────────────────────────────

enum GameMode {
	ESCORT,      ## Push payload to end
	DOMINATION,  ## Hold all points simultaneously
	KOTH,        ## King of the Hill: best of N rounds
	HYBRID,      ## Capture point, then escort payload
	CONTROL,     ## Like KOTH but BO3 with separate sub-maps
	DEATHMATCH,  ## Free-for-all: first to 20 kills or highest after 10 min
}

enum PhaseState {
	WAITING_FOR_PLAYERS,
	SETUP,            # Players locked in spawn
	OBJECTIVE_LOCKED, # Transitional: round started but obj not yet unlocked
	ACTIVE,           # Normal play
	OVERTIME,         # Overtime window
	ROUND_END,        # Brief pause between rounds
	MATCH_END,        # Game over
}

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal phase_changed(new_phase: PhaseState)
signal round_won(winning_team: Player.Team)
signal match_won(winning_team: Player.Team)
signal overtime_started()
signal overtime_ended()
signal time_updated(remaining: float)
signal koth_updated(time_held: Dictionary)
signal hybrid_point_captured_signal()

# ─────────────────────────────────────────────
#  EXPORTS — GENERAL
# ─────────────────────────────────────────────

@export_group("Mode")
@export var game_mode: GameMode = GameMode.KOTH

@export_group("Timing")
@export var setup_time: float = 5.0
@export var objective_unlock_delay: float = 0.0
@export var round_time: float = 300.0
@export var round_end_pause: float = 5.0

@export_group("Overtime")
@export var overtime_enabled: bool = true
@export var overtime_max_duration: float = 60.0
@export var overtime_requires_contest: bool = true

@export_group("Rounds")
@export var rounds_to_win: int = 2

# ─────────────────────────────────────────────
#  MODE NODES  (created in _create_mode_nodes)
# ─────────────────────────────────────────────

var escort_mode: EscortMode
var hybrid_mode: HybridMode
var koth_mode: KothMode
var domination_mode: DominationMode
var deathmatch_mode: DeathmatchMode
var deathmatch_announcer: DeathmatchAnnouncer

# ─────────────────────────────────────────────
#  RUNTIME STATE
# ─────────────────────────────────────────────

var current_phase: PhaseState = PhaseState.WAITING_FOR_PLAYERS
var phase_timer: float = 0.0
var overtime_timer: float = 0.0

var round_wins: Dictionary = {
	Player.Team.SPI: 0,
	Player.Team.SCI: 0,
}

var _hud_tick: float = 0.0
var _sync_timer: float = 0.0
const SYNC_INTERVAL: float = 0.1  # 10 Hz game state sync

# ─────────────────────────────────────────────
#  INIT
# ─────────────────────────────────────────────

func _ready() -> void:
	_create_mode_nodes()
	_connect_mode_signals()
	if game_mode == GameMode.DEATHMATCH:
		_create_deathmatch_announcer()
	if not multiplayer.is_server():
		return
	_transition_phase(PhaseState.SETUP)

func _create_mode_nodes() -> void:
	# Only create if not already assigned in the inspector
	if not escort_mode:
		escort_mode = EscortMode.new()
	if not hybrid_mode:
		hybrid_mode = HybridMode.new()
	if not koth_mode:
		koth_mode = KothMode.new()
	if not domination_mode:
		domination_mode = DominationMode.new()
	if not deathmatch_mode:
		deathmatch_mode = DeathmatchMode.new()

func _create_deathmatch_announcer() -> void:
	if deathmatch_announcer:
		return
	deathmatch_announcer = DeathmatchAnnouncer.new()
	deathmatch_announcer.name = "DeathmatchAnnouncer"
	add_child(deathmatch_announcer)

@rpc("authority", "call_local", "reliable")
func _rpc_sync_state(state: Dictionary) -> void:
	current_phase = state["phase"]
	phase_timer = state["phase_timer"]
	round_wins = state["round_wins"]

	if koth_mode:
		koth_mode.apply_sync_state(state["koth"])

	if domination_mode:
		domination_mode.apply_sync_state(state["domination"])

	if hybrid_mode:
		hybrid_mode.apply_sync_state(state["hybrid"])

	if deathmatch_mode:
		deathmatch_mode.apply_sync_state(state.get("deathmatch", {}))

func _build_snapshot() -> Dictionary:
	return {
		"phase": current_phase,
		"phase_timer": phase_timer,
		"round_wins": round_wins,

		"koth": koth_mode.get_sync_state() if koth_mode else {},
		"domination": domination_mode.get_sync_state() if domination_mode else {},
		"hybrid": hybrid_mode.get_sync_state() if hybrid_mode else {},
		"deathmatch": deathmatch_mode.get_sync_state() if deathmatch_mode else {},
	}


func _connect_mode_signals() -> void:
	if escort_mode:
		escort_mode.round_won.connect(_end_round)
	if hybrid_mode:
		hybrid_mode.round_won.connect(_end_round)
		hybrid_mode.point_captured.connect(_on_hybrid_point_captured)
	if koth_mode:
		koth_mode.round_won.connect(_end_round)
		koth_mode.time_held_updated.connect(_on_koth_time_held_updated)
	if domination_mode:
		domination_mode.round_won.connect(_end_round)
	if deathmatch_mode:
		deathmatch_mode.deathmatch_ended.connect(_on_deathmatch_ended)
		deathmatch_mode.announce_kills_remaining.connect(_on_dm_kills_remaining)

# ─────────────────────────────────────────────
#  REGISTRATION  (called by ControlPoint / PayloadNode)
# ─────────────────────────────────────────────

func register_control_point(cp: ControlPoint) -> void:
	if koth_mode:
		koth_mode.register_control_point(cp)
	if hybrid_mode:
		hybrid_mode.register_control_point(cp)
	if domination_mode:
		domination_mode.register_control_point(cp)

func unregister_control_point(cp: ControlPoint) -> void:
	if koth_mode:
		koth_mode.unregister_control_point(cp)
	if hybrid_mode:
		hybrid_mode.unregister_control_point(cp)
	if domination_mode:
		domination_mode.unregister_control_point(cp)

func register_payload(p: PayloadNode) -> void:
	if escort_mode:
		escort_mode.register_payload(p)
	if hybrid_mode:
		hybrid_mode.register_payload(p)

func on_payload_delivered(winning_team: Player.Team) -> void:
	match game_mode:
		GameMode.ESCORT:
			if escort_mode:
				escort_mode.on_payload_delivered(winning_team)
		GameMode.HYBRID:
			if hybrid_mode:
				hybrid_mode.on_payload_delivered(winning_team)

# ─────────────────────────────────────────────
#  PROCESS
# ─────────────────────────────────────────────

func _process(delta: float) -> void:
	if not multiplayer.is_server() or not is_multiplayer_authority():
		return

	_hud_tick += delta
	if _hud_tick >= 1.0:
		_hud_tick = 0.0
		_broadcast_time(phase_timer)

	match current_phase:
		PhaseState.SETUP:
			_tick_setup(delta)
		PhaseState.OBJECTIVE_LOCKED:
			_tick_objective_locked(delta)
		PhaseState.ACTIVE:
			_tick_active(delta)
		PhaseState.OVERTIME:
			_tick_overtime(delta)
		PhaseState.ROUND_END:
			_tick_round_end(delta)

	_sync_timer += delta
	if _sync_timer >= SYNC_INTERVAL:
		_sync_timer = 0.0
		_rpc_sync_state.rpc(_build_snapshot())

		# Also sync rounds_to_win in case a mode overrides it.
		_rpc_set_rounds_to_win.rpc(_effective_rounds_to_win())

# ─────────────────────────────────────────────
#  PHASE TICKS
# ─────────────────────────────────────────────

func _tick_setup(delta: float) -> void:
	phase_timer -= delta
	if phase_timer <= 0.0:
		if objective_unlock_delay > 0.0:
			_transition_phase(PhaseState.OBJECTIVE_LOCKED)
		else:
			_transition_phase(PhaseState.ACTIVE)

func _tick_objective_locked(delta: float) -> void:
	phase_timer -= delta
	if phase_timer <= 0.0:
		_transition_phase(PhaseState.ACTIVE)

func _tick_active(delta: float) -> void:
	if round_time > 0.0:
		phase_timer -= delta

	# Mode-specific tick
	var match_ended := false
	match game_mode:
		GameMode.ESCORT:
			pass  # EscortMode / PayloadNode drives itself
		GameMode.HYBRID:
			if hybrid_mode:
				hybrid_mode.tick(delta)
		GameMode.DOMINATION:
			if domination_mode:
				domination_mode.tick(delta)
		GameMode.KOTH, GameMode.CONTROL:
			if koth_mode:
				koth_mode.tick(delta)
		GameMode.DEATHMATCH:
			if deathmatch_mode:
				match_ended = deathmatch_mode.tick()

	if match_ended:
		return

	if round_time > 0.0 and phase_timer <= 0.0:
		_on_time_expired()

func _tick_overtime(delta: float) -> void:
	overtime_timer -= delta

	match game_mode:
		GameMode.KOTH, GameMode.CONTROL:
			if koth_mode:
				koth_mode.tick(delta)

	if not _is_objective_contested():
		_end_overtime_no_resolution()
	elif overtime_max_duration > 0.0 and overtime_timer <= 0.0:
		_end_overtime_no_resolution()

func _tick_round_end(delta: float) -> void:
	phase_timer -= delta
	if phase_timer <= 0.0:
		_start_new_round()

# ─────────────────────────────────────────────
#  EVENT HANDLERS
# ─────────────────────────────────────────────

func _on_hybrid_point_captured() -> void:
	_rpc_notify_hybrid_point_captured.rpc()

func _on_koth_time_held_updated(time_held: Dictionary) -> void:
	koth_updated.emit(time_held)

func _on_deathmatch_ended(winner_name: String, reason: String) -> void:
	if _round_ended:
		return
	_round_ended = true
	_rpc_deathmatch_ended.rpc(winner_name, reason, deathmatch_mode.standings if deathmatch_mode else [])
	_transition_phase(PhaseState.MATCH_END)


func _on_dm_kills_remaining(remaining: int) -> void:
	_rpc_announce_kills_remaining.rpc(remaining)

func _on_time_expired() -> void:
	# Deathmatch handles time expiry differently — no teams.
	if game_mode == GameMode.DEATHMATCH:
		if deathmatch_mode:
			deathmatch_mode.determine_timer_winner()
			_on_deathmatch_ended(deathmatch_mode.winner_name, deathmatch_mode.end_reason)
		return

	if overtime_enabled and overtime_requires_contest and _is_objective_contested():
		_start_overtime()
	else:
		_end_round(_determine_time_expired_winner())

func _start_overtime() -> void:
	overtime_timer = overtime_max_duration
	_transition_phase(PhaseState.OVERTIME)
	_rpc_notify_overtime_started.rpc()

func _end_overtime_no_resolution() -> void:
	var winner := _determine_time_expired_winner()
	overtime_ended.emit()
	_end_round(winner)

var _round_ended: bool = false

func _end_round(winner: Player.Team) -> void:
	if _round_ended:
		return
	_round_ended = true

	if winner != Player.Team.FFA:
		round_wins[winner] += 1
	_rpc_round_won.rpc(winner, round_wins.duplicate(true))

	if winner != Player.Team.FFA and round_wins[winner] >= _effective_rounds_to_win():
		_transition_phase(PhaseState.MATCH_END)
		_rpc_match_won.rpc(winner)
	else:
		_transition_phase(PhaseState.ROUND_END)

## Returns the number of rounds needed to win, checking mode-specific overrides.
func _effective_rounds_to_win() -> int:
	match game_mode:
		GameMode.DOMINATION:
			if domination_mode and domination_mode.rounds_to_win > 0:
				return domination_mode.rounds_to_win
	return rounds_to_win

func _start_new_round() -> void:
	_round_ended = false
	_rpc_set_rounds_to_win.rpc(_effective_rounds_to_win())
	for child in GameManager.spawn_parent.get_children():
		if child is Player:
			child.rpc_reset.rpc(child._get_spawn_position())

	match game_mode:
		GameMode.ESCORT:
			if escort_mode:
				escort_mode.reset()
		GameMode.HYBRID:
			if hybrid_mode:
				hybrid_mode.reset()
		GameMode.DOMINATION:
			if domination_mode:
				domination_mode.reset()
		GameMode.KOTH, GameMode.CONTROL:
			if koth_mode:
				koth_mode.reset()
		GameMode.DEATHMATCH:
			if deathmatch_mode:
				deathmatch_mode.reset()

	_transition_phase(PhaseState.SETUP)

# ─────────────────────────────────────────────
#  PHASE TRANSITION
# ─────────────────────────────────────────────

func _transition_phase(new_phase: PhaseState) -> void:
	current_phase = new_phase

	match new_phase:
		PhaseState.SETUP:
			phase_timer = setup_time
		PhaseState.OBJECTIVE_LOCKED:
			phase_timer = objective_unlock_delay
		PhaseState.ACTIVE:
			if game_mode == GameMode.DEATHMATCH and deathmatch_mode:
				phase_timer = deathmatch_mode.round_duration
			else:
				phase_timer = round_time
		PhaseState.OVERTIME:
			phase_timer = overtime_max_duration
		PhaseState.ROUND_END:
			phase_timer = round_end_pause
		PhaseState.MATCH_END:
			phase_timer = 0.0

	phase_changed.emit(new_phase)
	_rpc_sync_phase.rpc(new_phase, phase_timer)

# ─────────────────────────────────────────────
#  HELPER QUERIES
# ─────────────────────────────────────────────

func is_objective_unlocked() -> bool:
	return current_phase == PhaseState.ACTIVE or current_phase == PhaseState.OVERTIME

func is_players_locked_in_spawn() -> bool:
	return current_phase == PhaseState.SETUP or current_phase == PhaseState.WAITING_FOR_PLAYERS

func _is_objective_contested() -> bool:
	match game_mode:
		GameMode.KOTH, GameMode.CONTROL:
			return koth_mode.is_contested() if koth_mode else false
		GameMode.DEATHMATCH:
			return false
		GameMode.ESCORT:
			return escort_mode.is_contested() if escort_mode else false
		GameMode.HYBRID:
			return hybrid_mode.is_objective_contested() if hybrid_mode else false
		_:
			return false

func _determine_time_expired_winner() -> Player.Team:
	match game_mode:
		GameMode.KOTH, GameMode.CONTROL:
			return koth_mode.determine_tiebreak_winner() if koth_mode else Player.Team.FFA
		GameMode.DEATHMATCH:
			return Player.Team.FFA
		GameMode.ESCORT, GameMode.HYBRID:
			return Player.Team.SCI  # Defenders win on time expiry
		GameMode.DOMINATION:
			return domination_mode.determine_tiebreak_winner() if domination_mode else Player.Team.FFA
		_:
			return Player.Team.FFA

# ─────────────────────────────────────────────
#  RPC — server → all clients
# ─────────────────────────────────────────────

@rpc("authority", "call_local", "reliable")
func _rpc_sync_phase(new_phase: PhaseState, timer: float) -> void:
	current_phase = new_phase
	phase_timer = timer
	phase_changed.emit(new_phase)

	# Announce the match when it goes live (SETUP -> ACTIVE), once per peer.
	if game_mode == GameMode.DEATHMATCH and new_phase == PhaseState.ACTIVE and deathmatch_announcer:
		deathmatch_announcer.play_announce()

@rpc("authority", "call_local", "reliable")
func _rpc_round_won(winning_team: Player.Team, authoritative_wins: Dictionary) -> void:
	round_wins = authoritative_wins
	round_won.emit(winning_team)

@rpc("authority", "call_local", "reliable")
func _rpc_match_won(winning_team: Player.Team) -> void:
	match_won.emit(winning_team)

@rpc("authority", "call_local", "reliable")
func _rpc_notify_overtime_started() -> void:
	overtime_started.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_notify_hybrid_point_captured() -> void:
	hybrid_point_captured_signal.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_deathmatch_ended(winner_name: String, reason: String, standings: Array = []) -> void:
	if deathmatch_mode:
		deathmatch_mode.winner_name = winner_name
		deathmatch_mode.end_reason = reason
		deathmatch_mode.standings = standings
		deathmatch_mode.deathmatch_ended.emit(winner_name, reason)
	if deathmatch_announcer:
		deathmatch_announcer.play_placement(standings)


@rpc("authority", "call_local", "reliable")
func _rpc_announce_kills_remaining(remaining: int) -> void:
	if deathmatch_announcer:
		deathmatch_announcer.play_kills_remaining(remaining)

@rpc("authority", "call_local", "unreliable")
func _rpc_broadcast_time(remaining: float) -> void:
	phase_timer = remaining
	time_updated.emit(remaining)

@rpc("authority", "call_local", "reliable")
func _rpc_set_rounds_to_win(target: int) -> void:
	rounds_to_win = target

func _broadcast_time(remaining: float) -> void:
	_rpc_broadcast_time.rpc(remaining)
