extends Node3D
class_name WeaponModel

## AnimationPlayer that plays this weapon's own animations.  Lives under the
## weapon model node.  Used to resolve animation names/lengths, and as a fallback
## for legacy weapons that have no AnimationTree.
@export var anim_player: AnimationPlayer

## AnimationTree driving this weapon's own (first-person) animations.  When set,
## the weapon animates through the same one-shot + time-scale + hold layout as
## the human model's AnimationTree.  Null for legacy weapons, which fall back to
## anim_player.play().
@export var anim_tree: AnimationTree

## AnimationLibrary holding the human animations that pair with this weapon's
## animations.  The weapon controller injects these into the mannequin's
## AnimationPlayer.
@export var human_anims: AnimationLibrary

## Weapon <-> human animation pairs, one per slot (Hold/Shoot/Reload/Inspect).
@export var anim_groups: Array[WeaponAnimGroup] = []

# AnimationTree node names used to drive this weapon's own anims.  They mirror
# the human tree's layout so the same slot logic can be reused.
const HOLD_ANIM_NODE := &"HoldAnim"
const SHOOT_ONESHOT_NODE := &"ShootOneShot"
const SHOOT_ANIM_NODE := &"ShootAnim"
const SHOOT_TIMESCALE_NODE := &"ShootTimeScale"
const RELOAD_ONESHOT_NODE := &"ReloadOneShot"
const RELOAD_ANIM_NODE := &"ReloadAnim"
const RELOAD_TIMESCALE_NODE := &"ReloadTimeScale"
const RELOAD_EMPTY_ONESHOT_NODE := &"ReloadEmptyOneShot"
const RELOAD_EMPTY_ANIM_NODE := &"ReloadEmptyAnim"
const RELOAD_EMPTY_TIMESCALE_NODE := &"ReloadEmptyTimeScale"
const RELOAD_NONEMPTY_ONESHOT_NODE := &"ReloadNonemptyOneShot"
const RELOAD_NONEMPTY_ANIM_NODE := &"ReloadNonemptyAnim"
const RELOAD_NONEMPTY_TIMESCALE_NODE := &"ReloadNonemptyTimeScale"
const PULLOUT_ONESHOT_NODE := &"PulloutOneShot"
const PULLOUT_ANIM_NODE := &"PulloutAnim"
const PULLOUT_TIMESCALE_NODE := &"PulloutTimeScale"
const PUTAWAY_ONESHOT_NODE := &"PutawayOneShot"
const PUTAWAY_ANIM_NODE := &"PutawayAnim"
const PUTAWAY_TIMESCALE_NODE := &"PutawayTimeScale"
const INSPECT_ONESHOT_NODE := &"InspectOneShot"
const INSPECT_ANIM_NODE := &"InspectAnim"
const INSPECT_TIMESCALE_NODE := &"InspectTimeScale"


## Return the WeaponAnimGroup configured for [param slot], or null if none exists.
func get_anim_group(slot: WeaponAnimGroup.AnimSlot) -> WeaponAnimGroup:
	for group in anim_groups:
		if group != null and group.slot == slot:
			return group
	# Empty / non-empty reload fall back to the single RELOAD group so weapons that
	# author only one reload anim keep working until a dedicated group is added.
	if slot == WeaponAnimGroup.AnimSlot.RELOAD_EMPTY or slot == WeaponAnimGroup.AnimSlot.RELOAD_NONEMPTY:
		return get_anim_group(WeaponAnimGroup.AnimSlot.RELOAD)
	return null


## Name of this weapon's own (first-person) animation for [param slot].
func get_gun_anim(slot: WeaponAnimGroup.AnimSlot) -> StringName:
	var group := get_anim_group(slot)
	return group.gun_anim if group != null else &""


## Name of the human (third-person) animation for [param slot].
func get_human_anim(slot: WeaponAnimGroup.AnimSlot) -> StringName:
	var group := get_anim_group(slot)
	return group.human_anim if group != null else &""


## Name used to register this weapon's human_anims library on a player's
## AnimationPlayer.  Derived from the library resource (its resource_name, or
## the file stem as a fallback) so it matches the "library/animation" prefix
## the AnimationTree references.
func get_human_library_name() -> StringName:
	if human_anims == null:
		return &""
	if human_anims.resource_name != &"":
		return human_anims.resource_name
	return StringName(human_anims.resource_path.get_file().get_basename())


## Full animation name ("library/animation") for a slot, ready to assign to an
## AnimationNodeAnimation.  Returns an empty StringName when the slot has no
## human animation or the weapon has no library.
func get_human_anim_path(slot: WeaponAnimGroup.AnimSlot) -> StringName:
	var anim := get_human_anim(slot)
	if anim == &"" or human_anims == null:
		return &""
	var lib := get_human_library_name()
	if lib == &"":
		return anim
	return StringName(str(lib) + "/" + str(anim))


## Resolve [param name] to the actual animation name on this weapon's
## AnimationPlayer, tolerating leading/trailing whitespace.  Imported GLB/FBX
## animation names frequently carry a stray trailing space, so the authored
## gun_anim StringName can drift out of sync with the imported clip.  Matching
## after trimming both sides keeps them in sync.  Returns &"" when nothing matches.
func _resolve_animation(name: StringName) -> StringName:
	if anim_player == null or name == &"":
		return &""
	if anim_player.has_animation(name):
		return name
	var stripped := String(name).strip_edges()
	for anim_name in anim_player.get_animation_list():
		if String(anim_name).strip_edges() == stripped:
			return StringName(anim_name)
	return &""


## The blend-tree root of this weapon's AnimationTree, or null if the weapon has
## no tree (legacy) or the tree root isn't a blend tree.
func _blend_tree() -> AnimationNodeBlendTree:
	if anim_tree == null:
		return null
	return anim_tree.tree_root as AnimationNodeBlendTree


## AnimationTree node names used to play [param slot] as a one-shot.  Returns an
## empty dict for slots that aren't driven this way (or don't exist on the tree).
func _slot_nodes(slot: WeaponAnimGroup.AnimSlot) -> Dictionary:
	match slot:
		WeaponAnimGroup.AnimSlot.SHOOT:
			return { "anim": SHOOT_ANIM_NODE, "oneshot": SHOOT_ONESHOT_NODE, "timescale": SHOOT_TIMESCALE_NODE }
		WeaponAnimGroup.AnimSlot.RELOAD:
			return { "anim": RELOAD_ANIM_NODE, "oneshot": RELOAD_ONESHOT_NODE, "timescale": RELOAD_TIMESCALE_NODE }
		WeaponAnimGroup.AnimSlot.RELOAD_EMPTY:
			return { "anim": RELOAD_EMPTY_ANIM_NODE, "oneshot": RELOAD_EMPTY_ONESHOT_NODE, "timescale": RELOAD_EMPTY_TIMESCALE_NODE }
		WeaponAnimGroup.AnimSlot.RELOAD_NONEMPTY:
			return { "anim": RELOAD_NONEMPTY_ANIM_NODE, "oneshot": RELOAD_NONEMPTY_ONESHOT_NODE, "timescale": RELOAD_NONEMPTY_TIMESCALE_NODE }
		WeaponAnimGroup.AnimSlot.INSPECT:
			return { "anim": INSPECT_ANIM_NODE, "oneshot": INSPECT_ONESHOT_NODE, "timescale": INSPECT_TIMESCALE_NODE }
		WeaponAnimGroup.AnimSlot.PULLOUT:
			return { "anim": PULLOUT_ANIM_NODE, "oneshot": PULLOUT_ONESHOT_NODE, "timescale": PULLOUT_TIMESCALE_NODE }
		WeaponAnimGroup.AnimSlot.PUTAWAY:
			return { "anim": PUTAWAY_ANIM_NODE, "oneshot": PUTAWAY_ONESHOT_NODE, "timescale": PUTAWAY_TIMESCALE_NODE }
	return {}


## Play this weapon's animation for [param slot] on its own AnimationTree as a
## one-shot (unscaled).  Falls back to anim_player.play() for legacy weapons.
## No-ops when the weapon has no animation for that slot.
func play_anim(slot: WeaponAnimGroup.AnimSlot) -> void:
	if not _play_tree_oneshot(slot, 0.0):
		_play_legacy(slot, 0.0, false)


## Play this weapon's animation for [param slot], stretched to last [param duration]
## seconds via the one-shot's time-scale node (or playback speed for legacy
## weapons).  The clip is always resized to match the requested duration regardless
## of how it was authored.  No-ops when the slot has no animation.
func play_anim_scaled(slot: WeaponAnimGroup.AnimSlot, duration: float) -> void:
	if not _play_tree_oneshot(slot, duration):
		_play_legacy(slot, duration, false)


## Play this weapon's animation for [param slot] and loop it (used for the hold
## anim).  On the tree this points HoldAnim at the clip and forces a restart so
## the loop starts from frame zero, in sync with the paired human hold.  Legacy
## weapons set the clip to loop and play it.  No-ops when the slot has no animation.
func play_anim_loop(slot: WeaponAnimGroup.AnimSlot) -> void:
	if not _play_tree_hold(slot):
		_play_legacy(slot, 1.0, true)


## Force-restart the looping hold animation so it re-syncs from frame zero with
## the human model's hold.  Mirrors play_anim_loop(HOLD).
func restart_hold_anim() -> void:
	play_anim_loop(WeaponAnimGroup.AnimSlot.HOLD)


## Fire a one-shot on the weapon's AnimationTree for [param slot], stretched to
## [param duration] seconds (<= 0 means unscaled).  Returns false when the weapon
## has no tree or the slot can't be played that way, so the caller can fall back
## to legacy playback.
func _play_tree_oneshot(slot: WeaponAnimGroup.AnimSlot, duration: float) -> bool:
	var tree := _blend_tree()
	if tree == null:
		return false
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return false
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return false
	var nodes := _slot_nodes(slot)
	if nodes.is_empty() or not nodes.has("oneshot"):
		return false
	
	print(nodes["anim"])
	var anim_node := tree.get_node(nodes["anim"]) as AnimationNodeAnimation
	if anim_node == null:
		return false
	anim_node.animation = anim_name

	# Stretch the clip to the requested duration via the slot's time-scale node.
	if nodes.has("timescale") and duration > 0.0 and anim_player != null:
		var anim := anim_player.get_animation(anim_name)
		if anim != null and anim.length > 0.0:
			anim_tree.set("parameters/" + str(nodes["timescale"]) + "/scale", anim.length / duration)

	if tree.get_node(nodes["oneshot"]) == null:
		return false
	anim_tree.set(
		"parameters/" + str(nodes["oneshot"]) + "/request",
		AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	)
	return true


## Point the tree's HoldAnim at the looping hold clip and force a restart so the
## loop starts from frame zero.  Returns false when the weapon has no tree.
func _play_tree_hold(slot: WeaponAnimGroup.AnimSlot) -> bool:
	var tree := _blend_tree()
	if tree == null:
		return false
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return false
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return false
	var hold_node := tree.get_node(HOLD_ANIM_NODE) as AnimationNodeAnimation
	if hold_node == null:
		return false

	if anim_player != null:
		var anim := anim_player.get_animation(anim_name)
		if anim != null:
			anim.loop_mode = Animation.LOOP_LINEAR

	# Re-assigning the animation restarts it from the start of the loop.  Clear
	# first so even re-applying the same hold clip restarts, keeping this weapon's
	# hold in sync with the human model's hold (both restart in the same frame).
	hold_node.animation = &""
	hold_node.animation = anim_name
	return true


## Legacy playback via the raw AnimationPlayer, used when the weapon has no
## AnimationTree.  [param duration] > 0 scales the clip; [param loop] plays it
## in a loop.
func _play_legacy(slot: WeaponAnimGroup.AnimSlot, duration: float, loop: bool) -> void:
	if anim_player == null:
		return
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return
	var anim := anim_player.get_animation(anim_name)
	if loop:
		if anim != null:
			anim.loop_mode = Animation.LOOP_LINEAR
		anim_player.play(anim_name)
		return
	var speed := 1.0
	if duration > 0.0 and anim != null and anim.length > 0.0:
		speed = anim.length / duration
	anim_player.play(anim_name, -1, speed)


## Play a scope transition (SCOPE_IN / SCOPE_OUT) directly on the raw
## AnimationPlayer, bypassing the AnimationTree.  The tree is disabled for the
## duration of the transition so we don't have to add scope one-shot nodes to
## every weapon's tree.  The clip is scaled to last [param duration] seconds
## (duration <= 0 plays at authored speed).  Returns true only when a scope anim
## was actually started (and the tree was disabled); otherwise returns false.
func play_scope_anim(slot: WeaponAnimGroup.AnimSlot, duration: float) -> bool:
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return false
	if anim_player == null:
		return false
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return false
	if anim_tree != null:
		anim_tree.active = false
	var anim := anim_player.get_animation(anim_name)
	var speed := 1.0
	if duration > 0.0 and anim != null and anim.length > 0.0:
		speed = anim.length / duration
	anim_player.play(anim_name, -1, speed)
	return true


## Re-enable the weapon's AnimationTree and restore the looping hold animation
## after a scope transition finishes.  No-ops for legacy weapons (no tree).
func finish_scope_anim() -> void:
	if anim_tree != null:
		anim_tree.active = true
	play_anim_loop(WeaponAnimGroup.AnimSlot.HOLD)


## Stop an in-progress one-shot animation for [param slot] and return to the
## looping hold pose.  Used when a hold-required shot is released early so the
## shoot anim snaps back instead of completing.
func stop_anim(slot: WeaponAnimGroup.AnimSlot) -> void:
	var tree := _blend_tree()
	if tree != null:
		var nodes := _slot_nodes(slot)
		if not nodes.is_empty() and nodes.has("oneshot"):
			var oneshot_path := str(nodes["oneshot"])
			# Force the one-shot inactive immediately so it can't linger through
			# its fade-out, then abort any pending transition.
			anim_tree.set("parameters/" + oneshot_path + "/active", false)
			anim_tree.set("parameters/" + oneshot_path + "/internal_active", false)
			anim_tree.set(
				"parameters/" + oneshot_path + "/request",
				AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT
			)
	# Stop the raw AnimationPlayer too, covering the legacy fallback path where the
	# slot was played directly on anim_player rather than through the tree.
	if anim_player != null:
		anim_player.stop()
	play_anim_loop(WeaponAnimGroup.AnimSlot.HOLD)
