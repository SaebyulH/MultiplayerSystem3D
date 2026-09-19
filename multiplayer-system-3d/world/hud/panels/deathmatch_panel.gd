extends BaseModePanel
class_name DeathmatchPanel

## Top scoreboard: player portraits + kill counts flanking the timer.
##
## Players are split across the left/right bars by kill count (highest first);
## a single player goes on the right.  The local player's entry gets a light
## blue background.

const _entry_scene := preload("res://world/hud/panels/deathmatch_entry.tscn")
const OWN_BG := Color(0.25, 0.5, 0.9, 0.45)  # light blue for the local player

@onready var _left_container: HBoxContainer = $LeftBar/Container
@onready var _right_container: HBoxContainer = $RightBar/Container
@onready var _end_label: Label = $EndLabel

var _left_entries: Array[Control] = []
var _right_entries: Array[Control] = []

## Whether to show the kill count next to each portrait (deathmatch only).
var show_kills := true

func update_display(data: Dictionary) -> void:
	var ended: bool   = data.get("deathmatch_ended", false)
	var winner: String = data.get("winner_name", "")
	var reason: String = data.get("end_reason", "")

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
	players.sort_custom(_compare_kills)

	var left: Array
	var right: Array
	if players.size() <= 1:
		left = []
		right = players
	else:
		var mid := ceili(players.size() / 2.0)
		left = players.slice(0, mid)
		right = players.slice(mid)

	_populate(_left_container, _left_entries, left)
	_populate(_right_container, _right_entries, right)

func _populate(container: HBoxContainer, entries: Array, players: Array) -> void:
	while entries.size() < players.size():
		var entry := _entry_scene.instantiate() as Control
		container.add_child(entry)
		entries.append(entry)
	while entries.size() > players.size():
		var entry := entries.pop_back() as Control
		entry.queue_free()

	var my_id := str(multiplayer.get_unique_id())
	for i in players.size():
		var entry := entries[i] as Control
		var kill_label := entry.get_node("HBox/KillLabel") as Label
		var portrait := entry.get_node("HBox/Portrait") as TextureRect
		var bg := entry.get_node("Bg") as ColorRect

		kill_label.visible = show_kills
		if show_kills:
			kill_label.text = str(Leaderboard.get_kills(players[i]))
		var p := GameManager.find_player(players[i]) as Player
		var tex: Texture2D = null
		if p and p._character:
			tex = p._character.portrait
		portrait.texture = tex
		bg.color = OWN_BG if players[i] == my_id else Color(0, 0, 0, 0)

static func _compare_kills(a: String, b: String) -> bool:
	return Leaderboard.get_kills(a) > Leaderboard.get_kills(b)

func get_panel_name() -> String:
	return "DeathmatchPanel"
