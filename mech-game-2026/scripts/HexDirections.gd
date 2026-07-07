class_name HexDirections
extends RefCounted
## Shared hex-direction utilities (cube-coordinate compass), used for mech
## facing/rotation and for push/pull knockback.

## The 6 cube-coordinate unit directions, in compass order (index i and i+1
## are adjacent — a 60° turn apart), used for both facing and pushes/pulls.
const DIRECTIONS := [
	Vector3i(1, -1, 0), Vector3i(1, 0, -1), Vector3i(0, 1, -1),
	Vector3i(-1, 1, 0), Vector3i(-1, 0, 1), Vector3i(0, -1, 1),
]

## Converts a cube coordinate back to offset (odd-r) — mirrors HexGrid's
## internal formula since it isn't part of the addon's public API.
static func cube_to_offset(cube: Vector3i) -> Vector2i:
	var col := cube.x + ((cube.z - (cube.z & 1)) / 2)
	var row := cube.z
	return Vector2i(col, row)

## Returns the offset coordinate one step from [param coord] in direction [param dir_index] (0-5).
static func step(coord: Vector2i, dir_index: int) -> Vector2i:
	return cube_to_offset(HexGrid.offset_to_cube(coord) + DIRECTIONS[dir_index])

## Returns the direction index (0-5) that points most directly from [param from]
## to [param to] (best dot-product match — works even off-axis). Returns -1
## if from == to.
static func direction_index(from: Vector2i, to: Vector2i) -> int:
	if from == to:
		return -1
	var delta := HexGrid.offset_to_cube(to) - HexGrid.offset_to_cube(from)
	var best_index := 0
	var best_dot := -INF
	for i in DIRECTIONS.size():
		var dir : Vector3i = DIRECTIONS[i]
		var dot := float(dir.x * delta.x + dir.y * delta.y + dir.z * delta.z)
		if dot > best_dot:
			best_dot = dot
			best_index = i
	return best_index

## Angular distance (0-3) between two direction indices around the 6-direction
## compass (0 = same direction, 3 = directly opposite).
static func direction_distance(a: int, b: int) -> int:
	var diff := absi(a - b) % 6
	return mini(diff, 6 - diff)

## On-screen angle (radians) a sprite should be rotated to visually face
## [param dir_index]. Computed from the grid's own pixel math so it's always
## correct regardless of hex size or row parity.
static func angle_for(dir_index: int) -> float:
	var origin := Vector2i(4, 4)
	var origin_px := HexGrid.offset_to_pixel(origin)
	var neighbor_px := HexGrid.offset_to_pixel(step(origin, dir_index))
	var delta := neighbor_px - origin_px
	return atan2(delta.y, delta.x)
