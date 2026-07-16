extends Label3D

@export var attribute_component: AttributeComponent

var _last_health: float = -1.0

func _ready() -> void:
	if get_multiplayer_authority() != multiplayer.get_unique_id():
		position.z = 0.0
		position.x = 0.0


func _process(_delta: float) -> void:
	var h: float = attribute_component.health
	if h == _last_health:
		return
	_last_health = h
	var bars: int = max(0, int(h / 10.0))
	var tx: String = str(h) + "\n"
	for _i in range(bars):
		tx += "█"
	text = tx
