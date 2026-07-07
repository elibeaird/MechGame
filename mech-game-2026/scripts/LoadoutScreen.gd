class_name LoadoutScreen
extends CanvasLayer
## Full-page pre-match screen: build a loadout (up to mech.MAX_PARTS) and see
## a live stats summary, then hand off to Game_Manager via start_match.

signal start_match

## Folder scanned for equippable Part resources.
const PARTS_FOLDER := "res://resources/parts/"

## Source icon shown per part in the loadout list, keyed to its level
## requirement. "x" = usable at any charged level (required_level > 0,
## minimum, not exact — the flexible case); "0"/"1"/"2"/"3" = no requirement
## or an exact tier. These are full-size (834x563) — see _get_level_icon().
const LEVEL_ICONS := {
	"0": preload("res://images/Action_lvl_icon/lvl_0.png"),
	"1": preload("res://images/Action_lvl_icon/lvl_1.png"),
	"2": preload("res://images/Action_lvl_icon/lvl_2.png"),
	"3": preload("res://images/Action_lvl_icon/lvl_3.png"),
	"x": preload("res://images/Action_lvl_icon/lvl_x.png"),
}
## Button doesn't support capping icon size in this Godot version, so icons
## are pre-resized to this size (same aspect ratio as the source) and cached.
const LEVEL_ICON_SIZE := Vector2i(30, 20)
var _resized_level_icons : Dictionary = {}

## Badge icon per action type a part can grant, shown next to it in the list.
## "melee" and "ranged" are mutually exclusive (whichever matches the part's
## attack range), not layered on top of a generic attack icon.
const ACTION_TYPE_ICONS := {
	"movement": preload("res://images/Action type/action_move.png"),
	"melee": preload("res://images/Action type/Action_melee.png"),
	"ranged": preload("res://images/Action type/action_ranged.png"),
	"special": preload("res://images/Action type/action_special.png"),
	"block": preload("res://images/Action type/action_block.png"),
}
## Source images share a height (209) but differ in width, so icons are
## resized to this height keeping each one's own aspect ratio (see
## _get_resized_action_type_icon()) rather than a single fixed box.
const ACTION_TYPE_ICON_HEIGHT := 14
var _resized_action_type_icons : Dictionary = {}

## Set by Game_Manager before show_loadout() is called.
@export var player_mech : mech

@onready var stats_label: Label = $CenterContainer/PanelContainer/VBoxContainer/ContentRow/StatsColumn/StatsLabel
@onready var parts_list: VBoxContainer = $CenterContainer/PanelContainer/VBoxContainer/ContentRow/PartsColumn/PartsScroll/PartsList
@onready var start_match_button: Button = $CenterContainer/PanelContainer/VBoxContainer/ContentRow/RightColumn/LoadoutStartMatchButton


func _ready():
	start_match_button.pressed.connect(_on_start_match_pressed)


## Shows the screen and populates it. Called once by Game_Manager at boot.
func show_loadout():
	visible = true
	refresh()


func _on_start_match_pressed():
	visible = false
	start_match.emit()


## The part's resource file name (e.g. "WM-Aqua_Claw" for WM-Aqua_Claw.tres),
## so display_name never has to be hand-authored/kept in sync with the file.
## Falls back to display_name for parts with no resource_path (the innate
## Basic Movement/Attack, built in code rather than loaded from a file).
func _display_name_for(part: Actions) -> String:
	if part.resource_path.is_empty():
		return part.display_name
	return part.resource_path.get_file().get_basename()


## Scans PARTS_FOLDER for .tres resources whose script is Part (or a
## subclass), so new parts show up automatically without touching the scene.
func _scan_available_parts() -> Array[Part]:
	var found : Array[Part] = []
	var dir := DirAccess.open(PARTS_FOLDER)
	if dir == null:
		return found

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var res := load(PARTS_FOLDER + file_name)
			if res is Part:
				found.append(res)
		file_name = dir.get_next()
	dir.list_dir_end()
	return found


## Rebuilds the stats summary and part list from scratch — called on entry
## and after every equip, so it always reflects the current loadout.
func refresh():
	stats_label.text = _build_stats_summary()

	for child in parts_list.get_children():
		child.queue_free()

	var available_parts := _scan_available_parts()
	var loadout_full := player_mech.parts.size() >= mech.MAX_PARTS

	if available_parts.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No parts found in %s" % PARTS_FOLDER
		parts_list.add_child(empty_label)
	else:
		for part in available_parts:
			var btn := Button.new()
			btn.text = _display_name_for(part)
			btn.icon = _level_icon_for(part)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var already_equipped := player_mech.parts.has(part)
			if already_equipped:
				btn.text += " [equipped]"
				btn.disabled = true
			elif loadout_full:
				btn.disabled = true
			btn.pressed.connect(_on_part_selected.bind(part))

			var row := HBoxContainer.new()
			row.add_child(btn)
			row.add_child(_action_type_badge_row(part))
			if part.dice_count() > 0:
				row.add_child(DiceIcons.icon_row(part))
			parts_list.add_child(row)


## Icon reflecting the part's level requirement: lvl_0 if none, lvl_x if it's
## a minimum (usable at any charged level), or lvl_1/2/3 for an exact tier.
func _level_icon_for(part: Part) -> Texture2D:
	var key := "0"
	if part.required_level > 0:
		key = str(part.required_level) if part.exact_level_required else "x"
		if not LEVEL_ICONS.has(key):
			key = "x"
	return _get_resized_level_icon(key)


## Resizes a LEVEL_ICONS source texture down to LEVEL_ICON_SIZE once and
## caches the result — Button has no icon-size-cap property in this Godot
## version, so the source (834x563) would otherwise render full-size.
func _get_resized_level_icon(key: String) -> Texture2D:
	if not _resized_level_icons.has(key):
		var source_texture : Texture2D = LEVEL_ICONS[key]
		var img : Image = source_texture.get_image().duplicate()
		img.resize(LEVEL_ICON_SIZE.x, LEVEL_ICON_SIZE.y, Image.INTERPOLATE_LANCZOS)
		_resized_level_icons[key] = ImageTexture.create_from_image(img)
	return _resized_level_icons[key]


## Resizes an ACTION_TYPE_ICONS source texture down to ACTION_TYPE_ICON_HEIGHT
## once and caches the result, keeping that source's own aspect ratio (widths
## differ per icon) rather than forcing one fixed box.
func _get_resized_action_type_icon(key: String) -> Texture2D:
	if not _resized_action_type_icons.has(key):
		var source_texture : Texture2D = ACTION_TYPE_ICONS[key]
		var img : Image = source_texture.get_image().duplicate()
		var target_width := roundi(float(img.get_width()) * ACTION_TYPE_ICON_HEIGHT / img.get_height())
		img.resize(target_width, ACTION_TYPE_ICON_HEIGHT, Image.INTERPOLATE_LANCZOS)
		_resized_action_type_icons[key] = ImageTexture.create_from_image(img)
	return _resized_action_type_icons[key]


## Row of badges for which action types a part grants: movement, melee or
## ranged attack (mutually exclusive, by the part's range), special (drone
## deployment), block (push/pull).
func _action_type_badge_row(part: Part) -> HBoxContainer:
	var row := HBoxContainer.new()
	var keys : Array[String] = []
	if part.movement > 0:
		keys.append("movement")
	if part.dice_count() > 0:
		keys.append("ranged" if part.range > 1 else "melee")
	if part.drone_type != null:
		keys.append("special")
	if part.push_pull != 0:
		keys.append("block")

	for key in keys:
		var icon := _get_resized_action_type_icon(key)
		var rect := TextureRect.new()
		rect.texture = icon
		rect.custom_minimum_size = icon.get_size()
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(rect)
	return row


## "" if the part has no level requirement, else e.g. "needs Lv 2+" (minimum)
## or "needs exactly Lv 2" (exact_level_required).
func _level_requirement_text(part: Part) -> String:
	if part.required_level <= 0:
		return ""
	if part.exact_level_required:
		return "needs exactly Lv %d" % part.required_level
	return "needs Lv %d+" % part.required_level


## Comma-separated "N red", "N blue"... for whichever dice colors are set —
## shared by Part attack lines and the drone summary since both are Actions.
func _dice_bits_for(action: Actions) -> Array[String]:
	var bits : Array[String] = []
	if action.red_dice > 0:
		bits.append("%d red" % action.red_dice)
	if action.blue_dice > 0:
		bits.append("%d blue" % action.blue_dice)
	if action.yellow_dice > 0:
		bits.append("%d yellow" % action.yellow_dice)
	if action.purple_dice > 0:
		bits.append("%d purple" % action.purple_dice)
	return bits


## Plain-language summary of what the mech can currently do: total HP, every
## equipped movement option, every equipped attack (range + dice mix), and
## the drone (if any equipped part grants one).
func _build_stats_summary() -> String:
	var lines : Array[String] = []
	lines.append("Parts equipped: %d/%d" % [player_mech.parts.size(), mech.MAX_PARTS])
	lines.append("HP: %d" % player_mech.max_hp)

	var move_lines : Array[String] = ["  Basic Movement (built-in) — move 2"]
	var attack_lines : Array[String] = ["  Basic Attack (built-in) — range 1, 1 red"]
	for part in player_mech.parts:
		var req_text := _level_requirement_text(part)
		var level_text := " (%s)" % req_text if req_text != "" else ""
		if part.movement > 0:
			move_lines.append("  %s — move %d%s" % [_display_name_for(part), part.movement, level_text])
		if part.dice_count() > 0:
			var scale_note := " (x current level)" if part.dice_scale_with_level else ""
			var range_text := "range %d-%d" % [part.min_range, part.range] if part.min_range > 0 else "range %d" % part.range
			var aoe_note := " (hits all in range)" if part.is_aoe else ""
			attack_lines.append("  %s — %s, %s%s%s%s" % [_display_name_for(part), range_text, ", ".join(_dice_bits_for(part)), scale_note, level_text, aoe_note])

	lines.append("")
	lines.append("Movement:")
	lines.append_array(move_lines)

	lines.append("")
	lines.append("Attacks:")
	lines.append_array(attack_lines)

	var drone_type := player_mech.get_drone_type()
	lines.append("")
	lines.append("Drone:")
	if drone_type == null:
		lines.append("  none equipped")
	else:
		var dice_text := ", ".join(_dice_bits_for(drone_type)) if drone_type.dice_count() > 0 else "no attack"
		var range_text := "range %d-%d" % [drone_type.min_range, drone_type.range] if drone_type.min_range > 0 else "range %d" % drone_type.range
		var max_drones := player_mech.get_max_drones()
		var deploy_text := "1 deployment" if max_drones == 1 else "%d deployments" % max_drones
		lines.append("  %s — %d hp, move %d, %s, %s, %s per match" % [
			_display_name_for(drone_type), drone_type.bonus_hp, drone_type.movement, range_text, dice_text, deploy_text,
		])

	return "\n".join(lines)


func _on_part_selected(part: Part):
	if not player_mech.add_part(part):
		return
	refresh()
