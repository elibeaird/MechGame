class_name Dice
extends RefCounted
## Shared d6 roll/damage logic, used by Actions/Part (and the drone).

## Hits (damage) per die face (index 0 = face 1 ... index 5 = face 6), one
## table per dice color. Faces are always rolled uniformly (1-6); the table
## just decides how much damage each face is worth for that color.
const FACE_DAMAGE : Array[int] = [1, 2, 2, 2, 2, 3]
const BLUE_DAMAGE : Array[int] = [1, 1, 1, 2, 3, 4]
const YELLOW_DAMAGE : Array[int] = [1, 1, 2, 2, 3, 3]
const PURPLE_DAMAGE : Array[int] = [1, 1, 1, 1, 1, 7]

const COLOR_TABLES := {
	"red": FACE_DAMAGE,
	"blue": BLUE_DAMAGE,
	"yellow": YELLOW_DAMAGE,
	"purple": PURPLE_DAMAGE,
}

## Display color for each dice color, used to tint DieFace visuals.
const DISPLAY_COLORS := {
	"red": Color(0.85, 0.2, 0.2),
	"blue": Color(0.2, 0.45, 0.85),
	"yellow": Color(0.95, 0.8, 0.2),
	"purple": Color(0.6, 0.3, 0.75),
}

## Rolls [count] d6 for [color], mapping each face through that color's table.
## Unknown colors fall back to FACE_DAMAGE. Returns
## {"rolls": Array[int], "hits": Array[int], "colors": Array[String], "damage": int}.
static func roll_color(color: String, count: int) -> Dictionary:
	var table : Array[int] = COLOR_TABLES.get(color, FACE_DAMAGE)
	var rolls : Array[int] = []
	var hits : Array[int] = []
	var colors : Array[String] = []
	var damage := 0
	for i in count:
		var face := randi_range(1, 6)
		var hit : int = table[face - 1]
		rolls.append(face)
		hits.append(hit)
		colors.append(color)
		damage += hit
	return {"rolls": rolls, "hits": hits, "colors": colors, "damage": damage}


## Combines several roll_color() results (e.g. an action with more than one
## dice color) into one {"rolls", "hits", "colors", "damage"} result.
static func merge_results(results: Array[Dictionary]) -> Dictionary:
	var rolls : Array[int] = []
	var hits : Array[int] = []
	var colors : Array[String] = []
	var damage := 0
	for r in results:
		rolls.append_array(r.rolls)
		hits.append_array(r.hits)
		colors.append_array(r.colors)
		damage += r.damage
	return {"rolls": rolls, "hits": hits, "colors": colors, "damage": damage}
