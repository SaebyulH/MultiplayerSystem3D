extends Label3D

@export var attribute_component: AttributeComponent
# Called when the node enters the scene tree for the first time.
#func _ready() -> void:
	##This happens on ALL peers because the health is the attribute component's health
	#_on_attribute_component_health_changed(0.0)
	##attribute_component.health_changed.connect(_update_health)
#
#
#func _on_attribute_component_health_changed(delta: float) -> void:
	#text = str(attribute_component.health)
func _ready() -> void: 
	if get_multiplayer_authority() != multiplayer.get_unique_id(): 
		position.z = 0.0 
		position.x = 0.0



func _process(delta: float) -> void:
	text = str(attribute_component.health)
