class_name DroneType
extends Actions
## A deployable drone archetype. Reuses Actions' fields with drone-specific
## meaning instead of adding new ones:
##   movement  -> hexes the drone can move per Special "move drone" use
##   range     -> the drone's attack range
##   dice      -> the drone's attack dice (same roll()/dice_count() as a Part)
##   bonus_hp  -> the drone's total HP (a drone has exactly one type, so
##                there's no separate "base" to add a bonus on top of —
##                this number IS its HP pool)
##
## All of its sprite art comes from Actions' visual_scene: build one scene
## with an AnimatedSprite2D and add whichever of these named animations this
## drone type needs — idle, deploy, move, attack, crash, hit, defeated. Every
## one is optional; anything missing falls back to res://Scenes/Basic_drone.tscn's
## own baked-in default of that name (see Drone.gd), so a drone with no
## visual_scene at all still looks like something instead of just the base
## placeholder circle.
