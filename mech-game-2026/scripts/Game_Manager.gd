extends Node2D

enum PendingMode { NONE, MOVE, ATTACK, SPECIAL }

const HEX_SIZE := 48.0

## Used if level_map isn't assigned in the scene, so existing scenes keep
## working without needing an update.
const DEFAULT_LEVEL_MAP_PATH := "res://resources/Levels/RingTestMap.tres"

## Each turn is 2 action slots: slot 0 must be Move, slot 1 can be Move,
## Attack, or Special. Reaching this count ends the turn.
const ACTIONS_PER_TURN := 2

## Fixed tiebreak order for the 2nd-action column when two options share a level.
const SECOND_ACTION_KEYS := ["move", "attack", "special"]

## A direction counts as "in front" if it's within this many 60° steps of
## facing — 1 means facing + its two neighbors, a 180° front arc.
const FRONT_ARC_TOLERANCE := 1

## Movement points spent to ram: shove the enemy mech 1 hex further along
## your facing and take the hex it vacated. Only works if the enemy is
## directly in front and the hex beyond them is free.
const RAM_COST := 2
const RAM_COLOR := Color(0.9, 0.35, 0.1, 0.55)

## Terrain that blocks a ranged attack's line of sight. Melee (adjacent hexes)
## always passes trivially — there's no hex in between to block it.
const LOS_BLOCKING_TERRAINS : Array[int] = [HexCell.Terrain.FOREST, HexCell.Terrain.MOUNTAIN]

## Custom elevation-tier "terrain" ids for the reference map layout — HexCell.terrain
## accepts any int, not just Terrain.*, so these live outside that enum without
## touching it. Purely cosmetic for now (same 1.0 movement cost as PLAINS, and
## no attack-range bonus wired up); the dark-gray tier reuses the existing
## MOUNTAIN terrain instead of a 3rd custom id specifically so it inherits the
## LOS-blocking behavior already in LOS_BLOCKING_TERRAINS above.
const ALT_BLUE := 100
const ALT_GRAY := 101

## First internal HexCell.terrain id handed out to a TerrainType resource —
## clear of both the built-in Terrain enum (0-4) and ALT_BLUE/ALT_GRAY (100/101).
const CUSTOM_TERRAIN_ID_BASE := 200

@export var player_mech : mech
@export var ai_mech : mech
## The map this level uses — grid size, terrain layout, and mech spawns. See
## scripts/LevelMap.gd. Falls back to DEFAULT_LEVEL_MAP_PATH if unset.
@export var level_map : LevelMap

## Resolved from level_map in _ready() — used everywhere the grid's size matters.
var grid_width : int
var grid_height : int

## TerrainType resources used by the current level_map, each assigned an
## internal HexCell.terrain id (starting at CUSTOM_TERRAIN_ID_BASE) the first
## time they're seen — see _register_terrain_type().
var _terrain_type_ids : Dictionary = {}
var _terrain_type_by_id : Dictionary = {}
## Extra LOS-blocking ids contributed by TerrainType resources with
## blocks_los set, on top of the fixed LOS_BLOCKING_TERRAINS above.
var _custom_los_blocking_ids : Array[int] = []

@onready var hex_container: Node2D = $HexContainer
@onready var camera: Camera2D = $Camera2D
@onready var status_label: Label = $UI/MarginContainer/PanelContainer/VBoxContainer/StatusLabel
@onready var move_points_label: Label = $UI/MarginContainer/PanelContainer/VBoxContainer/MovePointsLabel
@onready var move_button_1: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/ActionColumns/FirstActionColumn/MoveButton1
@onready var move_button_2: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/ActionColumns/SecondActionColumn/MoveButton2
@onready var attack_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/ActionColumns/SecondActionColumn/AttackButton
@onready var special_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/ActionColumns/SecondActionColumn/SpecialButton
@onready var end_turn_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/ActionColumns/EndTurnColumn/EndTurnButton
@onready var skip_move_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/SkipMoveButton
@onready var dice_row: HBoxContainer = $UI/MarginContainer/PanelContainer/VBoxContainer/DiceRow

@onready var loadout_layer: LoadoutScreen = $LoadoutLayer

@onready var drone_action_popup: PopupPanel = $UI/DroneActionPopup
@onready var drone_popup_title: Label = $UI/DroneActionPopup/VBoxContainer/TitleLabel
@onready var drone_move_button: Button = $UI/DroneActionPopup/VBoxContainer/MoveButton
@onready var drone_attack_button: Button = $UI/DroneActionPopup/VBoxContainer/AttackButton
@onready var drone_crash_button: Button = $UI/DroneActionPopup/VBoxContainer/CrashButton

@onready var attack_weapon_popup: PopupPanel = $UI/AttackWeaponPopup
@onready var attack_weapon_list: VBoxContainer = $UI/AttackWeaponPopup/VBoxContainer/WeaponList

## True once the match has started — Parts can only be equipped before this.
var match_started : bool = false

var grid : HexGrid
var renderer : HexRenderer
var camera_ctrl : MapCamera

var current_mech : mech
var pending_mode : PendingMode = PendingMode.NONE
var reachable : Dictionary = {}
var highlighted_hexes : Dictionary = {}

## During a Move: Vector2i -> -1 (move forward there) or a direction index
## (rotate to face that way without moving). Points left in the current move.
var move_targets : Dictionary = {}
var move_points_remaining : int = 0

## Every drone the player currently has active on the field — level 3 Special
## can deploy up to 3 in a single chain (stock permitting), so this is no
## longer just one.
var player_drones : Array[Drone] = []
## Which of player_drones the current drone_sub_action (move/attack/crash)
## applies to. Set by clicking that drone's hex during the SPECIAL "choose
## deploy or select" step; null the rest of the time.
var selected_drone : Drone = null
## How many drones have been deployed so far this match, against the equipped
## drone part's max_drones budget (mech.get_max_drones()). Never resets mid-match.
var drones_deployed : int = 0
## Which drone action the player picked from drone_action_popup this Special
## use: "move", "attack", or "crash". "" while choosing between deploying a
## new drone or selecting an existing one to control.
var drone_sub_action : String = ""

## Weapon chosen from attack_weapon_popup for the current pending Attack —
## null until the player picks one, then used directly by _on_cell_pressed
## instead of re-deriving "the first eligible part" via
## get_attack_action_for_range().
var selected_attack_action : Actions = null

## A single press of Special chains one drone action per level of the Special
## ladder (minimum 1, even at level 0) before the action slot is actually
## used up. Decremented after each deploy/move/attack/crash; special_chain_active
## tracks whether at least one has gone through, so a failure on the very
## first attempt (no drone part, no budget) can cancel for free, but the same
## failure mid-chain still spends the action slot since something already happened.
var special_chain_remaining : int = 0
var special_chain_active : bool = false

## How many of the current player turn's 2 action slots have been used.
var actions_used : int = 0

## Level (0-3) of each 2nd-action-column option. Using an action drops it to
## 0; the other two climb 1 level each (capped at 3). Display-only for now.
var action_levels : Dictionary = {
	"move": 1,
	"attack": 2,
	"special": 3,
}

var game_over : bool = false


func _ready():
	if level_map == null:
		level_map = load(DEFAULT_LEVEL_MAP_PATH)
	grid_width = level_map.grid_width
	grid_height = level_map.grid_height

	_setup_grid()

	attack_button.pressed.connect(_on_attack_pressed)
	move_button_1.pressed.connect(_on_move_pressed)
	move_button_2.pressed.connect(_on_move_pressed)
	special_button.pressed.connect(_on_special_pressed)
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	skip_move_button.pressed.connect(_on_skip_move_pressed)
	loadout_layer.start_match.connect(_on_match_started)
	renderer.cell_pressed.connect(_on_cell_pressed)
	drone_move_button.pressed.connect(_on_drone_move_chosen)
	drone_attack_button.pressed.connect(_on_drone_attack_chosen)
	drone_crash_button.pressed.connect(_on_drone_crash_chosen)

	player_mech.hex_coord = level_map.player_spawn
	ai_mech.hex_coord = level_map.ai_spawn
	ai_mech.facing = level_map.ai_facing
	player_mech.hex_size = HEX_SIZE
	ai_mech.hex_size = HEX_SIZE
	player_mech.snap_to_grid()
	ai_mech.snap_to_grid()

	_update_action_level_labels()
	_enter_loadout_phase()


func _process(delta):
	if current_mech:
		camera_ctrl.process(delta, current_mech.position)


func _unhandled_input(event):
	camera_ctrl.handle_input(event)


func _setup_grid():
	_terrain_type_ids.clear()
	_terrain_type_by_id.clear()
	_custom_los_blocking_ids.clear()

	# Flatten PLAINS to cost 1.0 so "movement points" == "number of hexes",
	# matching the Move action's movement value (default terrain cost is 1.5).
	# ALT_BLUE/ALT_GRAY/MOUNTAIN are also flattened to 1.0 — this map's ring
	# pattern is cosmetic (+ MOUNTAIN's existing LOS block), not a movement toll.
	var cost_table := HexGrid.TERRAIN_COST.duplicate()
	cost_table[HexCell.Terrain.PLAINS] = 1.0
	cost_table[HexCell.Terrain.MOUNTAIN] = 1.0
	cost_table[ALT_BLUE] = 1.0
	cost_table[ALT_GRAY] = 1.0

	var palette := HexPalette.new()
	palette.terrain_colors[ALT_BLUE] = Color(0.25, 0.55, 0.85)
	palette.terrain_colors[ALT_GRAY] = Color(0.62, 0.62, 0.6)
	palette.terrain_colors[HexCell.Terrain.MOUNTAIN] = Color(0.32, 0.3, 0.28)

	# Register every TerrainType resource this level's overrides use, so their
	# difficulty/passable/color/blocks_los are wired in before the grid (which
	# needs the finished cost_table) and renderer (which needs the finished
	# palette) are actually built.
	for entry in level_map.tile_overrides:
		var raw = entry.get("terrain")
		if raw is TerrainType:
			_register_terrain_type(raw, cost_table, palette)

	grid = HexGrid.new(grid_width, grid_height, cost_table, HEX_SIZE)
	grid.generate_cells(HexCell.Terrain.PLAINS)
	_apply_level_terrain()

	renderer = HexRenderer.new(palette, HEX_SIZE, {
		"cell_icon_fn": _corner_marker_icon_fn,
		"overlay_fn": _forest_overlay_fn,
		"texture_fn": _terrain_texture_fn,
	})
	for coord in grid.cells:
		renderer.create_hex_visual(hex_container, coord, HexGrid.offset_to_pixel(coord, HEX_SIZE), grid.cells[coord])
		var fog := HexRenderer.get_visual_part(hex_container, coord, "Fog")
		if fog:
			fog.visible = false

	camera_ctrl = MapCamera.new(camera, get_viewport())
	camera.position = HexGrid.offset_to_pixel(Vector2i(grid_width / 2, grid_height / 2), HEX_SIZE)


## Assigns terrain_type an internal HexCell.terrain id (if it doesn't have one
## yet this level) and wires its difficulty/passable/color/blocks_los into
## cost_table/palette/LOS blocking. Idempotent — safe to call more than once
## for the same resource.
func _register_terrain_type(terrain_type: TerrainType, cost_table: Dictionary, palette: HexPalette) -> int:
	if _terrain_type_ids.has(terrain_type):
		return _terrain_type_ids[terrain_type]

	var id := CUSTOM_TERRAIN_ID_BASE + _terrain_type_ids.size()
	_terrain_type_ids[terrain_type] = id
	_terrain_type_by_id[id] = terrain_type
	cost_table[id] = terrain_type.difficulty if terrain_type.passable else -1.0
	palette.terrain_colors[id] = terrain_type.color
	if terrain_type.blocks_los:
		_custom_los_blocking_ids.append(id)
	return id


## Resolves a tile_overrides "terrain" value (a TerrainType resource or a
## legacy plain int) to the actual HexCell.terrain id to assign.
func _terrain_id_for(raw) -> int:
	if raw is TerrainType:
		return _terrain_type_ids.get(raw, HexCell.Terrain.PLAINS)
	if raw is int:
		return raw
	return HexCell.Terrain.PLAINS


## Applies level_map's tile_overrides (terrain per hex) and forest_tiles (tree
## overlay flag) to the freshly generated grid. Anything not listed keeps the
## default base terrain from generate_cells().
func _apply_level_terrain():
	for entry in level_map.tile_overrides:
		var coord : Vector2i = entry.get("coord", Vector2i.ZERO)
		var cell := grid.get_cell(coord)
		if cell:
			cell.terrain = _terrain_id_for(entry.get("terrain"))
	for coord in level_map.forest_tiles:
		var cell := grid.get_cell(coord)
		if cell:
			cell.tag = 1 # forest overlay flag, read by _forest_overlay_fn


## "◆" on the 4 board corners, matching the reference image's corner markers.
func _corner_marker_icon_fn(cell: HexCell) -> String:
	var corners := [
		Vector2i(0, 0), Vector2i(grid_width - 1, 0),
		Vector2i(0, grid_height - 1), Vector2i(grid_width - 1, grid_height - 1),
	]
	return "◆" if cell.coord in corners else ""


## Forest-tile overlay: a small tree-cluster icon on any cell tagged by
## _apply_level_terrain(), independent of that cell's terrain/elevation.
func _forest_overlay_fn(cell: HexCell) -> Array[Node2D]:
	if cell.tag != 1:
		return []
	return [ForestIcon.new()]


## Background image for a TerrainType-driven hex that has one set — falls
## back to its flat palette color (via _make_terrain_polygon) if null, or if
## this cell's terrain isn't a registered TerrainType at all.
func _terrain_texture_fn(cell: HexCell) -> Texture2D:
	var terrain_type : TerrainType = _terrain_type_by_id.get(cell.terrain, null)
	return terrain_type.texture if terrain_type else null


## Loadout phase: a full-page screen (LoadoutLayer) covers everything else.
## Only it and its Start Match button are usable until the player commits.
func _enter_loadout_phase():
	attack_button.disabled = true
	move_button_1.disabled = true
	move_button_2.disabled = true
	special_button.disabled = true
	end_turn_button.disabled = true
	status_label.text = "Equip parts, then click Start Match"
	loadout_layer.player_mech = player_mech
	loadout_layer.show_loadout()


func _on_match_started():
	if match_started:
		return
	match_started = true
	next_turn()


func next_turn ():
	if game_over:
		return

	_clear_pending()
	special_chain_remaining = 0
	special_chain_active = false

	if current_mech != null:
		current_mech.end_turn()

	if current_mech == ai_mech or current_mech == null:
		current_mech = player_mech
	else:
		current_mech = ai_mech

	current_mech.begin_turn()

	if _check_game_over():
		return

	if current_mech.is_player:
		actions_used = 0
		_update_action_buttons()
		status_label.text = "Your turn — move up to 2 hexes"
	else:
		attack_button.disabled = true
		move_button_1.disabled = true
		move_button_2.disabled = true
		special_button.disabled = true
		end_turn_button.disabled = true
		skip_move_button.disabled = true
		status_label.text = "Enemy turn..."
		await get_tree().create_timer(randf_range(0.5, 1.0)).timeout
		var attacked := _ai_take_turn()
		await get_tree().create_timer(3.4 if attacked else 0.4).timeout
		next_turn()


## Slot 0 (actions_used == 0) only allows the 1st-action Move. Slot 1 unlocks
## the 2nd-action column (Move/Attack/Special) — using any of them ends the turn.
func _update_action_buttons():
	move_button_1.disabled = actions_used != 0
	move_button_2.disabled = actions_used == 0
	attack_button.disabled = actions_used == 0
	special_button.disabled = actions_used == 0
	end_turn_button.disabled = false
	skip_move_button.disabled = true


func _use_action_slot():
	actions_used += 1
	if actions_used >= ACTIONS_PER_TURN:
		next_turn()
	else:
		_update_action_buttons()
		status_label.text = "Choose your second action: Move, Attack, or Special"


## Drops used_key's level to 0; the other two 2nd-action options climb 1
## level each (capped at 3). Only call this when the action taken was the
## 2nd action slot — the mandatory 1st-action Move isn't part of this ladder.
func _rotate_action_levels(used_key: String):
	for key in action_levels.keys():
		action_levels[key] = 0 if key == used_key else mini(action_levels[key] + 1, 3)
	_update_action_level_labels()


func _update_action_level_labels():
	move_button_2.text = "Move (Lv %d)" % action_levels["move"]
	attack_button.text = "Attack (Lv %d)" % action_levels["attack"]
	special_button.text = "Special (Lv %d)" % action_levels["special"]
	_reorder_second_action_buttons()


## Reorders the 2nd-action column so the highest-level option sits on top,
## breaking ties via SECOND_ACTION_KEYS so the order stays deterministic.
func _reorder_second_action_buttons():
	var buttons_by_key := {
		"move": move_button_2,
		"attack": attack_button,
		"special": special_button,
	}
	var sorted_keys := SECOND_ACTION_KEYS.duplicate()
	sorted_keys.sort_custom(func(a, b):
		if action_levels[a] != action_levels[b]:
			return action_levels[a] > action_levels[b]
		return SECOND_ACTION_KEYS.find(a) < SECOND_ACTION_KEYS.find(b))

	var column := move_button_2.get_parent()
	for i in sorted_keys.size():
		column.move_child(buttons_by_key[sorted_keys[i]], i + 1)


func _check_game_over() -> bool:
	if player_mech.current_hp <= 0:
		status_label.text = "Defeat! The enemy mech wins."
		game_over = true
	elif ai_mech.current_hp <= 0:
		status_label.text = "Victory! You destroyed the enemy mech."
		game_over = true

	if game_over:
		attack_button.disabled = true
		move_button_1.disabled = true
		move_button_2.disabled = true
		special_button.disabled = true
		end_turn_button.disabled = true
		skip_move_button.disabled = true
	return game_over


## Pressing Move starts a facing-based move: each of the mech's movement
## points buys either one step forward (in its current facing) or a free
## rotation to face any other direction. Pressing the same button again
## mid-move stops early instead of forcing every point to be spent.
func _on_move_pressed():
	if current_mech != player_mech:
		return

	if pending_mode == PendingMode.MOVE and move_points_remaining > 0:
		_finish_move()
		return

	if actions_used >= ACTIONS_PER_TURN:
		return

	var move_action := player_mech.get_move_action(action_levels["move"])
	if move_action == null:
		status_label.text = "No equipped movement part meets your current Move level (Lv %d)" % action_levels["move"]
		return

	move_points_remaining = move_action.movement
	pending_mode = PendingMode.MOVE
	_disable_buttons_during_move()
	_refresh_move_highlight()


## Only Move (whichever column applies) and Skip stay enabled during a move —
## everything else is locked out until the move finishes.
func _disable_buttons_during_move():
	move_button_1.disabled = actions_used != 0
	move_button_2.disabled = actions_used != 1
	attack_button.disabled = true
	special_button.disabled = true
	end_turn_button.disabled = true
	skip_move_button.disabled = false


func _on_skip_move_pressed():
	if current_mech != player_mech or not (pending_mode == PendingMode.MOVE and move_points_remaining > 0):
		return
	_finish_move()


func _is_hex_free(coord: Vector2i) -> bool:
	if not grid.is_valid(coord) or not grid.is_passable(coord):
		return false
	if coord == player_mech.hex_coord or coord == ai_mech.hex_coord:
		return false
	if _drone_at(coord) != null:
		return false
	return true


## Returns whichever of player_drones sits on coord, or null if none does.
func _drone_at(coord: Vector2i) -> Drone:
	for d in player_drones:
		if d.hex_coord == coord:
			return d
	return null


## Highlights the front hex (green = advance, orange = ram the enemy there
## if you have RAM_COST points and the hex beyond them is free) and the
## other 5 neighbors (yellow, click to rotate toward that one).
func _refresh_move_highlight():
	renderer.update_reachable_highlight(hex_container, grid, {}, highlighted_hexes)

	move_targets = {}
	var move_coords : Array[Vector2i] = []
	var rotate_coords : Array[Vector2i] = []
	var ram_coord : Vector2i
	var has_ram := false

	var front := HexDirections.step(player_mech.hex_coord, player_mech.facing)
	if _is_hex_free(front):
		move_targets[front] = -1
		move_coords.append(front)
	elif front == ai_mech.hex_coord and move_points_remaining >= RAM_COST:
		var beyond := HexDirections.step(front, player_mech.facing)
		if _is_hex_free(beyond):
			move_targets[front] = -2
			ram_coord = front
			has_ram = true

	for i in HexDirections.DIRECTIONS.size():
		if i == player_mech.facing:
			continue
		var neighbor := HexDirections.step(player_mech.hex_coord, i)
		if grid.is_valid(neighbor):
			move_targets[neighbor] = i
			rotate_coords.append(neighbor)

	renderer.update_los_highlight(hex_container, move_coords, rotate_coords, Color(0.2, 0.8, 0.2, 0.5), Color(0.9, 0.85, 0.3, 0.4))
	for coord in move_coords:
		highlighted_hexes[coord] = true
	for coord in rotate_coords:
		highlighted_hexes[coord] = true

	if has_ram:
		var node := HexRenderer.get_visual_part(hex_container, ram_coord, "Highlight")
		if node:
			node.color = RAM_COLOR
			node.visible = true
		highlighted_hexes[ram_coord] = true

	var hint := "Green = move forward, yellow = rotate that way"
	if has_ram:
		hint = "Orange = ram the enemy and take its place (costs %d), yellow = rotate" % RAM_COST
	status_label.text = "%s — click Skip to stop early" % hint

	move_points_label.visible = true
	move_points_label.text = "Movement left: %d" % move_points_remaining


## Ends the current move (whether points ran out or the player stopped early)
## and hands off to the normal action-slot bookkeeping.
func _finish_move():
	var is_second_action := actions_used == 1
	move_points_remaining = 0
	move_targets = {}
	_clear_pending()
	if is_second_action:
		_rotate_action_levels("move")
	_use_action_slot()


## True if target_coord is within FRONT_ARC_TOLERANCE direction-steps of
## attacker's facing (default tolerance 1 = facing + its two neighbors).
func _is_in_front_arc(attacker: mech, target_coord: Vector2i) -> bool:
	var dir := HexDirections.direction_index(attacker.hex_coord, target_coord)
	if dir == -1:
		return true
	return HexDirections.direction_distance(dir, attacker.facing) <= FRONT_ARC_TOLERANCE


## True if an unobstructed line can be drawn from the center of [param from] to
## the center of [param to] — uses the hex addon's own get_line_of_sight(),
## blocked by LOS_BLOCKING_TERRAINS. Adjacent hexes always pass (no hex in
## between to block them).
func _has_line_of_sight(from: Vector2i, to: Vector2i) -> bool:
	return grid.get_line_of_sight(from, to, LOS_BLOCKING_TERRAINS + _custom_los_blocking_ids)


## Every possible enemy target of attacker: the opposing mech, plus (only
## when attacker is the AI) every currently-deployed player drone. There's no
## symmetric list of enemy drones yet since the AI never deploys any.
func _enemy_targets_of(attacker: mech) -> Array:
	if attacker == player_mech:
		return [ai_mech]
	var targets : Array = [player_mech]
	targets.append_array(player_drones)
	return targets


## Short label for a status message, from whichever side is being attacked.
func _target_label(target) -> String:
	if target == player_mech:
		return "you"
	if target == ai_mech:
		return "the enemy mech"
	return "a drone"


## Every enemy target attacker's action can actually reach right now: within
## [min_range, range] of attacker, inside attacker's front arc, and with a
## clear line of sight. Used for is_aoe actions, which hit every one of these
## at once instead of a single clicked/chosen target.
func _targets_hit_by(attacker: mech, action: Actions) -> Array:
	var hits : Array = []
	for target in _enemy_targets_of(attacker):
		if not is_instance_valid(target):
			continue
		var dist := HexGrid.distance(attacker.hex_coord, target.hex_coord)
		if dist < action.min_range or dist > action.range:
			continue
		if not _is_in_front_arc(attacker, target.hex_coord):
			continue
		if not _has_line_of_sight(attacker.hex_coord, target.hex_coord):
			continue
		hits.append(target)
	return hits


## Rolls attacker's is_aoe action against every target _targets_hit_by finds —
## each target takes its own separate roll and push/pull, but all the dice
## show together and the status line summarizes every hit in one message.
func _resolve_aoe_attack(attacker: mech, action: Actions, current_level: int):
	var targets := _targets_hit_by(attacker, action)
	var all_hits : Array[int] = []
	var all_colors : Array[String] = []
	var lines : Array[String] = []
	for target in targets:
		var result := attacker.attack(target, action, current_level)
		var moved := _apply_push_pull(attacker.hex_coord, target, action.push_pull)
		all_hits.append_array(result.hits)
		all_colors.append_array(result.colors)
		lines.append("%s for %d damage%s" % [_target_label(target), result.damage, _push_pull_suffix(action.push_pull, moved)])
	_show_dice(all_hits, all_colors)
	var who := "You hit" if attacker == player_mech else "Enemy hit"
	if lines.is_empty():
		status_label.text = "%s nothing — no targets in range" % who
	else:
		status_label.text = "%s %s!" % [who, ", ".join(lines)]


## Pressing Attack no longer commits to a weapon automatically — it gathers
## every currently-usable weapon (equipped parts + the innate Basic Attack)
## and opens attack_weapon_popup so the player picks one before targeting.
func _on_attack_pressed():
	if current_mech != player_mech or actions_used == 0:
		return

	var dist := HexGrid.distance(player_mech.hex_coord, ai_mech.hex_coord)
	if player_mech.get_attack_action_for_range(dist) == null:
		status_label.text = "Enemy is out of range"
		return
	if not _is_in_front_arc(player_mech, ai_mech.hex_coord):
		status_label.text = "Enemy is outside your front arc — rotate to face them"
		return
	if not _has_line_of_sight(player_mech.hex_coord, ai_mech.hex_coord):
		status_label.text = "No line of sight to the enemy — something's blocking your shot"
		return

	var options := player_mech.get_available_attack_actions(dist, action_levels["attack"])
	if options.is_empty():
		status_label.text = "No equipped attack meets your current Attack level (Lv %d)" % action_levels["attack"]
		return

	for child in attack_weapon_list.get_children():
		child.queue_free()
	for action in options:
		var btn := Button.new()
		btn.text = _attack_action_name(action)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_attack_weapon_chosen.bind(action))

		var row := HBoxContainer.new()
		row.add_child(btn)
		if action.dice_count() > 0:
			row.add_child(DiceIcons.icon_row(action))
		attack_weapon_list.add_child(row)
	attack_weapon_popup.popup_centered()


func _on_attack_weapon_chosen(action: Actions):
	attack_weapon_popup.hide()
	selected_attack_action = action
	pending_mode = PendingMode.ATTACK
	renderer.update_reachable_highlight(hex_container, grid, {ai_mech.hex_coord: true}, highlighted_hexes)
	status_label.text = "Click the enemy to attack with %s" % _attack_action_name(action)


## Resource filename for a part (matches how LoadoutScreen names parts), or
## display_name for the innate Basic Attack (no resource_path of its own).
func _attack_action_name(action: Actions) -> String:
	if action.resource_path.is_empty():
		return action.display_name
	return action.resource_path.get_file().get_basename()


## Pressing Special starts a chain: 1 drone action (deploy/move/attack/crash)
## per level of the Special ladder, all under this single action slot. At
## level 0 there's nothing to chain, so the press does nothing. Each
## sub-action is picked and resolved via _prompt_special_action()/
## _advance_special_chain() before the slot is actually spent.
func _on_special_pressed():
	if current_mech != player_mech or actions_used == 0:
		return
	if action_levels["special"] <= 0:
		status_label.text = "Special is at Lv 0 — no drone actions available"
		return
	special_chain_remaining = action_levels["special"]
	special_chain_active = false
	_prompt_special_action()


## Shows the deploy-or-select step: click an empty adjacent hex to deploy a
## new drone (stock permitting), or click one of your existing drones to pick
## it and open the move/attack/crash popup for it. Called both by
## _on_special_pressed (first use) and _advance_special_chain (continuing
## the chain).
func _prompt_special_action():
	drone_sub_action = ""
	selected_drone = null

	var drone_type := player_mech.get_drone_type()
	var can_deploy := drone_type != null and drones_deployed < player_mech.get_max_drones()

	if player_drones.is_empty() and not can_deploy:
		status_label.text = "No equipped part grants a drone" if drone_type == null else "No drones remaining (%d/%d deployed)" % [drones_deployed, player_mech.get_max_drones()]
		if special_chain_active:
			_finish_special_use()
		return

	pending_mode = PendingMode.SPECIAL
	reachable = {}
	if can_deploy:
		for coord in HexGrid.get_neighbors(player_mech.hex_coord):
			if grid.is_valid(coord) and grid.is_passable(coord) and coord != ai_mech.hex_coord:
				reachable[coord] = true

	var highlight := reachable.duplicate()
	for d in player_drones:
		highlight[d.hex_coord] = true
	renderer.update_reachable_highlight(hex_container, grid, highlight, highlighted_hexes)

	var hint_parts : Array[String] = []
	if can_deploy:
		hint_parts.append("click an empty adjacent hex to deploy a drone")
	if not player_drones.is_empty():
		hint_parts.append("click one of your drones to control it")
	status_label.text = "%s (%d drone action(s) left)" % [", ".join(hint_parts), special_chain_remaining]


## Opens the move/attack/crash popup for whichever drone was just selected.
func _open_drone_popup():
	var dist_to_enemy := HexGrid.distance(selected_drone.hex_coord, ai_mech.hex_coord)
	var move_reachable := PathFinder.find_reachable(selected_drone.hex_coord, float(selected_drone.drone_type.movement), grid)
	move_reachable.erase(selected_drone.hex_coord)
	move_reachable.erase(player_mech.hex_coord)
	move_reachable.erase(ai_mech.hex_coord)
	for d in player_drones:
		move_reachable.erase(d.hex_coord)

	drone_move_button.disabled = move_reachable.is_empty()
	drone_attack_button.disabled = dist_to_enemy > selected_drone.drone_type.range or dist_to_enemy < selected_drone.drone_type.min_range or not _has_line_of_sight(selected_drone.hex_coord, ai_mech.hex_coord)
	drone_crash_button.disabled = dist_to_enemy != 1
	drone_popup_title.text = "Drone Action (%d left)" % special_chain_remaining
	drone_action_popup.popup_centered()


## Called after each sub-action resolves. Continues the chain if any drone
## actions remain, otherwise spends the action slot for real.
func _advance_special_chain():
	special_chain_active = true
	special_chain_remaining -= 1
	_clear_pending()
	if special_chain_remaining > 0 and not game_over:
		_prompt_special_action()
	else:
		_finish_special_use()


func _finish_special_use():
	special_chain_remaining = 0
	special_chain_active = false
	_rotate_action_levels("special")
	_clear_pending()
	_use_action_slot()


func _on_drone_move_chosen():
	drone_action_popup.hide()
	pending_mode = PendingMode.SPECIAL
	drone_sub_action = "move"

	reachable = PathFinder.find_reachable(selected_drone.hex_coord, float(selected_drone.drone_type.movement), grid)
	reachable.erase(selected_drone.hex_coord)
	reachable.erase(player_mech.hex_coord)
	reachable.erase(ai_mech.hex_coord)
	for d in player_drones:
		reachable.erase(d.hex_coord)
	renderer.update_reachable_highlight(hex_container, grid, reachable, highlighted_hexes)
	status_label.text = "Click a hex to move the drone (%d drone action(s) left)" % special_chain_remaining


func _on_drone_attack_chosen():
	drone_action_popup.hide()
	pending_mode = PendingMode.SPECIAL
	drone_sub_action = "attack"

	reachable = {}
	renderer.update_reachable_highlight(hex_container, grid, {ai_mech.hex_coord: true}, highlighted_hexes)
	status_label.text = "Click the enemy to attack with your drone (%d drone action(s) left)" % special_chain_remaining


func _on_drone_crash_chosen():
	drone_action_popup.hide()
	pending_mode = PendingMode.SPECIAL
	drone_sub_action = "crash"

	reachable = {}
	renderer.update_reachable_highlight(hex_container, grid, {ai_mech.hex_coord: true}, highlighted_hexes)
	var node := HexRenderer.get_visual_part(hex_container, ai_mech.hex_coord, "Highlight")
	if node:
		node.color = RAM_COLOR
		node.visible = true
	highlighted_hexes[ai_mech.hex_coord] = true
	status_label.text = "Click the enemy to crash your drone into it (destroys the drone, %d drone action(s) left)" % special_chain_remaining


func _on_end_turn_pressed():
	if current_mech != player_mech or game_over:
		return
	_clear_pending()
	next_turn()


func _on_cell_pressed(coord: Vector2i, event: InputEvent):
	if event is InputEventMouseButton and event.button_index != MOUSE_BUTTON_LEFT:
		return
	if current_mech != player_mech or game_over:
		return

	match pending_mode:
		PendingMode.MOVE:
			if move_targets.has(coord):
				var target_value : int = move_targets[coord]
				if target_value == -1:
					player_mech.move_to(coord)
					move_points_remaining -= 1
				elif target_value == -2:
					var beyond := HexDirections.step(coord, player_mech.facing)
					ai_mech.move_to(beyond)
					player_mech.move_to(coord)
					status_label.text = "You rammed the enemy back and took its place!"
					move_points_remaining -= RAM_COST
				else:
					player_mech.face(target_value)
					move_points_remaining -= 1
				move_points_remaining = maxi(0, move_points_remaining)
				if move_points_remaining <= 0:
					_finish_move()
				else:
					_refresh_move_highlight()
		PendingMode.ATTACK:
			if coord == ai_mech.hex_coord and selected_attack_action:
				var action := selected_attack_action
				if action.is_aoe:
					_resolve_aoe_attack(player_mech, action, action_levels["attack"])
				else:
					var result := player_mech.attack(ai_mech, action, action_levels["attack"])
					var moved := _apply_push_pull(player_mech.hex_coord, ai_mech, action.push_pull)
					status_label.text = "You hit for %s = %d damage!%s" % [str(result.hits), result.damage, _push_pull_suffix(action.push_pull, moved)]
					_show_dice(result.hits, result.colors)
				_rotate_action_levels("attack")
				_clear_pending()
				if not _check_game_over():
					await get_tree().create_timer(3.0).timeout
					next_turn()
		PendingMode.SPECIAL:
			if drone_sub_action == "":
				var clicked_drone := _drone_at(coord)
				if clicked_drone:
					selected_drone = clicked_drone
					_open_drone_popup()
				elif reachable.has(coord):
					_deploy_drone(coord)
					_advance_special_chain()
			elif drone_sub_action == "crash":
				if coord == ai_mech.hex_coord and HexGrid.distance(selected_drone.hex_coord, ai_mech.hex_coord) == 1:
					var damage := selected_drone.crash(ai_mech)
					status_label.text = "Your drone crashed for %d damage and was destroyed!" % damage
					if not _check_game_over():
						await get_tree().create_timer(3.0).timeout
						_advance_special_chain()
			elif drone_sub_action == "attack":
				var drone_dist := HexGrid.distance(selected_drone.hex_coord, ai_mech.hex_coord)
				if coord == ai_mech.hex_coord and drone_dist <= selected_drone.drone_type.range and drone_dist >= selected_drone.drone_type.min_range and _has_line_of_sight(selected_drone.hex_coord, ai_mech.hex_coord):
					var result := selected_drone.attack(ai_mech)
					status_label.text = "Drone hit for %s = %d damage!" % [str(result.hits), result.damage]
					_show_dice(result.hits, result.colors)
					if not _check_game_over():
						await get_tree().create_timer(3.0).timeout
						_advance_special_chain()
			elif drone_sub_action == "move":
				if reachable.has(coord):
					selected_drone.move_to(coord)
					_advance_special_chain()


func _deploy_drone(coord: Vector2i):
	var drone := Drone.new()
	drone.setup(player_mech.get_drone_type())
	drone.hex_size = HEX_SIZE
	drone.hex_coord = coord
	add_child(drone)
	drone.snap_to_grid()
	drone.died.connect(_on_drone_died.bind(drone))
	player_drones.append(drone)
	drones_deployed += 1


func _on_drone_died(drone: Drone):
	var remaining := player_mech.get_max_drones() - drones_deployed
	status_label.text = "One of your drones was destroyed! (%d more deployable this match)" % remaining
	player_drones.erase(drone)
	if selected_drone == drone:
		selected_drone = null
	drone.queue_free()


func _show_dice(hits: Array[int], colors: Array[String]):
	for child in dice_row.get_children():
		child.queue_free()
	for i in hits.size():
		var die := DieFace.new()
		die.face = hits[i]
		die.die_color = Dice.DISPLAY_COLORS.get(colors[i], Color.WHITE)
		dice_row.add_child(die)


func _clear_pending():
	pending_mode = PendingMode.NONE
	reachable = {}
	move_targets = {}
	move_points_remaining = 0
	drone_sub_action = ""
	selected_drone = null
	selected_attack_action = null
	move_points_label.visible = false
	renderer.update_reachable_highlight(hex_container, grid, {}, highlighted_hexes)


## Moves ai_mech up to movement_points hexes along the path toward target_coord,
## stopping short of the player mech or any of its drones' hexes. Returns true
## if it moved.
func _ai_move_leg(target_coord: Vector2i, movement_points: float) -> bool:
	var move_reachable := PathFinder.find_reachable(ai_mech.hex_coord, movement_points, grid)
	var path := PathFinder.find_path_astar(ai_mech.hex_coord, target_coord, grid)
	var moved := false
	for step in path:
		if step == player_mech.hex_coord:
			break
		if _drone_at(step) != null:
			break
		if not move_reachable.has(step):
			break
		ai_mech.move_to(step)
		moved = true
	return moved


## Shoves [param target] (a mech or Drone) [param amount] hexes along the
## attacker→target line: positive pushes it away, negative pulls it closer.
## Stops early on impassable terrain or a hex already occupied by another
## unit. Returns how many hexes it actually moved.
func _apply_push_pull(attacker_coord: Vector2i, target, amount: int) -> int:
	if amount == 0 or not is_instance_valid(target):
		return 0

	var dir_index := HexDirections.direction_index(attacker_coord, target.hex_coord)
	if dir_index == -1:
		return 0
	var dir : Vector3i = HexDirections.DIRECTIONS[dir_index]
	if amount < 0:
		dir = -dir

	var current : Vector2i = target.hex_coord
	var moved := 0
	for i in absi(amount):
		var next := HexDirections.cube_to_offset(HexGrid.offset_to_cube(current) + dir)
		if not grid.is_valid(next) or not grid.is_passable(next):
			break
		if next == player_mech.hex_coord or next == ai_mech.hex_coord:
			break
		if _drone_at(next) != null:
			break
		current = next
		target.move_to(current)
		moved += 1
	return moved


## Builds a status suffix like " Target pushed back 2!" for a push/pull result.
func _push_pull_suffix(amount: int, moved: int) -> String:
	if moved == 0:
		return ""
	return " Target pulled closer %d!" % moved if amount < 0 else " Target pushed back %d!" % moved


## Faces ai_mech toward target_coord if there's a meaningful direction.
## The AI doesn't spend a movement point to rotate the way the player does —
## teaching it to weigh rotation against advancing is a bigger AI problem
## than this prototype needs tonight, so it just always turns to face
## whatever it's about to shoot or move toward.
func _ai_face(target_coord: Vector2i):
	var dir := HexDirections.direction_index(ai_mech.hex_coord, target_coord)
	if dir != -1:
		ai_mech.face(dir)


## Mirrors the player's 2-action turn: move up to 2 hexes toward the player
## mech if not already in attack range, then attack (mech, then drone) or
## move again with the remaining action slot.
func _ai_take_turn() -> bool:
	var move_action := ai_mech.get_move_action()

	var dist := HexGrid.distance(ai_mech.hex_coord, player_mech.hex_coord)
	if move_action and ai_mech.get_attack_action_for_range(dist) == null:
		_ai_move_leg(player_mech.hex_coord, float(move_action.movement))
		dist = HexGrid.distance(ai_mech.hex_coord, player_mech.hex_coord)

	var attack_action := ai_mech.get_attack_action_for_range(dist)
	if attack_action and _has_line_of_sight(ai_mech.hex_coord, player_mech.hex_coord):
		_ai_face(player_mech.hex_coord)
		if attack_action.is_aoe:
			# Hits player_mech and any player drones next to it at once —
			# see _enemy_targets_of().
			_resolve_aoe_attack(ai_mech, attack_action, 1)
		else:
			var result := ai_mech.attack(player_mech, attack_action)
			var moved := _apply_push_pull(ai_mech.hex_coord, player_mech, attack_action.push_pull)
			status_label.text = "Enemy hit for %s = %d damage!%s" % [str(result.hits), result.damage, _push_pull_suffix(attack_action.push_pull, moved)]
			_show_dice(result.hits, result.colors)
		return true

	if not player_drones.is_empty():
		# Targets whichever of the player's drones is closest — the AI doesn't
		# weigh which drone is most threatening, just the easiest to reach.
		var target_drone : Drone = null
		var best_dist := 999999
		for d in player_drones:
			var dist_to_d := HexGrid.distance(ai_mech.hex_coord, d.hex_coord)
			if dist_to_d < best_dist:
				best_dist = dist_to_d
				target_drone = d

		var drone_attack_action := ai_mech.get_attack_action_for_range(best_dist)
		if target_drone and drone_attack_action and _has_line_of_sight(ai_mech.hex_coord, target_drone.hex_coord):
			_ai_face(target_drone.hex_coord)
			var result := ai_mech.attack(target_drone, drone_attack_action)
			var moved := _apply_push_pull(ai_mech.hex_coord, target_drone, drone_attack_action.push_pull)
			status_label.text = "Enemy destroyed one of your drones! (%s = %d damage)%s" % [str(result.hits), result.damage, _push_pull_suffix(drone_attack_action.push_pull, moved)]
			_show_dice(result.hits, result.colors)
			return true

	if move_action:
		var moved := _ai_move_leg(player_mech.hex_coord, float(move_action.movement))
		if moved:
			_ai_face(player_mech.hex_coord)
		status_label.text = "Enemy moved." if moved else "Enemy held position."
	else:
		status_label.text = "Enemy passed."

	return false
