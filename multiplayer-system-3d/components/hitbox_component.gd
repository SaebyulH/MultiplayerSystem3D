extends Area3D
class_name HitboxComponent

signal hit_hurtbox(hurtbox)
@export var health_delta: float = -10.0
@export var can_hit_shooter: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	area_entered.connect(_on_hurtbox_entered)
	

func _on_hurtbox_entered(hurtbox: Area3D):
	if not can_hit_shooter:
		if get_parent().shooter_name == hurtbox.get_parent().name: return
	if not hurtbox is HurtboxComponent: return
	
	
	hit_hurtbox.emit(hurtbox)
	#print("Hitbox named " + name + " has hit Hurtbox named" + hurtbox.name)
	hurtbox.hurt_or_heal.emit(self)
	#print("Hurtbox named " + hurtbox.name + " has been hit by Hurtbox named" + name)
#
#func get_shooter() -> String:
	#if "shooter_id" in get_parent():
		#return get_parent().shooter_id
	#else:
		#return "UNKNOWN"
