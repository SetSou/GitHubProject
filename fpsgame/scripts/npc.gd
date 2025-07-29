extends CharacterBody3D

@export var speed: float = 5.0  # Movement speed
@export var max_distance: float = 50.0  # Maximum distance for random points
@export var wait_time: float = 2.0  # Time to wait before picking a new point
@export var gravity: float = 9.8  # Gravity value (default for Godot physics)
@export var health: int = 1

@export var spawns: PackedVector3Array = ([
	Vector3(3, -1.5, -7.5),
	Vector3(6, -1.5, -7.5),
	Vector3(9, -1.5, -7.5),
	Vector3(12, -1.5, -7.5),
	Vector3(-3, -1.5, -7.5),
	Vector3(-6, -1.5, -7.5),
	Vector3(-9, -1.5, -7.5),
	Vector3(-12, -1.5, -7.5),
])
# Predefined set of colors for the NPC
@export var possible_colors: Array[Color] = [
	Color.RED,
	Color.BLUE,
	Color.GREEN,
	Color.YELLOW,
	Color.PURPLE,
	Color.CYAN,
	Color.ORANGE
]
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D  # Reference to NavigationAgent3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D  # Reference to MeshInstance3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer  # Reference to MultiplayerSynchronizer
var time_since_last_target: float = 0.0
# Synced property for NPC color
@export var npc_color: Color = Color.WHITE : set = _set_npc_color

func _ready() -> void:
	if not multiplayer.is_server():
		return
	set_multiplayer_authority(multiplayer.get_unique_id()) # Set to server (peer ID 1)
	position = spawns[randi() % spawns.size()]
	if nav_agent == null:
		print("ERROR: NavigationAgent3D not found! Check node setup.")
		return
	if mesh_instance == null:
		print("ERROR: MeshInstance3D not found! Check node setup.")
		return
	if synchronizer == null:
		print("ERROR: MultiplayerSynchronizer not found! Check node setup.")
		return
	nav_agent.path_desired_distance = 0.5
	nav_agent.target_desired_distance = 0.5
	print("NavigationAgent3D initialized. Current position: ", global_position)
	# Set random color on server
	npc_color = possible_colors[randi() % possible_colors.size()]
	set_random_target()

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	# Apply gravity if not on the floor
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0  # Reset vertical velocity when on floor

	# Check if the NPC has reached the target
	if nav_agent.is_navigation_finished():
		print("Target reached or navigation finished. Waiting for ", wait_time, " seconds.")
		time_since_last_target += delta
		if time_since_last_target >= wait_time:
			print("Wait time elapsed. Picking new random target.")
			set_random_target()
			time_since_last_target = 0.0
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	# Get the next position to move to
	var next_position: Vector3 = nav_agent.get_next_path_position()
	var distance_to_next: float = global_position.distance_to(next_position)
	var direction: Vector3 = (next_position - global_position).normalized()

	# Move only in XZ plane for navigation
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	#print("Current position: ", global_position, " | Next path position: ", next_position, " | Velocity: ", velocity)

	# Move the CharacterBody3D
	var collision = move_and_slide()
	if collision:
		var collider = get_last_slide_collision().get_collider() if get_last_slide_collision() else null
		print("Collision detected. Collider: ", collider, " at position: ", collider.global_position if collider else "Unknown")

func set_random_target() -> void:
	# Get the navigation map
	var nav_map: RID = get_world_3d().navigation_map
	if not nav_map:
		print("ERROR: No navigation map found! Check NavigationRegion3D setup.")
		return

	# Get NPC's current position
	var current_position: Vector3 = global_position
	print("Current NPC position: ", current_position)

	# Generate a random point within max_distance
	var random_offset: Vector3 = Vector3(
		randf_range(-max_distance, max_distance),
		0,
		randf_range(-max_distance, max_distance)
	)
	var target_position: Vector3 = current_position + random_offset
	print("Generated random target: ", target_position)

	# Find the closest point on the navigation mesh
	var closest_point: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, target_position)
	print("Closest point on nav mesh: ", closest_point)

	# Set the target position for the navigation agent
	nav_agent.set_target_position(closest_point)
	print("Target set: ", closest_point, " | Reachable: ", nav_agent.is_target_reachable())

func _set_npc_color(new_color: Color) -> void:
	npc_color = new_color
	# Apply color to the mesh
	if mesh_instance:
		var material = mesh_instance.get_surface_override_material(0)
		if material == null:
			material = StandardMaterial3D.new()
			mesh_instance.set_surface_override_material(0, material)
		material.albedo_color = new_color
		#print("NPC color set to: ", new_color, " at position: ", global_position)

@rpc("any_peer", "call_local")
func recieve_damage(damage: int = 1) -> void:
	if not multiplayer.is_server():
		return
	health -= damage
	print("NPC hit! Health: ", health, " | Peer: ", multiplayer.get_remote_sender_id())
	if health <= 0:
		health = 2
		print("NPC health <= 0, removing NPC at position: ", global_position)
		destroy_npc.rpc()
		destroy_npc()

@rpc("call_local")
func destroy_npc() -> void:
	super.queue_free()
