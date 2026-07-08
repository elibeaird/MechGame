class_name AIBehavior
extends Resource
## A named AI personality, assignable to an AI-controlled mech (see
## mech.ai_behavior). Tunable knobs the same shared AI turn logic in
## Game_Manager._ai_take_turn() reads — different resources here produce
## different-feeling opponents without any code changes.

@export var display_name : String = ""

## Which enemy target (the player's mech, or one of its drones) this AI goes
## after when it has a choice.
enum TargetPriority {
	MECH_FIRST,   ## Always prefers the player's mech itself over any drone.
	DRONES_FIRST, ## Picks off a drone before ever touching the mech.
	WEAKEST,      ## Whichever valid target currently has the least HP.
	NEAREST,      ## Whichever valid target is closest right now.
}
@export var target_priority : TargetPriority = TargetPriority.MECH_FIRST

## Prefers a ranged (range > 1) attack over a melee one when both are
## available and both could reach the target.
@export var prefers_ranged : bool = false

## If true and this AI already has an attack that can reach its target from
## where it's standing, it won't close the remaining distance — a kiting
## playstyle. Ignored if it doesn't have anything in range yet (it still
## approaches normally in that case).
@export var keeps_distance : bool = false

## HP fraction (0.0-1.0) below which this AI backs straight away from its
## target instead of engaging. 0 (default) = never retreats.
@export var retreat_hp_fraction : float = 0.0

## Reserved for when the AI can use Special/drones (it can't yet — see
## Game_Manager._ai_take_turn()). Not read by any gameplay code today.
@export var uses_special : bool = false

## If true, ignores every other field above and just makes a weak/random
## choice each turn instead of the best available one — a deliberately easy
## opponent. See Game_Manager._ai_take_random_turn().
@export var acts_randomly : bool = false
