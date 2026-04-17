extends Node

const SERVER_PORT: int = 8080
const GAME_SCENE = "res://world1.tscn"
const MAIN_MENU_SCENE = "res://main_menu.tscn"

var is_hosting_game = false

func create_server():
	is_hosting_game = true
	var enet_network_peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	enet_network_peer.create_server(SERVER_PORT)
	get_tree().get_multiplayer().multiplayer_peer = enet_network_peer
	print("Server created!")
	
func create_client(host_ip: String = "localhost", host_port: int = SERVER_PORT):
	is_hosting_game = false
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
	terminate_connection_load_main_menu()
	
func load_game_scene(map_path: String):
	print("Loading game scene")
	var game_scene = preload(GAME_SCENE).instantiate()
	var map = load(map_path).instantiate()
	map.name = "Map"
	game_scene.add_child(map)
	get_tree().call_deferred(&"change_scene_to", game_scene)

func terminate_connection_load_main_menu():
	print("Terminate connection, load main menu...")
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_load_main_menu()
	_terminate_connection()
	_disconnect_client_connection_signals()


func _load_main_menu():
	get_tree().call_deferred(&"change_scene_to_packed", preload(MAIN_MENU_SCENE))
		
func _terminate_connection():
	print("terminate connection")
	get_tree().get_multiplayer().multiplayer_peer = null

func _disconnect_client_connection_signals():
	if get_tree().get_multiplayer().server_disconnected.has_connections():
		get_tree().get_multiplayer().server_disconnected.disconnect(_server_disconnected)
