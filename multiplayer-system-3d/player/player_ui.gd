extends Control
class_name KillstreakUI

@export var attribute_component: AttributeComponent
@export var weapon_controller: WeaponController

@onready var health_bar: Label = $HealthBar
@onready var ammo_bar: Label = $AmmoBar
@onready var health_delta_bar: Label = $HealthDeltaBar



@onready var ammo_bar_public := $"../AmmoBarPublic"
@onready var health_bar_public := $"../HealthBarPublic"
@onready var health_delta_bar_public := $"../HealthDeltaBarPublic"
@onready var name_public := %NamePublic

@onready var WeaponList := $WeaponList
var _last_health := 0.0
var _last_change := 0.0
var _last_time := 0.0

const HIDE_TIME := 2.0



func _ready() -> void:
	
	weapon_controller.mag_changed.connect(func(_a=null,_b=null): _update_weapon_list())
	
	weapon_controller.weapon_changed.connect(func(_a=null,_b=null): _update_weapon_list())
	#weapon_controller.update.connect(_update_weapon_list)
	
	_update_weapon_list()
	#if it is OURS
	#if str(multiplayer.get_unique_id()) == get_parent().name:
		#
		#ammo_bar_public.set_multiplayer_authority(get_parent().name.to_int())
		#health_bar_public.set_multiplayer_authority(get_parent().name.to_int())
		#health_delta_bar_public.set_multiplayer_authority(get_parent().name.to_int())
		#name_public.set_multiplayer_authority(get_parent().name.to_int())
		

	var is_owner := is_multiplayer_authority()
	health_bar.visible = is_owner
	health_delta_bar.visible = is_owner
	ammo_bar.visible = is_owner
	
	ammo_bar_public.visible = not is_owner
	health_bar_public.visible = not is_owner
	health_delta_bar_public.visible = not is_owner
	name_public.visible = not is_owner
	$"../Marker".visible = not is_owner
	

	
	
	name_public.text = ("Host" if (name.to_int() == 1) else "Client") + ", NetID: " + str(name)
	
	#This happens on ALL peers because the health is the attribute component's health
	_on_mag_or_weapon_updated()
	weapon_controller.mag_changed.connect(_on_mag_or_weapon_updated)
	weapon_controller.weapon_changed.connect(_on_mag_or_weapon_updated)
	
	if attribute_component == null:
		return

	_last_health = attribute_component.health


func _update_weapon_list() -> void:
	if weapon_controller == null:
		return
	
	for child in WeaponList.get_children():
		child.queue_free()
	
	var weapons := weapon_controller.weapons
	var current_index := weapon_controller.current_weapon_index
	
	for i in weapons.size():
		var label := Label.new()
		label.text = weapons[i].display_name
		if i == current_index:
			label.modulate = Color(1.0, 1.0, 0.0)
		else:
			label.modulate = Color(1.0, 1.0, 1.0)
		WeaponList.add_child(label)

func _on_mag_or_weapon_updated(_current = null, _max = null) -> void:
	if weapon_controller == null:
		return
	
	var weapons = weapon_controller.weapons
	var index = weapon_controller.current_weapon_index
	
	if index < 0 or index >= weapons.size():
		return
	
	var weapon = weapons[index]
	if weapon.has_infinite_ammo:
		ammo_bar.text = "Infinite"
		ammo_bar_public.text = "Infinite"
		
		
	else:
		ammo_bar.text = "%d/%d" % [weapon.mag_current, weapon.mag_size]
		ammo_bar_public.text = "%d/%d" % [weapon.mag_current, weapon.mag_size]
		
		
		
func _process(_delta: float) -> void:
	if weapon_controller._is_reloading:
		# show remaining reload time (1 decimal is usually enough)
		ammo_bar.text = "Reloading: %.1f" % weapon_controller._reload_timer
		ammo_bar_public.text = "Reloading: %.1f" % weapon_controller._reload_timer
		
	# UI is local-only, no authority gating
	if attribute_component == null:
		return

	var hp := attribute_component.health
	var tx := str(hp) + "\n"

	for i in range(int(hp / 10)):
		tx += "█"
	
	
		
	var tx2 := str(hp) + " "

	for i in range(int(hp / 10)):
		tx2 += "█"
	
	health_bar.text = tx
	health_bar_public.text = tx2
	


	if attribute_component == null:
		return

	var current := attribute_component.health

	# detect change (works in multiplayer because health is replicated)
	if not is_equal_approx(current, _last_health):
		_last_change = current - _last_health
		_last_time = Time.get_ticks_msec() / 1000.0
		_last_health = current

	# hide after timeout
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_time > HIDE_TIME:
		health_delta_bar.text = ""
		health_delta_bar_public.text = ""
		
		return

	# display
	if _last_change < 0:
		health_delta_bar.modulate = Color(0.914, 0.0, 0.0, 1.0)
		health_delta_bar.text = "-%d" % int(abs(_last_change))
		health_delta_bar_public.modulate = Color(0.914, 0.0, 0.0, 1.0)
		health_delta_bar_public.text = "-%d" % int(abs(_last_change))
	elif _last_change > 0:
		health_delta_bar.modulate = Color(0.472, 0.914, 0.0, 1.0)
		health_delta_bar.text = "+%d" % int(_last_change)
		health_delta_bar_public.modulate = Color(0.472, 0.914, 0.0, 1.0)
		health_delta_bar_public.text = "+%d" % int(_last_change)
	else:
		health_delta_bar.text = ""
		health_delta_bar_public.text = ""


# =========================
# SERVER CALL ENTRY POINT
# =========================
# Call this ONLY on server when a kill happens
#
#@rpc("authority", "reliable")
#func server_notify_killstreak(killer_id: String) -> void:
	#var ks: int = Leaderboard.get_killstreak(killer_id)
#
	## broadcast to everyone
	#rpc("client_apply_killstreak", killer_id, ks)
#
#
## =========================
## CLIENT HANDLER
## =========================
#@rpc("any_peer", "reliable")
#func client_apply_killstreak(killer_id: String, ks: int) -> void:
	#if killer_id != player_id:
		#return
#
	#play_token += 1
	#var token := play_token
#
	## UI update
	#killstreak_label.text = str(ks)
	#killstreak_label.show()
#
	## audio + animation
	#var seq := _get_pitch_sequence(ks)
	#_play_sequence_async(seq, token)
#

# =========================
# AUDIO SEQUENCE
# =========================


	
