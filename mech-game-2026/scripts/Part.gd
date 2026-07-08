class_name Part
extends Actions
## Equipment assigned to a mech (legs, arms, weapons...). Shares Actions'
## fields (movement, range, dice) so a Part can be used anywhere an Actions
## resource is expected — a mech's equipped Parts feed directly into its
## available actions.

## If set, equipping this part grants the mech's Special action: deploying
## and controlling a drone of this type. Null (default) = this part doesn't
## grant drone deployment.
@export var drone_type : DroneType = null

## Total number of drones this part can deploy over the whole match (not how
## many can be active at once — only one drone is ever active at a time).
## Deploying uses one up; once a drone dies, another can be deployed as long
## as this budget isn't exhausted. Only meaningful when drone_type is set.
@export var max_drones : int = 1

## If true, this part grants a Reaction instead of an attack: when this mech
## is attacked, this part's own dice (red/blue/yellow/purple, same fields
## used for an attack) roll against the incoming hit and reduce its damage,
## gated by this part's own required_level like its other capabilities. A
## part can't do both — one that can_react is excluded from attack options
## (see mech.get_attack_action_for_range()/get_available_attack_actions()).
@export var can_react : bool = false
