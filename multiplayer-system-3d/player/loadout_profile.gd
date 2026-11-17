class_name LoadoutProfile
extends RefCounted

## Local/process loadout helper for the title and staging flows.
##
## A build is a plain Dictionary of resource paths so it can live on GameManager
## across world rebuilds and be sent through the existing loadout RPCs:
##   character_path, class_path, primary_path, secondary_path, melee_path,
##   randomize_on_death
##
## This intentionally does not touch the Loadout screen's node state.  The menu
## restores from the same dictionary and writes it back on confirm.

const CLASS_PATHS: Array[String] = [
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assistance.tres",
]


static func load_classes() -> Array[Class]:
	var out: Array[Class] = []
	for path in CLASS_PATHS:
		var cls := load(path) as Class
		if cls:
			out.append(cls)
	return out


static func random_build() -> Dictionary:
	var classes := load_classes()
	if classes.is_empty():
		return {}
	var cls: Class = classes[randi() % classes.size()]
	if cls.characters.is_empty():
		return {}
	var character: Character = cls.characters[randi() % cls.characters.size()]
	if cls.primary_weapons.is_empty() or cls.secondary_weapons.is_empty() or cls.melee_weapons.is_empty():
		return {}
	return {
		"class_path": cls.resource_path,
		"character_path": character.resource_path,
		"primary_path": cls.primary_weapons[randi() % cls.primary_weapons.size()].resource_path,
		"secondary_path": cls.secondary_weapons[randi() % cls.secondary_weapons.size()].resource_path,
		"melee_path": cls.melee_weapons[randi() % cls.melee_weapons.size()].resource_path,
		"randomize_on_death": false,
	}


static func is_valid(build: Dictionary) -> bool:
	for key in ["character_path", "class_path", "primary_path", "secondary_path", "melee_path"]:
		if str(build.get(key, "")) == "":
			return false
	return true


## Apply a build directly to a local/server Player.  This bypasses the
## Loadout screen and does not reset the player; callers decide whether to
## respawn or spawn.
static func apply_to_player(player: Player, build: Dictionary) -> bool:
	if player == null or not is_valid(build):
		return false
	var character := load(str(build["character_path"])) as Character
	var primary := load(str(build["primary_path"])) as Weapon
	var secondary := load(str(build["secondary_path"])) as Weapon
	var melee := load(str(build["melee_path"])) as Weapon
	if character == null or primary == null or secondary == null or melee == null:
		return false
	var weapons: Array[Weapon] = [
		primary.duplicate(true) as Weapon,
		secondary.duplicate(true) as Weapon,
		melee.duplicate(true) as Weapon,
	]
	player.weapon_controller.apply_loadout(weapons)
	player.set_character(character)
	player._loadout_character_path = str(build["character_path"])
	player._loadout_class_path = str(build["class_path"])
	player._loadout_primary_path = str(build["primary_path"])
	player._loadout_secondary_path = str(build["secondary_path"])
	player._loadout_melee_path = str(build["melee_path"])
	player.set_randomize_on_death(bool(build.get("randomize_on_death", false)))
	return true


## Path payload used by LoadoutMenuUI._request_loadout.  Kept in one place so
## the title, staging, and menu paths cannot drift.
static func rpc_args(build: Dictionary) -> Array:
	return [
		str(build.get("primary_path", "")),
		str(build.get("secondary_path", "")),
		str(build.get("melee_path", "")),
		str(build.get("character_path", "")),
		str(build.get("class_path", "")),
		bool(build.get("randomize_on_death", false)),
	]
