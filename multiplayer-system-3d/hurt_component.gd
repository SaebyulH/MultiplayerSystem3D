extends Node
class_name HurtComponent

@export var hurtbox_component: HurtboxComponent
@export var attribute_component: AttributeComponent
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	hurtbox_component.hurt.connect(func (hitbox_component: HitboxComponent):
		if is_multiplayer_authority():
			attribute_component.health -= hitbox_component.damage
			print(" Health of entity named " + str(get_parent().name) + ": " + str(attribute_component.health))
	)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
