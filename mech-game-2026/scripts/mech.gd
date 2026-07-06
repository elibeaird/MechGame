class_name mech
extends Node2D

@export var is_player : bool


@export var actions : Array[Actions]

var target_scale :float = 1.0

func begin_turn ():
	target_scale = 1.1
	
	if is_player:
		print( "player turn has begun")
	
	else :
			print("ai turn has begun")


func end_turn():
	target_scale = 0.9

#func _process(delta):
	#pass
	
#func take_hit():
		#pass

func take_action(actiion : Actions, target :mech):
	pass
