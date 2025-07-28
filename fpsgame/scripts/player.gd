extends CharacterBody3D

@onready var camera: Camera3D = $Camera3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var muzzle_flash: GPUParticles3D = $Camera3D/pistol/GPUParticles3D
@onready var raycast: RayCast3D = $Camera3D/RayCast3D
@onready var gunshot_sound: AudioStreamPlayer3D = %GunshotSound
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer

## Number of shots before a player dies
@export var health: int = 1
## Reference to the NavigationRegion3D node in the scene
@export var navigation_region: NavigationRegion3D
## Maximum attempts to find a valid spawn point
@export var max_spawn_attempts: int = 50
## Minimum distance from other players when spawning
@export var min_spawn_distance: float = 3.0

## Predefined set of colors for the player
@export var possible_colors: Array[Color] = [
	Color.RED,
	Color.BLUE,
	Color.GREEN,
	Color.YELLOW,
	Color.PURPLE,
	Color.CYAN,
	Color.ORANGE
]
## Synced property for player color
@export var player_color: Color = Color.WHITE : set = _set_player_color

# Local variable to track if this player should have a gun visible
var has_gun_visible: bool = true

var sensitivity: float = 0.005
var controller_sensitivity: float = 0.010
var axis_vector: Vector2
var mouse_captured: bool = true

const SPEED = 5.0
const JUMP_VELOCITY = 4.5

func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())

func _ready() -> void:
	if not is_multiplayer_authority():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera.current = true
	
	# Try to find NavigationRegion3D if not assigned
	if navigation_region == null:
		navigation_region = find_navigation_region()
	
	# Set initial spawn position
	position = get_random_nav_position()
	
	if mesh_instance == null:
		print("ERROR: MeshInstance3D not found! Check node setup for peer: ", multiplayer.get_unique_id())
		return
	if synchronizer == null:
		print("ERROR: MultiplayerSynchronizer not found! Check node setup for peer: ", multiplayer.get_unique_id())
		return
	
	# Delay the setup to ensure everything is properly initialized
	await get_tree().process_frame
	setup_player_role()

func find_navigation_region() -> NavigationRegion3D:
	# Try to find NavigationRegion3D in the scene
	var nav_region = get_tree().get_first_node_in_group("navigation")
	if nav_region and nav_region is NavigationRegion3D:
		return nav_region
	
	# Alternative: search in the scene tree
	var root = get_tree().current_scene
	return find_node_of_type(root, NavigationRegion3D) as NavigationRegion3D

func find_node_of_type(node: Node, node_type) -> Node:
	if node is NavigationRegion3D:
		return node
	for child in node.get_children():
		var result = find_node_of_type(child, node_type)
		if result:
			return result
	return null

func get_random_nav_position() -> Vector3:
	if navigation_region == null:
		print("WARNING: No NavigationRegion3D found! Using fallback position.")
		return Vector3.ZERO
	
	var nav_map = navigation_region.get_navigation_map()
	if nav_map == RID():
		print("WARNING: Navigation map not ready! Using fallback position.")
		return Vector3.ZERO
	
	# Get the AABB of the navigation mesh
	var nav_mesh = navigation_region.navigation_mesh
	if nav_mesh == null:
		print("WARNING: No navigation mesh found! Using fallback position.")
		return Vector3.ZERO
	
	# Try multiple attempts to find a valid position
	for attempt in max_spawn_attempts:
		var random_pos = get_random_position_in_bounds()
		var closest_point = NavigationServer3D.map_get_closest_point(nav_map, random_pos)
		
		# Check if the point is valid and not too close to other players
		if is_valid_spawn_position(closest_point):
			return closest_point
	
	print("WARNING: Could not find valid spawn position after ", max_spawn_attempts, " attempts. Using fallback.")
	return Vector3.ZERO

func get_random_position_in_bounds() -> Vector3:
	# Generate a random position within reasonable bounds
	# You may want to adjust these bounds based on your level size
	var bounds_size = Vector3(20, 5, 20)  # Adjust based on your level
	var bounds_center = Vector3.ZERO      # Adjust based on your level center
	
	return Vector3(
		bounds_center.x + randf_range(-bounds_size.x, bounds_size.x),
		bounds_center.y + randf_range(-bounds_size.y, bounds_size.y),
		bounds_center.z + randf_range(-bounds_size.z, bounds_size.z)
	)

func is_valid_spawn_position(pos: Vector3) -> bool:
	# Check if position is far enough from other players
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if player != self and player.global_position.distance_to(pos) < min_spawn_distance:
			return false
	return true

func _process(_delta: float) -> void:
	sensitivity = Global.sensitivity
	controller_sensitivity = Global.controller_sensitivity
	rotate_y(-axis_vector.x * controller_sensitivity)
	camera.rotate_x(-axis_vector.y * controller_sensitivity)
	camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	axis_vector = Input.get_vector("look_left", "look_right", "look_up", "look_down")

	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * sensitivity)
		camera.rotate_x(-event.relative.y * sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)

	if Input.is_action_just_pressed("shoot") and anim_player.current_animation != "shoot" and has_gun():
		play_shoot_effects.rpc()
		gunshot_sound.play()
		if raycast.is_colliding():
			var hit_collider = raycast.get_collider()
			if hit_collider and hit_collider is CharacterBody3D:
				var target_id = hit_collider.get_multiplayer_authority()
				print("Hit collider: ", hit_collider, " | Authority: ", target_id)
				hit_collider.recieve_damage.rpc_id(target_id, 1)

	if Input.is_action_just_pressed("respawn"):
		recieve_damage(2)

	if Input.is_action_just_pressed("capture"):
		if mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			mouse_captured = false
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null:
		if not is_multiplayer_authority():
			return
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	var input_dir := Input.get_vector("left", "right", "up", "down")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y))
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	if anim_player.current_animation == "shoot":
		pass
	elif input_dir != Vector2.ZERO and is_on_floor():
		anim_player.play("move")
	else:
		anim_player.play("idle")
	move_and_slide()

@rpc("call_local")
func play_shoot_effects() -> void:
	anim_player.stop()
	anim_player.play("shoot")
	muzzle_flash.restart()
	muzzle_flash.emitting = true

@rpc("any_peer", "call_local")
func recieve_damage(damage: int = 1) -> void:
	health -= damage
	if health <= 0:
		health = 2
		position = get_random_nav_position()  # Use random nav position instead of spawns array
		assign_player_color()

func setup_player_role() -> void:
	if not is_multiplayer_authority():
		return
	
	if multiplayer.is_server():
		# Host gets specific color (RED) and keeps gun visible
		player_color = Color.RED
		_set_player_color(Color.RED)
		has_gun_visible = true
		print("Host assigned RED color and gun for peer: ", multiplayer.get_unique_id())
	else:
		# Client gets random color and NO gun visible
		assign_random_color()
		has_gun_visible = false
		# Tell everyone to hide this player's gun
		set_gun_visibility.rpc(false)
		print("Client assigned no gun for peer: ", multiplayer.get_unique_id())

func assign_player_color() -> void:
	if not is_multiplayer_authority():
		return
	
	if multiplayer.is_server():
		# Host always gets RED
		player_color = Color.RED
		_set_player_color(Color.RED)
	else:
		# Client gets random color
		assign_random_color()

func assign_random_color() -> void:
	# Only the authority (owner) of this player should assign colors
	if not is_multiplayer_authority():
		return
	var new_color = possible_colors[randi() % possible_colors.size()]
	player_color = new_color
	_set_player_color(new_color)
	print("Assigned color: ", new_color, " for peer: ", multiplayer.get_unique_id())

func has_gun() -> bool:
	# Only the host (server) has a gun and can shoot
	return multiplayer.is_server() and is_multiplayer_authority()

@rpc("any_peer", "call_local")
func set_gun_visibility(visible: bool) -> void:
	has_gun_visible = visible
	var pistol = camera.get_node_or_null("pistol")
	if pistol:
		pistol.visible = visible
		print("Gun visibility set to: ", visible, " for peer: ", multiplayer.get_unique_id())

func hide_gun() -> void:
	# Hide the gun for clients
	set_gun_visibility.rpc(false)

func _set_player_color(new_color: Color) -> void:
	player_color = new_color
	if mesh_instance:
		var material = mesh_instance.get_surface_override_material(0)
		if material == null:
			material = StandardMaterial3D.new()
			mesh_instance.set_surface_override_material(0, material)
		material.albedo_color = new_color
		print("Player color set to: ", new_color, " for peer: ", multiplayer.get_unique_id())
	else:
		print("ERROR: MeshInstance3D is null for peer: ", multiplayer.get_unique_id())
