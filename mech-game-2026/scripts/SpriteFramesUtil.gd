class_name SpriteFramesUtil
extends RefCounted
## Static helpers for pulling one hand-authored animation out of a whole
## scene and copying it onto another SpriteFrames — lets a Part/DroneType
## supply custom art as a small scene (an AnimatedSprite2D with animations
## built in Godot's SpriteFrames editor: multi-select frames, per-animation
## loop/speed, per-frame duration) instead of filling in a texture array one
## frame at a time. See Actions.gd's visual_scene.

## Copies anim_name's frames (texture, per-frame duration, loop, speed) from
## source onto dest, adding or replacing just that one animation — dest's
## other animations are untouched. Returns false (no-op) if source is null
## or has no such animation.
static func copy_animation(dest: SpriteFrames, source: SpriteFrames, anim_name: String) -> bool:
	if source == null or not source.has_animation(anim_name):
		return false
	if dest.has_animation(anim_name):
		dest.clear(anim_name)
	else:
		dest.add_animation(anim_name)
	dest.set_animation_loop(anim_name, source.get_animation_loop(anim_name))
	dest.set_animation_speed(anim_name, source.get_animation_speed(anim_name))
	for i in source.get_frame_count(anim_name):
		dest.add_frame(anim_name, source.get_frame_texture(anim_name, i), source.get_frame_duration(anim_name, i))
	return true

## Instantiates scene just long enough to grab the SpriteFrames off its first
## AnimatedSprite2D (the root node, or wherever one is nested inside it) —
## the instance never enters the tree and is freed immediately after. Null
## if scene is null or contains no AnimatedSprite2D at all.
static func extract_sprite_frames(scene: PackedScene) -> SpriteFrames:
	if scene == null:
		return null
	var instance := scene.instantiate()
	var sprite := _find_animated_sprite(instance)
	var frames := sprite.sprite_frames if sprite else null
	instance.free()
	return frames

static func _find_animated_sprite(node: Node) -> AnimatedSprite2D:
	if node is AnimatedSprite2D:
		return node
	for child in node.get_children():
		var found := _find_animated_sprite(child)
		if found:
			return found
	return null

## Jumps sprite's currently-playing animation to wherever a shared global
## clock (Time.get_ticks_msec()) would already be in its loop, so every
## AnimatedSprite2D looping the same animation lands on the same frame at
## the same moment — e.g. every drone's "idle" bobbing in unison — instead
## of each one looping from whatever moment .play() happened to be called.
## Call once right after .play(); Godot's own per-frame stepping keeps it in
## phase from there on, since every instance advances at the same rate.
## No-op if anim_name isn't a real, non-empty animation on sprite.
static func sync_to_global_clock(sprite: AnimatedSprite2D, anim_name: StringName = &""):
	if anim_name == &"":
		anim_name = sprite.animation
	var frames := sprite.sprite_frames
	if frames == null or not frames.has_animation(anim_name):
		return
	var count := frames.get_frame_count(anim_name)
	if count <= 0:
		return
	var speed : float = frames.get_animation_speed(anim_name)
	if speed <= 0.0:
		speed = 1.0

	var durations : Array[float] = []
	var total := 0.0
	for i in count:
		var d : float = frames.get_frame_duration(anim_name, i) / speed
		durations.append(d)
		total += d
	if total <= 0.0:
		return

	var t := fmod(Time.get_ticks_msec() / 1000.0, total)
	for i in count:
		if t < durations[i] or i == count - 1:
			sprite.frame = i
			sprite.frame_progress = clampf(t / durations[i], 0.0, 1.0) if durations[i] > 0.0 else 0.0
			return
		t -= durations[i]
