class_name AssetViewerCatalog
extends RefCounted

## Static data for `world/asset_viewer.gd`.
##
## The effect list is explicit: the four live scene effects plus the two
## profile-driven toon catalogs.  A new effect scene must be added to
## SCENE_EFFECTS here; the toon lists follow their own JSON/profile data.
##
## Weapons and characters are scanned from disk (lazily, once) so a new
## resource shows up without touching this file.

const TOON_EXPLOSION := preload("res://effects/toon_explosions/toon_explosion.gd")
const TOON_TRAIL := preload("res://effects/toon_trail/toon_trail.gd")

const WEAPON_DIRS: Array[String] = [
	"res://weapon/assault_weapons",
	"res://weapon/assassin_weapons",
	"res://weapon/assistance_weapons",
	"res://weapon/shared",
	"res://weapon/tf2",
	"res://weapon/other",
]

const CHARACTER_DIR := "res://player/characters"

## Canonical weapon-list order (matches the class order: Assault, Assassin,
## Assistance, then the shared/TF2/other pools).
const WEAPON_GROUP_ORDER: Array[String] = [
	"ASSAULT", "ASSASSIN", "ASSISTANCE", "SHARED", "TF2", "OTHER",
]

static var _weapons: Array[Weapon] = []
static var _characters: Array[Character] = []


## Flat effect entries, in list order:
## { key, kind, id, title, group, camera_distance, default_scale }.
static func effect_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	out.append(_scene_entry("muzzle_flash", "Muzzle Flash",
		"res://effects/muzzle_flash.tscn", 1.6, 1.0))
	out.append(_scene_entry("bullet_impact", "Bullet Impact",
		"res://effects/bullet_impact.tscn", 1.8, 1.0))
	out.append(_scene_entry("explosion", "Explosion (fireball)",
		"res://effects/explosion.tscn", 2.6, 1.0))
	out.append(_scene_entry("rocket_impact", "Rocket Impact",
		"res://effects/rocket_impact/rocket_impact.tscn", 2.6, 1.0))

	for item in TOON_EXPLOSION.effect_catalog():
		if not item is Dictionary:
			continue
		var explosion: Dictionary = item
		var id := str(explosion.get("id", ""))
		var group := str(explosion.get("group", ""))
		out.append({
			"key": "toon_explosion/" + id,
			"kind": "toon_explosion",
			"id": id,
			"title": str(explosion.get("title", explosion.get("name", id))),
			"group": "Toon Explosion / " + group,
			"camera_distance": 3.5,
			"default_scale": 1.0,
		})

	for item in TOON_TRAIL.catalog():
		if not item is Dictionary:
			continue
		var trail: Dictionary = item
		var id := str(trail.get("id", ""))
		var group := str(trail.get("group", ""))
		out.append({
			"key": "toon_trail/" + id,
			"kind": "toon_trail",
			"id": id,
			"title": str(trail.get("title", id)),
			"group": "Toon Trail / " + group,
			"camera_distance": 4.0,
			# Projectiles author `trail_scale` at 1.0, so the viewer must start
			# there too.  Raise the SCALE slider for a closer look if needed.
			"default_scale": 1.0,
		})

	return out


static func _scene_entry(id: String, title: String, path: String,
		distance: float, scale: float) -> Dictionary:
	return {
		"key": "scene/" + id,
		"kind": "scene",
		"id": id,
		"scene_path": path,
		"title": title,
		"group": "Scene Effects",
		"camera_distance": distance,
		"default_scale": scale,
	}


## Every Weapon resource under the weapon folders, sorted by display name.
static func weapons() -> Array[Weapon]:
	if not _weapons.is_empty():
		return _weapons
	var found: Array[Weapon] = []
	for dir_path in WEAPON_DIRS:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file in dir.get_files():
			if not file.ends_with(".tres"):
				continue
			var res := load(dir_path.path_join(file))
			if res is Weapon:
				found.append(res as Weapon)
	found.sort_custom(func(a: Weapon, b: Weapon) -> bool:
		var group_a: String = weapon_group(a)
		var group_b: String = weapon_group(b)
		var rank_a := _group_rank(group_a)
		var rank_b := _group_rank(group_b)
		if rank_a != rank_b:
			return rank_a < rank_b
		return a.display_name.naturalnocasecmp_to(b.display_name) < 0)
	_weapons = found
	return _weapons


static func _group_rank(group: String) -> int:
	var index := WEAPON_GROUP_ORDER.find(group)
	return index if index >= 0 else WEAPON_GROUP_ORDER.size()


## Weapon folder name used as the list group ("ASSAULT_WEAPONS" -> "ASSAULT").
static func weapon_group(weapon: Weapon) -> String:
	if weapon == null or weapon.resource_path.is_empty():
		return "OTHER"
	var folder := weapon.resource_path.get_base_dir().get_file()
	if folder.ends_with("_weapons"):
		folder = folder.trim_suffix("_weapons")
	return folder.to_upper()


## Every Character resource in player/characters, sorted by display name.
static func characters() -> Array[Character]:
	if not _characters.is_empty():
		return _characters
	var found: Array[Character] = []
	var dir := DirAccess.open(CHARACTER_DIR)
	if dir != null:
		for file in dir.get_files():
			if not file.ends_with(".tres"):
				continue
			var res := load(CHARACTER_DIR.path_join(file))
			if res is Character:
				found.append(res as Character)
	found.sort_custom(func(a: Character, b: Character) -> bool:
		return a.character_name.naturalnocasecmp_to(b.character_name) < 0)
	_characters = found
	return _characters
