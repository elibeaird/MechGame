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
