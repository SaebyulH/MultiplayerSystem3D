extends Node
class_name DamageNumberManager

## Manages 2D damage / heal number popups for the owning player.
## Damage and healing are tracked separately — damage on the right side
## of the target, heals on the left.

const RESET_TIME: float = 1.2
const POPUP_SCENE: PackedScene = preload("res://components/damage_number_popup.tscn")

var _canvas: CanvasLayer = null
var _popups: Array[DamageNumberPopup] = []

# Separate accumulation per target: damage and healing don't mix.
var _accum: Dictionary = {}           # "target_name|dmg" or "target_name|heal" → float
var _accum_timers: Dictionary = {}    # same key → float

@onready var _owner_player: Player = get_parent()


func _ready() -> void:
	if not is_multiplayer_authority():
		set_process(false)
		return

	_canvas = CanvasLayer.new()
	_canvas.layer = 3
	_canvas.name = "DamageNumberCanvas"
	get_tree().root.add_child(_canvas)


func _process(delta: float) -> void:
	# Tick accum timers — flush when expired.
	var to_flush: Array[String] = []
	for key in _accum_timers:
		_accum_timers[key] -= delta
		if _accum_timers[key] <= 0.0:
			to_flush.append(key)
	for key in to_flush:
		_accum.erase(key)
		_accum_timers.erase(key)

	# Clean up dead popups.
	var alive: Array[DamageNumberPopup] = []
	for p in _popups:
		if is_instance_valid(p):
			alive.append(p)
	_popups = alive


func _key(target_name: String, is_heal: bool) -> String:
	return target_name + ("|heal" if is_heal else "|dmg")


func on_damage_dealt(target_name: String, amount: float, is_headshot: bool = false, falloff_mult: float = 1.0) -> void:
	if not is_multiplayer_authority():
		return

	var target: Player = GameManager.find_player(target_name)
	if target == null:
		return

	# Reset on respawn — numbers don't carry across lives.
	if not target.spawned:
		_accum.erase(_key(target_name, true))
		_accum.erase(_key(target_name, false))
		_accum_timers.erase(_key(target_name, true))
		_accum_timers.erase(_key(target_name, false))

	var is_heal: bool = amount > 0.0
	var abs_amount: float = abs(amount)
	var k: String = _key(target_name, is_heal)

	# Accumulate.
	var prev: float = _accum.get(k, 0.0)
	_accum[k] = prev + abs_amount
	_accum_timers[k] = RESET_TIME

	# If there's already a matching popup for this target + type, add to it.
	for p in _popups:
		if is_instance_valid(p) and p._target_node == target and p._is_heal == is_heal:
			p.add_value(abs_amount, is_headshot, falloff_mult)
			return

	# Otherwise spawn a new popup.
	var popup: DamageNumberPopup = POPUP_SCENE.instantiate() as DamageNumberPopup
	popup.setup(target, abs_amount, is_heal, is_headshot, falloff_mult)
	_canvas.add_child(popup)
	_popups.append(popup)


@rpc("any_peer", "call_local", "reliable")
func _receive_damage_number(target_name: String, amount: float, is_headshot: bool = false, falloff_mult: float = 1.0) -> void:
	on_damage_dealt(target_name, amount, is_headshot, falloff_mult)
