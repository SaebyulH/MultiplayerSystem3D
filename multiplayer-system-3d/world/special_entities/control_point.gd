extends Node3D
class_name ControlPoint

## A capturable point. Placeable in TrenchBroom as the `ControlPoint` entity — see
## `trenchbroom/entities/control_point.tres`.
##
## [b]The capture volume is a `trigger` brush, not a child of this scene.[/b] Whoever stands
## in the brush is fed here through [method add_occupant] / [method remove_occupant]; the
## brush's `target` names this point's [member targetname], and
## [method BrushEntityUtil.link_targets] wires the two together at map build time. That is why
## there is no `Area3D` below: a volume you draw in the map is visible, draggable and per
## placement, where a `BoxShape3D` in a `.tscn` is none of those. It also means a map with no
## [FuncGodotMap] has to author the brush by hand — see `docs/05-known-issues.md`.
##
## Only the server simulates capture ([method _process] returns on every other peer); the two
## RPCs below carry the result. Body tracking is deliberately peer-local and ungated, exactly
## as it was when an `Area3D` did it — nothing reads the list off the server.
##
## [b]The label is the whole readout.[/b] This used to also carry a colour-changing CSG box
## and a torus progress ring; both said what the label already says, and the colour pair cost
## three exports plus a per-instance material duplication on every spawn.

## This point's name in the map. A `trigger` brush's `target` resolves against it.
@export var targetname: String = ""
@export var default_owner: Player.Team = Player.Team.FFA
@export var capture_time: float = 4.0
@export var contest_slow_multiplier: float = 0.0

signal captured(team: Player.Team)
signal contested(is_contested: bool)
signal capture_progress_changed(team: Player.Team, progress: float)

var owning_team: Player.Team
var capture_team: Player.Team
var capture_progress: float = 0.0
var _sync_timer: float = 0.0
const CP_SYNC_RATE: float = 0.1  # 10 Hz

var is_contested: bool = false
var is_locked: bool = true
var _players_on_point: Array = []

var _gmc: GameModeComponent

@onready var capture_label: Label3D = $Label3D

func _ready() -> void:
	owning_team = default_owner
	capture_team = default_owner

	_refresh_label()

	# Resolved from the global rather than an `@export NodePath`, which TrenchBroom cannot
	# author.  `Map._enter_tree()` (`maps/map.gd:18`) sets it before any descendant's `_ready`,
	# so it is live on every path a map is built — boot, `load_match_map`, and a client's
	# spawner-driven instantiation.  It is *not* cleared when the lobby tears its world down,
	# though, so a freed component still compares unequal to null in GDScript;
	# `is_instance_valid` is the check that actually holds — same reasoning as
	# `world/special_entities/health_pack_spawner.gd`.
	_gmc = GameManager.game_mode_component
	if not is_instance_valid(_gmc):
		return

	_gmc.register_control_point(self)
	_gmc.phase_changed.connect(_on_phase_changed)

func reset_for_new_round() -> void:
	owning_team = default_owner
	capture_team = default_owner
	capture_progress = 0.0
	is_contested = false
	_players_on_point.clear()

	_refresh_label()

	_rpc_sync_state.rpc(owning_team, capture_team, capture_progress, is_contested)

func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	# Before the lock check, so a point that is locked for a whole round does not accumulate
	# freed Players the rest of the round and then count them on unlock.
	_prune_occupants()

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
	_sync_timer += delta
	if _sync_timer >= CP_SYNC_RATE:
		_sync_timer = 0.0
		_rpc_sync_state.rpc(owning_team, capture_team, capture_progress, is_contested)

func _capture(team: Player.Team) -> void:
	owning_team = team
	capture_team = team
	capture_progress = 1.0

	captured.emit(team)
	_refresh_label()

	_rpc_on_captured.rpc(team)

# -----------------------------
# Occupancy
# -----------------------------

## Called by the `trigger` brush wired to this point's [member targetname].  Filtering to
## Players lives here rather than in the brush so the brush stays generic; it is also what
## [method _prune_occupants] has to undo when one is freed mid-round.
func add_occupant(body: Node3D) -> void:
	if body is Player and body not in _players_on_point:
		_players_on_point.append(body)

func remove_occupant(body: Node3D) -> void:
	_players_on_point.erase(body)

## Drops occupants that have been freed.  A disconnect frees a Player without necessarily
## emitting `body_exited`, and a dangling entry would keep a ghost team capturing the point
## forever.  Backwards so an entry can be erased in place — the same walk
## `world/special_entities/health_pack.gd` does.
func _prune_occupants() -> void:
	for i in range(_players_on_point.size() - 1, -1, -1):
		if not is_instance_valid(_players_on_point[i]):
			_players_on_point.remove_at(i)

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
	is_locked = not _gmc.is_objective_unlocked()

# -----------------------------
# Visuals
# -----------------------------

## The label is the only readout left, so its wording carries the whole state.  Colours are
## fixed: `Color.GRAY` reads as inert and white as live.  Team identity is in the text
## (`SPI` / `SCI`), not in a tint.
func _refresh_label() -> void:
	if is_locked:
		capture_label.text = "LOCKED"
		capture_label.modulate = Color(0.8, 0.8, 0.8)
	elif is_contested:
		capture_label.text = "CONTESTED"
		capture_label.modulate = Color.WHITE
	elif capture_progress > 0.0:
		capture_label.text = "%d%%" % int(capture_progress * 100)
		capture_label.modulate = Color.WHITE
	elif owning_team != Player.Team.FFA:
		capture_label.text = _team_name(owning_team)
		capture_label.modulate = Color.WHITE
	else:
		capture_label.text = ""

func _team_name(team: Player.Team) -> String:
	match team:
		Player.Team.SPI: return "SPI"
		Player.Team.SCI: return "SCI"
		_: return ""

## Returns a dictionary snapshot of this point's state for HUD sync.
func get_cp_state() -> Dictionary:
	return {
		"owning_team": owning_team,
		"capture_team": capture_team,
		"capture_progress": capture_progress,
		"is_contested": is_contested,
		"is_locked": is_locked,
	}

## Apply a state dictionary from a sync snapshot.
## Called when a late-joining client receives the full game state,
## or when the periodic reliable sync arrives.
func apply_cp_state(state: Dictionary) -> void:
	owning_team = state.get("owning_team", owning_team)
	capture_team = state.get("capture_team", capture_team)
	capture_progress = state.get("capture_progress", capture_progress)
	is_contested = state.get("is_contested", is_contested)
	is_locked = state.get("is_locked", is_locked)

	capture_progress_changed.emit(capture_team, capture_progress)
	_refresh_label()

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
	_refresh_label()

@rpc("authority", "call_local", "reliable")
func _rpc_on_captured(team: Player.Team) -> void:
	owning_team = team
	capture_team = team
	capture_progress = 1.0

	captured.emit(team)
	_refresh_label()
