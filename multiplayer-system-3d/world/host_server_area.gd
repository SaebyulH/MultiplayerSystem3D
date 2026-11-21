extends Area3D
## HostServer interaction zone in the 3D lobby.
##
## Inside the zone the local player sees a crosshair HUD prompt ("E MATCH
## MENU") and E opens the globe menu.  The prompt is a local `InteractionPrompt`
## built in code, not a Label3D in the map.

const GLOBE_MENU_SCRIPT := preload("res://world/globe_menu.gd")

var _players_inside: Array[Player] = []
var _menu: Node = null
var _creating := false
var _prompt: InteractionPrompt = null


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_prompt = InteractionPrompt.new()
	_prompt.name = "HostServerPrompt"
	get_tree().root.add_child(_prompt)
	# The menu is deliberately NOT built here.  host_menu._ready() scans every
	# MapData, and each of those used to force Godot to parse its whole referenced
	# map scene as an ext_resource -- ~50 MB of synchronous work, 47.7 MB of it
	# maps/bind.tscn, on every lobby instantiation, on every peer, joining clients
	# included.  Only the party leader can ever open this, so it is built on
	# demand.  See docs/05-known-issues.md.


## Build the host menu on first use.  Returns true when the menu exists.
func _ensure_menu() -> bool:
	if _menu != null and is_instance_valid(_menu):
		return true
	_menu = GLOBE_MENU_SCRIPT.new()
	if _menu == null:
		return false
	get_tree().root.add_child(_menu)
	return true


func _exit_tree() -> void:
	if _menu and is_instance_valid(_menu):
		_menu.queue_free()
		_menu = null
	if _prompt and is_instance_valid(_prompt):
		_prompt.queue_free()
		_prompt = null


# ─────────────────────────────────────────────
#  Body tracking
# ─────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if body is Player and body not in _players_inside:
		_players_inside.append(body)
		_refresh_prompt()


func _on_body_exited(body: Node3D) -> void:
	_players_inside.erase(body)
	_refresh_prompt()


func _local_player_inside() -> bool:
	var my_id := MatchSession.local_id_string()
	for p in _players_inside:
		# `body_exited` is not guaranteed for a Player that is freed outright.
		if is_instance_valid(p) and p.name == my_id:
			return true
	return false


func _is_leader() -> bool:
	return MatchSession.local_is_host()


## Local 3D shell: pressing E opens the Match Menu.  CREATE LOCAL starts an
## in-process listen server; CREATE VPS allocates a lobbyd server.
func _lobby_shell() -> bool:
	return NetworkManager.role == NetworkManager.Role.OFFLINE


## Staging match: pressing E opens the map picker and starts the match.  The
## listen-server host loads directly; a dedicated-server host sends the RPC.
func _lobby_staging() -> bool:
	return NetworkManager.role == NetworkManager.Role.CLIENT \
		or NetworkManager.role == NetworkManager.Role.LISTEN_SERVER


func _refresh_prompt() -> void:
	if _prompt == null:
		return
	if not _local_player_inside():
		_prompt.hide_prompt()
		return
	if _creating:
		_prompt.show_note("Creating match…")
		return
	_prompt.show_action("Match Menu")


# ─────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if _menu != null and is_instance_valid(_menu) and _menu.visible:
		if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
			_menu.close_menu()
		return
	if not _local_player_inside():
		return
	if event.is_action_pressed("interact") and not event.is_echo():
		# Another menu (loadout, dev hacks, …) owns input.
		if PlayerInput.ui_open:
			return
		if _ensure_menu():
			_menu.open_menu()


func _create_match_via_lobby() -> void:
	if _creating:
		return
	_creating = true
	if _prompt:
		_prompt.show_note("Creating match…")
	var result: Dictionary = await LobbyClient.create_match()
	if not result.has("endpoint") or not result.has("grant"):
		push_error("Lobby create failed: %s" % result.get("error", "unknown"))
		_creating = false
		_refresh_prompt()
		return
	await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))
