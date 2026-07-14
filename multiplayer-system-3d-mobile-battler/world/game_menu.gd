extends Control

@onready var leaderboard: ItemList = $VBoxContainer/Leaderboard
@onready var killstreak_label: Label = $Killstreak

@export var base_sound: AudioStream

var player_id: String
var play_token: int = 0

# Pitch constants (E-based semitone scaling)
const PITCH_E  := pow(2.0, 0.0 / 12.0)
const PITCH_FS := pow(2.0, 2.0 / 12.0)
const PITCH_G  := pow(2.0, 3.0 / 12.0)
const PITCH_A  := pow(2.0, 5.0 / 12.0)
const PITCH_B  := pow(2.0, 7.0 / 12.0)


func _ready() -> void:
	player_id = str(multiplayer.get_unique_id())
	$ID.text = "ID: " + player_id

	killstreak_label.text = ""

	Leaderboard.killstreak_changed.connect(_on_killstreak_changed)


func _process(delta: float) -> void:
	if Leaderboard == null:
		return

	leaderboard.clear()

	var players = Leaderboard.get_players()

	players.sort_custom(func(a, b):
		return Leaderboard.get_kills(a) > Leaderboard.get_kills(b)
	)

	for player in players:
		var kills := Leaderboard.get_kills(player)
		var deaths := Leaderboard.get_deaths(player)
		var streak := Leaderboard.get_killstreak(player)
		var damage := Leaderboard.get_damage(player)
		var self_dam := Leaderboard.get_self_damage(player)
		var heal_others := Leaderboard.get_heal_others(player)
		var self_heal := Leaderboard.get_self_heal(player)

		var row := (
			"%-12s  K:%-3d  D:%-3d  Streak:%-3d  DMG:%-5d  Self DMG:%-5d  Heal Others:%-4d Self Heal:%-4d"
			% [player, kills, deaths, streak, int(damage), int(self_dam), int(heal_others), int(self_heal)]
		)

		leaderboard.add_item(row)

		if player == player_id:
			killstreak_label.text = "%d☠︎︎" % streak


# EXPECTED SIGNAL: (player_id, killstreak)
func _on_killstreak_changed(player_name: String, killstreak: int) -> void:
	if player_name != player_id:
		return

	play_token += 1
	var token := play_token

	var seq := _get_pitch_sequence(killstreak)
	_play_sequence_async(seq, token)

func _play_sequence_async(seq: Array[float], token: int) -> void:
	for pitch in seq:
		if token != play_token:
			return
		if not is_inside_tree():
			return
		var p := AudioStreamPlayer.new()
		p.stream = base_sound
		p.pitch_scale = pitch
		add_child(p)
		p.play()
		p.finished.connect(func(): p.queue_free())
		await get_tree().create_timer(0.15).timeout
	if token == play_token:
		if not is_inside_tree():
			return
		await get_tree().create_timer(0.3).timeout


# =========================
# PITCH MAPPING
# =========================
func _get_pitch_sequence(ks: int) -> Array[float]:
	match ks:
		# === KILL 1-5: Sparse, ominous opening ===
		1:
			return [PITCH_E]
		2:
			return [PITCH_G]
		3:
			return [PITCH_A]
		4:
			return [PITCH_B]
		5:
			return [PITCH_E, PITCH_E, PITCH_G, PITCH_A, PITCH_B]
		# === KILL 6-10: Picking up, minor tension ===
		6:
			return [PITCH_E, PITCH_G]
		7:
			return [PITCH_G, PITCH_A]
		8:
			return [PITCH_A, PITCH_B]
		9:
			return [PITCH_B, PITCH_E]
		10:
			return [PITCH_E, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_G]
		# === KILL 11-15: Ascending urgency ===
		11:
			return [PITCH_E, PITCH_FS, PITCH_G]
		12:
			return [PITCH_G, PITCH_A, PITCH_B]
		13:
			return [PITCH_A, PITCH_B, PITCH_E]
		14:
			return [PITCH_FS, PITCH_A, PITCH_B]
		15:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_A, PITCH_G]
		# === KILL 16-20: Driving rhythm, more density ===
		16:
			return [PITCH_E, PITCH_G, PITCH_E, PITCH_B]
		17:
			return [PITCH_G, PITCH_A, PITCH_G, PITCH_E]
		18:
			return [PITCH_A, PITCH_B, PITCH_A, PITCH_G]
		19:
			return [PITCH_B, PITCH_A, PITCH_FS, PITCH_E]
		20:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		# === KILL 21-25: Epic swell, heroic feel ===
		21:
			return [PITCH_E, PITCH_G, PITCH_B, PITCH_G, PITCH_E]
		22:
			return [PITCH_FS, PITCH_A, PITCH_B, PITCH_A, PITCH_FS]
		23:
			return [PITCH_G, PITCH_B, PITCH_E, PITCH_B, PITCH_G]
		24:
			return [PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A]
		25:
			return [PITCH_E, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		# === KILL 26-30: Full climax, relentless and soaring ===
		26:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E]
		27:
			return [PITCH_B, PITCH_A, PITCH_G, PITCH_FS, PITCH_E, PITCH_FS]
		28:
			return [PITCH_E, PITCH_G, PITCH_B, PITCH_E, PITCH_B, PITCH_G, PITCH_E]
		29:
			return [PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G]
		30:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
		_:
			return [PITCH_E, PITCH_FS, PITCH_G, PITCH_A, PITCH_B, PITCH_E, PITCH_B, PITCH_A, PITCH_G, PITCH_FS]
