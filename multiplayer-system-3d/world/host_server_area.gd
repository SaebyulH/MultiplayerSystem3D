extends Area3D
## HostServer interaction zone in the 3D lobby.
##
## Only the party leader (peer 1) can host: inside the zone they see
## "Press E to host" and E opens the full host menu (world/host_menu.tscn).
## A joined player instead sees "MUST BE PARTY LEADER" and cannot interact.

const HOST_MENU_SCENE := preload("res://world/host_menu.tscn")

@onready var prompt_label: Label3D = $PromptLabel

var _players_inside: Array[Player] = []
var _menu: Node = null


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
	if not _is_leader():
		return false
	_menu = HOST_MENU_SCENE.instantiate()
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
	var my_id := str(multiplayer.get_unique_id())
	for p in _players_inside:
		if p.name == my_id:
			return true
	return false


func _is_leader() -> bool:
	return multiplayer.get_unique_id() == 1


func _refresh_prompt() -> void:
	if not _local_player_inside():
		prompt_label.visible = false
		return
	prompt_label.visible = true
	prompt_label.text = "Host Server (E)" if _is_leader() else "MUST BE PARTY LEADER"


# ─────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if _menu != null and is_instance_valid(_menu) and _menu.is_open():
		if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
			_menu.close()
		return
	if not _local_player_inside():
		return
	if event.is_action_pressed("interact") and not event.is_echo() and _is_leader():
		if _ensure_menu():
			_menu.open()
