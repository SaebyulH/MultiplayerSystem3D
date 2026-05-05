extends Control
class_name PlayerBodyUI

@export var attribute_component: AttributeComponent
@export var weapon_controller: WeaponController

@onready var team_text: Label = $TeamText
@onready var health_bar: Label = $HealthBar
@onready var ammo_bar: Label = $AmmoBar
@onready var health_delta_bar: Label = $HealthDeltaBar

@onready var ammo_bar_public := $"../AmmoBarPublic"
@onready var health_bar_public := $"../HealthBarPublic"
@onready var health_delta_bar_public := $"../HealthDeltaBarPublic"
@onready var name_public := %NamePublic

@onready var WeaponList := $WeaponList
@onready var _owner_player := $"../.."


var _last_health := 0.0
var _last_change := 0.0
var _last_time := 0.0

const HIDE_TIME := 2.0
const MIN_DISPLAY_DELTA := 0.5

func _ready() -> void:
	_owner_player.team_changed.connect(_update_health_bar_color)
	var current_client_player = GameManager.find_player(str(multiplayer.get_unique_id()))
	current_client_player.team_changed.connect(_update_health_bar_color)
	
	_update_health_bar_color()
	
	weapon_controller.mag_changed.connect(func(_a=null, _b=null): _update_weapon_list())
	weapon_controller.weapon_changed.connect(func(_a=null, _b=null): _update_weapon_list())
	_update_weapon_list()
	
	
	var is_owner := is_multiplayer_authority()
	health_bar.visible = is_owner and not _owner_player.is_bot
	health_delta_bar.visible = is_owner and not _owner_player.is_bot
	ammo_bar.visible = is_owner and not _owner_player.is_bot
	team_text.visible = is_owner and not _owner_player.is_bot

	ammo_bar_public.visible = not is_owner or _owner_player.is_bot
	
	
	health_bar_public.visible = not is_owner or _owner_player.is_bot
	health_delta_bar_public.visible = not is_owner or _owner_player.is_bot
	name_public.visible = not is_owner or _owner_player.is_bot

	# Authority computes the display name and broadcasts it to all peers
	if is_owner:
		var display_name := ("Host" if (name.to_int() == 1) else "Client") + ", NetID: " + str(name)
		_set_name_label.rpc(display_name)

	_on_mag_or_weapon_updated()
	weapon_controller.mag_changed.connect(_on_mag_or_weapon_updated)
	weapon_controller.weapon_changed.connect(_on_mag_or_weapon_updated)

	if attribute_component == null:
		return
	_last_health = attribute_component.health

	_update_team_text()


func _update_health_bar_color():
	var local_id = str(multiplayer.get_unique_id())
	var current_client_player = GameManager.find_player(local_id)
	print("Local ID: ", local_id)
	print("Current client player: ", current_client_player)
	print("Owner player: ", _owner_player)
	print("Owner team: ", _owner_player.team)
	print("Client team: ", current_client_player.team if current_client_player else "NULL - player not found!")
	
	var is_enemy_to_current_client: bool = _owner_player.team != current_client_player.team

	var health_bar_public_color: Color = Color.GREEN if not is_enemy_to_current_client else Color.RED
	health_bar_public.modulate = health_bar_public_color



@rpc("authority", "call_local", "reliable")
func _set_name_label(display_name: String) -> void:
	name_public.text = display_name
#
#var _last_health := 0.0
#var _last_change := 0.0
#var _last_time := 0.0
#
#const HIDE_TIME := 2.0
#const MIN_DISPLAY_DELTA := 0.5
#
#func _ready() -> void:
	#weapon_controller.mag_changed.connect(func(_a=null, _b=null): _update_weapon_list())
	#weapon_controller.weapon_changed.connect(func(_a=null, _b=null): _update_weapon_list())
	#_update_weapon_list()
#
	#var is_owner := is_multiplayer_authority()
	#health_bar.visible = is_owner
	#health_delta_bar.visible = is_owner
	#ammo_bar.visible = is_owner
	#team_text.visible = is_owner
#
	#ammo_bar_public.visible = not is_owner
	#health_bar_public.visible = not is_owner
	#health_delta_bar_public.visible = not is_owner
	#name_public.visible = not is_owner
#
	#name_public.text = ("Host" if (name.to_int() == 1) else "Client") + ", NetID: " + str(name)
#
	#_on_mag_or_weapon_updated()
	#weapon_controller.mag_changed.connect(_on_mag_or_weapon_updated)
	#weapon_controller.weapon_changed.connect(_on_mag_or_weapon_updated)
#
	#if attribute_component == null:
		#return
	#_last_health = attribute_component.health
#
	#_update_team_text()

func _update_team_text() -> void:
	var player := get_parent().get_parent() as Player
	if player == null:
		return
	match player.team:
		Player.Team.SPI: team_text.text = "Team: SPI"
		Player.Team.SCI: team_text.text = "Team: SCI"
		Player.Team.FFA: team_text.text = "Team: FFA"

func _update_weapon_list() -> void:
	if weapon_controller == null:
		return

	for child in WeaponList.get_children():
		child.queue_free()

	var weapons := weapon_controller.get_weapons()
	var current_index := weapon_controller.current_weapon_index

	for i in weapons.size():
		var label := Label.new()
		label.text = weapons[i].display_name
		label.modulate = Color(1.0, 1.0, 0.0) if i == current_index else Color(1.0, 1.0, 1.0)
		WeaponList.add_child(label)

func _on_mag_or_weapon_updated(_current = null, _max = null) -> void:
	if weapon_controller == null:
		return

	var weapons := weapon_controller.get_weapons()
	var index := weapon_controller.current_weapon_index

	if index < 0 or index >= weapons.size():
		return

	var weapon := weapons[index]
	var text := "Infinite" if weapon.has_infinite_ammo else "%d/%d" % [weapon.mag_current, weapon.mag_size]
	ammo_bar.text = text
	ammo_bar_public.text = text

func _process(_delta: float) -> void:
	# --- Team text (updates live in case team changes after spawn) ---
	_update_team_text()

	# --- Ammo / reload display ---
	if weapon_controller._is_reloading:
		var reload_text := "Reloading: %.1f" % weapon_controller._reload_timer
		ammo_bar.text = reload_text
		ammo_bar_public.text = reload_text

	# --- Health bar ---
	if attribute_component == null:
		return

	var hp := int(attribute_component.health)
	var bar := ""
	for i in range(int(hp / 10)):
		bar += "█"

	health_bar.text = str(hp) + "\n" + bar
	health_bar_public.text = str(hp) + " " + bar

	# --- Health delta display ---
	var current := attribute_component.health

	if not is_equal_approx(current, _last_health):
		var change := current - _last_health
		_last_health = current
		if abs(change) >= MIN_DISPLAY_DELTA:
			_last_change = change
			_last_time = Time.get_ticks_msec() / 1000.0

	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_time > HIDE_TIME:
		health_delta_bar.text = ""
		health_delta_bar_public.text = ""
		return

	if _last_change < 0:
		health_delta_bar.modulate = Color(0.914, 0.0, 0.0, 1.0)
		health_delta_bar_public.modulate = Color(0.914, 0.0, 0.0, 1.0)
		health_delta_bar.text = "-%d" % int(abs(_last_change))
		health_delta_bar_public.text = "-%d" % int(abs(_last_change))
	elif _last_change > 0:
		health_delta_bar.modulate = Color(0.472, 0.914, 0.0, 1.0)
		health_delta_bar_public.modulate = Color(0.472, 0.914, 0.0, 1.0)
		health_delta_bar.text = "+%d" % int(_last_change)
		health_delta_bar_public.text = "+%d" % int(_last_change)
	else:
		health_delta_bar.text = ""
		health_delta_bar_public.text = ""
