extends CollisionObject3D
class_name HurtboxComponent
@export var is_head: bool = false
signal hurt_or_heal(hitbox, is_ally_hit)


## Resolve the nearest owning Player or PlayerShield ancestor.  Hurtboxes used to
## be direct children of the Player; physical-bone hurtboxes are nested deep under
## the mannequin skeleton, so `get_parent()` no longer returns the owner.
func get_hurtbox_owner() -> Node:
	var n: Node = self
	while n != null:
		if n is Player or n is PlayerShield:
			return n
		n = n.get_parent()
	return null


## The Player that owns this hurtbox (resolves a shield owner to its player).
func get_owner_player() -> Player:
	var owner := get_hurtbox_owner()
	if owner is PlayerShield:
		return (owner as PlayerShield).player
	return owner as Player
