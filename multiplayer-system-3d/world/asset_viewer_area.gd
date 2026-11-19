extends Area3D

## AssetViewer interaction zone in the 3D lobby.
##
## Inside the zone the local player sees a crosshair HUD prompt ("E ASSET
## VIEWER") and E opens `world/asset_viewer.gd` — a local, dev-only CanvasLayer
## that renders effects/agents in its own SubViewport.  Nothing here touches the
## network; every peer runs its own zone and its own menu.
##
## Follows `world/host_server_area.gd`: body tracking, local-player check and
## the crosshair InteractionPrompt are the same pattern.

const ASSET_VIEWER_SCRIPT := preload("res://world/asset_viewer.gd")

var _players_inside: Array[Player] = []
var _menu: Node = null
var _prompt: InteractionPrompt = null


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_prompt = InteractionPrompt.new()
	_prompt.name = "AssetViewerPrompt"
	get_tree().root.add_child(_prompt)


func _exit_tree() -> void:
	if _menu and is_instance_valid(_menu):
		_menu.queue_free()
		_menu = null
	if _prompt and is_instance_valid(_prompt):
		_prompt.queue_free()
		_prompt = null


## Build the viewer on first use.  Returns true when the menu exists.
func _ensure_menu() -> bool:
	if _menu != null and is_instance_valid(_menu):
		return true
	_menu = ASSET_VIEWER_SCRIPT.new()
	if _menu == null:
		return false
	get_tree().root.add_child(_menu)
	return true


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


func _refresh_prompt() -> void:
	if _prompt == null:
		return
	if not _local_player_inside():
		_prompt.hide_prompt()
		return
	_prompt.show_action("Asset Viewer")


# ─────────────────────────────────────────────
#  Input
# ─────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if _menu != null and is_instance_valid(_menu) and _menu.visible:
		if event.is_action_pressed("ui_cancel") or (event.is_action_pressed("interact") and not event.is_echo()):
			_menu.close_menu()
			get_viewport().set_input_as_handled()
		return
	if not _local_player_inside():
		return
	if event.is_action_pressed("interact") and not event.is_echo():
		# Another menu (loadout, dev hacks, …) owns input.
		if PlayerInput.ui_open:
			return
		if _ensure_menu():
			_menu.open_menu()
			get_viewport().set_input_as_handled()
