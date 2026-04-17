extends Control




func _on_host_game_pressed() -> void:
	NetworkManager.create_server()
	NetworkManager.load_game_scene()
	
func _on_join_game_pressed() -> void:
	NetworkManager.create_client()
	NetworkManager.load_game_scene()
	
	
func _on_send_test_message_pressed() -> void:
	_send_test_message.rpc("I am connected to you")

@rpc("any_peer", "call_remote", )
func _send_test_message(message: String):
	print("Peer [%s] recieved message [%s] from peer [%s]" 
	%[get_tree().get_multiplayer().get_unique_id(), 
	message,
	get_tree().get_multiplayer().get_remote_sender_id()])
	
