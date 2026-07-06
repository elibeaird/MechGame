extends Node2D

@export var player_mech : mech
@export var ai_mech : mech
var current_mech : mech

var game_over :bool = false

func _ready():
	next_turn()
	
func next_turn ():
	if game_over:
		return
	
	if current_mech != null:
		current_mech.end_turn()
	
	if current_mech ==ai_mech or current_mech == null:
		current_mech = player_mech
	else:
		current_mech = ai_mech
	
	current_mech.begin_turn()
	
	if current_mech. is_player:
		pass
		#enable and set playe UI
	else:
		#disable player UI
		var wait_time = randf_range(0.5, 1.5)
		await get_tree().create_timer(wait_time).timeout
		#cast action
		await get_tree().create_timer(wait_time).timeout
		next_turn()

func player_take_action (action):
	if player_mech != current_mech:
		return
		
		#player_mech.take_action(action. ai_mech)
		#disable player AI
		await get_tree().create_timer(0.5).timeout
		next_turn()

func ai_decide_action ():
	pass
	
