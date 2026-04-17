extends Node

const SERVER_PORT: int = 8080

func create_server():
	var enet_network_peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	enet_network_peer.create_server(SERVER_PORT)
	get_tree().get_multiplayer().multiplayer_peer = enet_network_peer
	print("Server created!")
	
func create_client(host_ip: String = "localhost", host_port: int = SERVER_PORT):
	_setup_client_connection_signals()
	var enet_network_peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	enet_network_peer.create_client(host_ip, host_port)
	get_tree().get_multiplayer().multiplayer_peer = enet_network_peer
	print("Client peer created!")

func _setup_client_connection_signals():
	if not get_tree().get_multiplayer().server_disconnected.is_connected(_server_disconnected):
		get_tree().get_multiplayer().server_disconnected.connect(_server_disconnected)

func _server_disconnected():
	print("Server has disconnected!")
	get_tree().get_multiplayer().multiplayer_peer = null
	
