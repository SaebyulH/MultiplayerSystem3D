extends Label3D

@export var attribute_component: AttributeComponent

func _ready() -> void:
	if get_multiplayer_authority() != multiplayer.get_unique_id():
		position.z = 0.0
		position.x = 0.0


func _process(delta: float) -> void:
	var tx = str(attribute_component.health) + "\n"
	for i in range(attribute_component.health / 10):
		tx += "█"
	text = tx
