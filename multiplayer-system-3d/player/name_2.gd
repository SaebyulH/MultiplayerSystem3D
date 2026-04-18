extends Label3D

@export var attribute_component: AttributeComponent
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	#This happens on ALL peers because the health is the attribute component's health
	_update_health()
	attribute_component.health_changed.connect(_update_health)


func _update_health():
	text = str(attribute_component.health)
