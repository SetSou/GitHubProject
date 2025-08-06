extends CharacterBody3D

@export var speed: float = 5.0
@export var max_distance: float = 50.0
@export var wait_time: float = 2.0
@export var gravity: float = 9.8
@export var health: int = 1

# Movement behavior parameters
@export var acceleration: float = 15.0  # How quickly NPC accelerates
@export var deceleration: float = 20.0  # How quickly NPC stops
@export var direction_change_chance: float = 0.02  # Chance per frame to change direction slightly
@export var stop_chance: float = 0.001  # Chance per frame to stop and look around
@export var pause_duration_range: Vector2 = Vector2(0.5, 3.0)  # Random pause duration
@export var movement_variation: float = 0.3  # How much to vary movement direction

# Rotation parameters
@export var rotation_speed: float = 8.0  # How fast the NPC rotates to face movement direction
@export var min_movement_threshold: float = 0.1  # Minimum movement speed to trigger rotation

# Animation parameters
@export var idle_animation_name: String = "Idle_A"  # Name of the idle animation
@export var walk_animation_name: String = "Walk_A"  # Name of the walking animation
@export var death_animation_name: String = "Death_A"  # Name of the death animation
@export var animation_transition_speed: float = 0.3  # How fast to blend between animations

# NavMesh parameters
@export var path_update_distance: float = 2.0  # How close to get before updating path
@export var navmesh_sample_distance: float = 5.0  # How far to search for valid NavMesh points

# Collision avoidance parameters
@export var wall_check_distance: float = 2.0  # How far ahead to check for walls
@export var ledge_check_distance: float = 1.5  # How far ahead to check for ledges
@export var avoidance_force: float = 3.0  # How strong the avoidance force is

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

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer
@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var skeleton: Skeleton3D = $Character_1_2_22/CharacterArmature1/Skeleton3D

# Movement state
var target_direction: Vector3 = Vector3.ZERO
var current_velocity: Vector3 = Vector3.ZERO
var is_paused: bool = false
var pause_timer: float = 0.0
var movement_timer: float = 0.0

# Animation state
var current_animation: String = ""
var is_moving: bool = false
var is_dead: bool = false

# Mesh selection
var available_meshes: Array[Node] = []
var selected_mesh_index: int = -1

# Navigation state
var current_path: PackedVector3Array = PackedVector3Array()
var path_index: int = 0
var final_target: Vector3

# Target selection
var spawn_positions: Array[Vector3] = []
var target_reached_threshold: float = 2.0

# Synced property for NPC color
@export var npc_color: Color = Color.WHITE : set = _set_npc_color

# Synced property for selected mesh
@export var synced_mesh_index: int = -1 : set = _set_synced_mesh_index

# Synced property for death state
@export var synced_is_dead: bool = false : set = _set_synced_death_state

func _ready() -> void:
	_collect_spawn_positions()
	
	# Setup random mesh selection
	# Wait a frame to ensure multiplayer is properly set up
	await get_tree().process_frame
	_setup_random_mesh()
	
	# Setup NavigationAgent3D
	if navigation_agent:
		# Wait for navigation map to be ready
		call_deferred("_setup_navigation")
	
	# Initialize animation
	if animation_player:
		_play_animation(idle_animation_name)
	
	if not multiplayer.is_server():
		return
		
	set_multiplayer_authority(multiplayer.get_unique_id())
	
	# Use collected spawn positions for initial spawn
	if spawn_positions.size() > 0:
		position = spawn_positions[randi() % spawn_positions.size()]
	else:
		position = Vector3.ZERO
	
	if mesh_instance == null:
		return
	if synchronizer == null:
		return
	
	# Set random color on server
	npc_color = possible_colors[randi() % possible_colors.size()]
	
	# Sync the selected mesh to all clients (removed - now done in _setup_random_mesh)
	# if selected_mesh_index >= 0:
	#	sync_mesh_selection.rpc(selected_mesh_index)

@rpc("call_local")
func sync_mesh_selection(mesh_index: int) -> void:
	selected_mesh_index = mesh_index
	
	# Apply the mesh selection on all clients
	if available_meshes.size() == 0:
		_setup_random_mesh()  # Initialize meshes if not done yet
		return  # _setup_random_mesh will handle the sync, avoid infinite loop
	
	# Hide all meshes
	for mesh in available_meshes:
		if is_instance_valid(mesh):
			mesh.visible = false
	
	# Show the selected mesh
	if selected_mesh_index >= 0 and selected_mesh_index < available_meshes.size():
		if is_instance_valid(available_meshes[selected_mesh_index]):
			available_meshes[selected_mesh_index].visible = true
			print("Showing mesh index: ", selected_mesh_index, " on peer: ", multiplayer.get_unique_id())

@rpc("call_local")
func sync_death_state() -> void:
	if is_dead:
		return  # Already applied
		
	# Apply death state on all clients
	is_dead = true
	
	# Stop navigation
	if navigation_agent:
		navigation_agent.target_position = global_position
	
	# Disable collision layer so things can pass through
	collision_layer = 0
	
	# Play death animation
	_play_animation(death_animation_name)

func _setup_navigation() -> void:
	if navigation_agent:
		# Configure the navigation agent
		navigation_agent.radius = 0.5
		navigation_agent.height = 1.8
		navigation_agent.path_desired_distance = 0.5
		navigation_agent.target_desired_distance = 1.0
		navigation_agent.path_max_distance = 100.0
		
		# Connect signals
		navigation_agent.target_reached.connect(_on_target_reached)
		navigation_agent.navigation_finished.connect(_on_navigation_finished)
		
		# Start navigation after a short delay to ensure everything is ready
		await get_tree().process_frame
		_pick_new_target()

func _collect_spawn_positions() -> void:
	spawn_positions.clear()
	var spawn_nodes = get_tree().get_nodes_in_group("SpawnPoint")
	
	if spawn_nodes.size() == 0:
		print("WARNING: No nodes found in group 'SpawnPoint'.")
		return
	
	for node in spawn_nodes:
		if node is Node3D:
			spawn_positions.append(node.global_position)

func _setup_random_mesh() -> void:
	if not skeleton:
		print("WARNING: Skeleton3D node not found at path: Character_1_2_22/CharacterArmature1/Skeleton3D")
		return
	
	# Collect all mesh children under the skeleton
	available_meshes.clear()
	for child in skeleton.get_children():
		if child is MeshInstance3D:
			available_meshes.append(child)
	
	if available_meshes.size() == 0:
		print("WARNING: No MeshInstance3D nodes found under Skeleton3D")
		return
	
	print("Found ", available_meshes.size(), " meshes under Skeleton3D")
	
	# Hide all meshes first
	for mesh in available_meshes:
		mesh.visible = false
	
	# Only server selects the mesh, then syncs to all clients
	if multiplayer.is_server():
		selected_mesh_index = randi() % available_meshes.size()
		print("Server selected mesh index: ", selected_mesh_index)
		_show_selected_mesh()
		# Use call_deferred to ensure the RPC happens after the scene is fully ready
		call_deferred("_sync_mesh_to_clients", selected_mesh_index)
	else:
		print("Client waiting for mesh selection from server...")

func _sync_mesh_to_clients(mesh_index: int) -> void:
	sync_mesh_selection.rpc(mesh_index)
	
func _show_selected_mesh() -> void:
	if selected_mesh_index >= 0 and selected_mesh_index < available_meshes.size():
		available_meshes[selected_mesh_index].visible = true
		print("Selected mesh index: ", selected_mesh_index)

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	
	# Handle death state
	if is_dead:
		_handle_death_state(delta)
		return
	
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	
	# Handle pause behavior
	if is_paused:
		pause_timer -= delta
		if pause_timer <= 0.0:
			is_paused = false
			_pick_new_target()  # Pick new target after pause
		_apply_deceleration(delta)
		_update_animation_and_rotation(delta)
		move_and_slide()
		return
	
	# Random chance to pause (simulate player stopping to look around)
	if randf() < stop_chance:
		_start_pause()
		return
	
	# Navigate using NavigationAgent3D
	if navigation_agent and not navigation_agent.is_navigation_finished():
		_navigate_to_target(delta)
	else:
		# Pick a new target if we've finished navigation
		_pick_new_target()
	
	# Update animation and rotation based on movement
	_update_animation_and_rotation(delta)
	
	move_and_slide()

func _navigate_to_target(delta: float) -> void:
	# Get the next position from the navigation agent
	var next_path_position = navigation_agent.get_next_path_position()
	var current_agent_position = global_position
	
	# Calculate direction to next waypoint
	var desired_direction = (next_path_position - current_agent_position).normalized()
	
	# Add human-like imprecision and variation
	if randf() < direction_change_chance:
		_add_movement_variation()
	
	desired_direction = _add_human_like_imprecision(desired_direction)
	
	# Apply some collision avoidance as backup (though NavMesh should handle most of this)
	desired_direction = _apply_basic_collision_avoidance(desired_direction)
	
	# Update target direction with smoothing
	target_direction = target_direction.lerp(desired_direction, 3.0 * delta)
	target_direction = target_direction.normalized()
	
	# Apply acceleration/deceleration with consistent speed
	var target_velocity = target_direction * speed
	
	if target_velocity.length() > 0.1:
		current_velocity = current_velocity.move_toward(target_velocity, acceleration * delta)
	else:
		current_velocity = current_velocity.move_toward(Vector3.ZERO, deceleration * delta)
	
	# Apply velocity
	velocity.x = current_velocity.x
	velocity.z = current_velocity.z

func _update_animation_and_rotation(delta: float) -> void:
	# Don't update animation/rotation if dead
	if is_dead:
		return
	
	# Calculate horizontal movement speed
	var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
	var movement_speed = horizontal_velocity.length()
	
	# Determine if the NPC is moving
	var was_moving = is_moving
	is_moving = movement_speed > min_movement_threshold
	
	# Update animation based on movement
	var desired_animation = walk_animation_name if is_moving else idle_animation_name
	if desired_animation != current_animation:
		_play_animation(desired_animation)
	
	# Rotate to face movement direction
	if is_moving and horizontal_velocity.length() > min_movement_threshold:
		var target_look_direction = horizontal_velocity.normalized()
		var target_transform = transform.looking_at(global_position + target_look_direction, Vector3.UP)
		
		# Smoothly rotate towards the target direction
		transform = transform.interpolate_with(target_transform, rotation_speed * delta)

func _play_animation(animation_name: String) -> void:
	if not animation_player:
		return
		
	# Check if the animation exists
	if not animation_player.has_animation(animation_name):
		print("Warning: Animation '", animation_name, "' not found!")
		return
	
	# Don't restart the same animation
	if current_animation == animation_name and animation_player.is_playing():
		return
	
	current_animation = animation_name
	
	# Play the animation with smooth transition
	if animation_player.current_animation != "":
		# Blend from current animation to new one
		animation_player.play(animation_name, animation_transition_speed)
	else:
		# No current animation, just play
		animation_player.play(animation_name)

func _apply_basic_collision_avoidance(desired_direction: Vector3) -> Vector3:
	# Simplified collision avoidance as backup to NavMesh
	var space_state = get_world_3d().direct_space_state
	var avoidance_direction = Vector3.ZERO
	
	# Check for walls/obstacles ahead
	var wall_check_start = global_position + Vector3(0, 0.5, 0)
	var wall_check_end = wall_check_start + desired_direction * wall_check_distance
	
	var wall_query = PhysicsRayQueryParameters3D.create(wall_check_start, wall_check_end)
	wall_query.exclude = [self]
	var wall_result = space_state.intersect_ray(wall_query)
	
	if wall_result:
		# Hit a wall, add avoidance force
		var wall_normal = wall_result.normal
		avoidance_direction += wall_normal * avoidance_force
	
	# Combine desired direction with avoidance
	var final_direction = desired_direction + avoidance_direction
	return final_direction.normalized()

func _add_human_like_imprecision(direction: Vector3) -> Vector3:
	# Add slight random variations to simulate human imprecision
	var noise_x = sin(movement_timer * 2.0 + randf() * 10.0) * 0.1
	var noise_z = cos(movement_timer * 1.5 + randf() * 10.0) * 0.1
	
	direction.x += noise_x * movement_variation
	direction.z += noise_z * movement_variation
	
	return direction.normalized()

func _add_movement_variation() -> void:
	# Add random variation to current movement direction
	var random_angle = randf_range(-PI/6, PI/6)  # ±30 degrees
	target_direction = target_direction.rotated(Vector3.UP, random_angle)

func _start_pause() -> void:
	is_paused = true
	pause_timer = randf_range(pause_duration_range.x, pause_duration_range.y)

func _apply_deceleration(delta: float) -> void:
	current_velocity = current_velocity.move_toward(Vector3.ZERO, deceleration * delta)
	velocity.x = current_velocity.x
	velocity.z = current_velocity.z

func _pick_new_target() -> void:
	if not navigation_agent or is_dead:
		return
		
	var attempts = 0
	var max_attempts = 20
	
	while attempts < max_attempts:
		# Pick a random target within max_distance
		var random_offset = Vector3(
			randf_range(-max_distance, max_distance),
			0,
			randf_range(-max_distance, max_distance)
		)
		var potential_target = global_position + random_offset
		
		# Use NavigationServer3D to check if the target is on the NavMesh
		var nav_map = navigation_agent.get_navigation_map()
		var closest_point = NavigationServer3D.map_get_closest_point(nav_map, potential_target)
		
		# Check if the closest point on navmesh is reasonably close to our desired target
		var distance_to_navmesh = potential_target.distance_to(closest_point)
		
		if distance_to_navmesh < navmesh_sample_distance:
			# Target is close enough to NavMesh, use the closest point on NavMesh
			final_target = closest_point
			navigation_agent.target_position = final_target
			return
		
		attempts += 1
	
	# If no good target found, pick a nearby spawn position
	if spawn_positions.size() > 0:
		final_target = spawn_positions[randi() % spawn_positions.size()]
		navigation_agent.target_position = final_target
	else:
		# Last resort: stay near current position
		var nav_map = navigation_agent.get_navigation_map()
		final_target = NavigationServer3D.map_get_closest_point(nav_map, global_position)
		navigation_agent.target_position = final_target

func _on_target_reached() -> void:
	# Called when the navigation agent reaches its target
	_pick_new_target()

func _on_navigation_finished() -> void:
	# Called when navigation is complete
	_pick_new_target()

func get_random_spawn_position() -> Vector3:
	if spawn_positions.size() == 0:
		return Vector3.ZERO
	return spawn_positions[randi() % spawn_positions.size()]

func _set_npc_color(new_color: Color) -> void:
	npc_color = new_color
	if mesh_instance:
		var material = mesh_instance.get_surface_override_material(0)
		if material == null:
			material = StandardMaterial3D.new()
			mesh_instance.set_surface_override_material(0, material)
		material.albedo_color = new_color

func _set_synced_mesh_index(new_index: int) -> void:
	synced_mesh_index = new_index
	selected_mesh_index = new_index
	
	# Apply the mesh selection on all clients
	if available_meshes.size() == 0:
		_setup_random_mesh()  # Initialize meshes if not done yet
	
	# Hide all meshes
	for mesh in available_meshes:
		if is_instance_valid(mesh):
			mesh.visible = false
	
	# Show the selected mesh
	if selected_mesh_index >= 0 and selected_mesh_index < available_meshes.size():
		if is_instance_valid(available_meshes[selected_mesh_index]):
			available_meshes[selected_mesh_index].visible = true

func _handle_death_state(delta: float) -> void:
	# Stop all movement
	current_velocity = Vector3.ZERO
	velocity.x = 0.0
	velocity.z = 0.0
	
	# Apply gravity so the NPC falls to ground if needed
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	
	# Keep the NPC on the last frame of the death animation
	move_and_slide()

func _start_death_sequence() -> void:
	if is_dead:
		return  # Already dead
	
	is_dead = true
	
	# Stop navigation
	if navigation_agent:
		navigation_agent.target_position = global_position
	
	# Disable collision layer so other things can pass through the dead NPC
	# but keep collision mask so the NPC still detects the floor
	collision_layer = 0
	# collision_mask stays the same so NPC can still detect ground
	
	# Play death animation (will stay on last frame when finished)
	_play_animation(death_animation_name)
	
	# Sync death state to all clients via RPC
	sync_death_state.rpc()

func _set_synced_death_state(new_death_state: bool) -> void:
	synced_is_dead = new_death_state
	
	if new_death_state and not is_dead:
		# Apply death state on client
		is_dead = true
		
		# Stop navigation on client
		if navigation_agent:
			navigation_agent.target_position = global_position
		
		# Disable collision layer on client so things can pass through
		# but keep collision mask so NPC still detects ground
		collision_layer = 0
		# collision_mask stays the same so NPC can still detect ground
		
		# Play death animation on client
		_play_animation(death_animation_name)

@rpc("any_peer", "call_local")
func recieve_damage(damage: int = 1) -> void:
	if not multiplayer.is_server():
		return
	
	if is_dead:
		return  # Already dead, ignore damage
	
	health -= damage
	if health <= 0:
		# Start death sequence instead of immediately destroying
		_start_death_sequence()

@rpc("call_local")
func destroy_npc() -> void:
	super.queue_free()

# Debug function - call this manually if needed
func force_sync_mesh() -> void:
	if multiplayer.is_server() and selected_mesh_index >= 0:
		print("Force syncing mesh index: ", selected_mesh_index)
		sync_mesh_selection.rpc(selected_mesh_index)
