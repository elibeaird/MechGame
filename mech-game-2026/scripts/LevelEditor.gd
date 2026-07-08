extends Node2D
## Standalone dev tool for building LevelMap resources by clicking hexes,
## instead of hand-editing tile_overrides in a .tres file. Not part of the
## normal game flow — open this scene directly in the editor and press
## "Run Current Scene" to use it.
##
## Only understands TerrainType-based overrides (see scripts/TerrainType.gd).
## Loading a level that also has legacy raw-int overrides (like
## RingTestMap.tres's MOUNTAIN/ALT_GRAY/ALT_BLUE tiles) will warn that those
## entries can't be edited here and will be dropped if you save over it.

const TERRAIN_FOLDER := "res://resources/Terrain/"
const LEVELS_FOLDER := "res://resources/Levels/"
const HEX_SIZE := 48.0
const CUSTOM_TERRAIN_ID_BASE := 200

enum BrushMode { PAINT, PLAYER_SPAWN, AI_SPAWN, FOREST_TOGGLE }

@onready var hex_container: Node2D = $HexContainer
@onready var camera: Camera2D = $Camera2D
@onready var width_input: LineEdit = $UI/MarginContainer/PanelContainer/VBoxContainer/GridSizeRow/WidthInput
@onready var height_input: LineEdit = $UI/MarginContainer/PanelContainer/VBoxContainer/GridSizeRow/HeightInput
@onready var new_grid_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/GridSizeRow/NewGridButton
@onready var load_option: OptionButton = $UI/MarginContainer/PanelContainer/VBoxContainer/LoadSaveRow/LoadOption
@onready var load_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/LoadSaveRow/LoadButton
@onready var filename_input: LineEdit = $UI/MarginContainer/PanelContainer/VBoxContainer/LoadSaveRow/FilenameInput
@onready var save_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/LoadSaveRow/SaveButton
@onready var set_player_spawn_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/SpawnRow/SetPlayerSpawnButton
@onready var set_ai_spawn_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/SpawnRow/SetAiSpawnButton
@onready var toggle_forest_button: Button = $UI/MarginContainer/PanelContainer/VBoxContainer/SpawnRow/ToggleForestButton
@onready var terrain_palette: VBoxContainer = $UI/MarginContainer/PanelContainer/VBoxContainer/PaletteScroll/TerrainPalette
@onready var status_label: Label = $UI/MarginContainer/PanelContainer/VBoxContainer/StatusLabel

var grid : HexGrid
var renderer : HexRenderer
var camera_ctrl : MapCamera

var grid_width := 10
var grid_height := 11
var player_spawn := Vector2i(1, 5)
var ai_spawn := Vector2i(8, 5)
var ai_facing := 3

## coord -> TerrainType. Absent = base terrain.
var tile_overrides : Dictionary = {}
## coord -> true. Independent of tile_overrides.
var forest_tiles : Dictionary = {}

## null selected_terrain + PAINT brush = "erase to base terrain".
var selected_terrain : TerrainType = null
var brush_mode : BrushMode = BrushMode.PAINT

var _terrain_type_ids : Dictionary = {}
var _terrain_type_by_id : Dictionary = {}


func _ready():
	width_input.text = str(grid_width)
	height_input.text = str(grid_height)

	new_grid_button.pressed.connect(_on_new_grid_pressed)
	load_button.pressed.connect(_on_load_pressed)
	save_button.pressed.connect(_on_save_pressed)
	set_player_spawn_button.pressed.connect(_on_set_player_spawn_pressed)
	set_ai_spawn_button.pressed.connect(_on_set_ai_spawn_pressed)
	toggle_forest_button.pressed.connect(_on_toggle_forest_pressed)

	_populate_terrain_palette()
	_populate_load_list()
	_rebuild_grid()


## No _process()/camera_ctrl.process() call here on purpose — that's what
## drives both MapCamera's follow-lerp and its edge-scroll-when-near-screen-
## edge behavior, neither of which fits an editor with no "focus target" and
## no reason to pan just because the mouse neared a border. Drag-to-pan and
## scroll-to-zoom still work fully — both are handled directly in
## handle_input() below, independent of process().
func _unhandled_input(event):
	if camera_ctrl:
		camera_ctrl.handle_input(event)


## Scans TERRAIN_FOLDER for TerrainType resources so new ones show up
## automatically, same pattern as LoadoutScreen._scan_available_parts().
func _populate_terrain_palette():
	for child in terrain_palette.get_children():
		child.queue_free()

	var clear_btn := Button.new()
	clear_btn.text = "Base terrain (eraser)"
	clear_btn.pressed.connect(_on_terrain_selected.bind(null))
	terrain_palette.add_child(clear_btn)

	var dir := DirAccess.open(TERRAIN_FOLDER)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var res := load(TERRAIN_FOLDER + file_name)
			if res is TerrainType:
				var btn := Button.new()
				btn.text = res.display_name if res.display_name != "" else file_name.get_basename()
				btn.pressed.connect(_on_terrain_selected.bind(res))
				terrain_palette.add_child(btn)
		file_name = dir.get_next()
	dir.list_dir_end()


func _populate_load_list():
	load_option.clear()
	load_option.add_item("(new)")
	var dir := DirAccess.open(LEVELS_FOLDER)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			load_option.add_item(file_name.get_basename())
		file_name = dir.get_next()
	dir.list_dir_end()


func _on_terrain_selected(terrain_type):
	selected_terrain = terrain_type
	brush_mode = BrushMode.PAINT
	var label : String = terrain_type.display_name if terrain_type else "base terrain"
	status_label.text = "Click hexes to paint: %s" % label


func _on_set_player_spawn_pressed():
	brush_mode = BrushMode.PLAYER_SPAWN
	status_label.text = "Click a hex to set the player spawn"


func _on_set_ai_spawn_pressed():
	brush_mode = BrushMode.AI_SPAWN
	status_label.text = "Click a hex to set the AI spawn"


func _on_toggle_forest_pressed():
	brush_mode = BrushMode.FOREST_TOGGLE
	status_label.text = "Click hexes to toggle their forest overlay"


func _on_new_grid_pressed():
	grid_width = maxi(1, int(width_input.text))
	grid_height = maxi(1, int(height_input.text))
	tile_overrides.clear()
	forest_tiles.clear()
	player_spawn = Vector2i.ZERO
	ai_spawn = Vector2i(grid_width - 1, grid_height - 1)
	filename_input.text = ""
	status_label.text = "New %dx%d grid" % [grid_width, grid_height]
	_rebuild_grid()


## Loads name's tile_overrides into the editor's in-memory model. Entries
## whose "terrain" isn't a TerrainType resource (legacy raw-int overrides,
## e.g. RingTestMap.tres) can't be represented here and are dropped — warns
## instead of silently discarding them.
func _on_load_pressed():
	var idx := load_option.selected
	if idx <= 0:
		return
	var level_name := load_option.get_item_text(idx)
	var level : LevelMap = load(LEVELS_FOLDER + level_name + ".tres")
	if level == null:
		status_label.text = "Couldn't load %s" % level_name
		return

	grid_width = level.grid_width
	grid_height = level.grid_height
	player_spawn = level.player_spawn
	ai_spawn = level.ai_spawn
	ai_facing = level.ai_facing

	tile_overrides.clear()
	var skipped := 0
	for entry in level.tile_overrides:
		var raw = entry.get("terrain")
		if raw is TerrainType:
			tile_overrides[entry.get("coord")] = raw
		else:
			skipped += 1

	forest_tiles.clear()
	for coord in level.forest_tiles:
		forest_tiles[coord] = true

	width_input.text = str(grid_width)
	height_input.text = str(grid_height)
	filename_input.text = level_name
	if skipped > 0:
		status_label.text = "Loaded %s (%d legacy tile(s) not shown — saving will drop them)" % [level_name, skipped]
	else:
		status_label.text = "Loaded %s" % level_name
	_rebuild_grid()


func _on_save_pressed():
	var level := LevelMap.new()
	level.grid_width = grid_width
	level.grid_height = grid_height
	level.player_spawn = player_spawn
	level.ai_spawn = ai_spawn
	level.ai_facing = ai_facing

	var overrides : Array[Dictionary] = []
	for coord in tile_overrides:
		overrides.append({"coord": coord, "terrain": tile_overrides[coord]})
	level.tile_overrides = overrides

	var forest_list : Array[Vector2i] = []
	for coord in forest_tiles:
		forest_list.append(coord)
	level.forest_tiles = forest_list

	var level_name := filename_input.text.strip_edges()
	if level_name == "":
		status_label.text = "Enter a filename before saving"
		return

	var path := LEVELS_FOLDER + level_name + ".tres"
	var err := ResourceSaver.save(level, path)
	if err == OK:
		status_label.text = "Saved to %s" % path
		_populate_load_list()
	else:
		status_label.text = "Save failed (error %d)" % err


## Assigns terrain_type an internal HexCell.terrain id (if it doesn't have
## one yet this rebuild) and wires its difficulty/passable/color into
## cost_table/palette — mirrors Game_Manager._register_terrain_type().
func _register_terrain_type(terrain_type: TerrainType, cost_table: Dictionary, palette: HexPalette) -> int:
	if _terrain_type_ids.has(terrain_type):
		return _terrain_type_ids[terrain_type]
	var id := CUSTOM_TERRAIN_ID_BASE + _terrain_type_ids.size()
	_terrain_type_ids[terrain_type] = id
	_terrain_type_by_id[id] = terrain_type
	cost_table[id] = terrain_type.difficulty if terrain_type.passable else -1.0
	palette.terrain_colors[id] = terrain_type.color
	return id


func _rebuild_grid():
	for child in hex_container.get_children():
		child.queue_free()

	_terrain_type_ids.clear()
	_terrain_type_by_id.clear()

	var cost_table := HexGrid.TERRAIN_COST.duplicate()
	cost_table[HexCell.Terrain.PLAINS] = 1.0

	var palette := HexPalette.new()
	for terrain_type in tile_overrides.values():
		_register_terrain_type(terrain_type, cost_table, palette)

	grid = HexGrid.new(grid_width, grid_height, cost_table, HEX_SIZE)
	grid.generate_cells(HexCell.Terrain.PLAINS)

	for coord in tile_overrides:
		var cell := grid.get_cell(coord)
		if cell:
			cell.terrain = _terrain_type_ids[tile_overrides[coord]]
	for coord in forest_tiles:
		var cell := grid.get_cell(coord)
		if cell:
			cell.tag = 1

	renderer = HexRenderer.new(palette, HEX_SIZE, {
		"cell_icon_fn": _spawn_icon_fn,
		"overlay_fn": _forest_overlay_fn,
		"texture_fn": _terrain_texture_fn,
	})
	for coord in grid.cells:
		renderer.create_hex_visual(hex_container, coord, HexGrid.offset_to_pixel(coord, HEX_SIZE), grid.cells[coord])
		var fog := HexRenderer.get_visual_part(hex_container, coord, "Fog")
		if fog:
			fog.visible = false
	renderer.cell_pressed.connect(_on_cell_pressed)

	if camera_ctrl == null:
		camera_ctrl = MapCamera.new(camera, get_viewport())
		camera_ctrl.follow_target = false
	camera.position = HexGrid.offset_to_pixel(Vector2i(grid_width / 2, grid_height / 2), HEX_SIZE)


func _forest_overlay_fn(cell: HexCell) -> Array[Node2D]:
	if cell.tag != 1:
		return []
	return [ForestIcon.new()]


func _terrain_texture_fn(cell: HexCell) -> Texture2D:
	var terrain_type : TerrainType = _terrain_type_by_id.get(cell.terrain, null)
	return terrain_type.texture if terrain_type else null


## "P"/"A" markers so the spawns are visible while editing.
func _spawn_icon_fn(cell: HexCell) -> String:
	if cell.coord == player_spawn:
		return "P"
	if cell.coord == ai_spawn:
		return "A"
	return ""


func _on_cell_pressed(coord: Vector2i, event: InputEvent):
	if event is InputEventMouseButton and event.button_index != MOUSE_BUTTON_LEFT:
		return
	match brush_mode:
		BrushMode.PAINT:
			if selected_terrain == null:
				tile_overrides.erase(coord)
			else:
				tile_overrides[coord] = selected_terrain
			_rebuild_grid()
		BrushMode.PLAYER_SPAWN:
			player_spawn = coord
			status_label.text = "Player spawn set to %s" % str(coord)
			_rebuild_grid()
		BrushMode.AI_SPAWN:
			ai_spawn = coord
			status_label.text = "AI spawn set to %s" % str(coord)
			_rebuild_grid()
		BrushMode.FOREST_TOGGLE:
			if forest_tiles.has(coord):
				forest_tiles.erase(coord)
			else:
				forest_tiles[coord] = true
			_rebuild_grid()
