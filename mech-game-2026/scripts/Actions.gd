class_name Actions
extends Resource

@export var display_name : String
@export var Description : String

@export var movement : int
@export var flight : bool
## Farthest distance this attack can reach.
@export var range : int = 0
## Closest distance this attack can reach — 0 (default) means it can hit
## anything up to range, including adjacent. Set above 0 for a weapon that
## can't hit nearby targets (e.g. artillery with min_range 2 can't hit
## anything closer than 2 hexes away, even though it reaches out to range).
@export var min_range : int = 0

## If true, this attack hits every valid enemy target within
## [min_range, range] and your front arc at once (e.g. a melee sweep hitting
## the enemy mech and any of its drones standing next to you), instead of
## picking one target to click on.
@export var is_aoe : bool = false

@export var red_dice : int
@export var blue_dice : int
@export var yellow_dice : int
@export var purple_dice : int

## Hexes to shove the target on a successful hit. Positive = push (away
## from the attacker), negative = pull (toward the attacker), 0 = no effect.
@export var push_pull : int = 0

## Extra max HP granted while this part is equipped (0 for non-HP parts).
@export var bonus_hp : int = 0

## Action-ladder level (0-3) needed to use this part. By default this is a
## minimum (current level >= required_level) — e.g. required_level = 1 means
## "usable at any charged level, just not 0". Set exact_level_required to
## require the track sit at EXACTLY this level instead.
@export var required_level : int = 0
## If true, this part only works when the track is at exactly required_level
## (not higher, not lower). If false (default), required_level is a minimum.
@export var exact_level_required : bool = false

@export var AI_prioraty :int = 100

## If true, every dice color's count is multiplied by the current action-ladder
## level when rolled (e.g. blue_dice = 1 rolls 3 blue dice at level 3, 1 at
## level 1). Pair with required_level >= 1 — at level 0 this rolls no dice at all.
@export var dice_scale_with_level : bool = false

## Custom sprite art for this part/drone type, authored as a whole scene
## instead of filling in a texture array one frame at a time: make a small
## scene (root = AnimatedSprite2D, or an AnimatedSprite2D anywhere inside
## it) and use Godot's SpriteFrames editor panel to build whichever of these
## named animations apply — "attack" and "move" for a Part, plus "idle",
## "deploy", "crash", "hit", "defeated" for a DroneType (see DroneType.gd).
## Only the names actually present are used; anything missing falls back to
## the mech/drone's own default (see mech.gd's play_attack_animation()/
## play_move_animation() and Drone.gd's play_*_animation() methods). Null =
## use the defaults for everything.
@export var visual_scene : PackedScene = null

var _cached_visual_frames : SpriteFrames = null
var _cached_visual_scene : PackedScene = null

## Lazily extracts and caches visual_scene's SpriteFrames (see
## SpriteFramesUtil.extract_sprite_frames()). Null if visual_scene isn't set.
func get_visual_frames() -> SpriteFrames:
	if visual_scene == null:
		return null
	if _cached_visual_scene != visual_scene:
		_cached_visual_frames = SpriteFramesUtil.extract_sprite_frames(visual_scene)
		_cached_visual_scene = visual_scene
	return _cached_visual_frames

## True if current_level satisfies this part's level requirement, honoring
## exact_level_required (== vs >=).
func level_met(current_level: int) -> bool:
	if exact_level_required:
		return current_level == required_level
	return current_level >= required_level

## Total number of dice this action/part rolls, across all colors. Always the
## base (unscaled) count — used for "does this part have any dice at all"
## eligibility checks, not for damage.
func dice_count() -> int:
	return red_dice + blue_dice + yellow_dice + purple_dice

## Rolls all of this action/part's dice, each color through its own damage
## table, and returns the combined {"rolls", "hits", "colors", "damage"}
## result. current_level only matters if dice_scale_with_level is true, in
## which case every color's count is multiplied by it.
func roll(current_level: int = 1) -> Dictionary:
	var multiplier := current_level if dice_scale_with_level else 1
	var results : Array[Dictionary] = []
	if red_dice > 0:
		results.append(Dice.roll_color("red", red_dice * multiplier))
	if blue_dice > 0:
		results.append(Dice.roll_color("blue", blue_dice * multiplier))
	if yellow_dice > 0:
		results.append(Dice.roll_color("yellow", yellow_dice * multiplier))
	if purple_dice > 0:
		results.append(Dice.roll_color("purple", purple_dice * multiplier))
	return Dice.merge_results(results)
