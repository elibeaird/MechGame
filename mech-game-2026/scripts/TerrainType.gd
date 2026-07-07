class_name TerrainType
extends Resource
## A custom terrain you can paint onto a level's map. Create one of these per
## new terrain type instead of touching code, then reference it directly in a
## LevelMap's tile_overrides (as a resource, not a magic int) — Game_Manager
## assigns each one an internal HexCell.terrain id at grid-build time.

@export var display_name : String = ""
@export var color : Color = Color.GRAY

## Movement cost to enter this terrain — higher = slower going (1.0 = a
## normal hex). Ignored if passable is false.
@export var difficulty : int = 1

## Whether mechs/drones can enter this terrain at all. If false, the hex is
## impassable (like the addon's WATER terrain) and difficulty doesn't matter.
@export var passable : bool = true

## Whether this terrain blocks a ranged attack's line of sight.
@export var blocks_los : bool = false

## Reserved for a future destructible-terrain mechanic — not read by any
## gameplay code yet.
@export var breakable : bool = false
@export var Hp : int = 1

## Reserved for a future objective/capture-point mechanic — not read by any
## gameplay code yet.
@export var objective : bool = false

## Optional background image for this terrain. Leave unset to just use color.
@export var texture : Texture2D = null
