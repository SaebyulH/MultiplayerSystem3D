extends Node
class_name HurtComponent

@export var hurtbox_component: HurtboxComponent
@export var attribute_component: AttributeComponent

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	hurtbox_component.hurt.connect(func (hitbox_component: HitboxComponent):
		if is_multiplayer_authority():
			var original_health = attribute_component.health
			attribute_component.health -= hitbox_component.damage
			
			attribute_component.last_attacker = hitbox_component.get_parent().shooter_name
			print(" Health of entity named " 
				+ str(get_parent().name) + ": " 
				+ str(original_health) + " to " + str(attribute_component.health)
				+ " by attacker: " + attribute_component.last_attacker
			)
	)
