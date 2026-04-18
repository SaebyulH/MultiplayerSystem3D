extends ItemList

@export var leaderboard_component: LeaderboardComponent

func _process(delta: float) -> void:
	if leaderboard_component == null:
		return
	
	clear()
	
	var players = leaderboard_component.get_players()
	
	# Optional: sort players by kills descending
	players.sort_custom(func(a, b):
		return leaderboard_component.get_kills(a) > leaderboard_component.get_kills(b)
	)
	
	for player in players:
		var kills = leaderboard_component.get_kills(player)
		var deaths = leaderboard_component.get_deaths(player)
		
		var row = "%-15s   D: %-3d   K: %-3d" % [player, deaths, kills]
		add_item(row)
