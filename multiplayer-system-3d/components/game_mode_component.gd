extends Node
class_name GameModeComponent

# ─────────────────────────────────────────────
#  ENUMS
# ─────────────────────────────────────────────

enum GameMode {
	ESCORT,       ## Push payload to end
	DOMINATION,   ## Hold all points simultaneously
	KOTH,         ## King of the Hill: best of N rounds
	HYBRID,       ## Capture point, then escort payload (like Overwatch Hybrid)
	CONTROL,      ## Like Overwatch Control/KOTH but BO3 with separate sub-maps
}

#enum Player.Team {
	#SPI,
	#SCI,
	#FFA,
#}

enum PhaseState {
	WAITING_FOR_PLAYERS,
	SETUP,           # Players locked in spawn
	OBJECTIVE_LOCKED,# Transitional: round started but obj not yet unlocked
	ACTIVE,          # Normal play
	OVERTIME,        # Overtime window
	ROUND_END,       # Brief pause between rounds
	MATCH_END,       # Game over
}

# ─────────────────────────────────────────────
#  SIGNALS
# ─────────────────────────────────────────────

signal phase_changed(new_phase: PhaseState)
signal round_won(winning_team: Player.Team)
signal match_won(winning_team: Player.Team)
signal overtime_started()
signal overtime_ended()
signal time_updated(remaining: float)   # fires every second for HUD

signal koth_updated(time_held: Dictionary)
# ─────────────────────────────────────────────
#  EXPORTS — GENERAL
# ─────────────────────────────────────────────

@export_group("Mode")
@export var game_mode: GameMode = GameMode.KOTH

@export_group("Timing")
## How long players are locked in spawn before the round begins
@export var setup_time: float = 5.0
## Delay after setup before objectives become capturable/pushable
@export var objective_unlock_delay: float = 0.0
## Total round time (seconds). 0 = no limit
@export var round_time: float = 300.0
## How long to pause between rounds
@export var round_end_pause: float = 5.0

@export_group("Overtime")
## Whether overtime is enabled for this mode
@export var overtime_enabled: bool = true
## Max overtime duration (seconds). 0 = infinite while contested
@export var overtime_max_duration: float = 60.0
## For modes where overtime triggers when time runs out and obj is contested
@export var overtime_requires_contest: bool = true

# ─────────────────────────────────────────────
#  EXPORTS — ESCORT
# ─────────────────────────────────────────────

@export_group("Escort Settings")
## How fast the payload moves per player pushing (units/sec per pusher)
@export var payload_push_speed: float = 2.0
## How fast payload returns when uncontested (units/sec)
@export var payload_return_speed: float = 0.5
## Seconds before payload starts returning after pushers leave
@export var payload_return_delay: float = 3.0
## Number of checkpoints along the track (payload stops briefly at each)
@export var payload_checkpoint_count: int = 2
## How long payload is locked at checkpoint before next segment opens
@export var payload_checkpoint_pause: float = 3.0
## Max pushers that increase speed (additional pushers beyond this don't add speed)
@export var payload_max_speed_pushers: int = 3

# ─────────────────────────────────────────────
#  EXPORTS — DOMINATION
# ─────────────────────────────────────────────

@export_group("Domination Settings")
## Seconds a team must hold ALL points to win the round
@export var domination_hold_time: float = 10.0

# ─────────────────────────────────────────────
#  EXPORTS — KOTH / CONTROL
# ─────────────────────────────────────────────

@export_group("KOTH / Control Settings")
## Number of rounds to win the match
@export var rounds_to_win: int = 2
## How long a team must hold the point to win the round (seconds)
@export var koth_capture_time_to_win: float = 30.0
## Whether the capture clock pauses when point is contested
@export var koth_pause_on_contest: bool = true

# ─────────────────────────────────────────────
#  RUNTIME STATE  (server-authoritative)
# ─────────────────────────────────────────────

var current_phase: PhaseState = PhaseState.WAITING_FOR_PLAYERS
var phase_timer: float = 0.0       # counts DOWN
var overtime_timer: float = 0.0

# Round wins per team
var round_wins: Dictionary = {
	Player.Team.SPI: 0,
	Player.Team.SCI: 0,
}

# KOTH: time held per team this round (counts UP)
var koth_time_held: Dictionary = {
	Player.Team.SPI: 0.0,
	Player.Team.SCI: 0.0,
}

# Escort
var payload_progress: float = 0.0      # 0.0 → 1.0
var payload_return_countdown: float = 0.0
var payload_checkpoint_index: int = 0
var payload_at_checkpoint: bool = false
var payload_checkpoint_timer: float = 0.0

# Domination
var domination_hold_timer: float = 0.0  # how long all points held

# Registered control points
var _control_points: Array[ControlPoint] = []

# HUD tick helper
var _hud_tick: float = 0.0

# ─────────────────────────────────────────────
#  INIT
# ─────────────────────────────────────────────

func _ready() -> void:
	if not multiplayer.is_server():
		return
	_transition_phase(PhaseState.SETUP)

func register_control_point(cp: ControlPoint) -> void:
	if cp not in _control_points:
		_control_points.append(cp)

func unregister_control_point(cp: ControlPoint) -> void:
	_control_points.erase(cp)


# add at top with other state vars
var _payload: PayloadNode = null

func register_payload(p: PayloadNode) -> void:
	_payload = p

func on_payload_delivered(winning_team: Player.Team) -> void:
	_end_round(winning_team)

# replace the two stubs:
func _get_payload_pushers() -> Array:
	if _payload:
		return [_payload.get_attackers_on_point()]  # count, not array — or adjust overtime check
	return []



# ─────────────────────────────────────────────
#  PROCESS  (server only drives timers)
# ─────────────────────────────────────────────

func _process(delta: float) -> void:
	if not multiplayer.is_server() or not is_multiplayer_authority():
		return

	# HUD update once/sec
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

#func _tick_active(delta: float) -> void:
	#if round_time > 0.0:
		#phase_timer -= delta
#
	#match game_mode:
		#GameMode.ESCORT, GameMode.HYBRID:
			#_tick_escort(delta)
		#GameMode.DOMINATION:
			#_tick_domination(delta)
		#GameMode.KOTH, GameMode.CONTROL:
			#_tick_koth(delta)
#
	## Time expired
	##if round_time > 0.0 and phase_timer <= 0.0:
		##_on_time_expired()
#
#
#
# In _tick_active, replace the escort case:
func _tick_active(delta: float) -> void:
	if round_time > 0.0:
		phase_timer -= delta

	match game_mode:
		GameMode.ESCORT, GameMode.HYBRID:
			pass  # PayloadNode drives itself and calls on_payload_delivered directly
		GameMode.DOMINATION:
			_tick_domination(delta)
		GameMode.KOTH, GameMode.CONTROL:
			_tick_koth(delta)

	#if round_time > 0.0 and phase_timer <= 0.0:
		#_on_time_expired()

# Same in _tick_overtime:
func _tick_overtime(delta: float) -> void:
	overtime_timer -= delta

	match game_mode:
		GameMode.KOTH, GameMode.CONTROL:
			_tick_koth(delta)
		# Escort overtime: payload just needs to keep moving, PayloadNode handles it

	var still_contested := _is_objective_contested()
	if not still_contested:
		_end_overtime_no_resolution()
	elif overtime_max_duration > 0.0 and overtime_timer <= 0.0:
		_end_overtime_no_resolution()





#func _tick_overtime(delta: float) -> void:
	#overtime_timer -= delta
#
	#match game_mode:
		#GameMode.ESCORT, GameMode.HYBRID:
			#_tick_escort(delta)
		#GameMode.KOTH, GameMode.CONTROL:
			#_tick_koth(delta)
#
	## Check if overtime should end without resolution
	#var still_contested := _is_objective_contested()
	#if not still_contested:
		#_end_overtime_no_resolution()
	#elif overtime_max_duration > 0.0 and overtime_timer <= 0.0:
		#_end_overtime_no_resolution()

func _tick_round_end(delta: float) -> void:
	phase_timer -= delta
	if phase_timer <= 0.0:
		_start_new_round()

# ─────────────────────────────────────────────
#  MODE-SPECIFIC TICKS
# ─────────────────────────────────────────────

func _tick_escort(delta: float) -> void:
	var pushers := _get_payload_pushers()
	var num_pushers := mini(pushers.size(), payload_max_speed_pushers)
	var defenders := _get_payload_defenders()

	if num_pushers > 0 and defenders.is_empty():
		# Payload moves forward
		payload_return_countdown = payload_return_delay
		var push_amount := payload_push_speed * num_pushers * delta
		payload_progress = minf(payload_progress + push_amount, 1.0)
		_broadcast_payload_progress(payload_progress)

		# Checkpoint logic
		var checkpoint_threshold := float(payload_checkpoint_index + 1) / float(payload_checkpoint_count + 1)
		if payload_checkpoint_index < payload_checkpoint_count and payload_progress >= checkpoint_threshold:
			payload_at_checkpoint = true
			payload_checkpoint_timer = payload_checkpoint_pause
			payload_checkpoint_index += 1

		if payload_progress >= 1.0:
			_on_escort_delivered()

	elif payload_at_checkpoint:
		payload_checkpoint_timer -= delta
		if payload_checkpoint_timer <= 0.0:
			payload_at_checkpoint = false

	else:
		# Return countdown
		if payload_return_countdown > 0.0:
			payload_return_countdown -= delta
		else:
			payload_progress = maxf(payload_progress - payload_return_speed * delta, 0.0)
			_broadcast_payload_progress(payload_progress)

func _tick_domination(delta: float) -> void:
	if _all_points_owned_by_same_team() != Player.Team.FFA:
		domination_hold_timer += delta
		if domination_hold_timer >= domination_hold_time:
			_end_round(_all_points_owned_by_same_team())
	else:
		domination_hold_timer = 0.0

func _tick_koth(delta: float) -> void:
	var holding_team := _get_koth_holder()
	var contested := _is_koth_contested()

	if holding_team != Player.Team.FFA:
		if not (koth_pause_on_contest and contested):
			koth_time_held[holding_team] += delta
			koth_updated.emit(koth_time_held)
			_broadcast_koth_progress(koth_time_held)
			if koth_time_held[holding_team] >= koth_capture_time_to_win:
				_end_round(holding_team)

# ─────────────────────────────────────────────
#  EVENT HANDLERS
# ─────────────────────────────────────────────

#func _on_time_expired() -> void:
	#if overtime_enabled and overtime_requires_contest and _is_objective_contested():
		#_start_overtime()
	#else:
		## Determine winner by current state
		##var winner := _determine_time_expired_winner()
		##_end_round(winner)

func _on_escort_delivered() -> void:
	_end_round(Player.Team.SPI)  # Attackers win — configure per map

#func _start_overtime() -> void:
	#overtime_timer = overtime_max_duration
	#_transition_phase(PhaseState.OVERTIME)
	#overtime_started.emit()
	#_rpc_notify_overtime_started.rpc()

func _start_overtime() -> void:
	overtime_timer = overtime_max_duration
	_transition_phase(PhaseState.OVERTIME)
	# REMOVE THIS LINE: overtime_started.emit() 
	_rpc_notify_overtime_started.rpc() # This will emit it for you locally!


func _end_overtime_no_resolution() -> void:
	var winner := _determine_time_expired_winner()
	overtime_ended.emit()
	_end_round(winner)
#
#func _end_round(winner: Player.Team) -> void:
	#if winner != Player.Team.FFA:
		#round_wins[winner] += 1
	#round_won.emit(winner)
	#_rpc_round_won.rpc(winner)
#
	#if round_wins[winner] >= rounds_to_win:
		#_transition_phase(PhaseState.MATCH_END)
		#match_won.emit(winner)
		#_rpc_match_won.rpc(winner)
	#else:
		#_transition_phase(PhaseState.ROUND_END)
		
func _end_round(winner: Player.Team) -> void:
	# Server increments the score authoritatively
	if winner != Player.Team.FFA:
		round_wins[winner] += 1
		print("ROUND WINS INCREAESD")
	# Sync the authoritative round_wins and notify all peers (including server)
	_rpc_round_won.rpc(winner, round_wins.duplicate(true))

	# Check win condition using server-authoritative state
	if winner != Player.Team.FFA and round_wins[winner] >= rounds_to_win:
		_transition_phase(PhaseState.MATCH_END)
		_rpc_match_won.rpc(winner)
	else:
		_transition_phase(PhaseState.ROUND_END)
		
func _start_new_round() -> void:
	# Reset per-round state
	koth_time_held[Player.Team.SPI] = 0.0
	koth_time_held[Player.Team.SCI] = 0.0
	domination_hold_timer = 0.0
	payload_progress = 0.0
	payload_checkpoint_index = 0
	payload_at_checkpoint = false
	
	for child in GameManager.spawn_parent.get_children():
		if child is Player:
			child.reset()

	for cp in _control_points:
		cp.reset_for_new_round()

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
#  HELPER QUERIES  (pure logic, no RPC)
# ─────────────────────────────────────────────

func is_objective_unlocked() -> bool:
	return current_phase == PhaseState.ACTIVE or current_phase == PhaseState.OVERTIME

func is_players_locked_in_spawn() -> bool:
	return current_phase == PhaseState.SETUP or current_phase == PhaseState.WAITING_FOR_PLAYERS

#func _get_payload_pushers() -> Array:
	## Returns players of the attacking team near the payload
	## Stub: ControlPoint or PayloadNode should call notify_pushers each frame
	#return []  # Filled via notify_payload_contact

func _get_payload_defenders() -> Array:
	return []

func _get_koth_holder() -> Player.Team:
	if _control_points.is_empty():
		return Player.Team.FFA
	return _control_points[0].owning_team

func _is_koth_contested() -> bool:
	if _control_points.is_empty():
		return false
	return _control_points[0].is_contested

#func _is_objective_contested() -> bool:
	#match game_mode:
		#GameMode.KOTH, GameMode.CONTROL:
			#return _is_koth_contested()
		#GameMode.ESCORT, GameMode.HYBRID:
			#return not _get_payload_pushers().is_empty()
		#_:
			#return false

func _is_objective_contested() -> bool:
	match game_mode:
		GameMode.KOTH, GameMode.CONTROL:
			return _is_koth_contested()
		GameMode.ESCORT, GameMode.HYBRID:
			if _payload:
				return _payload.is_contested or _payload.is_being_pushed
			return false
		_:
			return false

func _all_points_owned_by_same_team() -> Player.Team:
	if _control_points.is_empty():
		return Player.Team.FFA
	var first_team: Player.Team = _control_points[0].owning_team
	if first_team == Player.Team.FFA:
		return Player.Team.FFA
	for cp in _control_points:
		if cp.owning_team != first_team:
			return Player.Team.FFA
	return first_team

func _determine_time_expired_winner() -> Player.Team:
	match game_mode:
		GameMode.KOTH, GameMode.CONTROL:
			# Whoever has more time held wins
			if koth_time_held[Player.Team.SPI] > koth_time_held[Player.Team.SCI]:
				return Player.Team.SPI
			elif koth_time_held[Player.Team.SCI] > koth_time_held[Player.Team.SPI]:
				return Player.Team.SCI
			else:
				return Player.Team.FFA  # Draw
		GameMode.ESCORT, GameMode.HYBRID:
			# Defenders win on time expiry
			return Player.Team.SCI
		GameMode.DOMINATION:
			var holder := _all_points_owned_by_same_team()
			return holder
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

@rpc("authority", "call_local", "reliable")
func _rpc_round_won(winning_team: Player.Team, authoritative_wins: Dictionary) -> void:
	# Clients adopt the server's authoritative round_wins
	round_wins = authoritative_wins
	round_won.emit(winning_team)

@rpc("authority", "call_local", "reliable")
func _rpc_match_won(winning_team: Player.Team) -> void:
	match_won.emit(winning_team)

@rpc("authority", "call_local", "reliable")
func _rpc_notify_overtime_started() -> void:
	overtime_started.emit()

@rpc("authority", "call_local", "unreliable")
func _rpc_broadcast_time(remaining: float) -> void:
	phase_timer = remaining
	time_updated.emit(remaining)

@rpc("authority", "call_local", "unreliable")
func _rpc_broadcast_payload(progress: float) -> void:
	payload_progress = progress

@rpc("authority", "call_local", "unreliable")
func _rpc_broadcast_koth(held: Dictionary) -> void:
	koth_time_held = held
	koth_updated.emit(koth_time_held)

func _broadcast_time(remaining: float) -> void:
	_rpc_broadcast_time.rpc(remaining)

func _broadcast_payload_progress(progress: float) -> void:
	_rpc_broadcast_payload.rpc(progress)

func _broadcast_koth_progress(held: Dictionary) -> void:
	_rpc_broadcast_koth.rpc(held)
