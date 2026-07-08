class_name Drone
extends Node2D
## A deployed drone. Its HP, movement, attack range, and dice all come from
## whichever DroneType it was set up with — see setup(). Spawned from
## res://Scenes/drone.tscn (Game_Manager.deploy_drone_scene.instantiate()),
## not Drone.new() — it needs its Body/AttackEffect children from the scene.

signal died

const RADIUS := 10.0
const COLOR := Color(0.3, 0.8, 0.9)

@export var hex_coord : Vector2i
var hex_size : float = HexGrid.HEX_SIZE
var drone_type : DroneType
var hp : int = 1

## Shows drone_type's idle/deploy/move/crash/defeated/hit animations (from
## its visual_scene, see Actions.gd) when it has them; otherwise falls back
## to whichever of those animations res://Scenes/drone.tscn's own Body
## SpriteFrames already has built in (see each play_*_animation() below) —
## drone_type only needs a visual_scene for a drone that wants to look
## different from the scene's default art.
@onready var _body: AnimatedSprite2D = $Body
## Plays drone_type's "attack" visual_scene animation, layered on top of
## _body (which stays on whatever it was already doing) — mirrors mech.gd's
## _attack_effect. Falls back to the scene's own "attack" animation the same
## way _body does, if it has any frames (empty by default in drone.tscn — a
## pure overlay flourish, not every drone type needs one).
@onready var _attack_effect: AnimatedSprite2D = $AttackEffect


func _ready():
	# drone.tscn's Body/AttackEffect SpriteFrames are SubResource-backed —
	# shared by reference across every Drone instance unless duplicated here.
	# Without this, one drone type's copied-in animation (see
	# play_*_animation() below) would leak onto every other drone sharing
	# this scene, including different types deployed at the same time.
	_body.sprite_frames = _body.sprite_frames.duplicate(true)
	_attack_effect.sprite_frames = _attack_effect.sprite_frames.duplicate(true)

	_body.visible = true
	_body.animation_finished.connect(_on_body_animation_finished)
	_attack_effect.visible = false
	_attack_effect.animation_finished.connect(_on_attack_effect_finished)

	play_deploy_animation()


## Must be called once right after instantiating res://Scenes/drone.tscn,
## before deploying it.
func setup(type: DroneType):
	drone_type = type
	hp = maxi(1, type.bonus_hp)


func snap_to_grid():
	position = HexGrid.offset_to_pixel(hex_coord, hex_size)


func move_to(coord: Vector2i):
	hex_coord = coord
	snap_to_grid()
	play_move_animation()


func attack(target) -> Dictionary:
	play_attack_animation(target.global_position)
	var result := drone_type.roll()
	target.take_damage(result.damage)
	return result


## Kamikaze: rams an adjacent target for damage equal to the drone's current
## HP, then destroys the drone regardless of how much HP that was. Returns
## the damage dealt so the caller can apply it and report it.
func crash(target) -> int:
	play_crash_animation()
	var damage := hp
	hp = 0
	target.take_damage(damage)
	play_defeated_animation()
	return damage


func take_damage(amount: int):
	hp = maxi(0, hp - amount)
	if hp <= 0:
		play_defeated_animation()
	else:
		play_hit_animation()


func _draw():
	draw_circle(Vector2.ZERO, RADIUS, COLOR)
	draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 32, Color.BLACK, 2.0)


## Loops for as long as nothing else is playing — the drone's resting look.
## Synced to a shared global clock (see SpriteFramesUtil.sync_to_global_clock)
## so every drone's idle loop bobs in phase with every other drone's,
## regardless of when each one was deployed.
func play_idle_animation():
	var custom := drone_type.get_visual_frames() if drone_type else null
	if SpriteFramesUtil.copy_animation(_body.sprite_frames, custom, "idle") or _body.sprite_frames.has_animation("idle"):
		_body.visible = true
		_body.play("idle")
		SpriteFramesUtil.sync_to_global_clock(_body, "idle")

func play_deploy_animation():
	var custom := drone_type.get_visual_frames() if drone_type else null
	if SpriteFramesUtil.copy_animation(_body.sprite_frames, custom, "deploy") or _body.sprite_frames.has_animation("deploy"):
		_body.visible = true
		_body.play("deploy")
	else:
		play_idle_animation()

func play_move_animation():
	var custom := drone_type.get_visual_frames() if drone_type else null
	if SpriteFramesUtil.copy_animation(_body.sprite_frames, custom, "move") or _body.sprite_frames.has_animation("move"):
		_body.visible = true
		_body.play("move")

func play_crash_animation():
	var custom := drone_type.get_visual_frames() if drone_type else null
	if SpriteFramesUtil.copy_animation(_body.sprite_frames, custom, "crash") or _body.sprite_frames.has_animation("crash"):
		_body.visible = true
		_body.play("crash")

## Plays at target_position (the world position of whatever's being hit —
## see attack()) rather than over this drone's own body, same as mech.gd —
## the flourish represents the attack landing, not the drone performing it.
func play_attack_animation(target_position: Vector2):
	var custom := drone_type.get_visual_frames() if drone_type else null
	SpriteFramesUtil.copy_animation(_attack_effect.sprite_frames, custom, "attack")
	if _attack_effect.sprite_frames.has_animation("attack") and _attack_effect.sprite_frames.get_frame_count("attack") > 0:
		_attack_effect.global_position = target_position
		_attack_effect.visible = true
		_attack_effect.play("attack")

## Plays drone_type's "hit" visual_scene animation if it has one, else the
## scene's own "hit" animation if it has one; otherwise falls back to a
## plain scale-punch tween so getting shot always has some feedback even
## with no art at all.
func play_hit_animation():
	var custom := drone_type.get_visual_frames() if drone_type else null
	if SpriteFramesUtil.copy_animation(_body.sprite_frames, custom, "hit") or _body.sprite_frames.has_animation("hit"):
		_body.visible = true
		_body.play("hit")
	else:
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2(1.3, 1.3), 0.08)
		tween.tween_property(self, "scale", Vector2.ONE, 0.12)

## Plays once HP hits 0 (from take_damage() or crash()) before the drone is
## actually removed. If a "defeated" animation is available, died only emits
## once it finishes (_on_body_animation_finished) — long enough for the
## Game_Manager pauses that already follow a killing hit to cover it.
## Emits immediately, as before, if there's no defeated animation at all.
func play_defeated_animation():
	var custom := drone_type.get_visual_frames() if drone_type else null
	if SpriteFramesUtil.copy_animation(_body.sprite_frames, custom, "defeated") or _body.sprite_frames.has_animation("defeated"):
		_body.visible = true
		_body.play("defeated")
	else:
		died.emit()


## Once a one-shot _body animation finishes, settle back onto idle — mirrors
## mech.gd's revert-to-idle. play_idle_animation() already handles both the
## custom-frames and scene-fallback cases, so no branching is needed here.
## defeated is the one exception — it's a permanent end state, so this is
## also where died actually emits once it's finished playing.
func _on_body_animation_finished():
	if _body.animation == "defeated":
		died.emit()
		return
	if _body.animation == "idle":
		return
	play_idle_animation()

## Hides the attack effect overlay again once its one-shot animation
## finishes, and returns it to its normal child position (centered on this
## drone) so it doesn't stay displaced at wherever the last attack landed.
func _on_attack_effect_finished():
	_attack_effect.stop()
	_attack_effect.visible = false
	_attack_effect.position = Vector2.ZERO
