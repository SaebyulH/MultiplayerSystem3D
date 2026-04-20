extends ItemList

func _process(delta: float) -> void:
	if Leaderboard == null:
		return

	clear()

	var players = Leaderboard.get_players()

	# Sort by kills (descending)
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
			% [player, kills, deaths, streak, damage, self_dam, heal_others, self_heal,]
		)

		add_item(row)
