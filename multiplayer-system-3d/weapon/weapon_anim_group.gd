extends Resource
class_name WeaponAnimGroup

## Animation slots that pair one weapon animation with one human animation.
enum AnimSlot {
	HOLD,
	SHOOT,
	RELOAD,
	INSPECT,
	PULLOUT,
	PUTAWAY
}

## Which of the Hold/Shoot/Reload/Inspect slots this group fills.
@export var slot: AnimSlot = AnimSlot.HOLD

## Name of the weapon's own (first-person) animation on the model's AnimationPlayer.
@export var gun_anim: StringName = &""

## Name of the human (third-person) animation in the model's human_anims library.
@export var human_anim: StringName = &""
