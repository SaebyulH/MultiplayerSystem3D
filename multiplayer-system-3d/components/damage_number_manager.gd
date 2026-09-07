extends Node
class_name DamageNumberManager

## Manages 2D damage / heal number popups for the owning player.
## Damage and healing are tracked separately — damage on the right side
## of the target, heals on the left.

const POPUP_SCENE: PackedScene = preload("res://components/damage_number_popup.tscn")

var _canvas: CanvasLayer = null
var _popups: Array[DamageNumberPopup] = []

@onready var _owner_player: Player = get_parent()


func _ready() -> void:
	if not is_multiplayer_authority():
		return

	_canvas = CanvasLayer.new()
	_canvas.layer = 3
	_canvas.name = "DamageNumberCanvas"
	get_tree().root.add_child(_canvas)


func on_damage_dealt(target_name: String, amount: float, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false) -> void:
	if not is_multiplayer_authority():
		return

	var target: Player = GameManager.find_player(target_name)
	if target == null:
		return

	var is_heal: bool = amount > 0.0
	var abs_amount: float = abs(amount)

	# If there's already a matching popup for this target + type, add to it.
	for p in _popups:
		if is_instance_valid(p) and p._target_node == target and p._is_heal == is_heal:
			p.add_value(abs_amount, is_headshot, falloff_mult, is_backshot)
			return

	# Otherwise spawn a new popup.  It removes itself from _popups when freed.
	var popup: DamageNumberPopup = POPUP_SCENE.instantiate() as DamageNumberPopup
	popup.setup(target, abs_amount, is_heal, is_headshot, falloff_mult, is_backshot)
	_canvas.add_child(popup)
	_popups.append(popup)
	popup.tree_exited.connect(func() -> void:
		_popups.erase(popup)
	)


@rpc("any_peer", "call_local", "reliable")
func _receive_damage_number(target_name: String, amount: float, is_headshot: bool = false, falloff_mult: float = 1.0, is_backshot: bool = false) -> void:
	on_damage_dealt(target_name, amount, is_headshot, falloff_mult, is_backshot)
