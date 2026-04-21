extends Label

func _process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer():
		text = "Killstreak: " + str(Leaderboard.get_killstreak(str(multiplayer.get_unique_id())))
