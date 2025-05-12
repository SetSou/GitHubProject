extends CharacterBody3D

@export var navigation : NavigationAgent3D
var speed = 3.0

func _ready():
	if not navigation:
		navigation = $NavigationAgent3D
		
func _physics_process(delta):
	if navigation.is_navigation_finished():
		return

	var direction = navigation.get_next_path_position()
	if direction.length() > 0.1:
		direction = direction.normalized()
		velocity = direction * speed
		move_and_slide()

func set_target_position(target: Vector3):
	if navigation:
		navigation.set_target_position(target)
