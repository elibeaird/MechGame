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

## Personality this mech's AI turn uses when it isn't player-controlled (see
## scripts/AIBehavior.gd). Unused/ignored for the player's own mech.
## Game_Manager falls back to a default if this is unset.
@export var ai_behavior : AIBehavior

## Reskins this mech with another chassis scene's art (e.g.
## res://Scenes/Mech_Tera.tscn, Mech_Aqua.tscn, Mech_aero.tscn) — set this
## instead of hand-editing which scene main.tscn instances. Any of that
## scene's BodyRight/BodyUpperRight/.../AttackEffect nodes it has get copied
## over; any it doesn't have, this mech keeps its own baked-in art for. Null
## (default) keeps this mech's own art as-is. Applied once in _ready().
@export var chassis_visual : PackedScene = null

var hex_size : float = HexGrid.HEX_SIZE
var max_hp : int = 0
var current_hp : int

## Where this mech started the match — captured once by Game_Manager right
## after placing it at its level_map spawn point, before anything can move
## it. respawn() returns here rather than wherever it died.
var spawn_hex_coord : Vector2i
var spawn_facing : int = 0

## Which of Game_Manager's SECOND_ACTION_KEYS ("move"/"attack"/"special"/
## "react") this mech has been granted Overdrive on — one gets added each
## time this mech respawns (see Game_Manager._handle_respawn_overdrive()).
## Persists for the rest of the match; never cleared by respawn(). See
## get_effective_level().
var overdrive_actions : Array[String] = []

## Grants Overdrive on key, if it isn't already granted. No-op otherwise.
func add_overdrive(key: String):
	if not overdrive_actions.has(key):
		overdrive_actions.append(key)

## Returns current_level boosted by 1 (capped at 3, the top of the action
## ladder) if this mech has Overdrive on key, else current_level unchanged.
## Callers pass this wherever they'd otherwise feed Game_Manager's
## action_levels[key] straight through into a roll or level-gating check —
## see Game_Manager's attack/move/special/react call sites.
func get_effective_level(key: String, current_level: int) -> int:
	if overdrive_actions.has(key):
		return mini(3, current_level + 1)
	return current_level

var target_scale :float = 1.0
var _base_scale : Vector2 = Vector2.ONE

const HEALTH_BAR_WIDTH := 40.0
@onready var _health_bar_fill: ColorRect = $HealthBarFill
@onready var _facing_arrow: FacingArrow = $FacingArrow

## 6 independent body sprites, one per hex direction — each has its own
## SpriteFrames (see mech.tscn), so any of them can be repainted with real
## art without affecting the others. The 3 "left" ones currently still
## reuse their "right" counterpart's textures with flip_h baked in as a
## placeholder (a static scene property now, not toggled in code), until
## real distinct art replaces them. See _DIRECTION_GROUPS/
## _update_body_sprite_for_facing().
@onready var _body_right: AnimatedSprite2D = $BodyRight
@onready var _body_upper_right: AnimatedSprite2D = $BodyUpperRight
@onready var _body_lower_right: AnimatedSprite2D = $BodyLowerRight
@onready var _body_upper_left: AnimatedSprite2D = $BodyUpperLeft
@onready var _body_left: AnimatedSprite2D = $BodyLeft
@onready var _body_lower_left: AnimatedSprite2D = $BodyLowerLeft
## All 6 above, keyed by _DIRECTION_GROUPS' names — built once in _ready().
var _body_sprites_by_group : Dictionary = {}
## Whichever of the 6 above is currently showing, based on facing — every
## play_*_animation() below just plays on this, so they don't need to care
## which direction is actually active.
var _animated_sprite: AnimatedSprite2D

## Plays melee/ranged attack flourishes (default or per-part custom) on top
## of the body sprite, which stays visible throughout — see
## play_attack_animation().
@onready var _attack_effect: AnimatedSprite2D = $AttackEffect

## Indexed by facing (0-5, matching HexDirections.DIRECTIONS) — which of the
## 6 _body_sprites_by_group entries that facing shows.
const _DIRECTION_GROUPS := ["right", "upper_right", "upper_left", "left", "lower_left", "lower_right"]

## Every mech can always move 3 and melee-attack (1 red die, range 1), even
## with zero parts equipped — parts add on top of this, they never take it
## away. Built fresh per mech so nothing shares state across instances.
var _innate_move : Actions
var _innate_attack : Actions

func _ready():
	_innate_move = Actions.new()
	_innate_move.display_name = "Basic Movement"
	_innate_move.movement = 3

	_innate_attack = Actions.new()
	_innate_attack.display_name = "Basic Attack"
	_innate_attack.red_dice = 1
	_innate_attack.range = 1

	for part in parts:
		max_hp += part.bonus_hp
	current_hp = max_hp
	_base_scale = scale
	_update_health_bar()

	_body_sprites_by_group = {
		"right": _body_right, "upper_right": _body_upper_right, "lower_right": _body_lower_right,
		"upper_left": _body_upper_left, "left": _body_left, "lower_left": _body_lower_left,
	}

	if chassis_visual != null:
		_apply_chassis_visual(chassis_visual)

	# mech.tscn's 6 body sprites + attack effect are each SubResource-backed
	# SpriteFrames — shared by reference across every instance of this scene
	# (both player_mech and ai_mech) unless duplicated here. Without this, a
	# part's custom attack/move animation (copied in via play_*_animation()
	# below) would leak onto whichever other mech happens to share this art.
	for sprite: AnimatedSprite2D in _body_sprites_by_group.values():
		sprite.sprite_frames = sprite.sprite_frames.duplicate(true)
		sprite.animation_finished.connect(_on_body_animation_finished.bind(sprite))
		sprite.visible = false
	_attack_effect.sprite_frames = _attack_effect.sprite_frames.duplicate(true)

	_animated_sprite = _body_right
	_animated_sprite.visible = true
	_play_idle()

	_update_facing_visual()

	_attack_effect.visible = false
	_attack_effect.animation_finished.connect(_on_attack_effect_finished)

## Runtime version of the chassis_visual export — swaps this mech's art to
## source's immediately, e.g. when a player picks a themed Quick Loadout
## preset in LoadoutScreen after the mech is already alive on-screen.
## chassis_visual itself is only ever read once, in _ready(); this is how
## anything later than that changes it. No-op if source is null.
func set_chassis_visual(source: PackedScene):
	if source == null:
		return
	chassis_visual = source
	_apply_chassis_visual(source)
	_play_idle()

## Copies source's body/attack-effect art onto this mech's own sprites — see
## chassis_visual/set_chassis_visual(). Each sprite's new frames are
## duplicated on the way in, same as the sprite_frames.duplicate(true) loop
## in _ready() does for this mech's own baked-in art — otherwise two mechs
## (or two calls) picking the same chassis would end up sharing one
## SpriteFrames object, and a per-part animation copied onto one (see
## play_*_animation()) would leak onto the other.
##
## Also rescales each sprite to compensate for source's art being a
## different native resolution than whatever this mech's own art already
## was (e.g. dropping in a 36x36 pixel-art replacement for a 200x200
## painted sprite) — otherwise the swapped-in art would suddenly render
## tiny or huge instead of at the mech's usual on-screen size. This makes
## chassis_visual resolution-agnostic, so future art (pixel or otherwise)
## at any size drops in at the right size without needing scale tuned by
## hand per chassis scene. The rescale snaps to a whole-number factor (see
## _rescale_sprite_for_new_art()) rather than matching the target size
## exactly, so pixel art actually looks crisp instead of unevenly scaled.
func _apply_chassis_visual(source: PackedScene):
	var sprite_by_node_name := {
		"BodyRight": _body_right, "BodyUpperRight": _body_upper_right, "BodyLowerRight": _body_lower_right,
		"BodyUpperLeft": _body_upper_left, "BodyLeft": _body_left, "BodyLowerLeft": _body_lower_left,
	}
	for node_name in sprite_by_node_name:
		var sprite : AnimatedSprite2D = sprite_by_node_name[node_name]
		var frames := SpriteFramesUtil.extract_named_sprite_frames(source, node_name)
		if frames:
			var old_size := _reference_frame_size(sprite.sprite_frames)
			var new_size := _reference_frame_size(frames)
			sprite.sprite_frames = frames.duplicate(true)
			_rescale_sprite_for_new_art(sprite, old_size, new_size)
	var attack_frames := SpriteFramesUtil.extract_named_sprite_frames(source, "AttackEffect")
	if attack_frames:
		var old_size := _reference_frame_size(_attack_effect.sprite_frames)
		var new_size := _reference_frame_size(attack_frames)
		_attack_effect.sprite_frames = attack_frames.duplicate(true)
		_rescale_sprite_for_new_art(_attack_effect, old_size, new_size)

## Rescales sprite so its just-swapped-in art (new_size, its native pixel
## width) lands at roughly the on-screen size old_size/sprite's previous
## scale implied — snapped to the nearest whole-number scale factor rather
## than matching that target exactly. Pixel art wants every source pixel
## mapped to an identically-sized block of screen pixels; a fractional
## scale (e.g. 2.03x) still looks uneven/jittery even with nearest-neighbor
## filtering on, since different source pixels then land on inconsistently
## sized blocks. Trading a little precision on the target size is worth it
## for crisp, even pixels. No-op if either size is unknown (0.0).
func _rescale_sprite_for_new_art(sprite: AnimatedSprite2D, old_size: float, new_size: float):
	if old_size <= 0.0 or new_size <= 0.0:
		return
	var ideal_scale := sprite.scale.x * (old_size / new_size)
	sprite.scale = Vector2.ONE * maxf(1.0, roundf(ideal_scale))

## Pixel width of frame 0 of "idle" (or whichever animation exists first, if
## frames has no "idle") — used by _apply_chassis_visual() as a stand-in for
## "how big was this art actually drawn" so a swap can rescale against it.
## 0.0 if there's nothing to measure (null frames, or an empty animation).
func _reference_frame_size(frames: SpriteFrames) -> float:
	if frames == null:
		return 0.0
	var names := frames.get_animation_names()
	var anim : StringName = &"idle" if frames.has_animation("idle") else (names[0] if names.size() > 0 else &"")
	if anim == &"" or frames.get_frame_count(anim) == 0:
		return 0.0
	var tex := frames.get_frame_texture(anim, 0)
	return tex.get_width() if tex else 0.0

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

## move_action is optional — pass the Actions/Part that's actually powering
## this step (see Game_Manager) to play its custom move animation, if it has
## one. Omit it for shoves/pushes/pulls, which aren't the mech moving under
## its own power.
func move_to(coord: Vector2i, move_action: Actions = null):
	hex_coord = coord
	snap_to_grid()
	if move_action:
		play_move_animation(move_action)

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
	_update_body_sprite_for_facing()

## Shows whichever of the 6 body sprites matches the current facing, hides
## the other five. If the active sprite is actually changing, carries over
## whatever animation was playing so switching direction mid-idle/mid-move
## doesn't visibly reset it. flip_h is a static per-sprite scene property
## now (see mech.tscn), not toggled here — each direction owns its own
## sprite instead of 3 directions sharing/mirroring another's.
func _update_body_sprite_for_facing():
	var group : String = _DIRECTION_GROUPS[facing]
	var target : AnimatedSprite2D = _body_sprites_by_group[group]

	if target != _animated_sprite:
		var current_anim : StringName = _animated_sprite.animation if _animated_sprite else &"idle"
		if not target.sprite_frames.has_animation(current_anim):
			current_anim = "idle"
		if _animated_sprite:
			_animated_sprite.visible = false
		_animated_sprite = target
		_animated_sprite.visible = true
		_animated_sprite.play(current_anim)
		if current_anim == "idle":
			SpriteFramesUtil.sync_to_global_clock(_animated_sprite, "idle")

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

## Clears every equipped part and the HP they granted, back to a fresh
## Move-2/melee-only mech with 0 HP — used to give a 2-player match's joining
## client a blank loadout to build, instead of inheriting whatever fixed
## parts this node happens to carry (e.g. ai_mech's solo-vs-AI loadout).
func reset_loadout():
	parts = []
	max_hp = 0
	current_hp = 0
	hp_changed.emit(current_hp, max_hp)
	_update_health_bar()

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

## Every equipped part that grants a drone (drone_type != null) — used to let
## the player pick which one to deploy from when more than one is equipped,
## same idea as get_available_attack_actions(). get_drone_type()/
## get_max_drones() still just return the first match, for callers (the AI)
## that don't need to choose.
func get_available_drone_parts() -> Array[Part]:
	var options : Array[Part] = []
	for part in parts:
		if part.drone_type != null:
			options.append(part)
	return options

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
## Excludes can_react parts — a part that blocks can't also attack.
func get_attack_action_for_range(dist: int, current_level: int = -1) -> Actions:
	for part in parts:
		if not part.can_react and part.dice_count() > 0 and dist >= part.min_range and dist <= part.range and (current_level < 0 or part.level_met(current_level)):
			return part
	if dist >= _innate_attack.min_range and dist <= _innate_attack.range:
		return _innate_attack
	return null

## Every equipped part (in equip order) plus the innate Basic Attack that
## currently qualifies for dist/current_level — used to let the player pick a
## specific weapon instead of always defaulting to the first match (see
## get_attack_action_for_range(), which the AI still uses since it doesn't
## need to choose). Excludes can_react parts — a part that blocks can't also
## attack.
func get_available_attack_actions(dist: int, current_level: int = -1) -> Array[Actions]:
	var options : Array[Actions] = []
	for part in parts:
		if not part.can_react and part.dice_count() > 0 and dist >= part.min_range and dist <= part.range and (current_level < 0 or part.level_met(current_level)):
			options.append(part)
	if dist >= _innate_attack.min_range and dist <= _innate_attack.range:
		options.append(_innate_attack)
	return options

## Returns the first equipped part with can_react set whose level requirement
## is met, or null if none qualify — see get_move_action() for current_level.
func get_reacting_part(current_level: int = -1) -> Part:
	for part in parts:
		if part.can_react and (current_level < 0 or part.level_met(current_level)):
			return part
	return null

## target: mech or Drone — anything with a take_damage(amount) method.
## current_level only matters for parts with dice_scale_with_level set; it
## defaults to 1 (no scaling) for callers that don't track levels (the AI).
## defender_react_level >= 0 checks target for a qualifying Reaction (see
## get_reacting_part()) and, if found, rolls that part's own dice and
## subtracts the result from the incoming damage (floored at 0).
func attack(target, action : Actions, current_level: int = 1, defender_react_level: int = -1) -> Dictionary:
	play_attack_animation(action, target.global_position)
	var result := action.roll(current_level)
	result["reaction_used"] = false
	if defender_react_level >= 0 and target.has_method("get_reacting_part"):
		var reacting_part : Part = target.get_reacting_part(defender_react_level)
		if reacting_part:
			var reduction : int = reacting_part.roll(defender_react_level).damage
			result.damage = maxi(0, result.damage - reduction)
			result["reaction_reduction"] = reduction
			result["reaction_part_name"] = reacting_part.resource_path.get_file().get_basename() if reacting_part.resource_path != "" else reacting_part.display_name
			result["reaction_used"] = true
	target.take_damage(result.damage)
	return result

## Plays an attack flourish on _attack_effect at target_position (the world
## position of whatever's being hit — see attack()) rather than over this
## mech's own body, since the flourish represents the attack landing, not
## the mech performing it. _attack_effect stays a child of this mech (so it
## still shares its SpriteFrames/animation-finished wiring), but its
## position is overridden via global_position each time this plays, and
## reset once the animation finishes (see _on_attack_effect_finished()).
## Uses action's "attack" visual_scene animation if it has one (each part
## can get its own distinct attack effect), else the mech's shared
## melee_attack/ranged_attack flash/slash — range > 1 = ranged, matching the
## same threshold used for the melee/ranged badge icons in the loadout screen.
func play_attack_animation(action: Actions, target_position: Vector2):
	var default_anim := "ranged_attack" if action.range > 1 else "melee_attack"
	var anim_name := default_anim
	if SpriteFramesUtil.copy_animation(_attack_effect.sprite_frames, action.get_visual_frames(), "attack"):
		anim_name = "attack"
	_attack_effect.global_position = target_position
	_attack_effect.visible = true
	_attack_effect.play(anim_name)

## Plays action's "move" visual_scene animation if it has one (each movement
## part can get its own distinct walk/run/hover animation), else just stays
## idle.
func play_move_animation(action: Actions):
	if SpriteFramesUtil.copy_animation(_animated_sprite.sprite_frames, action.get_visual_frames(), "move"):
		_animated_sprite.play("move")
	else:
		_play_idle()

## Returns to "idle" once a one-shot move/hit animation finishes on the body
## sprite. idle loops so this never fires for it; defeated is meant to be a
## permanent end state, so it's excluded too. Bound to the specific body
## sprite that fired it (source) — a sprite that got swapped out mid-
## animation for a facing change keeps playing in the background while
## hidden, so this ignores it if it's not the currently active one.
func _on_body_animation_finished(source: AnimatedSprite2D):
	if source != _animated_sprite:
		return
	if _animated_sprite.animation != "idle" and _animated_sprite.animation != "defeated":
		_play_idle()

## Plays "idle", synced to a shared global clock (see
## SpriteFramesUtil.sync_to_global_clock) so every mech's idle loop bobs in
## phase with every other mech's (and every drone's — see Drone.gd), instead
## of each one looping from whatever moment it happened to start.
func _play_idle():
	_animated_sprite.play("idle")
	SpriteFramesUtil.sync_to_global_clock(_animated_sprite, "idle")

## Hides the attack effect overlay again once its one-shot animation
## finishes, and returns it to its normal child position (centered on this
## mech) so it doesn't stay displaced at wherever the last attack landed.
func _on_attack_effect_finished():
	_attack_effect.stop()
	_attack_effect.visible = false
	_attack_effect.position = Vector2.ZERO

func take_damage(amount: int):
	current_hp = maxi(0, current_hp - amount)
	hp_changed.emit(current_hp, max_hp)
	_update_health_bar()
	if current_hp <= 0:
		play_defeated_animation()
		died.emit()
	else:
		play_hit_animation()

## Shared "hit" reaction (like idle, not tied to any specific part) — reverts
## to idle via _on_body_animation_finished() once it finishes.
func play_hit_animation():
	_animated_sprite.play("hit")

## Plays once HP hits 0 and stays on its last frame — mechs aren't removed
## from the scene on death. Usually brief: Game_Manager respawns this mech
## (see respawn()) unless that KO just won the match, in which case this
## "powered down" pose is what's left on screen once the match ends.
func play_defeated_animation():
	_animated_sprite.play("defeated")

## Brings this mech back at full HP on its own spawn hex, facing its original
## spawn direction — called by Game_Manager after a KO that didn't just win
## the match (see Game_Manager.WINNING_SCORE). Equipped parts are untouched.
func respawn():
	hex_coord = spawn_hex_coord
	facing = spawn_facing
	current_hp = max_hp
	snap_to_grid()
	_play_idle()
	hp_changed.emit(current_hp, max_hp)
	_update_health_bar()

## Applies incoming state from a 2-player match's network snapshot (see
## Game_Manager._rpc_apply_snapshot) — updates position/facing/HP directly
## without invoking the authoritative math (no dice rolls, no double-
## counted damage), since the host already resolved the real mutation and
## is just telling this peer what happened. Still plays the hit/defeated
## reaction so it's visible either way — just skips the move animation
## (which move part was used isn't part of the snapshot), so a synced move
## reads as a snap to the new hex rather than an animated walk.
## new_max_hp defaults to -1 ("unchanged") so older callers/snapshots that
## don't track it still work — losing a part to a Reaction is the only thing
## that currently changes max_hp mid-match, so this only matters then.
func sync_visual_state(new_hex_coord: Vector2i, new_facing: int, new_hp: int, new_max_hp: int = -1):
	var hp_decreased := new_hp < current_hp
	hex_coord = new_hex_coord
	facing = new_facing
	current_hp = new_hp
	if new_max_hp >= 0:
		max_hp = new_max_hp
	snap_to_grid()
	_update_health_bar()
	if new_hp <= 0:
		play_defeated_animation()
	elif hp_decreased:
		play_hit_animation()
	elif _animated_sprite.animation == "defeated":
		# hp went up (not down) while showing the defeated pose — a respawn.
		_play_idle()

func _update_health_bar():
	var pct := float(current_hp) / float(max_hp) if max_hp > 0 else 0.0
	_health_bar_fill.size.x = HEALTH_BAR_WIDTH * clampf(pct, 0.0, 1.0)
