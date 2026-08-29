extends Node
class_name DeathmatchAnnouncer

## Client-side PA/announcer voice for the DEATHMATCH mode.
##
## Plays the "Deathmatch", "N kills remaining", and podium ("First / Second /
## Third place", "Match over — defeat") voice lines at the appropriate moments.
## GameModeComponent drives this node from its server→client RPCs, so each peer
## hears the announcement exactly once (including the host).
##
## The voices are routed through a dedicated "Announcer" audio bus whose
## high-pass / low-pass / reverb chain makes them sound like they're coming
## over a cheap arena ceiling speaker instead of a clean studio voice.

# ─────────────────────────────────────────────
#  SOUND ASSETS
# ─────────────────────────────────────────────

const SOUND_ANNOUNCE := preload("res://assets/deathmatch_sounds/deathmatch_announce.mp3")
const SOUND_KILLS_10 := preload("res://assets/deathmatch_sounds/10_kills_remain.mp3")
const SOUND_KILLS_5  := preload("res://assets/deathmatch_sounds/5_kills_remain.mp3")
const SOUND_KILLS_1  := preload("res://assets/deathmatch_sounds/1_kill_remain.mp3")
const SOUND_FIRST    := preload("res://assets/deathmatch_sounds/first_place.mp3")
const SOUND_SECOND   := preload("res://assets/deathmatch_sounds/second_place.mp3")
const SOUND_THIRD    := preload("res://assets/deathmatch_sounds/third_place.mp3")
const SOUND_DEFEAT   := preload("res://assets/deathmatch_sounds/match_over_defeat.mp3")

const BUS_NAME := "Announcer"

var _player: AudioStreamPlayer


func _ready() -> void:
	_setup_bus()
	_player = AudioStreamPlayer.new()
	_player.bus = BUS_NAME
	_player.volume_db = -2.0
	add_child(_player)


## Build the PA-speaker bus once per process (band-limited voice + roomy tail).
func _setup_bus() -> void:
	if AudioServer.get_bus_index(BUS_NAME) != -1:
		return

	AudioServer.add_bus()  # appended at the end of the bus list
	var idx: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, BUS_NAME)

	# Cut sub-bass rumble and top-end hiss so the voice reads as coming through
	# a tinny ceiling speaker, then add a short reverb tail for the "big room"
	# announcement feel.
	var highpass := AudioEffectHighPassFilter.new()
	highpass.cutoff_hz = 180.0
	AudioServer.add_bus_effect(idx, highpass)

	var lowpass := AudioEffectLowPassFilter.new()
	lowpass.cutoff_hz = 3800.0
	AudioServer.add_bus_effect(idx, lowpass)

	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.4
	reverb.damping = 0.6
	reverb.wet = 0.28
	reverb.dry = 1.0
	AudioServer.add_bus_effect(idx, reverb)


# ─────────────────────────────────────────────
#  PUBLIC API  (called by GameModeComponent)
# ─────────────────────────────────────────────

func play_announce() -> void:
	_play(SOUND_ANNOUNCE)


func play_kills_remaining(remaining: int) -> void:
	match remaining:
		10: _play(SOUND_KILLS_10)
		5:  _play(SOUND_KILLS_5)
		1:  _play(SOUND_KILLS_1)


## Play the local player's final-placement line.  [param standings] is the
## server-authoritative player ordering (best first).
func play_placement(standings: Array) -> void:
	match _local_rank(standings):
		1: _play(SOUND_FIRST)
		2: _play(SOUND_SECOND)
		3: _play(SOUND_THIRD)
		_: _play(SOUND_DEFEAT)


# ─────────────────────────────────────────────
#  INTERNAL
# ─────────────────────────────────────────────

func _local_rank(standings: Array) -> int:
	var my_id := str(multiplayer.get_unique_id())
	var pos: int = standings.find(my_id)
	if pos != -1:
		return pos + 1

	# Fallback: derive from the locally-synced leaderboard if the standings
	# never arrived (e.g. a late join).
	var players := Leaderboard.get_players()
	players.sort_custom(func(a, b): return Leaderboard.get_kills(a) > Leaderboard.get_kills(b))
	pos = players.find(my_id)
	return pos + 1 if pos != -1 else 0


func _play(stream: AudioStream) -> void:
	if stream == null:
		return
	_player.stream = stream
	_player.play()
