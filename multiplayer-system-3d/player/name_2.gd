extends Label3D

@export var attribute_component: AttributeComponent

func _ready() -> void:
	if get_multiplayer_authority() != multiplayer.get_unique_id():
		position.z = 0.0
		position.x = 0.0
	if attribute_component:
		attribute_component.health_changed.connect(_update_text)
		_update_text()


func _update_text() -> void:
	if not attribute_component:
		return
	var tx = str(attribute_component.health) + "\n"
	for i in range(attribute_component.health / 10):
		tx += "█"
	text = tx
