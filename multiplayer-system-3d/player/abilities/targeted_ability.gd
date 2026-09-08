class_name TargetedAbility
extends Ability

## A no-aim ability that targets visible enemies nearest the crosshair.
##
## Candidates are enemies within [member max_range] that the caster can see
## (line of sight) and that sit within [member min_angle_deg] of the crosshair.
## The [member max_targets] candidates closest to the crosshair (by on-screen
## distance) are the ones hit when the ability is cast.
##
## Preview text (the ability name) is drawn over every candidate by the HUD; the
## locked (would-hit) targets are shown in [member locked_color], the rest in
## [member preview_color].

@export var max_range: float = 20.0
@export var min_angle_deg: float = 35.0
@export var max_targets: int = 1
@export var preview_color: Color = Color(0.85, 0.85, 0.85, 1.0)
@export var locked_color: Color = Color(1.0, 0.25, 0.25, 1.0)

## Server-side: apply the effect to the chosen targets.  Subclasses override.
func apply_to_targets(player: Player, targets: Array[Player]) -> void:
	pass


## Client-side: every valid candidate (enemy, spawned, in range, inside the view
## cone, and visible), sorted by on-screen distance from the crosshair (closest
## first).  The first [member max_targets] are the locked targets.
func find_candidates(player: Player) -> Array[Player]:
	if player == null:
		return []
	var cam := player.camera as Camera3D
	var viewport := player.get_viewport()
	if cam == null or viewport == null:
		return []

	var cam_pos := cam.global_position
	var cam_fwd := player.camera_forward()
	var screen_center: Vector2 = viewport.get_visible_rect().size * 0.5
	var cos_min := cos(deg_to_rad(min_angle_deg))

	var scored: Array[Dictionary] = []
	for node in player.get_tree().get_nodes_in_group("players"):
		var other := node as Player
		if other == null or other == player or not other.spawned:
			continue
		if not player._is_enemy_of(other):
			continue
		var center := other.global_position + Vector3(0, 1.2, 0)
		var to := center - cam_pos
		var dist := to.length()
		if dist > max_range:
			continue
		if cam_fwd.dot(to.normalized()) < cos_min:
			continue
		if not player.has_line_of_sight_to(other):
			continue
		var screen_pos: Vector2 = cam.unproject_position(center)
		var sd := screen_pos.distance_to(screen_center)
		scored.append({"player": other, "dist": sd})

	scored.sort_custom(func(a, b): return a["dist"] < b["dist"])
	var result: Array[Player] = []
	for s in scored:
		result.append(s["player"])
	return result
