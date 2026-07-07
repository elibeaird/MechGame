class_name mech
extends Node2D

signal hp_changed(current: int, max: int)
signal died

const MAX_PARTS := 4

@export var is_player : bool
## Equipped parts (legs, arms, weapons, chassis...) — the ONLY source of HP,
## and everything ABOVE the innate baseline for movement/attack (every mech
## always has Move 2 and a 1-red-die melee attack at range 1, parts-or-not).
## A mech with no HP-granting part still has 0 HP and dies instantly.
@export var parts : Array[Part]
@export var hex_coord : Vector2i

## Which of the 6 hex directions this mech is facing (index into
## HexDirections.DIRECTIONS). Moving forward doesn't change this; only face()
## (spending a movement point to rotate) does.
@export var facing : int = 0

var hex_size : float = HexGrid.HEX_SIZE
var max_hp : int = 0
var current_hp : int

var target_scale :float = 1.0
var _base_scale : Vector2 = Vector2.ONE

const HEALTH_BAR_WIDTH := 40.0
@onready var _health_bar_fill: ColorRect = $HealthBarFill
@onready var _facing_arrow: FacingArrow = $FacingArrow

## Every mech can always move 2 and melee-attack (1 red die, range 1), even
## with zero parts equipped — parts add on top of this, they never take it
## away. Built fresh per mech so nothing shares state across instances.
var _innate_move : Actions
var _innate_attack : Actions

func _ready():
	_innate_move = Actions.new()
	_innate_move.display_name = "Basic Movement"
	_innate_move.movement = 2

	_innate_attack = Actions.new()
	_innate_attack.display_name = "Basic Attack"
	_innate_attack.red_dice = 1
	_innate_attack.range = 1

	for part in parts:
		max_hp += part.bonus_hp
	current_hp = max_hp
	_base_scale = scale
	_update_health_bar()
	_update_facing_visual()

func _process(delta):
	scale = scale.lerp(_base_scale * target_scale, delta * 8.0)

func begin_turn ():
	target_scale = 1.1

	if is_player:
		print( "player turn has begun")

	else :
			print("ai turn has begun")


func end_turn():
	target_scale = 0.9

func snap_to_grid():
	position = HexGrid.offset_to_pixel(hex_coord, hex_size)
	_update_facing_visual()

func move_to(coord: Vector2i):
	hex_coord = coord
	snap_to_grid()

## Rotates to face dir_index (0-5) without moving. Costs a movement point,
## same as moving forward one hex — the caller (Game_Manager) enforces that.
func face(dir_index: int):
	facing = dir_index
	_update_facing_visual()

func _update_facing_visual():
	_facing_arrow.rotation = HexDirections.angle_for(facing)
	# Base sits just past this hex's own edge (center-to-edge ≈ hex_size),
	# tip further in — the whole arrow lives inside the hex being faced,
	# short of reaching the neighbor's center (center-to-center ≈ hex_size * 1.73).
	_facing_arrow.base_offset = hex_size
	_facing_arrow.length = hex_size * 1.6

## Equips a part, up to MAX_PARTS and no duplicates. A part's bonus_hp raises
## max_hp and heals by the same amount, so equipping never wastes the extra
## capacity. Returns false (and does nothing) if the loadout is full or the
## part is already equipped.
func add_part(part: Part) -> bool:
	if parts.size() >= MAX_PARTS or parts.has(part):
		return false
	parts.append(part)
	if part.bonus_hp != 0:
		max_hp += part.bonus_hp
		current_hp += part.bonus_hp
		hp_changed.emit(current_hp, max_hp)
		_update_health_bar()
	return true

## Returns the first equipped part's drone_type (whichever part grants Special
## drone deployment), or null if no equipped part has one set.
func get_drone_type() -> DroneType:
	for part in parts:
		if part.drone_type != null:
			return part.drone_type
	return null

## Returns the max_drones budget of whichever equipped part grants a drone
## (see get_drone_type()), or 0 if no equipped part has one set.
func get_max_drones() -> int:
	for part in parts:
		if part.drone_type != null:
			return part.max_drones
	return 0

## Returns the first equipped part that can move (movement > 0) and whose
## level requirement is met, or the innate Move 2 if none qualify (parts
## only ever add capability on top of the baseline, never remove it).
## current_level < 0 (the default) skips the level check entirely — used by
## callers that don't track levels (the AI).
func get_move_action(current_level: int = -1) -> Actions:
	for part in parts:
		if part.movement > 0 and (current_level < 0 or part.level_met(current_level)):
			return part
	return _innate_move

## Returns the first equipped part with dice whose range covers dist and whose
## level requirement is met, or the innate Basic Attack if none qualify but
## dist is within its range. Returns null only if nothing — equipped or
## innate — can reach that far. See get_move_action() for current_level.
func get_attack_action_for_range(dist: int, current_level: int = -1) -> Actions:
	for part in parts:
		if part.dice_count() > 0 and dist >= part.min_range and dist <= part.range and (current_level < 0 or part.level_met(current_level)):
			return part
	if dist >= _innate_attack.min_range and dist <= _innate_attack.range:
		return _innate_attack
	return null

## Every equipped part (in equip order) plus the innate Basic Attack that
## currently qualifies for dist/current_level — used to let the player pick a
## specific weapon instead of always defaulting to the first match (see
## get_attack_action_for_range(), which the AI still uses since it doesn't
## need to choose).
func get_available_attack_actions(dist: int, current_level: int = -1) -> Array[Actions]:
	var options : Array[Actions] = []
	for part in parts:
		if part.dice_count() > 0 and dist >= part.min_range and dist <= part.range and (current_level < 0 or part.level_met(current_level)):
			options.append(part)
	if dist >= _innate_attack.min_range and dist <= _innate_attack.range:
		options.append(_innate_attack)
	return options

## target: mech or Drone — anything with a take_damage(amount) method.
## current_level only matters for parts with dice_scale_with_level set; it
## defaults to 1 (no scaling) for callers that don't track levels (the AI).
func attack(target, action : Actions, current_level: int = 1) -> Dictionary:
	var result := action.roll(current_level)
	target.take_damage(result.damage)
	return result

func take_damage(amount: int):
	current_hp = maxi(0, current_hp - amount)
	hp_changed.emit(current_hp, max_hp)
	_update_health_bar()
	if current_hp <= 0:
		died.emit()

func _update_health_bar():
	var pct := float(current_hp) / float(max_hp) if max_hp > 0 else 0.0
	_health_bar_fill.size.x = HEALTH_BAR_WIDTH * clampf(pct, 0.0, 1.0)
