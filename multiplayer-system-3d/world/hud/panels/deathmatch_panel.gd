extends BaseModePanel
class_name DeathmatchPanel

## Deathmatch scoreboard panel.
##
## Displays a horizontal row of player-name + kill-count entries
## at the bottom center of the screen.  Each kill count is enclosed
## in a bordered square.

const _entry_scene := preload("res://world/hud/panels/deathmatch_entry.tscn")

@onready var _score_container: HBoxContainer = $VBox/ScoreContainer
@onready var _end_label: Label = $EndLabel

var _player_labels: Array[Label] = []
var _kill_labels:   Array[Label] = []
var _kill_squares:  Array[Panel] = []

func update_display(data: Dictionary) -> void:
	var ended: bool   = data.get("deathmatch_ended", false)
	var winner: String = data.get("winner_name", "")
	var reason: String = data.get("end_reason", "")

	# Scores
	var players := Leaderboard.get_players()
	_refresh_entries(players)

	if ended and winner != "":
		var reason_text := "First to %d kills!" % [
			data.get("kills_to_win", 20)
		] if reason == "kills" else "Most kills after time!"
		_end_label.text = "%s wins!  Match over  —  %s" % [winner, reason_text]
		_end_label.visible = true
	else:
		_end_label.visible = false

func _refresh_entries(players: Array) -> void:
	while _player_labels.size() < players.size():
		var entry := _entry_scene.instantiate()
		_score_container.add_child(entry)
		_player_labels.append(entry.get_node("NameLabel") as Label)
		_kill_labels.append(entry.get_node("KillSquare/KillLabel") as Label)
		_kill_squares.append(entry.get_node("KillSquare") as Panel)

	while _player_labels.size() > players.size():
		var name_label := _player_labels.pop_back() as Label
		_kill_labels.pop_back()
		_kill_squares.pop_back()
		name_label.get_parent().queue_free()

	players.sort_custom(_compare_kills)

	for i in players.size():
		_player_labels[i].text = players[i]
		_kill_labels[i].text = str(Leaderboard.get_kills(players[i]))

static func _compare_kills(a: String, b: String) -> bool:
	return Leaderboard.get_kills(a) > Leaderboard.get_kills(b)

func get_panel_name() -> String:
	return "DeathmatchPanel"
