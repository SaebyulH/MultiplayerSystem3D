extends Node

const SERVER_PORT: int = 8080
const GAME_SCENE = "res://world/world1.tscn"
const MAIN_MENU_SCENE = "res://ui/main_menu.tscn"

var is_hosting_game = false
var game_scene

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
	NetworkTimeSynchronizer.stop()  # stop before terminate tears down the peer
	terminate_connection_load_main_menu()

func enter_existing_game_scene():
	print("Entering game scene")
	game_scene = preload(GAME_SCENE).instantiate()
	# Add as child of current scene instead of replacing it
	get_tree().current_scene.add_child(game_scene)
	get_tree().current_scene.hide_main_menu()

func load_game_scene(map_path: String):
	print("Loading game scene")
	game_scene = preload(GAME_SCENE).instantiate()
	game_scene.map_path = map_path

	# Add as child of current scene instead of replacing it
	get_tree().current_scene.add_child(game_scene)
	get_tree().current_scene.hide_main_menu()

#func _swap_scene(new_scene: Node):
	#var root = get_tree().root
	#var current = get_tree().current_scene
	#if current:
		#root.remove_child(current)
		#current.queue_free()
	#root.add_child(new_scene)
	#get_tree().current_scene = new_scene
func terminate_connection_load_main_menu():
	print("Terminate connection, load main menu...")
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_terminate_connection()              # disconnect peer FIRST
	_disconnect_client_connection_signals()
	_load_main_menu()                    # THEN clean up the scene

func _load_main_menu():
	if game_scene == null:
		push_warning("terminate called but game_scene is null")
		get_tree().current_scene.show_main_menu()
		return

	get_tree().current_scene.remove_child(game_scene)
	game_scene.queue_free()             # actually free it
	game_scene = null                   # clear the reference
	get_tree().current_scene.show_main_menu()

func _terminate_connection():
	print("terminate connection")
	var mp = get_tree().get_multiplayer()
	if mp.multiplayer_peer != null:
		NetworkTimeSynchronizer.stop()  # stop sync loop before peer is nulled
		mp.multiplayer_peer.close()
		mp.multiplayer_peer = null

func _disconnect_client_connection_signals():
	var mp = get_tree().get_multiplayer()
	if mp.server_disconnected.is_connected(_server_disconnected):  # correct check
		mp.server_disconnected.disconnect(_server_disconnected)
		
		
		
#func terminate_connection_load_main_menu():
	#print("Terminate connection, load main menu...")
	#Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	#_load_main_menu()
	#_terminate_connection()
	#_disconnect_client_connection_signals()


#func _load_main_menu():
	#get_tree().current_scene.remove_child(game_scene)
	#
	#get_tree().current_scene.show_main_menu()
	##get_tree().call_deferred(&"change_scene_to_packed", preload(MAIN_MENU_SCENE))
		#
#func _terminate_connection():
	#print("terminate connection")
	#get_tree().get_multiplayer().multiplayer_peer = null
#
#func _disconnect_client_connection_signals():
	#if get_tree().get_multiplayer().server_disconnected.has_connections():
		#get_tree().get_multiplayer().server_disconnected.disconnect(_server_disconnected)
