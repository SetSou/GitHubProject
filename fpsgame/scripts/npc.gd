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
@export var speed_variation: float = 0.4  # Speed multiplier variation (0.6 to 1.4 of base speed)

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

# Movement state
var target_direction: Vector3 = Vector3.ZERO
var current_velocity: Vector3 = Vector3.ZERO
var is_paused: bool = false
var pause_timer: float = 0.0
var movement_timer: float = 0.0
var current_speed_multiplier: float = 1.0

# Target selection
var spawn_positions: Array[Vector3] = []
var current_target: Vector3
var target_reached_threshold: float = 2.0

# Synced property for NPC color
@export var npc_color: Color = Color.WHITE : set = _set_npc_color

func _ready() -> void:
	_collect_spawn_positions()
	
	if not multiplayer.is_server():
		return
		
	set_multiplayer_authority(multiplayer.get_unique_id())
	
	# Use collected spawn positions for initial spawn
	if spawn_positions.size() > 0:
		position = spawn_positions[randi() % spawn_positions.size()]
	else:
		#print("WARNING: No SpawnPoint nodes found in group 'SpawnPoint'. Using default position.")
		position = Vector3.ZERO
	
	if mesh_instance == null:
		#print("ERROR: MeshInstance3D not found! Check node setup.")
		return
	if synchronizer == null:
		#wprint("ERROR: MultiplayerSynchronizer not found! Check node setup.")
		return
	
	# Set random color on server
	npc_color = possible_colors[randi() % possible_colors.size()]
	_pick_new_target()
	_randomize_movement_parameters()

func _collect_spawn_positions() -> void:
	spawn_positions.clear()
	var spawn_nodes = get_tree().get_nodes_in_group("SpawnPoint")
	
	if spawn_nodes.size() == 0:
		print("WARNING: No nodes found in group 'SpawnPoint'.")
		return
	
	for node in spawn_nodes:
		if node is Node3D:
			spawn_positions.append(node.global_position)

func _randomize_movement_parameters() -> void:
	# Randomize speed to make each NPC move slightly differently
	current_speed_multiplier = randf_range(1.0 - speed_variation, 1.0 + speed_variation)
	#print("NPC speed multiplier: ", current_speed_multiplier)

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
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
		move_and_slide()
		return
	
	# Random chance to pause (simulate player stopping to look around)
	if randf() < stop_chance:
		_start_pause()
		return
	
	# Check if we've reached our target
	var distance_to_target = global_position.distance_to(current_target)
	if distance_to_target < target_reached_threshold:
		_pick_new_target()
		return
	
	# Random direction changes (simulate human imprecision)
	if randf() < direction_change_chance:
		_add_movement_variation()
	
	# Update movement timer
	movement_timer += delta
	
	# Calculate desired direction with some human-like imprecision
	var desired_direction = (current_target - global_position).normalized()
	desired_direction = _add_human_like_imprecision(desired_direction)
	
	# Apply collision avoidance
	desired_direction = _apply_collision_avoidance(desired_direction)
	
	# Update target direction with some smoothing
	target_direction = target_direction.lerp(desired_direction, 3.0 * delta)
	target_direction = target_direction.normalized()
	
	# Apply acceleration/deceleration
	var target_velocity = target_direction * speed * current_speed_multiplier
	
	if target_velocity.length() > 0.1:
		current_velocity = current_velocity.move_toward(target_velocity, acceleration * delta)
	else:
		current_velocity = current_velocity.move_toward(Vector3.ZERO, deceleration * delta)
	
	# Apply velocity
	velocity.x = current_velocity.x
	velocity.z = current_velocity.z
	
	move_and_slide()

func _apply_collision_avoidance(desired_direction: Vector3) -> Vector3:
	var space_state = get_world_3d().direct_space_state
	var avoidance_direction = Vector3.ZERO
	
	# Check for walls/obstacles ahead
	var wall_check_start = global_position + Vector3(0, 0.5, 0)  # Check at chest height
	var wall_check_end = wall_check_start + desired_direction * wall_check_distance
	
	var wall_query = PhysicsRayQueryParameters3D.create(wall_check_start, wall_check_end)
	wall_query.exclude = [self]  # Don't collide with self
	var wall_result = space_state.intersect_ray(wall_query)
	
	if wall_result:
		# Hit a wall, add avoidance force
		var wall_normal = wall_result.normal
		avoidance_direction += wall_normal * avoidance_force
		#print("NPC avoiding wall, normal: ", wall_normal)
	
	# Check for ledges/drops ahead
	var ledge_check_start = global_position + desired_direction * ledge_check_distance + Vector3(0, 0.2, 0)
	var ledge_check_end = ledge_check_start + Vector3(0, -2.0, 0)  # Check 2 units down
	
	var ledge_query = PhysicsRayQueryParameters3D.create(ledge_check_start, ledge_check_end)
	ledge_query.exclude = [self]
	var ledge_result = space_state.intersect_ray(ledge_query)
	
	if not ledge_result:
		# No ground ahead, avoid this direction
		var perpendicular = Vector3(-desired_direction.z, 0, desired_direction.x)
		avoidance_direction += perpendicular * avoidance_force
		#print("NPC avoiding ledge")
	
	# Also check left and right for additional wall avoidance
	var left_direction = desired_direction.rotated(Vector3.UP, PI/4)  # 45 degrees left
	var right_direction = desired_direction.rotated(Vector3.UP, -PI/4)  # 45 degrees right
	
	for check_dir in [left_direction, right_direction]:
		var side_check_end = wall_check_start + check_dir * (wall_check_distance * 0.7)
		var side_query = PhysicsRayQueryParameters3D.create(wall_check_start, side_check_end)
		side_query.exclude = [self]
		var side_result = space_state.intersect_ray(side_query)
		
		if side_result:
			avoidance_direction += side_result.normal * (avoidance_force * 0.5)
	
	# Combine desired direction with avoidance
	var final_direction = desired_direction + avoidance_direction
	
	# If we're being pushed in the opposite direction, pick a new target
	if final_direction.dot(desired_direction) < 0.3:
		_pick_new_target()
		return Vector3.ZERO  # Stop moving this frame
	
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
	#print("NPC pausing for ", pause_timer, " seconds")

func _apply_deceleration(delta: float) -> void:
	current_velocity = current_velocity.move_toward(Vector3.ZERO, deceleration * delta)
	velocity.x = current_velocity.x
	velocity.z = current_velocity.z

func _pick_new_target() -> void:
	var attempts = 0
	var max_attempts = 10
	
	while attempts < max_attempts:
		# Pick a random target within max_distance
		var random_offset = Vector3(
			randf_range(-max_distance, max_distance),
			0,
			randf_range(-max_distance, max_distance)
		)
		var potential_target = global_position + random_offset
		
		# Check if the target is reachable (has ground beneath it)
		if _is_target_safe(potential_target):
			current_target = potential_target
			_randomize_movement_parameters()
			#print("NPC new target: ", current_target, " | Speed multiplier: ", current_speed_multiplier)
			return
		
		attempts += 1
	
	# If no safe target found, just pick a closer one
	var safe_offset = Vector3(
		randf_range(-max_distance * 0.3, max_distance * 0.3),
		0,
		randf_range(-max_distance * 0.3, max_distance * 0.3)
	)
	current_target = global_position + safe_offset
	_randomize_movement_parameters()
	#print("NPC fallback target: ", current_target)

func _is_target_safe(target_pos: Vector3) -> bool:
	var space_state = get_world_3d().direct_space_state
	
	# Check if there's ground at the target position
	var ground_check_start = target_pos + Vector3(0, 1.0, 0)
	var ground_check_end = target_pos + Vector3(0, -2.0, 0)
	
	var ground_query = PhysicsRayQueryParameters3D.create(ground_check_start, ground_check_end)
	var ground_result = space_state.intersect_ray(ground_query)
	
	return ground_result != null  # True if there's ground

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

@rpc("any_peer", "call_local")
func recieve_damage(damage: int = 1) -> void:
	if not multiplayer.is_server():
		return
	health -= damage
	#print("NPC hit! Health: ", health, " | Peer: ", multiplayer.get_remote_sender_id())
	if health <= 0:
		health = 2
		#print("NPC health <= 0, removing NPC at position: ", global_position)
		destroy_npc.rpc()
		destroy_npc()

@rpc("call_local")
func destroy_npc() -> void:
	super.queue_free()
