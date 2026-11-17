extends Area3D
## HostServer interaction zone in the 3D lobby.
##
## Only the party leader (peer 1) can host: inside the zone they see
## "Press E to host" and E opens the full host menu (world/host_menu.tscn).
## A joined player instead sees "MUST BE PARTY LEADER" and cannot interact.

const GLOBE_MENU_SCRIPT := preload("res://world/globe_menu.gd")

@onready var prompt_label: Label3D = $PromptLabel

var _players_inside: Array[Player] = []
var _menu: Node = null
var _creating := false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	prompt_label.visible = false
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


## Local 3D shell: pressing E hosts a match with no external service.  With the
## C lobby enabled it allocates a lobbyd server instead; otherwise it starts an
## in-process listen server.
func _lobby_shell() -> bool:
	return NetworkManager.role == NetworkManager.Role.OFFLINE


## Staging match: pressing E opens the map picker and starts the match.  The
## listen-server host loads directly; a dedicated-server host sends the RPC.
func _lobby_staging() -> bool:
	return NetworkManager.role == NetworkManager.Role.CLIENT \
		or NetworkManager.role == NetworkManager.Role.LISTEN_SERVER


func _refresh_prompt() -> void:
	if not _local_player_inside():
		prompt_label.visible = false
		return
	prompt_label.visible = true
	prompt_label.text = "Match Menu (E)"


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
	prompt_label.text = "Creating match…"
	var result: Dictionary = await LobbyClient.create_match()
	if not result.has("endpoint") or not result.has("grant"):
		push_error("Lobby create failed: %s" % result.get("error", "unknown"))
		_creating = false
		_refresh_prompt()
		return
	await NetworkManager.join_match(str(result["endpoint"]), str(result["grant"]))
