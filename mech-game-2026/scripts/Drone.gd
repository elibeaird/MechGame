class_name Drone
extends Node2D
## A deployed drone. Its HP, movement, attack range, and dice all come from
## whichever DroneType it was set up with — see setup().

signal died

const RADIUS := 10.0
const COLOR := Color(0.3, 0.8, 0.9)

@export var hex_coord : Vector2i
var hex_size : float = HexGrid.HEX_SIZE
var drone_type : DroneType
var hp : int = 1

## Must be called once right after Drone.new(), before deploying it.
func setup(type: DroneType):
	drone_type = type
	hp = maxi(1, type.bonus_hp)

func snap_to_grid():
	position = HexGrid.offset_to_pixel(hex_coord, hex_size)

func move_to(coord: Vector2i):
	hex_coord = coord
	snap_to_grid()

func attack(target) -> Dictionary:
	var result := drone_type.roll()
	target.take_damage(result.damage)
	return result

## Kamikaze: rams an adjacent target for damage equal to the drone's current
## HP, then destroys the drone regardless of how much HP that was. Returns
## the damage dealt so the caller can apply it and report it.
func crash(target) -> int:
	var damage := hp
	hp = 0
	target.take_damage(damage)
	died.emit()
	return damage

func take_damage(amount: int):
	hp = maxi(0, hp - amount)
	if hp <= 0:
		died.emit()

func _draw():
	draw_circle(Vector2.ZERO, RADIUS, COLOR)
	draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 32, Color.BLACK, 2.0)
