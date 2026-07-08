class_name FacingArrow
extends Node2D
## Arrow pointing into whichever neighboring hex the mech is facing. Both its
## base and tip sit past this hex's own edge, inside the neighbor — it reads
## as "this hex over there", not as a decoration on the mech itself.

const WIDTH := 30.0
const COLOR := Color(1.0, 1.0, 1.0, 0.9)

## Distance from the mech's center to the tip, in pixels.
@export var length : float = 5.0 :
	set(value):
		length = value
		queue_redraw()

## Distance from the mech's center to the base, in pixels — set past the
## shared hex border so the whole arrow lives inside the neighboring hex.
@export var base_offset : float = 48.0 :
	set(value):
		base_offset = value
		queue_redraw()

func _draw():
	var half_width := WIDTH * 0.5
	var points := PackedVector2Array([
		Vector2(length, 0),
		Vector2(base_offset, half_width),
		Vector2(base_offset, -half_width),
	])
	draw_colored_polygon(points, COLOR)
