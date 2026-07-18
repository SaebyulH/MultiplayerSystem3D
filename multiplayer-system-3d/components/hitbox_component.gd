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

func _ready() -> void:
	area_entered.connect(_on_hurtbox_entered)


func _on_hurtbox_entered(hurtbox: Area3D):

	if not hurtbox is HurtboxComponent: return

	# Shield hurtbox — use the shield's owning player for team checks.
	var hurtbox_parent := hurtbox.get_parent()
	if hurtbox_parent is PlayerShield:
		hurtbox_parent = (hurtbox_parent as PlayerShield).player
		if not hurtbox_parent:
			return

	var hit_self: bool = (get_parent().shooter_name == hurtbox_parent.name)

	if not can_hit_shooter and hit_self:
		return


	var hit_ally: bool = (hurtbox_parent.team == get_parent().shooter_team)
	# FFA has no allies — same team doesn't mean friendly.
	if hit_ally and hurtbox_parent.team == Player.Team.FFA:
		hit_ally = hurtbox_parent.name == get_parent().shooter_name

	var hit_other_ally: bool = hit_ally and not hit_self


	if hit_other_ally and not can_hit_other_teamates:
		return
	elif not can_hit_enemy:
		return



	hurtbox.hurt_or_heal.emit(self, hit_ally)
	hit_hurtbox.emit(hurtbox)

	if not can_hit_multiple_times:
		area_entered.disconnect(_on_hurtbox_entered)
