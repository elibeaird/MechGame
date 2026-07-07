class_name DiceIcons
extends RefCounted
## Shared dice-color icon loader for any UI that shows attack dice visually
## (loadout part list, attack weapon popup). Loaded (not preloaded) and
## checked with ResourceLoader.exists() so a color you haven't added an icon
## for yet is just skipped instead of erroring.

const ICON_PATHS := {
	"red": "res://images/dice/dice_red.png",
	"blue": "res://images/dice/dice_blue.png",
	"yellow": "res://images/dice/dice_yellow.png",
	"purple": "res://images/dice/dice_purple.png",
}
const ICON_SIZE := Vector2i(18, 18)
static var _resized : Dictionary = {}


## Loads+resizes a die color's icon on first use, caching the result. Returns
## null if no icon file has been added for that color yet.
static func get_icon(color: String) -> Texture2D:
	if _resized.has(color):
		return _resized[color]

	var result : Texture2D = null
	var path : String = ICON_PATHS.get(color, "")
	if path != "" and ResourceLoader.exists(path):
		var source_texture : Texture2D = load(path)
		var img : Image = source_texture.get_image().duplicate()
		img.resize(ICON_SIZE.x, ICON_SIZE.y, Image.INTERPOLATE_LANCZOS)
		result = ImageTexture.create_from_image(img)

	_resized[color] = result
	return result


## Row of small icons, one per die color action rolls (red, blue, yellow,
## purple order) — colors with no icon file yet are just skipped.
static func icon_row(action: Actions) -> HBoxContainer:
	var row := HBoxContainer.new()
	var counts := {
		"red": action.red_dice,
		"blue": action.blue_dice,
		"yellow": action.yellow_dice,
		"purple": action.purple_dice,
	}
	for color in ["red", "blue", "yellow", "purple"]:
		if counts[color] <= 0:
			continue
		var icon := get_icon(color)
		if icon == null:
			continue
		var rect := TextureRect.new()
		rect.texture = icon
		rect.custom_minimum_size = ICON_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(rect)
	return row
