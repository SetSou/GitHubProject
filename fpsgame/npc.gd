extends CharacterBody3D

@export var speed: float = 5.0  # Movement speed
@export var min_wait_time: float = 1.0  # Min time before choosing new point
@export var max_wait_time: float = 3.0  # Max time before choosing new point
@export var target_reach_distance: float = 0.5  # Distance to consider target reached

var navigation_agent: NavigationAgent3D
var path: Array = []  # Array of Vector3 points for the path
var current_target: Vector3
var is_moving: bool = false

func _ready():
	# Get or add NavigationAgent3D
	navigation_agent = get_node_or_null("NavigationAgent3D")
	if not navigation_agent:
		navigation_agent = NavigationAgent3D.new()
		add_child(navigation_agent)
	
	# Start the random movement process
	choose_new_random_point()

func _physics_process(delta):
	print(path.size())
	if is_moving and path.size() > 0:
		print("moving")
		# Get the next point in the path
		var next_point = path[0]
		
		# Move towards the next point
		var direction = (next_point - global_position).normalized()
		velocity = direction * speed
		
		# Move the NPC
		move_and_slide()
		
		# Check if close to the next point
		if global_position.distance_to(next_point) < target_reach_distance:
			path.remove_at(0)  # Remove the reached point
			if path.size() == 0:
				# Reached the final target, stop and choose a new point
				is_moving = false
				velocity = Vector3.ZERO
				start_wait_timer()

func choose_new_random_point():
	# Get the navigation map from the NavigationRegion3D
	print("choosing random poi")
	var nav_region = get_parent().get_node_or_null("NavigationRegion3D")
	if not nav_region:
		print("No Nav Region")
		return
	
	var nav_map = nav_region.navigation_mesh.get_rid()
	
	# Get a random point on the navmesh
	current_target = NavigationServer3D.map_get_random_point(nav_map, true, false)
	
	# Calculate path to the random point
	path = NavigationServer3D.map_get_path(
		get_world_3d().navigation_map,
		global_position,
		current_target,
		true
	)
	print("set is_moving to true")
	is_moving = true

func start_wait_timer():
	print("waiting")
	# Wait for a random time before choosing a new point
	var wait_time = randf_range(min_wait_time, max_wait_time)
	await get_tree().create_timer(wait_time).timeout
	choose_new_random_point()
