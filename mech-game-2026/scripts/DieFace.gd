class_name DieFace
extends Control
## Draws a classic 6-sided die face (pips) for a given face value (1-6).

const PIP_LAYOUTS := {
	1: [Vector2(0.5, 0.5)],
	2: [Vector2(0.25, 0.25), Vector2(0.75, 0.75)],
	3: [Vector2(0.25, 0.25), Vector2(0.5, 0.5), Vector2(0.75, 0.75)],
	4: [Vector2(0.25, 0.25), Vector2(0.75, 0.25), Vector2(0.25, 0.75), Vector2(0.75, 0.75)],
	5: [Vector2(0.25, 0.25), Vector2(0.75, 0.25), Vector2(0.5, 0.5), Vector2(0.25, 0.75), Vector2(0.75, 0.75)],
	6: [Vector2(0.25, 0.2), Vector2(0.75, 0.2), Vector2(0.25, 0.5), Vector2(0.75, 0.5), Vector2(0.25, 0.8), Vector2(0.75, 0.8)],
}

@export var face : int = 1 :
	set(value):
		face = clampi(value, 1, 6)
		queue_redraw()

## Background tint matching the dice color that rolled (see Dice.DISPLAY_COLORS).
@export var die_color : Color = Color.WHITE :
	set(value):
		die_color = value
		queue_redraw()

func _init():
	custom_minimum_size = Vector2(40, 40)

func _draw():
	var size := get_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), die_color, true)
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK, false, 2.0)
	var pip_radius := size.x * 0.09
	var pip_color := Color.BLACK if die_color.v > 0.6 else Color.WHITE
	for p in PIP_LAYOUTS.get(face, []):
		draw_circle(p * size, pip_radius, pip_color)
