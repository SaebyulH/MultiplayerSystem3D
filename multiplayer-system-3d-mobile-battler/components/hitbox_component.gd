extends Area3D
class_name HitboxComponent

signal hit_hurtbox(hurtbox)
@export var health_delta: float = -10.0
@export var headshot_multiplier: float = 1.0
@export var can_hit_shooter: bool = false

@export var can_hit_other_teamates: bool = false ##DOES NOT INCLUDE YOU
@export var can_hit_enemy: bool = true
@export var enemy_delta_multiplier: float = 1.0  ##Like crusaders crossbow if -2.0 etc.

## With this enabled, STICK projectiles are basically poisonous! Warning!
@export var can_hit_multiple_times: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	area_entered.connect(_on_hurtbox_entered)
	

func _on_hurtbox_entered(hurtbox: Area3D):

	if not hurtbox is HurtboxComponent: return


	var hit_self: bool = (get_parent().shooter_name == hurtbox.get_parent().name)
	
	if not can_hit_shooter and hit_self:
		return
	
	
	var hit_ally: bool = (hurtbox.get_parent().team == get_parent().shooter_team)
	
	var hit_other_ally: bool = hit_ally and not hit_self
	
	
	if hit_other_ally and not can_hit_other_teamates:
		return
	#we hit an enemy
	elif not can_hit_enemy:
		return
	
	
	
	
	hurtbox.hurt_or_heal.emit(self, hit_ally)
	hit_hurtbox.emit(hurtbox)
	
	if not can_hit_multiple_times:
		area_entered.disconnect(_on_hurtbox_entered)
		
		
		
		


	#print("Hitbox named " + name + " has hit Hurtbox named" + hurtbox.name)

	#print("Hurtbox named " + hurtbox.name + " has been hit by Hurtbox named" + name)
#
#func get_shooter() -> String:
	#if "shooter_id" in get_parent():
		#return get_parent().shooter_id
	#else:
		#return "UNKNOWN"
