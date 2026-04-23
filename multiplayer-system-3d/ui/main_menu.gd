extends Control
@onready var address_input = $VBoxContainer/AddressInput
@onready var ip_label = $VBoxContainer/IPLabel
@onready var option_button = $VBoxContainer/OptionButton

@export var world: Node3D
@export var class_select_menu: Control
func _ready():
	var local_ip = IP.get_local_addresses()
	for addr in local_ip:
		if "." in addr \
		and not addr.begins_with("127.") \
		and not addr.begins_with("169.254."):
			ip_label.text = "Your IP: " + addr
			break
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.peer_connected.connect(_on_peer_connected)
	

	

	

func _get_selected_map():
	if option_button.selected < 0:
		return null
	return option_button.get_item_text(option_button.selected)

func _on_host_game_pressed() -> void:
	if not _get_selected_map():
		print("select map first!")
		return
	NetworkManager.create_server()
	hide()
	#NetworkManager.load_game_scene(_get_selected_map())
	
	world.load_map(_get_selected_map())
	$"../GameMenu".on_server_ready()
	class_select_menu.show()

func _on_join_game_pressed() -> void:
	var address = address_input.text
	if address == "":
		#address = "100.92.64.109"
		address = "100.104.145.26"
	
	NetworkManager.create_client(address)

func _on_connected_to_server():
	print("Connected! My ID: ", multiplayer.get_unique_id())
	#NetworkManager.enter_existing_game_scene()
	hide()
	$"../GameMenu".on_server_ready()
	class_select_menu.show()
	
	

func _on_connection_failed():
	print("Connection failed!")

func _on_peer_connected(id: int):
	print("Peer connected: ", id)

func _on_send_test_message_pressed() -> void:
	_send_test_message.rpc("I am connected to you")

@rpc("any_peer", "call_remote")
func _send_test_message(message: String):
	print("Peer [%s] recieved message [%s] from peer [%s]"
	%[get_tree().get_multiplayer().get_unique_id(),
	message,
	get_tree().get_multiplayer().get_remote_sender_id()])


func _on_join_local_pressed() -> void:
	var address = "127.0.0.1"
	NetworkManager.create_client(address)
