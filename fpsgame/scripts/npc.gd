extends CharacterBody3D

@export var speed: float = 3.0
@export var max_distance: float = 50.0
@export var wait_time: float = 2.0
@export var gravity: float = 9.8
@export var health: int = 1

# Movement behavior parameters
@export var acceleration: float = 15.0
@export var deceleration: float = 20.0
@export var direction_change_chance: float = 0.02
@export var stop_chance: float = 0.001
@export var pause_duration_range: Vector2 = Vector2(0.5, 3.0)
@export var movement_variation: float = 0.3

# Rotation parameters
@export var rotation_speed: float = 8.0
@export var min_movement_threshold: float = 0.1

# Animation parameters
@export var idle_animation_name: String = "Idle_A"
@export var walk_animation_name: String = "Walk_A"
@export var death_animation_name: String = "Death_A"
@export var animation_transition_speed: float = 0.3

# NavMesh parameters
@export var path_update_distance: float = 2.0
@export var navmesh_sample_distance: float = 5.0

# Collision avoidance parameters
@export var wall_check_distance: float = 2.0
@export var ledge_check_distance: float = 1.5
@export var avoidance_force: float = 3.0

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
var mesh_setup_complete: bool = false

# Navigation state
var current_path: PackedVector3Array = PackedVector3Array()
var path_index: int = 0
var final_target: Vector3

# Target selection
var spawn_positions: Array[Vector3] = []
var target_reached_threshold: float = 2.0

# Synced properties
@export var npc_color: Color = Color.WHITE : set = _set_npc_color
@export var synced_mesh_index: int = -1 : set = _set_synced_mesh_index
@export var synced_is_dead: bool = false : set = _set_synced_death_state
@export var synced_is_moving: bool = false : set = _set_synced_is_moving
@export var synced_position: Vector3 = Vector3.ZERO : set = _set_synced_position

func _ready() -> void:
	_collect_spawn_positions()
	
	# Initialize position first
	if multiplayer.is_server():
		if spawn_positions.size() > 0:
			position = spawn_positions[randi() % spawn_positions.size()]
		else:
			position = Vector3.ZERO
	
	# Set up multiplayer authority
	if multiplayer.is_server():
		set_multiplayer_authority(multiplayer.get_unique_id())
	
	# Wait for multiplayer to be properly set up
	await get_tree().process_frame
	await get_tree().process_frame  # Extra frame for safety
	
	# Setup mesh selection with proper timing
	_setup_mesh_system()
	
	# Setup navigation
	if navigation_agent:
		call_deferred("_setup_navigation")
	
	# Initialize animation
	if animation_player:
		_play_animation(idle_animation_name)
	
	# Set random color on server
	if multiplayer.is_server():
		npc_color = possible_colors[randi() % possible_colors.size()]

func _setup_mesh_system() -> void:
	# First, collect available meshes
	_collect_available_meshes()
	
	if available_meshes.size() == 0:
		print("ERROR: No meshes found for NPC!")
		return
	
	if multiplayer.is_server():
		# Server selects and syncs the mesh
		_server_select_and_sync_mesh()
	else:
		# Client waits for server's mesh selection
		_wait_for_mesh_sync()

func _collect_available_meshes() -> void:
	available_meshes.clear()
	
	if not skeleton:
		print("WARNING: Skeleton3D node not found")
		return
	
	# Collect all mesh children under the skeleton
	for child in skeleton.get_children():
		if child is MeshInstance3D:
			available_meshes.append(child)
			child.visible = false  # Hide all meshes initially
	
	print("Found ", available_meshes.size(), " meshes under Skeleton3D")

func _server_select_and_sync_mesh() -> void:
	if available_meshes.size() == 0:
		return
	
	# Select random mesh
	selected_mesh_index = randi() % available_meshes.size()
	synced_mesh_index = selected_mesh_index  # Update synced property
	
	# Show the selected mesh locally
	_show_mesh_at_index(selected_mesh_index)
	
	# Wait a moment for clients to be ready, then sync
	await get_tree().create_timer(0.5).timeout
	_sync_mesh_to_all_clients()
	
	mesh_setup_complete = true
	print("Server: Mesh setup complete for index: ", selected_mesh_index)

func _wait_for_mesh_sync() -> void:
	# Client waits for server to send mesh selection
	var timeout = 0.0
	var max_wait = 10.0  # 10 second timeout
	
	while synced_mesh_index == -1 and timeout < max_wait:
		await get_tree().process_frame
		timeout += get_process_delta_time()
	
	if synced_mesh_index != -1:
		_show_mesh_at_index(synced_mesh_index)
		mesh_setup_complete = true
		print("Client: Received mesh index: ", synced_mesh_index)
	else:
		print("Client: Timeout waiting for mesh sync, using fallback")
		_use_fallback_mesh()

func _use_fallback_mesh() -> void:
	# Fallback: show first available mesh
	if available_meshes.size() > 0:
		_show_mesh_at_index(0)
		mesh_setup_complete = true

func _show_mesh_at_index(index: int) -> void:
	if index < 0 or index >= available_meshes.size():
		return
	
	# Hide all meshes
	for mesh in available_meshes:
		if is_instance_valid(mesh):
			mesh.visible = false
	
	# Show selected mesh
	if is_instance_valid(available_meshes[index]):
		available_meshes[index].visible = true
		selected_mesh_index = index

@rpc("call_local", "reliable")
func _sync_mesh_to_all_clients() -> void:
	if multiplayer.is_server():
		_receive_mesh_sync.rpc(selected_mesh_index)

@rpc("call_local", "reliable")
func _receive_mesh_sync(mesh_index: int) -> void:
	print("Received mesh sync for index: ", mesh_index)
	synced_mesh_index = mesh_index
	_show_mesh_at_index(mesh_index)
	mesh_setup_complete = true

@rpc("call_local", "reliable")
func sync_death_animation() -> void:
	# Force death animation on all clients
	if not multiplayer.is_server():
		is_dead = true
		collision_layer = 0
		_play_animation(death_animation_name)
		print("Client: Received death animation sync")

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
		if multiplayer.is_server():
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

func _physics_process(delta: float) -> void:
	# Don't process if mesh setup isn't complete
	if not mesh_setup_complete:
		return
	
	if multiplayer.is_server():
		_server_physics_process(delta)
	else:
		_client_physics_process(delta)

func _server_physics_process(delta: float) -> void:
	# Handle death state
	if is_dead:
		_handle_death_state(delta)
		synced_is_moving = false
		synced_position = global_position
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
			_pick_new_target()
		_apply_deceleration(delta)
		_update_animation_and_rotation(delta)
		synced_is_moving = false
		move_and_slide()
		synced_position = global_position
		return
	
	# Random chance to pause
	if randf() < stop_chance:
		_start_pause()
		return
	
	# Navigate using NavigationAgent3D
	if navigation_agent and not navigation_agent.is_navigation_finished():
		_navigate_to_target(delta)
	else:
		_pick_new_target()
	
	# Update animation and rotation based on movement
	_update_animation_and_rotation(delta)
	
	# Sync movement state to clients
	var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
	synced_is_moving = horizontal_velocity.length() > min_movement_threshold
	
	move_and_slide()
	synced_position = global_position

func _client_physics_process(delta: float) -> void:
	# Clients only handle animations and position interpolation
	if is_dead:
		# Make sure death animation stays playing
		if current_animation != death_animation_name:
			_play_animation(death_animation_name)
		return
	
	# Interpolate position smoothly
	global_position = global_position.lerp(synced_position, 10.0 * delta)
	
	# Update animations based on synced movement state
	_update_client_animation()

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
		animation_player.play(animation_name, animation_transition_speed)
	else:
		animation_player.play(animation_name)

func _apply_basic_collision_avoidance(desired_direction: Vector3) -> Vector3:
	var space_state = get_world_3d().direct_space_state
	var avoidance_direction = Vector3.ZERO
	
	var wall_check_start = global_position + Vector3(0, 0.5, 0)
	var wall_check_end = wall_check_start + desired_direction * wall_check_distance
	
	var wall_query = PhysicsRayQueryParameters3D.create(wall_check_start, wall_check_end)
	wall_query.exclude = [self]
	var wall_result = space_state.intersect_ray(wall_query)
	
	if wall_result:
		var wall_normal = wall_result.normal
		avoidance_direction += wall_normal * avoidance_force
	
	var final_direction = desired_direction + avoidance_direction
	return final_direction.normalized()

func _add_human_like_imprecision(direction: Vector3) -> Vector3:
	var noise_x = sin(movement_timer * 2.0 + randf() * 10.0) * 0.1
	var noise_z = cos(movement_timer * 1.5 + randf() * 10.0) * 0.1
	
	direction.x += noise_x * movement_variation
	direction.z += noise_z * movement_variation
	
	return direction.normalized()

func _add_movement_variation() -> void:
	var random_angle = randf_range(-PI/6, PI/6)
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
		var random_offset = Vector3(
			randf_range(-max_distance, max_distance),
			0,
			randf_range(-max_distance, max_distance)
		)
		var potential_target = global_position + random_offset
		
		var nav_map = navigation_agent.get_navigation_map()
		var closest_point = NavigationServer3D.map_get_closest_point(nav_map, potential_target)
		
		var distance_to_navmesh = potential_target.distance_to(closest_point)
		
		if distance_to_navmesh < navmesh_sample_distance:
			final_target = closest_point
			navigation_agent.target_position = final_target
			return
		
		attempts += 1
	
	# Fallback to spawn position
	if spawn_positions.size() > 0:
		final_target = spawn_positions[randi() % spawn_positions.size()]
		navigation_agent.target_position = final_target
	else:
		var nav_map = navigation_agent.get_navigation_map()
		final_target = NavigationServer3D.map_get_closest_point(nav_map, global_position)
		navigation_agent.target_position = final_target

func _on_target_reached() -> void:
	_pick_new_target()

func _on_navigation_finished() -> void:
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
	var old_index = synced_mesh_index
	synced_mesh_index = new_index
	
	# Only apply if this is a new value and we have meshes available
	if old_index != new_index and available_meshes.size() > 0:
		_show_mesh_at_index(new_index)

func _handle_death_state(delta: float) -> void:
	current_velocity = Vector3.ZERO
	velocity.x = 0.0
	velocity.z = 0.0
	
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	
	move_and_slide()

func _start_death_sequence() -> void:
	if is_dead:
		return
	
	is_dead = true
	synced_is_dead = true  # Sync to clients
	synced_is_moving = false  # Stop movement animation
	
	if navigation_agent:
		navigation_agent.target_position = global_position
	
	collision_layer = 0
	_play_animation(death_animation_name)
	
	# Explicitly sync death animation to all clients
	sync_death_animation.rpc()

func _update_client_animation() -> void:
	# Update animation based on synced movement state
	var desired_animation = walk_animation_name if synced_is_moving else idle_animation_name
	if desired_animation != current_animation:
		_play_animation(desired_animation)

func _set_synced_is_moving(new_moving_state: bool) -> void:
	synced_is_moving = new_moving_state
	# If this is a client, update animation immediately (but not if dead)
	if not multiplayer.is_server() and not is_dead:
		_update_client_animation()

func _set_synced_position(new_position: Vector3) -> void:
	synced_position = new_position

func _set_synced_death_state(new_death_state: bool) -> void:
	var old_state = synced_is_dead
	synced_is_dead = new_death_state
	
	if old_state != new_death_state and new_death_state and not is_dead:
		is_dead = true
		
		if navigation_agent:
			navigation_agent.target_position = global_position
		
		collision_layer = 0
		_play_animation(death_animation_name)

@rpc("any_peer", "call_local", "reliable")
func recieve_damage(damage: int = 1) -> void:
	if not multiplayer.is_server():
		return
	
	if is_dead:
		return
	
	health -= damage
	if health <= 0:
		_start_death_sequence()

@rpc("call_local", "reliable")
func destroy_npc() -> void:
	super.queue_free()
