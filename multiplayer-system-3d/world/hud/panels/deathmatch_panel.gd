extends BaseModePanel
class_name DeathmatchPanel

## Deathmatch scoreboard panel.
##
## Displays a horizontal row of player-name + kill-count entries
## at the bottom center of the screen.  Each kill count is enclosed
## in a bordered square.

var _score_container: HBoxContainer
var _player_labels: Array[Label] = []
var _kill_labels:   Array[Label] = []
var _kill_squares:  Array[Panel] = []
var _end_label: Label

func _ready() -> void:
	_build()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

	# Centered strip at the bottom of the screen.
	anchor_left   = 0.5
	anchor_right  = 0.5
	anchor_top    = 1.0
	anchor_bottom = 1.0
	offset_left   = -380
	offset_right  = 380
	offset_top    = -60
	offset_bottom = -4

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.anchor_left   = 0.0
	vbox.anchor_right  = 1.0
	vbox.anchor_top    = 0.0
	vbox.anchor_bottom = 1.0
	add_child(vbox)

	# Score row
	_score_container = HBoxContainer.new()
	_score_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_score_container.add_theme_constant_override("separation", 3)
	_score_container.anchor_left   = 0.0
	_score_container.anchor_right  = 1.0
	vbox.add_child(_score_container)

	# Match-end label (hidden during play)
	_end_label = Label.new()
	_end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_end_label.add_theme_constant_override("outline_size", 8)
	_end_label.add_theme_font_size_override("font_size", 26)
	_end_label.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	_end_label.visible = false
	# Center of screen, as a direct child of the CanvasLayer
	_end_label.anchor_left   = 0.5
	_end_label.anchor_right  = 0.5
	_end_label.anchor_top    = 0.5
	_end_label.anchor_bottom = 0.5
	_end_label.offset_left   = -300
	_end_label.offset_right  = 300
	_end_label.offset_top    = -30
	_end_label.offset_bottom = 10
	add_child(_end_label)

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
		var entry := _create_entry()
		_score_container.add_child(entry.container)
		_player_labels.append(entry.name_label)
		_kill_labels.append(entry.kill_label)
		_kill_squares.append(entry.square)

	while _player_labels.size() > players.size():
		var c = _player_labels.back().get_parent()
		_player_labels.pop_back()
		_kill_labels.pop_back()
		_kill_squares.pop_back()
		c.queue_free()

	players.sort_custom(_compare_kills)

	for i in players.size():
		_player_labels[i].text = players[i]
		_kill_labels[i].text = str(Leaderboard.get_kills(players[i]))

static func _compare_kills(a: String, b: String) -> bool:
	return Leaderboard.get_kills(a) > Leaderboard.get_kills(b)

func _create_entry() -> Dictionary:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 1)
	container.alignment = BoxContainer.ALIGNMENT_CENTER
	container.custom_minimum_size = Vector2(50, 42)

	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	name_label.add_theme_constant_override("outline_size", 2)
	name_label.text = "..."
	container.add_child(name_label)

	# Kill-count square
	var square_style := StyleBoxFlat.new()
	square_style.bg_color = Color(0.06, 0.06, 0.08, 0.75)
	square_style.set_border_width_all(2)
	square_style.border_color = Color(0.55, 0.55, 0.55, 1)
	square_style.set_corner_radius_all(3)

	var square := Panel.new()
	square.add_theme_stylebox_override("panel", square_style)
	square.custom_minimum_size = Vector2(32, 28)
	container.add_child(square)

	var kill_label := Label.new()
	kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kill_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	kill_label.add_theme_font_size_override("font_size", 22)
	kill_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	kill_label.add_theme_constant_override("outline_size", 3)
	kill_label.text = "0"
	kill_label.anchor_left   = 0.0
	kill_label.anchor_right  = 1.0
	kill_label.anchor_top    = 0.0
	kill_label.anchor_bottom = 1.0
	square.add_child(kill_label)

	return {
		"container": container,
		"name_label": name_label,
		"kill_label": kill_label,
		"square": square,
	}

func get_panel_name() -> String:
	return "DeathmatchPanel"
