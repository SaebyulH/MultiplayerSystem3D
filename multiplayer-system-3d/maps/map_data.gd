extends Resource
class_name MapData

## Metadata resource for a playable map: points at the map scene and carries a
## pre-rendered overview thumbnail.  Mirrors Character (character_scene + portrait).

@export var display_name: String = ""

## The map scene this entry describes (res://maps/<name>.tscn).
@export var map_scene: PackedScene

## Pre-rendered overview image.  Generate with maps/map_thumbnail_generator.gd
## (F6 while its scene is open).
@export var map_image: Texture2D

## Game mode this map plays, as a GameModeComponent.GameMode value
## (DEATHMATCH=5, ESCORT=0, DOMINATION=1, KOTH=2, HYBRID=3, CONTROL=4).
@export var game_mode: int = -1
