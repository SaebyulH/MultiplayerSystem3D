class_name WeaponCard
extends PanelContainer

## A single weapon entry in the loadout menu.
##
## The root is a PanelContainer (not a Button) so it auto-sizes to its content — the
## killfeed icon plus the name label — which keeps the name inside the rectangle with no
## manual height math.  The killfeed PNG is a 16:9 silhouette scaled to fill the card
## width at its native aspect ratio.

signal card_pressed(card)

const ICON_ASPECT := 9.0 / 16.0   # killfeed icons are 256x144
const ICON_HEIGHT_SCALE := 0.6    # shrink the icon (and card) height ~25%
const CONTENT_MARGIN := 6.0        # matches the panel stylebox content margins

@onready var icon: TextureRect = $VBox/Icon
@onready var placeholder: ColorRect = $VBox/Placeholder
@onready var name_label: Label = $VBox/NameLabel

var _weapon: Weapon = null


## Called from _make_weapon_card before the card enters the tree, so store the weapon and
## apply it in _ready (once the @onready node refs exist).
func setup(weapon: Weapon) -> void:
	_weapon = weapon
	if is_node_ready():
		_apply_weapon()


func _ready() -> void:
	resized.connect(_fit_icon)
	_apply_weapon()
	_fit_icon()


func _apply_weapon() -> void:
	if _weapon == null:
		return
	if _weapon.killfeed_icon:
		icon.texture = _weapon.killfeed_icon
		icon.visible = true
		placeholder.visible = false
	else:
		icon.visible = false
		placeholder.visible = true
	name_label.text = _weapon.display_name


## Keep the icon at the card width, scaling its height to the 16:9 aspect so the texture
## fills the rectangle exactly (no letterbox / crop).
func _fit_icon() -> void:
	var content_w := size.x - 2.0 * CONTENT_MARGIN
	if content_w <= 0.0:
		return
	var h := content_w * ICON_ASPECT * ICON_HEIGHT_SCALE
	icon.custom_minimum_size = Vector2(content_w, h)
	placeholder.custom_minimum_size = Vector2(content_w, h)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			card_pressed.emit(self)
