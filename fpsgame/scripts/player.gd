extends CharacterBody3D

@onready var camera: Camera3D = $Camera3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var muzzle_flash: GPUParticles3D = $Camera3D/pistol/GPUParticles3D
@onready var raycast: RayCast3D = $Camera3D/RayCast3D
@onready var gunshot_sound: AudioStreamPlayer3D = %GunshotSound
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer
@onready var skeleton: Skeleton3D = $Character_1_2_22/CharacterArmature1/Skeleton3D

## Number of shots before a player dies
@export var health: int = 1
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

# Movement parameters - MUST match NPC values exactly
const BASE_SPEED = 3.0  # Same as NPC speed
const ACCELERATION = 15.0  # Same as NPC acceleration
const DECELERATION = 20.0  # Same as NPC deceleration
const JUMP_VELOCITY = 4.5
const GRAVITY = 9.8  # Same as NPC gravity

# Array to store spawn positions from SpawnPoint nodes
var spawn_positions: Array[Vector3] = []

# Local variable to track if this player should have a gun visible
var has_gun_visible: bool = true

# Movement state variables to match NPC behavior
var current_velocity: Vector3 = Vector3.ZERO

var sensitivity: float = 0.005
var controller_sensitivity: float = 0.010
var axis_vector: Vector2
var mouse_captured: bool = true

# Skin selection variables
var available_skins: Array[Node] = []
var selected_skin_index: int = -1
var skin_setup_complete: bool = false

# Synced properties for skin system
@export var synced_skin_index: int = -1 : set = _set_synced_skin_index

func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())

func _ready() -> void:
	# Collect spawn positions from SpawnPoint nodes
	_collect_spawn_positions()
	
	# Wait for multiplayer to be ready
	await get_tree().process_frame
	await get_tree().process_frame
	
	# Setup skin system for all players
	_setup_skin_system()
	
	# Only setup controls and camera for the local player
	if is_multiplayer_authority():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		camera.current = true
		
		# Use collected spawn positions for initial spawn
		if spawn_positions.size() > 0:
			position = spawn_positions[randi() % spawn_positions.size()]
		else:
			print("WARNING: No SpawnPoint nodes found in group 'SpawnPoint'. Using default position.")
			position = Vector3.ZERO
		
		if mesh_instance == null:
			print("ERROR: MeshInstance3D not found! Check node setup for peer: ", multiplayer.get_unique_id())
			return
		if synchronizer == null:
			print("ERROR: MultiplayerSynchronizer not found! Check node setup for peer: ", multiplayer.get_unique_id())
			return
		
		# Setup player role after skin system
		call_deferred("setup_player_role")

func _setup_skin_system() -> void:
	print("Setting up skin system for player: ", name, " | Authority: ", multiplayer.get_unique_id(), " | Is local: ", is_multiplayer_authority())
	
	# First, collect available skins
	_collect_available_skins()
	
	if available_skins.size() == 0:
		print("ERROR: No skins found for Player!")
		return
	
	# Only the player's owner selects their skin
	if is_multiplayer_authority():
		if multiplayer.is_server():
			# Host gets the police skin (index 0)
			print("Host selecting police skin (index 0)")
			_select_and_sync_skin(0)
		else:
			# Client gets random skin (excluding police skin)
			var random_index = randi() % (available_skins.size() - 1) + 1  # Skip index 0 (police)
			print("Client selecting random skin (index ", random_index, ")")
			_select_and_sync_skin(random_index)
	
	# All instances wait for the skin sync and apply visibility rules
	_wait_and_apply_skin_visibility()

func _collect_available_skins() -> void:
	available_skins.clear()
	
	if not skeleton:
		print("WARNING: Skeleton3D node not found for player")
		return
	
	# Collect all mesh children under the skeleton
	for child in skeleton.get_children():
		if child is MeshInstance3D:
			available_skins.append(child)
			child.visible = false  # Hide all skins initially
	
	print("Player found ", available_skins.size(), " skins under Skeleton3D")

func _select_and_sync_skin(skin_index: int) -> void:
	if available_skins.size() == 0:
		return
	
	# Clamp skin index to valid range
	skin_index = clamp(skin_index, 0, available_skins.size() - 1)
	selected_skin_index = skin_index
	synced_skin_index = skin_index
	
	print("Player ", name, " selected skin index: ", skin_index)
	
	# Sync to all clients
	_broadcast_skin_selection.rpc(skin_index)

@rpc("call_local", "reliable")
func _broadcast_skin_selection(skin_index: int) -> void:
	print("Received skin broadcast for player ", name, ": index ", skin_index)
	synced_skin_index = skin_index
	selected_skin_index = skin_index
	
	# Apply visibility immediately
	_apply_skin_visibility()

func _wait_and_apply_skin_visibility() -> void:
	# Wait for skin selection
	var timeout = 0.0
	var max_wait = 5.0
	
	while synced_skin_index == -1 and timeout < max_wait:
		await get_tree().process_frame
		timeout += get_process_delta_time()
	
	if synced_skin_index != -1:
		_apply_skin_visibility()
		skin_setup_complete = true
		print("Skin setup complete for player ", name)
	else:
		print("Timeout waiting for skin sync for player ", name)

func _apply_skin_visibility() -> void:
	if available_skins.size() == 0 or selected_skin_index == -1:
		return
	
	# Hide all skins first
	for skin in available_skins:
		if is_instance_valid(skin):
			skin.visible = false
	
	# Determine if this player should be visible
	# Hide skin for the local player (first person view), show for others
	var should_show_skin = not is_multiplayer_authority()
	
	print("Player ", name, " skin visibility: ", should_show_skin, " (is_local: ", is_multiplayer_authority(), ")")
	
	# Show the selected skin if it should be visible
	if should_show_skin and selected_skin_index < available_skins.size():
		if is_instance_valid(available_skins[selected_skin_index]):
			available_skins[selected_skin_index].visible = true
			print("Showing skin index ", selected_skin_index, " for player ", name)

func _collect_spawn_positions() -> void:
	spawn_positions.clear()
	var spawn_nodes = get_tree().get_nodes_in_group("SpawnPoint")
	
	if spawn_nodes.size() == 0:
		print("WARNING: No nodes found in group 'SpawnPoint'. Make sure you have Node3D nodes added to the 'SpawnPoint' group.")
		return
	
	for node in spawn_nodes:
		if node is Node3D:
			spawn_positions.append(node.global_position)
			print("Added spawn position: ", node.global_position)
		else:
			print("WARNING: Node ", node.name, " in SpawnPoint group is not a Node3D")
	
	print("Total spawn positions collected: ", spawn_positions.size())

func get_random_spawn_position() -> Vector3:
	if spawn_positions.size() == 0:
		print("ERROR: No spawn positions available. Using Vector3.ZERO")
		return Vector3.ZERO
	return spawn_positions[randi() % spawn_positions.size()]

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
	
	# Apply gravity - same as NPCs
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0
	
	# Handle jumping
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	
	# Get input direction
	var input_dir := Input.get_vector("left", "right", "up", "down")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	# Calculate target velocity with consistent speed
	var target_velocity = Vector3.ZERO
	if direction.length() > 0.1:
		target_velocity = direction * BASE_SPEED
	
	# Apply acceleration/deceleration (same as NPCs)
	if target_velocity.length() > 0.1:
		current_velocity = current_velocity.move_toward(target_velocity, ACCELERATION * delta)
	else:
		current_velocity = current_velocity.move_toward(Vector3.ZERO, DECELERATION * delta)
	
	# Apply the calculated velocity
	velocity.x = current_velocity.x
	velocity.z = current_velocity.z
	
	# Handle animations
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
		health = 1
		position = get_random_spawn_position()
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

func _set_synced_skin_index(new_index: int) -> void:
	var old_index = synced_skin_index
	synced_skin_index = new_index
	selected_skin_index = new_index
	
	# Only apply if this is a new value and we have skins available
	if old_index != new_index and available_skins.size() > 0:
		_apply_skin_visibility()
