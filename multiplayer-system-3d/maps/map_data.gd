extends Resource
class_name MapData

## Metadata resource for a playable map: points at the map scene and carries a
## pre-rendered overview thumbnail.  Mirrors Character (character_scene + portrait).

@export var display_name: String = ""

## Path of the map scene this entry describes (res://maps/<name>.tscn).
##
## Deliberately a path string and NOT a PackedScene.  ConnectionUtils.scan_map_data()
## loads every MapData in this directory, and a PackedScene reference makes each
## one parse its entire map as an ext_resource.  That cost ~50 MB of synchronous
## parsing on every lobby instantiation, on every peer -- including joining
## clients, who cannot even host -- with maps/bind.tscn alone at 47.7 MB.  Only
## the path is ever needed: the host menu passes it straight to
## NetworkManager.load_match_map().  See docs/05-known-issues.md.
@export_file("*.tscn") var map_scene_path: String = ""

## Pre-rendered overview image.  Generate with maps/map_thumbnail_generator.gd
## (F6 while its scene is open).
@export var map_image: Texture2D

## Game mode this map plays, as a GameModeComponent.GameMode value
## (DEATHMATCH=5, ESCORT=0, DOMINATION=1, KOTH=2, HYBRID=3, CONTROL=4).
@export var game_mode: int = -1
