extends Node3D
class_name WeaponModel

## AnimationPlayer that plays this weapon's own animations.  Lives under the
## weapon model node.
@export var anim_player: AnimationPlayer

## AnimationLibrary holding the human animations that pair with this weapon's
## animations.  The weapon controller injects these into the mannequin's
## AnimationPlayer.
@export var human_anims: AnimationLibrary

## Weapon <-> human animation pairs, one per slot (Hold/Shoot/Reload/Inspect).
@export var anim_groups: Array[WeaponAnimGroup] = []


## Return the WeaponAnimGroup configured for [param slot], or null if none exists.
func get_anim_group(slot: WeaponAnimGroup.AnimSlot) -> WeaponAnimGroup:
	for group in anim_groups:
		if group != null and group.slot == slot:
			return group
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


## Play this weapon's animation for [param slot] on its own AnimationPlayer.
## No-ops when the weapon has no anim_player, no group for that slot, or the
## anim_player is missing the referenced animation.
func play_anim(slot: WeaponAnimGroup.AnimSlot) -> void:
	if anim_player == null:
		return
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return
	anim_player.play(anim_name)


## Play this weapon's animation for [param slot], stretched to last [param duration]
## seconds.  The playback speed is derived from the animation's own length, so the
## anim always matches the requested duration regardless of how it was authored.
## No-ops when the weapon has no anim_player, no group for that slot, or the
## anim_player is missing the referenced animation.
func play_anim_scaled(slot: WeaponAnimGroup.AnimSlot, duration: float) -> void:
	if anim_player == null:
		return
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return
	var anim := anim_player.get_animation(anim_name)
	var speed := 1.0
	if anim != null and anim.length > 0.0 and duration > 0.0:
		speed = anim.length / duration
	anim_player.play(anim_name, -1, speed)


## Play this weapon's animation for [param slot] and loop it (used for the hold
## anim).  Sets the clip to loop before playing so the weapon rests in this pose
## indefinitely.  No-ops when the weapon has no anim_player, no group for that
## slot, or the anim_player is missing the referenced animation.
func play_anim_loop(slot: WeaponAnimGroup.AnimSlot) -> void:
	if anim_player == null:
		return
	var group := get_anim_group(slot)
	if group == null or group.gun_anim == &"":
		return
	var anim_name := _resolve_animation(group.gun_anim)
	if anim_name == &"":
		return
	var anim := anim_player.get_animation(anim_name)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	anim_player.play(anim_name)
