class_name ForestIcon
extends Node2D
## Small procedural tree-cluster icon drawn as a hex overlay — no image asset
## needed, same approach as Drone.gd's circle.

const RADIUS := 8.0
const COLOR := Color(0.15, 0.5, 0.2)

func _draw():
	draw_circle(Vector2(-6, -4), RADIUS, COLOR)
	draw_circle(Vector2(6, -4), RADIUS, COLOR)
	draw_circle(Vector2(0, 6), RADIUS, COLOR)
