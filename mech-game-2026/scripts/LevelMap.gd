class_name LevelMap
extends Resource
## A specific hex map for one level/scenario: grid size, mech spawn points,
## and which hexes deviate from base terrain. Assign one of these to
## Game_Manager.level_map to build a level — everything not listed in
## tile_overrides/forest_tiles defaults to plain base terrain.

@export var grid_width : int = 10
@export var grid_height : int = 11

@export var player_spawn : Vector2i = Vector2i(1, 5)
@export var ai_spawn : Vector2i = Vector2i(8, 5)
## Which of HexDirections.DIRECTIONS (0-5) the AI mech starts facing.
@export var ai_facing : int = 3

## Only hexes that AREN'T base terrain need an entry. Each element is
## {"coord": Vector2i, "terrain": ...}. "terrain" can be a TerrainType
## resource (the normal way to make new terrain — see scripts/TerrainType.gd)
## or a plain int (legacy: a HexCell.Terrain.* value, or one of
## Game_Manager's custom tier ids ALT_BLUE/ALT_GRAY), for maps like
## RingTestMap.tres that predate TerrainType.
@export var tile_overrides : Array[Dictionary] = []

## Hexes that get a forest-tree overlay icon. Independent of tile_overrides —
## a hex can have both a terrain override and a forest overlay.
@export var forest_tiles : Array[Vector2i] = []
