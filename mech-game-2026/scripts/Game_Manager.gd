extends Node2D

enum PendingMode { NONE, MOVE, ATTACK, SPECIAL }

const HEX_SIZE := 48.0

const DRONE_SCENE := preload("res://Scenes/drone.tscn")

## Used if level_map isn't assigned in the scene, so existing scenes keep
## working without needing an update.
const DEFAULT_LEVEL_MAP_PATH := "res://resources/Levels/RingTestMap.tres"

## Used if ai_mech.ai_behavior isn't assigned, so existing scenes keep
## working without needing an update.
const DEFAULT_AI_BEHAVIOR_PATH := "res://resources/AI/Bold.tres"

## Each turn is 2 action slots: slot 0 must be Move, slot 1 can be Move,
## Attack, or Special. Reaching this count ends the turn.
const ACTIONS_PER_TURN := 2

## First to WINNING_SCORE kills wins the match. Destroying a mech that
## hasn't yet cost its owner the match respawns it (at full HP, on its own
## spawn hex) instead of ending things outright — see _check_game_over().
const WINNING_SCORE := 2
var player_score : int = 0
var ai_score : int = 0

## Fixed tiebreak order for the 2nd-action column when two options share a level.
## "react" is display-only (see ReactRow) — it's never pressed, only shown.
const SECOND_ACTION_KEYS := ["move", "attack", "special", "react"]

## Human-readable labels for SECOND_ACTION_KEYS, used by the Overdrive
## choice popup (see _prompt_overdrive_choice()).
const OVERDRIVE_LABELS := {"move": "Move", "attack": "Attack", "special": "Special", "react": "React"}

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

@onready var world_viewport_container: SubViewportContainer = $UI/WorldViewportContainer
@onready var world_viewport: SubViewport = $UI/WorldViewportContainer/WorldViewport
@onready var hex_container: Node2D = $UI/WorldViewportContainer/WorldViewport/HexContainer
@onready var camera: Camera2D = $UI/WorldViewportContainer/WorldViewport/Camera2D
@onready var score_label: Label = $UI/BottomBar/Margin/VBox/ScoreLabel
@onready var status_label: Label = $UI/BottomBar/Margin/VBox/StatusLabel
@onready var move_points_label: Label = $UI/BottomBar/Margin/VBox/MovePointsLabel
@onready var move_button_1: Button = $UI/MovePanel/Margin/VBox/MoveButton1
@onready var move_button_2: Button = $UI/SecondActionPanel/Margin/VBox/RowsBox/MoveRow/MoveButton2
@onready var attack_button: Button = $UI/SecondActionPanel/Margin/VBox/RowsBox/AttackRow/AttackButton
@onready var special_button: Button = $UI/SecondActionPanel/Margin/VBox/RowsBox/SpecialRow/SpecialButton
## Not connected to anything (React is display-only, see react_row) — only
## used to swap its icon between the normal/Overdrive art. See
## _update_action_type_icons().
@onready var react_button: Button = $UI/SecondActionPanel/Margin/VBox/RowsBox/ReactRow/ReactButton
## Spends the 2nd action slot to freely re-rank all 4 action_levels instead
## of Move/Attack/Special — see _on_reset_pressed()/_prompt_reset_order().
@onready var reset_button: Button = $UI/SecondActionPanel/Margin/VBox/ResetButton
@onready var end_turn_button: Button = $UI/EndTurnPanel/Margin/EndTurnButton
@onready var skip_move_button: Button = $UI/MovePanel/Margin/VBox/SkipButton1
@onready var skip_move_button_2: Button = $UI/SecondActionPanel/Margin/VBox/SkipButton2
@onready var dice_row: HBoxContainer = $UI/BottomBar/Margin/VBox/DiceRow

## Level badges shown next to each 2nd-action option (see _update_action_level_labels()).
@onready var move_level_badge: TextureRect = $UI/SecondActionPanel/Margin/VBox/RowsBox/MoveRow/MoveLevelBadge
@onready var attack_level_badge: TextureRect = $UI/SecondActionPanel/Margin/VBox/RowsBox/AttackRow/AttackLevelBadge
@onready var special_level_badge: TextureRect = $UI/SecondActionPanel/Margin/VBox/RowsBox/SpecialRow/SpecialLevelBadge
@onready var react_level_badge: TextureRect = $UI/SecondActionPanel/Margin/VBox/RowsBox/ReactRow/ReactLevelBadge
## Row containers (badge + button) reordered as a unit by _reorder_second_action_buttons().
@onready var move_row: HBoxContainer = $UI/SecondActionPanel/Margin/VBox/RowsBox/MoveRow
@onready var attack_row: HBoxContainer = $UI/SecondActionPanel/Margin/VBox/RowsBox/AttackRow
@onready var special_row: HBoxContainer = $UI/SecondActionPanel/Margin/VBox/RowsBox/SpecialRow
@onready var react_row: HBoxContainer = $UI/SecondActionPanel/Margin/VBox/RowsBox/ReactRow
const LEVEL_BADGE_TEXTURES := [
	preload("res://images/Action_lvl_icon/lvl_0.png"),
	preload("res://images/Action_lvl_icon/lvl_1.png"),
	preload("res://images/Action_lvl_icon/lvl_2.png"),
	preload("res://images/Action_lvl_icon/lvl_3.png"),
]

## Normal action-type icon for each 2nd-action row's button — see
## _update_action_type_icons().
const ACTION_ICON_TEXTURES := {
	"move": preload("res://images/Action type/move.png"),
	"attack": preload("res://images/Action type/attack.png"),
	"special": preload("res://images/Action type/drone.png"),
	"react": preload("res://images/Action type/block.png"),
}
## "+1" Overdrive variant of each of the above — shown instead when the
## local player's own mech has Overdrive on that action (see
## mech.overdrive_actions / mech.get_effective_level()).
const OVERDRIVE_ICON_TEXTURES := {
	"move": preload("res://images/Action type/move+1.png"),
	"attack": preload("res://images/Action type/attack+1.png"),
	"special": preload("res://images/Action type/Drone+1.png"),
	"react": preload("res://images/Action type/block+1.png"),
}

@onready var loadout_layer: LoadoutScreen = $LoadoutLayer
@onready var connect_layer: ConnectScreen = $ConnectLayer

@onready var drone_action_popup: PopupPanel = $UI/DroneActionPopup
@onready var drone_popup_title: Label = $UI/DroneActionPopup/VBoxContainer/TitleLabel
@onready var drone_move_button: Button = $UI/DroneActionPopup/VBoxContainer/MoveButton
@onready var drone_attack_button: Button = $UI/DroneActionPopup/VBoxContainer/AttackButton
@onready var drone_crash_button: Button = $UI/DroneActionPopup/VBoxContainer/CrashButton

@onready var attack_weapon_popup: PopupPanel = $UI/AttackWeaponPopup
@onready var attack_weapon_list: VBoxContainer = $UI/AttackWeaponPopup/VBoxContainer/WeaponList

@onready var overdrive_popup: PopupPanel = $UI/OverdrivePopup
@onready var overdrive_action_list: VBoxContainer = $UI/OverdrivePopup/VBoxContainer/ActionList

@onready var reset_order_popup: PopupPanel = $UI/ResetOrderPopup
@onready var reset_order_action_list: VBoxContainer = $UI/ResetOrderPopup/VBoxContainer/ActionList

## True once the match has started — Parts can only be equipped before this.
var match_started : bool = false

var grid : HexGrid
var renderer : HexRenderer
var camera_ctrl : MapCamera

var current_mech : mech
## Peer id of whichever peer controls ai_mech in a 2-player match (the host,
## peer 1, always controls player_mech). Set once the second peer connects —
## see _on_network_peer_connected().
var ai_mech_owner_peer_id : int = -1
## Host-only: whether each side's loadout is done yet — see
## _on_loadout_finished()/_maybe_start_networked_match().
var _host_loadout_ready : bool = false
var _client_loadout_ready : bool = false
var pending_mode : PendingMode = PendingMode.NONE
var reachable : Dictionary = {}
var highlighted_hexes : Dictionary = {}

## During a Move: Vector2i -> -1 (move forward there) or a direction index
## (rotate to face that way without moving). Points left in the current move.
var move_targets : Dictionary = {}
var move_points_remaining : int = 0
## Whichever move part/action is powering the player's current move — passed
## to mech.move_to() so its custom move animation (if any) can play.
var current_move_action : Actions = null

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

## Whichever mech is currently showing the Overdrive choice popup (always
## the LOCAL peer's own mech — see _prompt_overdrive_choice()) — null the
## rest of the time.
var _overdrive_prompt_mech : mech = null

## Keys ranked so far while the local player is choosing a Reset order
## (highest first) — see _on_reset_pressed()/_show_reset_order_options().
var _reset_order_picks : Array[String] = []

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
	"react": 0,
}

var game_over : bool = false


func _ready():
	if level_map == null:
		level_map = load(DEFAULT_LEVEL_MAP_PATH)
	grid_width = level_map.grid_width
	grid_height = level_map.grid_height

	if ai_mech.ai_behavior == null:
		ai_mech.ai_behavior = load(DEFAULT_AI_BEHAVIOR_PATH)

	_setup_grid()

	attack_button.pressed.connect(_on_attack_pressed)
	move_button_1.pressed.connect(_on_move_pressed)
	move_button_2.pressed.connect(_on_move_pressed)
	special_button.pressed.connect(_on_special_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	skip_move_button.pressed.connect(_on_skip_move_pressed)
	skip_move_button_2.pressed.connect(_on_skip_move_pressed)
	loadout_layer.start_match.connect(_on_loadout_finished)
	connect_layer.finished.connect(_on_connect_finished)
	NetworkManager.peer_connected.connect(_on_network_peer_connected)
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

	player_mech.spawn_hex_coord = player_mech.hex_coord
	player_mech.spawn_facing = player_mech.facing
	ai_mech.spawn_hex_coord = ai_mech.hex_coord
	ai_mech.spawn_facing = ai_mech.facing

	_update_action_level_labels()
	_update_score_label()
	connect_layer.show_screen()


## Called once the connect screen decides the match type (vs AI, or a 2P
## connection was established) — only now do we actually enter the loadout
## phase(s).
func _on_connect_finished():
	_enter_loadout_phase()


## Fires on both sides once host+client are connected. Only meaningful on
## the host — records which peer controls ai_mech for the rest of the match
## (turn-ownership checks in the RPC receivers above).
func _on_network_peer_connected(peer_id: int):
	if NetworkManager.am_i_host():
		ai_mech_owner_peer_id = peer_id

func _unhandled_input(event):
	# camera_ctrl isn't created until _setup_grid() runs partway through
	# _ready() — an input event can still reach here before then (e.g. a
	# queued event from before the scene finished loading, or a live script
	# reload while the scene was already running).
	if camera_ctrl == null:
		return
	camera_ctrl.handle_input(event)
	_maybe_handle_world_click(event)


## Hex clicks are normally picked up via HexRenderer's Area2D-based physics
## picking (see renderer.cell_pressed), which relies on the hex world's own
## SubViewport having physics_object_picking enabled — that works natively
## but hasn't proven reliable in an HTML5/browser export. This is a second,
## independent path to the same _on_cell_pressed() logic: compute the clicked
## hex directly from the click's screen position, bypassing physics picking
## entirely, so it works the same everywhere. Only fires for clicks that
## fall through every UI Control (buttons etc. already consume their own).
func _maybe_handle_world_click(event: InputEvent):
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var container_rect := Rect2(world_viewport_container.global_position, world_viewport_container.size)
	if not container_rect.has_point(event.global_position):
		return
	var local_pos : Vector2 = event.global_position - world_viewport_container.global_position
	var world_pos : Vector2 = world_viewport.get_canvas_transform().affine_inverse() * local_pos
	var coord := HexGrid.pixel_to_offset(world_pos, HEX_SIZE)
	_on_cell_pressed(coord, event)


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

	# The camera is meant to stay completely fixed — Game_Manager has no
	# _process() override, so camera_ctrl.process() (the only thing that
	# would move it: follow-the-current-mech lerp, or its edge-scroll
	# fallback when follow is off — MapCamera.process() always does one or
	# the other, there's no "neither" mode) is simply never called. Manual
	# right-click drag / scroll zoom still work — those are handled in
	# handle_input(), which _unhandled_input() still forwards every event to.
	# follow_target/edge_margin below are set defensively in case anything
	# ever calls .process() directly, but aren't load-bearing today.
	camera_ctrl = MapCamera.new(camera, world_viewport, {"edge_margin": 0.0})
	camera_ctrl.follow_target = false
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
## In a 2-player match, each peer builds their OWN mech's loadout locally —
## the host builds player_mech, the joining client builds their own local
## ai_mech — then the client's final parts are synced to the host (see
## _on_loadout_finished/_rpc_sync_client_parts) before the match starts.
func _enter_loadout_phase():
	attack_button.disabled = true
	move_button_1.disabled = true
	move_button_2.disabled = true
	special_button.disabled = true
	reset_button.disabled = true
	end_turn_button.disabled = true
	status_label.text = "Equip parts, then click Start Match"
	# The joining client builds their loadout on ai_mech, which may carry
	# fixed parts meant for solo vs-AI mode (see main.tscn) — start it blank
	# so player 2 gets the same empty slate player_mech always has.
	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		ai_mech.reset_loadout()
	loadout_layer.player_mech = _my_mech()
	loadout_layer.show_loadout()


## Fires once THIS peer's own loadout screen is done. Solo/vs-AI starts the
## match immediately as before; a 2-player match waits for both sides.
func _on_loadout_finished():
	if not NetworkManager.is_networked():
		_on_match_started()
		return

	if NetworkManager.am_i_host():
		_host_loadout_ready = true
		status_label.text = "Waiting for the other player to finish their loadout..."
		_maybe_start_networked_match()
	else:
		var paths : Array[String] = []
		for part in ai_mech.parts:
			paths.append(part.resource_path)
		_rpc_sync_client_parts.rpc_id(1, paths)
		status_label.text = "Waiting for the host to start the match..."


## Host-only: receives the joining client's final loadout (as resource
## paths — both sides ship the same res://resources/parts/*.tres files, so
## loading by path is enough) and applies it to the host's own ai_mech via
## add_part(), same as if the host had picked them from the same screen.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_sync_client_parts(paths: Array):
	if not multiplayer.is_server():
		return
	# The host's own ai_mech may still carry whatever fixed parts main.tscn
	# gives it for solo vs-AI mode — clear those first (mirroring the
	# client's own reset_loadout() call in _enter_loadout_phase()) so the
	# client's real choices don't silently fail to add_part() because the
	# loadout already reads as "full" from leftover solo-mode data.
	ai_mech.reset_loadout()
	for path in paths:
		var part : Part = load(path)
		if part:
			ai_mech.add_part(part)
	_client_loadout_ready = true
	_maybe_start_networked_match()


func _maybe_start_networked_match():
	if _host_loadout_ready and _client_loadout_ready:
		_rpc_start_match.rpc()
		_on_match_started()


## Tells the joining client the match is starting — the client's own
## next_turn() is a no-op either way (only the host runs it for real), but
## _on_match_started() also flips match_started so a stray double-call is
## harmless, and the real turn state arrives via the host's next
## _broadcast_state().
@rpc("authority", "call_remote", "reliable")
func _rpc_start_match():
	_on_match_started()


func _on_match_started():
	if match_started:
		return
	match_started = true
	next_turn()


## The other mech from m's perspective — player_mech's opponent is ai_mech
## and vice versa. Used to keep the turn-based handlers (move/attack/end
## turn) generic over whichever mech is actually acting, instead of always
## assuming "player_mech acts against ai_mech" — needed so a 2-player match
## can drive ai_mech's turn through the exact same UI code path as
## player_mech's, not just the AI logic.
func _opponent_of(m: mech) -> mech:
	return ai_mech if m == player_mech else player_mech


## Whichever mech THIS peer is allowed to act for. Solo/vs-AI and the host in
## a 2-player match both control player_mech; the joining client controls
## ai_mech. NetworkManager.is_networked() is false in solo/vs-AI, so this is
## always player_mech there regardless of am_i_host().
func _my_mech() -> mech:
	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		return ai_mech
	return player_mech


## In a 2-player match, only the host ever runs this for real — the client
## just waits for the resulting state snapshot (see _rpc_apply_snapshot).
func next_turn ():
	if game_over:
		return
	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
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
		if NetworkManager.is_networked():
			_broadcast_state()
		return

	if NetworkManager.is_networked():
		actions_used = 0
		_apply_turn_ui()
		_broadcast_state()
	elif current_mech.is_player:
		actions_used = 0
		_update_action_buttons()
		status_label.text = "Your turn — move up to 3 hexes"
	else:
		attack_button.disabled = true
		move_button_1.disabled = true
		move_button_2.disabled = true
		special_button.disabled = true
		reset_button.disabled = true
		end_turn_button.disabled = true
		skip_move_button.disabled = true
		skip_move_button_2.disabled = true
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
	reset_button.disabled = actions_used == 0
	end_turn_button.disabled = false
	skip_move_button.disabled = true
	skip_move_button_2.disabled = true
	if NetworkManager.is_networked() and current_mech != player_mech:
		# Special/drones aren't wired for a 2-player match yet (player_drones,
		# drones_deployed etc. are all singular/player-1-only) — keep it
		# hidden from player 2 rather than letting them hit a broken path.
		special_button.disabled = true


## Shows/hides this peer's own action buttons based on whether it's actually
## their turn — called both by the host (right after next_turn()) and by a
## client applying an incoming state snapshot.
func _apply_turn_ui():
	if current_mech == _my_mech() and not game_over:
		_update_action_buttons()
		status_label.text = "Your turn — move up to 3 hexes"
	else:
		attack_button.disabled = true
		move_button_1.disabled = true
		move_button_2.disabled = true
		special_button.disabled = true
		reset_button.disabled = true
		end_turn_button.disabled = true
		skip_move_button.disabled = true
		skip_move_button_2.disabled = true
		if not game_over:
			status_label.text = "Waiting for the other player's turn..."


func _use_action_slot():
	actions_used += 1
	if actions_used >= ACTIONS_PER_TURN:
		next_turn()
	else:
		_update_action_buttons()
		status_label.text = "Choose your second action: Move, Attack, Special, or Reset"


## Drops used_key to 0 and shifts every key that was ranked below it up by
## one to fill the gap — every key at or above used_key's old rank keeps its
## exact level. Only call this when the action taken was the 2nd action slot
## — the mandatory 1st-action Move isn't part of this ladder.
##
## action_levels must always hold a permutation of 0..N-1 (each level used
## exactly once) so there's a clear ranking — incrementing every non-used
## key independently (the previous approach) breaks that guarantee as soon
## as two keys are both already at the cap, since neither can climb any
## higher and they end up tied (e.g. 0,1,3,3 instead of 0,1,2,3). Resetting
## more than one key (e.g. an attack that also triggers a Reaction) needs
## two separate calls in sequence, not one call with both keys — two keys
## can't both legitimately be "the most recently used" at once.
func _rotate_action_levels(used_key: String):
	var used_rank : int = action_levels[used_key]
	for key in action_levels.keys():
		if key != used_key and action_levels[key] < used_rank:
			action_levels[key] += 1
	action_levels[used_key] = 0
	_update_action_level_labels()


func _update_action_level_labels():
	move_level_badge.texture = LEVEL_BADGE_TEXTURES[action_levels["move"]]
	attack_level_badge.texture = LEVEL_BADGE_TEXTURES[action_levels["attack"]]
	special_level_badge.texture = LEVEL_BADGE_TEXTURES[action_levels["special"]]
	react_level_badge.texture = LEVEL_BADGE_TEXTURES[action_levels["react"]]
	_update_action_type_icons()
	_reorder_second_action_buttons()


## Swaps each 2nd-action row's button icon to its Overdrive ("+1") variant
## if the local player's own mech (_my_mech()) has Overdrive on that action,
## else its normal icon — see ACTION_ICON_TEXTURES/OVERDRIVE_ICON_TEXTURES.
func _update_action_type_icons():
	var my_overdrive := _my_mech().overdrive_actions
	move_button_2.icon = OVERDRIVE_ICON_TEXTURES["move"] if my_overdrive.has("move") else ACTION_ICON_TEXTURES["move"]
	attack_button.icon = OVERDRIVE_ICON_TEXTURES["attack"] if my_overdrive.has("attack") else ACTION_ICON_TEXTURES["attack"]
	special_button.icon = OVERDRIVE_ICON_TEXTURES["special"] if my_overdrive.has("special") else ACTION_ICON_TEXTURES["special"]
	react_button.icon = OVERDRIVE_ICON_TEXTURES["react"] if my_overdrive.has("react") else ACTION_ICON_TEXTURES["react"]


## Reorders the 2nd-action rows so the highest-level option sits on top,
## breaking ties via SECOND_ACTION_KEYS so the order stays deterministic.
## Each row (level badge + colored button) moves as a unit.
func _reorder_second_action_buttons():
	var rows_by_key := {
		"move": move_row,
		"attack": attack_row,
		"special": special_row,
		"react": react_row,
	}
	var sorted_keys := SECOND_ACTION_KEYS.duplicate()
	sorted_keys.sort_custom(func(a, b):
		if action_levels[a] != action_levels[b]:
			return action_levels[a] > action_levels[b]
		return SECOND_ACTION_KEYS.find(a) < SECOND_ACTION_KEYS.find(b))

	var rows_box := move_row.get_parent()
	for i in sorted_keys.size():
		rows_box.move_child(rows_by_key[sorted_keys[i]], i)


## A KO awards the destroying player a point (see WINNING_SCORE) — if that
## point wins the match, it ends here; otherwise the destroyed mech respawns
## and play continues.
func _check_game_over() -> bool:
	if player_mech.current_hp <= 0:
		_score_kill(ai_mech, player_mech)
	elif ai_mech.current_hp <= 0:
		_score_kill(player_mech, ai_mech)

	if game_over:
		attack_button.disabled = true
		move_button_1.disabled = true
		move_button_2.disabled = true
		special_button.disabled = true
		reset_button.disabled = true
		end_turn_button.disabled = true
		skip_move_button.disabled = true
		skip_move_button_2.disabled = true
	_update_score_label()
	return game_over


## killer just destroyed victim: awards killer's owner a point. Ends the
## match (game_over = true) if that reaches WINNING_SCORE, otherwise
## respawns victim (see mech.respawn()) and reports the score so far.
func _score_kill(killer: mech, victim: mech):
	var killer_is_player := killer == player_mech
	if killer_is_player:
		player_score += 1
	else:
		ai_score += 1

	if killer_is_player and player_score >= WINNING_SCORE:
		status_label.text = "Victory! You win %d-%d." % [player_score, ai_score]
		game_over = true
	elif not killer_is_player and ai_score >= WINNING_SCORE:
		status_label.text = "Defeat! The enemy mech wins %d-%d." % [ai_score, player_score]
		game_over = true
	else:
		victim.respawn()
		var who := "Your" if victim == player_mech else "The enemy"
		status_label.text = "%s mech was destroyed! Score: you %d — enemy %d." % [who, player_score, ai_score]
		_handle_respawn_overdrive(victim)


func _update_score_label():
	score_label.text = "You: %d   Enemy: %d   (first to %d wins)" % [player_score, ai_score, WINNING_SCORE]


## Picks an Overdrive action for victim right after it respawns. _score_kill()
## (the only caller) runs host-authoritative-only in a 2-player match (or
## directly in solo mode) — so a networked player 2's mech (ai_mech) needs a
## remote prompt via RPC, while the local player and a solo-mode AI are
## handled directly.
func _handle_respawn_overdrive(victim: mech):
	if NetworkManager.is_networked():
		if victim == player_mech:
			_prompt_overdrive_choice(player_mech)
		else:
			_rpc_prompt_overdrive_choice.rpc_id(ai_mech_owner_peer_id)
	elif victim == ai_mech:
		_ai_choose_overdrive(ai_mech)
	else:
		_prompt_overdrive_choice(player_mech)


## Solo-mode AI auto-pick: prefers boosting Attack (the most directly
## impactful option for its own damage output) if it's still available, else
## whichever unclaimed action comes first. Special is never offered — the AI
## never deploys drones, so it would have no effect.
func _ai_choose_overdrive(m: mech):
	var available : Array[String] = []
	for key in SECOND_ACTION_KEYS:
		if key != "special" and not m.overdrive_actions.has(key):
			available.append(key)
	if available.is_empty():
		return
	var key : String = "attack" if available.has("attack") else available[0]
	m.add_overdrive(key)
	status_label.text += " The enemy mech gained Overdrive on %s!" % OVERDRIVE_LABELS[key]


## Shows the Overdrive choice popup for m — always the LOCAL peer's own mech
## (the host's player_mech, or a client's own ai_mech) — letting them grant
## Overdrive to one action m doesn't already have it on. No-op if every
## action is already claimed. Special is left off the list for a networked
## player 2 (ai_mech) since Special/drones aren't wired for 2-player matches
## at all (see _update_action_buttons()).
func _prompt_overdrive_choice(m: mech):
	var available : Array[String] = []
	for key in SECOND_ACTION_KEYS:
		if key == "special" and NetworkManager.is_networked() and m == ai_mech:
			continue
		if not m.overdrive_actions.has(key):
			available.append(key)
	if available.is_empty():
		return

	_overdrive_prompt_mech = m
	for child in overdrive_action_list.get_children():
		child.queue_free()
	for key in available:
		var btn := Button.new()
		btn.text = OVERDRIVE_LABELS[key]
		btn.pressed.connect(_on_overdrive_choice.bind(key))
		overdrive_action_list.add_child(btn)
	overdrive_popup.popup_centered()


func _on_overdrive_choice(key: String):
	overdrive_popup.hide()
	var m := _overdrive_prompt_mech
	_overdrive_prompt_mech = null
	if m == null:
		return

	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		# m is always our own ai_mech here (see _rpc_prompt_overdrive_choice) —
		# the host applies it for real and broadcasts the result back.
		_rpc_request_overdrive_choice.rpc_id(1, key)
		return

	m.add_overdrive(key)
	status_label.text = "%s granted Overdrive on %s!" % ["Your mech" if m == player_mech else "The enemy mech", OVERDRIVE_LABELS[key]]
	_update_action_level_labels()
	if NetworkManager.is_networked():
		_broadcast_state()


## Host-only: applies the joining client's Overdrive choice to the host's own
## ai_mech and broadcasts the result — mirrors the client->host request
## pattern used by _rpc_request_move()/_rpc_request_attack().
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_overdrive_choice(key: String):
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id:
		return
	ai_mech.add_overdrive(key)
	status_label.text = "The enemy mech granted Overdrive on %s!" % OVERDRIVE_LABELS[key]
	_broadcast_state()


## Tells the joining client to show the Overdrive choice popup for their own
## mech — sent right after the host authoritatively respawns ai_mech, since
## only the host ever runs _score_kill() (see _handle_respawn_overdrive()).
@rpc("authority", "call_remote", "reliable")
func _rpc_prompt_overdrive_choice():
	_prompt_overdrive_choice(ai_mech)


## The react level to use when resolving an attack against target: target's
## own Overdrive-boosted level if it's a mech, else the raw shared ladder
## value unchanged (a Drone target has no Overdrive/get_reacting_part() of
## its own — mech.attack() already guards on has_method("get_reacting_part")
## for exactly this reason, so the exact value passed through for a Drone
## target is moot).
func _react_level_for(target) -> int:
	if target is mech:
		return target.get_effective_level("react", action_levels["react"])
	return action_levels["react"]


## Alternative 2nd action: instead of Move/Attack/Special, spend the slot to
## freely re-rank all 4 action_levels in whatever order the player wants
## (via reset_order_popup — see _prompt_reset_order()), rather than letting
## the normal _rotate_action_levels() rotation decide. Costs the action slot
## and ends the turn like any other 2nd action.
func _on_reset_pressed():
	if current_mech != _my_mech() or actions_used == 0:
		return
	_reset_order_picks = []
	_show_reset_order_options()


## Shows a button for every SECOND_ACTION_KEYS entry not yet in
## _reset_order_picks — clicking one ranks it next (highest remaining rank
## first), until only one key is left, at which point it's auto-assigned
## the bottom rank and the whole order is committed (see _on_reset_order_pick()).
func _show_reset_order_options():
	for child in reset_order_action_list.get_children():
		child.queue_free()
	for key in SECOND_ACTION_KEYS:
		if _reset_order_picks.has(key):
			continue
		var btn := Button.new()
		btn.text = OVERDRIVE_LABELS[key]
		btn.pressed.connect(_on_reset_order_pick.bind(key))
		reset_order_action_list.add_child(btn)
	reset_order_popup.popup_centered()


func _on_reset_order_pick(key: String):
	_reset_order_picks.append(key)
	if _reset_order_picks.size() < SECOND_ACTION_KEYS.size() - 1:
		_show_reset_order_options()
		return
	for key2 in SECOND_ACTION_KEYS:
		if not _reset_order_picks.has(key2):
			_reset_order_picks.append(key2)
			break
	reset_order_popup.hide()
	_finish_reset_order(_reset_order_picks)


## Commits the finished order — locally if this peer is authoritative
## (solo/host), or as a request to the host otherwise (mirrors
## _on_skip_move_pressed()'s client/host split).
func _finish_reset_order(order: Array[String]):
	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		_rpc_request_reset_order.rpc_id(1, order)
		status_label.text = "Reordering — waiting to sync..."
		return
	_apply_reset_order(order)


## Host-only: applies the joining client's chosen order for real — mirrors
## the client->host request pattern used by _rpc_request_move()/
## _rpc_request_attack().
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_reset_order(order: Array):
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id or current_mech != ai_mech:
		return
	var typed_order : Array[String] = []
	typed_order.assign(order)
	_apply_reset_order(typed_order)


## order[0] gets the highest level (SECOND_ACTION_KEYS.size() - 1), order[1]
## the next, and so on down to 0 — this IS a valid 0..N-1 permutation by
## construction, same invariant _rotate_action_levels() maintains, so no
## other code needs to change to keep trusting that. Always the 2nd (and
## thus turn-ending) action — see the actions_used == 0 gate in
## _on_reset_pressed() — so _use_action_slot() always reaches next_turn(),
## which broadcasts on its own; no separate broadcast needed here.
func _apply_reset_order(order: Array[String]):
	for i in order.size():
		action_levels[order[i]] = order.size() - 1 - i
	var labels := order.map(func(k): return OVERDRIVE_LABELS[k])
	status_label.text = "%s reordered actions: %s" % ["You" if current_mech == player_mech else "The enemy", ", ".join(labels)]
	_update_action_level_labels()
	_clear_pending()
	_use_action_slot()


## Pressing Move starts a facing-based move: each of the mech's movement
## points buys either one step forward (in its current facing) or a free
## rotation to face any other direction. Pressing the same button again
## mid-move stops early instead of forcing every point to be spent.
func _on_move_pressed():
	if current_mech != _my_mech():
		return

	if pending_mode == PendingMode.MOVE and move_points_remaining > 0:
		_on_skip_move_pressed()
		return

	if actions_used >= ACTIONS_PER_TURN:
		return

	if not _start_move():
		return
	_disable_buttons_during_move()

	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		_rpc_request_move.rpc_id(1)


## Shared "start a move" mutation: computes move_targets from current_mech's
## own position/facing so pressing Move shows the right highlighted hexes.
## Runs locally on whichever peer needs the highlight (host or solo player).
## In a 2-player match the HOST must ALSO run this for the client's move (see
## _rpc_request_move) — not just the client's own local display — since
## _handle_cell_pressed() validates a clicked hex against the HOST's own
## move_targets, computed independently here from the same synced mech state
## rather than transmitted over the network. Deliberately does NOT touch
## button state (see _disable_buttons_during_move()) since that's only
## correct for whichever peer's own turn is actually showing on screen.
func _start_move() -> bool:
	var move_level := current_mech.get_effective_level("move", action_levels["move"])
	var move_action := current_mech.get_move_action(move_level)
	if move_action == null:
		status_label.text = "No equipped movement part meets your current Move level (Lv %d)" % move_level
		return false
	current_move_action = move_action
	move_points_remaining = move_action.movement
	pending_mode = PendingMode.MOVE
	_refresh_move_highlight()
	return true


## The RPC target the client calls to tell the host it started a move — the
## host needs its own move_targets populated (not just the client's local
## display) so it can validate the client's subsequent hex-click RPC for real.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_move():
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id or current_mech != ai_mech:
		return
	_start_move()


## Only Move (whichever column applies) and Skip stay enabled during a move —
## everything else is locked out until the move finishes.
func _disable_buttons_during_move():
	move_button_1.disabled = actions_used != 0
	move_button_2.disabled = actions_used != 1
	attack_button.disabled = true
	special_button.disabled = true
	reset_button.disabled = true
	end_turn_button.disabled = true
	skip_move_button.disabled = false
	skip_move_button_2.disabled = false


func _on_skip_move_pressed():
	if current_mech != _my_mech() or not (pending_mode == PendingMode.MOVE and move_points_remaining > 0):
		return
	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		_rpc_request_skip_move.rpc_id(1)
		return
	_finish_move()
	if NetworkManager.is_networked():
		_broadcast_state()


## The RPC target the client calls to ask the host to skip their remaining
## move for real — only ever meaningful on the host, validated against
## whichever peer actually owns the current turn.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_skip_move():
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id or current_mech != ai_mech:
		return
	if not (pending_mode == PendingMode.MOVE and move_points_remaining > 0):
		return
	_finish_move()
	_broadcast_state()


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

	var front := HexDirections.step(current_mech.hex_coord, current_mech.facing)
	if _is_hex_free(front):
		move_targets[front] = -1
		move_coords.append(front)
	elif front == _opponent_of(current_mech).hex_coord and move_points_remaining >= RAM_COST:
		var beyond := HexDirections.step(front, current_mech.facing)
		if _is_hex_free(beyond):
			move_targets[front] = -2
			ram_coord = front
			has_ram = true

	for i in HexDirections.DIRECTIONS.size():
		if i == current_mech.facing:
			continue
		var neighbor := HexDirections.step(current_mech.hex_coord, i)
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
## Returns true if any target's Reaction fired, so the caller can also
## rotate "react" (in a separate call, after "attack") when it did.
func _resolve_aoe_attack(attacker: mech, action: Actions, current_level: int) -> bool:
	var targets := _targets_hit_by(attacker, action)
	var all_hits : Array[int] = []
	var all_colors : Array[String] = []
	var lines : Array[String] = []
	var any_reaction := false
	for target in targets:
		var result := attacker.attack(target, action, current_level, _react_level_for(target))
		var moved := _apply_push_pull(attacker.hex_coord, target, action.push_pull)
		all_hits.append_array(result.hits)
		all_colors.append_array(result.colors)
		var reaction_suffix := " (%s's Reaction blocked %d damage!)" % [result.reaction_part_name, result.reaction_reduction] if result.reaction_used else ""
		lines.append("%s for %d damage%s%s" % [_target_label(target), result.damage, _push_pull_suffix(action.push_pull, moved), reaction_suffix])
		any_reaction = any_reaction or result.reaction_used
	_show_dice(all_hits, all_colors)
	var who := "You hit" if attacker == player_mech else "Enemy hit"
	if lines.is_empty():
		status_label.text = "%s nothing — no targets in range" % who
	else:
		status_label.text = "%s %s!" % [who, ", ".join(lines)]
	return any_reaction


## Pressing Attack no longer commits to a weapon automatically — it gathers
## every currently-usable weapon (equipped parts + the innate Basic Attack)
## and opens attack_weapon_popup so the player picks one before targeting.
func _on_attack_pressed():
	if current_mech != _my_mech() or actions_used == 0:
		return

	var enemy := _opponent_of(current_mech)
	var dist := HexGrid.distance(current_mech.hex_coord, enemy.hex_coord)
	if current_mech.get_attack_action_for_range(dist) == null:
		status_label.text = "Enemy is out of range"
		return
	if not _is_in_front_arc(current_mech, enemy.hex_coord):
		status_label.text = "Enemy is outside your front arc — rotate to face them"
		return
	if not _has_line_of_sight(current_mech.hex_coord, enemy.hex_coord):
		status_label.text = "No line of sight to the enemy — something's blocking your shot"
		return

	var attack_level_for_options := current_mech.get_effective_level("attack", action_levels["attack"])
	var options := current_mech.get_available_attack_actions(dist, attack_level_for_options)
	if options.is_empty():
		status_label.text = "No equipped attack meets your current Attack level (Lv %d)" % attack_level_for_options
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
	_start_attack(action)

	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		var enemy := _opponent_of(current_mech)
		var dist := HexGrid.distance(current_mech.hex_coord, enemy.hex_coord)
		var options := current_mech.get_available_attack_actions(dist, current_mech.get_effective_level("attack", action_levels["attack"]))
		_rpc_request_attack.rpc_id(1, options.find(action))


## Shared "pick this attack, wait for a target click" mutation — see
## _start_move() for why the host needs this too, not just the client's own
## local display: _handle_cell_pressed()'s ATTACK branch validates the
## clicked hex against the HOST's own selected_attack_action/pending_mode.
func _start_attack(action: Actions):
	selected_attack_action = action
	pending_mode = PendingMode.ATTACK
	var enemy := _opponent_of(current_mech)
	renderer.update_reachable_highlight(hex_container, grid, {enemy.hex_coord: true}, highlighted_hexes)
	status_label.text = "Click the enemy to attack with %s" % _attack_action_name(action)


## The RPC target the client calls to tell the host which attack it chose —
## sent as an index into get_available_attack_actions() (the same options
## list the client's own weapon popup was built from) rather than the Actions
## resource itself, since both peers can independently recompute that list
## identically from synced mech/level state.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_attack(option_index: int):
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id or current_mech != ai_mech:
		return
	var enemy := _opponent_of(current_mech)
	var dist := HexGrid.distance(current_mech.hex_coord, enemy.hex_coord)
	var options := current_mech.get_available_attack_actions(dist, current_mech.get_effective_level("attack", action_levels["attack"]))
	if option_index < 0 or option_index >= options.size():
		return
	_start_attack(options[option_index])


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
	var special_level := player_mech.get_effective_level("special", action_levels["special"])
	if special_level <= 0:
		status_label.text = "Special is at Lv 0 — no drone actions available"
		return
	special_chain_remaining = special_level
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
			if grid.is_valid(coord) and grid.is_passable(coord) and coord != ai_mech.hex_coord and _drone_at(coord) == null:
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
	if current_mech != _my_mech() or game_over:
		return
	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		_rpc_request_end_turn.rpc_id(1)
		return
	_clear_pending()
	next_turn()


## The RPC target the client calls to ask the host to end their turn for
## real — only ever meaningful on the host, validated against whichever
## peer actually owns the current turn.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_end_turn():
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id or current_mech != ai_mech:
		return
	_clear_pending()
	next_turn()


func _on_cell_pressed(coord: Vector2i, event: InputEvent):
	if event is InputEventMouseButton and event.button_index != MOUSE_BUTTON_LEFT:
		return
	if current_mech != _my_mech() or game_over:
		return

	if NetworkManager.is_networked() and not NetworkManager.am_i_host():
		_rpc_request_cell_pressed.rpc_id(1, coord)
		return

	await _handle_cell_pressed(coord)


## The RPC target the client calls to ask the host to process their click —
## only ever meaningful on the host, validated against whichever peer
## actually owns the current turn.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_cell_pressed(coord: Vector2i):
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != ai_mech_owner_peer_id or current_mech != ai_mech:
		return
	await _handle_cell_pressed(coord)


## Real mutation logic for a hex click — was the body of _on_cell_pressed(),
## now shared between a direct local click (solo, or the host acting on its
## own turn) and _rpc_request_cell_pressed (the host executing a click the
## client sent it). SPECIAL/drone handling is untouched and still only ever
## reachable when current_mech == player_mech — see _on_special_pressed().
func _handle_cell_pressed(coord: Vector2i):
	var enemy := _opponent_of(current_mech)
	match pending_mode:
		PendingMode.MOVE:
			if move_targets.has(coord):
				var target_value : int = move_targets[coord]
				if target_value == -1:
					current_mech.move_to(coord, current_move_action)
					move_points_remaining -= 1
				elif target_value == -2:
					var beyond := HexDirections.step(coord, current_mech.facing)
					enemy.move_to(beyond)
					enemy.take_damage(1)
					current_mech.move_to(coord, current_move_action)
					status_label.text = "You rammed the enemy back for 1 damage and took its place!"
					move_points_remaining -= RAM_COST
					# Ramming is the only Move outcome that can deal damage, so
					# it's the only one that needs a game-over check — every
					# other branch here just repositions/rotates.
					if _check_game_over():
						if NetworkManager.is_networked():
							_broadcast_state()
						return
				else:
					current_mech.face(target_value)
					move_points_remaining -= 1
				move_points_remaining = maxi(0, move_points_remaining)
				if move_points_remaining <= 0:
					_finish_move()
				else:
					_refresh_move_highlight()
				if NetworkManager.is_networked():
					_broadcast_state()
		PendingMode.ATTACK:
			if coord == enemy.hex_coord and selected_attack_action:
				var action := selected_attack_action
				var reaction_fired := false
				var attack_level := current_mech.get_effective_level("attack", action_levels["attack"])
				if action.is_aoe:
					reaction_fired = _resolve_aoe_attack(current_mech, action, attack_level)
				else:
					var result := current_mech.attack(enemy, action, attack_level, _react_level_for(enemy))
					var moved := _apply_push_pull(current_mech.hex_coord, enemy, action.push_pull)
					var reaction_suffix := " (%s's Reaction blocked %d damage!)" % [result.reaction_part_name, result.reaction_reduction] if result.reaction_used else ""
					status_label.text = "You hit for %s = %d damage!%s%s" % [str(result.hits), result.damage, _push_pull_suffix(action.push_pull, moved), reaction_suffix]
					_show_dice(result.hits, result.colors)
					reaction_fired = result.reaction_used
				_rotate_action_levels("attack")
				if reaction_fired:
					_rotate_action_levels("react")
				_clear_pending()
				if not _check_game_over():
					if NetworkManager.is_networked():
						_broadcast_state()
					await get_tree().create_timer(3.0).timeout
					next_turn()
				elif NetworkManager.is_networked():
					_broadcast_state()
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
	var drone : Drone = DRONE_SCENE.instantiate()
	drone.setup(player_mech.get_drone_type())
	drone.hex_size = HEX_SIZE
	drone.hex_coord = coord
	world_viewport.add_child(drone)
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


## Host-only: sends the current authoritative state to the joining peer so
## their local rendering catches up. Called after every mutation and turn
## transition in a 2-player match. Scope note: player_drones aren't included
## here — player 1 can still fully use Special on their own turn, but any
## drone they deploy won't render on player 2's screen (the underlying
## damage/turn logic on the host stays correct either way). Dice-face icons
## also aren't synced — the status text summary is, so the result is still
## visible, just not the rolled faces themselves.
func _broadcast_state():
	if not NetworkManager.is_networked() or not NetworkManager.am_i_host():
		return
	var data := {
		"player_hex": player_mech.hex_coord, "player_facing": player_mech.facing, "player_hp": player_mech.current_hp, "player_max_hp": player_mech.max_hp,
		"ai_hex": ai_mech.hex_coord, "ai_facing": ai_mech.facing, "ai_hp": ai_mech.current_hp, "ai_max_hp": ai_mech.max_hp,
		"current_is_player": current_mech == player_mech,
		"actions_used": actions_used,
		"action_levels": action_levels.duplicate(),
		"status_text": status_label.text,
		"game_over": game_over,
		"player_score": player_score,
		"ai_score": ai_score,
		"player_overdrive": player_mech.overdrive_actions.duplicate(),
		"ai_overdrive": ai_mech.overdrive_actions.duplicate(),
	}
	_rpc_apply_snapshot.rpc(data)


## Applied only on the client (call_remote — the host already has this state
## for real) — updates local mechs/turn/UI to match, never re-running the
## authoritative logic that produced it.
@rpc("authority", "call_remote", "reliable")
func _rpc_apply_snapshot(data: Dictionary):
	player_mech.sync_visual_state(data["player_hex"], data["player_facing"], data["player_hp"], data.get("player_max_hp", -1))
	ai_mech.sync_visual_state(data["ai_hex"], data["ai_facing"], data["ai_hp"], data.get("ai_max_hp", -1))
	current_mech = player_mech if data["current_is_player"] else ai_mech
	actions_used = data["actions_used"]
	action_levels = data["action_levels"]
	game_over = data["game_over"]
	player_score = data.get("player_score", player_score)
	ai_score = data.get("ai_score", ai_score)
	# Typed arrays lose their element type over RPC serialization (arrive as
	# plain Array) — assign() converts back instead of a direct assignment,
	# which would otherwise be a type mismatch against overdrive_actions'
	# Array[String] declaration.
	player_mech.overdrive_actions.assign(data.get("player_overdrive", player_mech.overdrive_actions))
	ai_mech.overdrive_actions.assign(data.get("ai_overdrive", ai_mech.overdrive_actions))
	status_label.text = data["status_text"]
	_update_action_level_labels()
	_update_score_label()
	if game_over:
		attack_button.disabled = true
		move_button_1.disabled = true
		move_button_2.disabled = true
		special_button.disabled = true
		reset_button.disabled = true
		end_turn_button.disabled = true
		skip_move_button.disabled = true
		skip_move_button_2.disabled = true
	else:
		_apply_turn_ui()


func _clear_pending():
	pending_mode = PendingMode.NONE
	reachable = {}
	move_targets = {}
	move_points_remaining = 0
	current_move_action = null
	drone_sub_action = ""
	selected_drone = null
	selected_attack_action = null
	move_points_label.visible = false
	renderer.update_reachable_highlight(hex_container, grid, {}, highlighted_hexes)


## Moves ai_mech up to movement_points hexes along the path toward target_coord,
## stopping short of the player mech or any of its drones' hexes. Returns true
## if it moved.
func _ai_move_leg(target_coord: Vector2i, movement_points: float, move_action: Actions = null) -> bool:
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
		ai_mech.move_to(step, move_action)
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


## Current HP of an _enemy_targets_of()-style target — mech and Drone name
## this differently (current_hp vs hp).
func _target_hp(target) -> int:
	if target is mech:
		return target.current_hp
	return target.hp


## Picks which of ai_mech's valid targets (the player's mech, or one of its
## drones) to go after this turn, per behavior.target_priority. Null if
## somehow nothing valid is left.
func _ai_pick_target(behavior: AIBehavior):
	var candidates : Array = []
	for t in _enemy_targets_of(ai_mech):
		if is_instance_valid(t):
			candidates.append(t)
	if candidates.is_empty():
		return null

	match behavior.target_priority:
		AIBehavior.TargetPriority.DRONES_FIRST:
			for c in candidates:
				if c != player_mech:
					return c
			return player_mech
		AIBehavior.TargetPriority.WEAKEST:
			var best = candidates[0]
			for c in candidates:
				if _target_hp(c) < _target_hp(best):
					best = c
			return best
		AIBehavior.TargetPriority.NEAREST:
			var best = candidates[0]
			var best_dist := HexGrid.distance(ai_mech.hex_coord, best.hex_coord)
			for c in candidates:
				var d := HexGrid.distance(ai_mech.hex_coord, c.hex_coord)
				if d < best_dist:
					best_dist = d
					best = c
			return best
		_: # MECH_FIRST
			return player_mech


## Whichever of ai_mech's currently-qualifying attack options (see
## mech.get_available_attack_actions()) best matches behavior's style —
## prefers a ranged (range > 1) option if prefers_ranged, else a melee one —
## falling back to whatever's available if nothing matches that preference.
func _ai_choose_attack_action(dist: int, behavior: AIBehavior) -> Actions:
	var options := ai_mech.get_available_attack_actions(dist)
	if options.is_empty():
		return null
	for opt in options:
		if behavior.prefers_ranged == (opt.range > 1):
			return opt
	return options[0]


## Steps ai_mech directly away from threat_coord, up to movement_points
## hexes, stopping at the first blocked/occupied hex. Returns true if it moved.
func _ai_retreat_leg(threat_coord: Vector2i, movement_points: float, move_action: Actions) -> bool:
	var dir := HexDirections.direction_index(threat_coord, ai_mech.hex_coord)
	if dir == -1:
		return false
	var moved := false
	for i in int(movement_points):
		var next := HexDirections.step(ai_mech.hex_coord, dir)
		if not grid.is_valid(next) or not grid.is_passable(next):
			break
		if next == player_mech.hex_coord or _drone_at(next) != null:
			break
		ai_mech.move_to(next, move_action)
		moved = true
	return moved


## Weak/random fallback turn for an acts_randomly behavior (Dumb): a coin
## flip on whether to even use an attack already in range, else wander to a
## random reachable hex instead of reliably closing in on the player.
func _ai_take_random_turn() -> bool:
	var move_action := ai_mech.get_move_action()
	var dist := HexGrid.distance(ai_mech.hex_coord, player_mech.hex_coord)
	var attack_action := ai_mech.get_attack_action_for_range(dist)

	if attack_action and _has_line_of_sight(ai_mech.hex_coord, player_mech.hex_coord) and randf() < 0.5:
		_ai_face(player_mech.hex_coord)
		var result := ai_mech.attack(player_mech, attack_action, ai_mech.get_effective_level("attack", 1), _react_level_for(player_mech))
		var moved := _apply_push_pull(ai_mech.hex_coord, player_mech, attack_action.push_pull)
		var reaction_suffix := " (%s's Reaction blocked %d damage!)" % [result.reaction_part_name, result.reaction_reduction] if result.reaction_used else ""
		status_label.text = "Enemy hit for %s = %d damage!%s%s" % [str(result.hits), result.damage, _push_pull_suffix(attack_action.push_pull, moved), reaction_suffix]
		_show_dice(result.hits, result.colors)
		if result.reaction_used:
			_rotate_action_levels("react")
		return true

	if move_action:
		var reachable := PathFinder.find_reachable(ai_mech.hex_coord, float(move_action.movement), grid)
		reachable.erase(ai_mech.hex_coord)
		var options : Array = []
		for coord in reachable.keys():
			if coord != player_mech.hex_coord and _drone_at(coord) == null:
				options.append(coord)
		if not options.is_empty():
			ai_mech.move_to(options[randi() % options.size()], move_action)
			status_label.text = "Enemy wandered aimlessly."
			return false

	status_label.text = "Enemy did nothing useful."
	return false


## Runs ai_mech's assigned personality (see mech.ai_behavior/AIBehavior.gd):
## picks a target per target_priority, retreats instead of engaging if hurt
## past retreat_hp_fraction, closes distance unless keeps_distance already
## has something in range, then attacks with whichever option matches
## prefers_ranged — or defers entirely to _ai_take_random_turn() if
## acts_randomly is set.
func _ai_take_turn() -> bool:
	var behavior := ai_mech.ai_behavior
	if behavior.acts_randomly:
		return _ai_take_random_turn()

	var target = _ai_pick_target(behavior)
	if target == null:
		status_label.text = "Enemy passed."
		return false

	var move_action := ai_mech.get_move_action()
	var dist := HexGrid.distance(ai_mech.hex_coord, target.hex_coord)
	var max_hp = maxi(1, ai_mech.max_hp)
	var hp_fraction := float(ai_mech.current_hp) / float(max_hp)

	if behavior.retreat_hp_fraction > 0.0 and hp_fraction < behavior.retreat_hp_fraction and move_action:
		var retreated := _ai_retreat_leg(target.hex_coord, float(move_action.movement), move_action)
		status_label.text = "Enemy retreated." if retreated else "Enemy held position, cornered."
		return false

	var attack_action := _ai_choose_attack_action(dist, behavior)
	if attack_action and behavior.keeps_distance and dist < attack_action.range and move_action:
		# Already has a usable shot but isn't at its max effective range yet —
		# back away instead of holding position, so the player can't just
		# walk up next turn. Only relevant once it's found something to
		# shoot with; see the "no attack at all" branch below for closing in.
		_ai_retreat_leg(target.hex_coord, float(move_action.movement), move_action)
		dist = HexGrid.distance(ai_mech.hex_coord, target.hex_coord)
		attack_action = _ai_choose_attack_action(dist, behavior)
	elif move_action and attack_action == null:
		_ai_move_leg(target.hex_coord, float(move_action.movement), move_action)
		dist = HexGrid.distance(ai_mech.hex_coord, target.hex_coord)
		attack_action = _ai_choose_attack_action(dist, behavior)

	if attack_action and _has_line_of_sight(ai_mech.hex_coord, target.hex_coord):
		_ai_face(target.hex_coord)
		var ai_attack_level := ai_mech.get_effective_level("attack", 1)
		if attack_action.is_aoe:
			# Hits every valid target next to ai_mech at once, regardless of
			# which one was "the" chosen target — see _enemy_targets_of().
			if _resolve_aoe_attack(ai_mech, attack_action, ai_attack_level):
				_rotate_action_levels("react")
		else:
			var result := ai_mech.attack(target, attack_action, ai_attack_level, _react_level_for(target))
			var moved := _apply_push_pull(ai_mech.hex_coord, target, attack_action.push_pull)
			var who := "you" if target == player_mech else "one of your drones"
			var reaction_suffix := " (%s's Reaction blocked %d damage!)" % [result.reaction_part_name, result.reaction_reduction] if result.reaction_used else ""
			status_label.text = "Enemy hit %s for %s = %d damage!%s%s" % [who, str(result.hits), result.damage, _push_pull_suffix(attack_action.push_pull, moved), reaction_suffix]
			_show_dice(result.hits, result.colors)
			if result.reaction_used:
				_rotate_action_levels("react")
		return true

	if move_action:
		var moved := _ai_move_leg(target.hex_coord, float(move_action.movement), move_action)
		if moved:
			_ai_face(target.hex_coord)
		status_label.text = "Enemy moved." if moved else "Enemy held position."
	else:
		status_label.text = "Enemy passed."

	return false
