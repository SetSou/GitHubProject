extends CharacterBody3D

@onready var camera: Camera3D = $Camera3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var muzzle_flash: GPUParticles3D = $Camera3D/pistol/GPUParticles3D
@onready var raycast: RayCast3D = $Camera3D/RayCast3D
@onready var gunshot_sound: AudioStreamPlayer3D = %GunshotSound
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer
@onready var skeleton: Skeleton3D = $Character_1_2_22/CharacterArmature1/Skeleton3D

# UI Elements for bullet counter
@onready var bullet_ui: Control
@onready var bullet_label: Label
@onready var reload_progress: ProgressBar

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

# Bullet system constants
const MAX_BULLETS = 6  # Pistol magazine size
const RELOAD_TIME = 2.0  # Seconds to reload
const RELOAD_ANIMATION = "reload"  # Add this animation to your AnimationPlayer
const SHOOT_COOLDOWN = 0.1  # Minimum time between shots (prevents double shooting)

# Movement parameters - MUST match NPC values exactly
const BASE_SPEED = 3.0  # Same as NPC speed
const ACCELERATION = 15.0  # Same as NPC acceleration
const DECELERATION = 20.0  # Same as NPC deceleration
const JUMP_VELOCITY = 4.5
const GRAVITY = 9.8  # Same as NPC gravity

# Animation parameters - different sets for host vs clients
const HOST_IDLE_ANIMATION = "Pistol_Idle"
const HOST_WALK_ANIMATION = "Pistol_Walk" 
const CLIENT_IDLE_ANIMATION = "Idle_A"
const CLIENT_WALK_ANIMATION = "Walk_A"
const SHOOT_ANIMATION = "shoot"
const ANIMATION_TRANSITION_SPEED = 0.3

# Array to store spawn positions from SpawnPoint nodes
var spawn_positions: Array[Vector3] = []

# Local variable to track if this player should have a gun visible
var has_gun_visible: bool = true

# Bullet system variables
var current_bullets: int = MAX_BULLETS
var is_reloading: bool = false
var reload_timer: float = 0.0
var can_shoot_timer: float = 0.0  # Debounce timer to prevent double shooting
var last_shot_time: float = 0.0   # Track when we last shot

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

# Animation variables
var current_animation_name: String = ""
var is_moving_for_animation: bool = false

# FIXED: Added the missing synced properties that the MultiplayerSynchronizer expects
@export var synced_skin_index: int = -1 : set = _set_synced_skin_index
@export var synced_mesh_index: int = -1 : set = _set_synced_mesh_index

func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())

func _ready() -> void:
	# Collect spawn positions from SpawnPoint nodes
	_collect_spawn_positions()
	
	# Wait for multiplayer to be ready
	await get_tree().process_frame
	await get_tree().process_frame
	
	# Setup skin system - this needs to happen for ALL player instances
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
		
		# Setup bullet counter UI for the host (gun player)
		call_deferred("setup_bullet_ui")

func setup_bullet_ui() -> void:
	# Only show bullet UI for the player with the gun
	if not has_gun():
		return
	
	# Create UI elements
	bullet_ui = Control.new()
	bullet_ui.name = "BulletUI"
	bullet_ui.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	bullet_ui.position = Vector2(-150, 20)
	bullet_ui.size = Vector2(130, 80)
	
	# Create bullet counter label
	bullet_label = Label.new()
	bullet_label.name = "BulletLabel"
	bullet_label.text = str(current_bullets) + " / " + str(MAX_BULLETS)
	bullet_label.add_theme_font_size_override("font_size", 24)
	bullet_label.add_theme_color_override("font_color", Color.WHITE)
	bullet_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	bullet_label.add_theme_constant_override("shadow_offset_x", 2)
	bullet_label.add_theme_constant_override("shadow_offset_y", 2)
	bullet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bullet_label.size = Vector2(130, 30)
	
	# Create reload progress bar
	reload_progress = ProgressBar.new()
	reload_progress.name = "ReloadProgress"
	reload_progress.position = Vector2(0, 35)
	reload_progress.size = Vector2(130, 20)
	reload_progress.min_value = 0
	reload_progress.max_value = RELOAD_TIME
	reload_progress.value = 0
	reload_progress.visible = false
	
	# Add a background for better visibility
	var panel = Panel.new()
	panel.name = "Background"
	panel.position = Vector2(-5, -5)
	panel.size = Vector2(140, 90)
	panel.modulate = Color(0, 0, 0, 0.5)
	
	# Build UI hierarchy
	bullet_ui.add_child(panel)
	bullet_ui.add_child(bullet_label)
	bullet_ui.add_child(reload_progress)
	
	# Add to scene
	get_tree().current_scene.add_child(bullet_ui)
	
	print("Bullet UI created for host player")

func _process(delta: float) -> void:
	sensitivity = Global.sensitivity
	controller_sensitivity = Global.controller_sensitivity
	rotate_y(-axis_vector.x * controller_sensitivity)
	camera.rotate_x(-axis_vector.y * controller_sensitivity)
	camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)
	
	# Handle reload timer and UI updates
	if is_reloading:
		reload_timer -= delta
		if reload_progress:
			reload_progress.value = RELOAD_TIME - reload_timer
		
		if reload_timer <= 0:
			complete_reload()
	
	# Update shoot cooldown timer
	if can_shoot_timer > 0:
		can_shoot_timer -= delta

func complete_reload() -> void:
	is_reloading = false
	current_bullets = MAX_BULLETS
	reload_timer = 0.0
	
	if reload_progress:
		reload_progress.visible = false
	
	update_bullet_ui()
	print("Reload complete! Bullets: ", current_bullets)

func start_reload() -> void:
	if is_reloading or current_bullets == MAX_BULLETS:
		return
	
	is_reloading = true
	reload_timer = RELOAD_TIME
	
	if reload_progress:
		reload_progress.visible = true
		reload_progress.value = 0
	
	# Play reload animation if available
	if anim_player.has_animation(RELOAD_ANIMATION):
		anim_player.play(RELOAD_ANIMATION)
		current_animation_name = RELOAD_ANIMATION
	
	print("Starting reload...")

func update_bullet_ui() -> void:
	if bullet_label:
		bullet_label.text = str(current_bullets) + " / " + str(MAX_BULLETS)
		
		# Change color based on bullet count
		if current_bullets == 0:
			bullet_label.add_theme_color_override("font_color", Color.RED)
		elif current_bullets <= 2:
			bullet_label.add_theme_color_override("font_color", Color.ORANGE)
		else:
			bullet_label.add_theme_color_override("font_color", Color.WHITE)

func can_shoot() -> bool:
	var time_since_last_shot = Time.get_ticks_msec() - last_shot_time
	
	return (has_gun() and 
			current_bullets > 0 and 
			not is_reloading and 
			can_shoot_timer <= 0 and
			time_since_last_shot >= (SHOOT_COOLDOWN * 1000))  # Convert to milliseconds

func _setup_skin_system() -> void:
	print("Setting up skin system for player: ", name, " | Authority: ", multiplayer.get_unique_id(), " | Is local: ", is_multiplayer_authority())
	
	# First, collect available skins
	_collect_available_skins()
	
	if available_skins.size() == 0:
		print("ERROR: No skins found for Player!")
		return
	
	# Only the player's owner selects and broadcasts their skin
	if is_multiplayer_authority():
		# Wait a bit longer for all players to be ready
		await get_tree().create_timer(0.5).timeout
		
		if multiplayer.is_server():
			# Host gets the police skin (index 0)
			print("Host selecting police skin (index 0)")
			_select_and_sync_skin(0)
		else:
			# Client gets random skin (excluding police skin)  
			var random_index = randi_range(1, available_skins.size() - 1)  # Skip index 0 (police)
			print("Client selecting random skin (index ", random_index, ")")
			_select_and_sync_skin(random_index)
	else:
		# Non-authority players wait for skin broadcast
		print("Non-authority player waiting for skin broadcast for: ", name)

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
	
	print("Player ", name, " selected skin index: ", skin_index)
	
	# Set both synced properties
	synced_skin_index = skin_index
	synced_mesh_index = skin_index
	
	# Broadcast to all players including self
	_broadcast_skin_selection.rpc(skin_index)

@rpc("call_local", "reliable")
func _broadcast_skin_selection(skin_index: int) -> void:
	print("Received skin broadcast for player ", name, ": index ", skin_index)
	
	# Set the synced skin index (this will trigger _set_synced_skin_index)
	synced_skin_index = skin_index
	synced_mesh_index = skin_index
	selected_skin_index = skin_index
	
	# Force immediate visibility update
	_update_skin_visibility()

func _update_skin_visibility() -> void:
	if available_skins.size() == 0:
		print("No available skins to update visibility for player ", name)
		return
	
	var skin_index_to_use = synced_skin_index if synced_skin_index != -1 else selected_skin_index
	
	if skin_index_to_use == -1 or skin_index_to_use >= available_skins.size():
		print("Invalid skin index for player ", name, ": ", skin_index_to_use)
		return
	
	# Hide all skins first
	for i in range(available_skins.size()):
		if is_instance_valid(available_skins[i]):
			available_skins[i].visible = false
	
	# FIXED LOGIC: Show skin for remote players, hide for local player
	var is_local_player = is_multiplayer_authority()
	var should_show_skin = not is_local_player
	
	print("Player ", name, " skin visibility decision: ", should_show_skin, " (is_local_player: ", is_local_player, ", authority: ", multiplayer.get_unique_id(), ") using skin index: ", skin_index_to_use)
	
	if should_show_skin and is_instance_valid(available_skins[skin_index_to_use]):
		available_skins[skin_index_to_use].visible = true
		print("SUCCESS: Showing skin index ", skin_index_to_use, " for player ", name)
		skin_setup_complete = true
	else:
		print("Hiding skin for local player ", name, " (first person view)")
		skin_setup_complete = true

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

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	axis_vector = Input.get_vector("look_left", "look_right", "look_up", "look_down")

	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * sensitivity)
		camera.rotate_x(-event.relative.y * sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)

	# Modified shooting logic with bullet counter and debouncing
	if Input.is_action_just_pressed("shoot"):
		if can_shoot() and anim_player.current_animation != SHOOT_ANIMATION:
			# Set cooldown timer to prevent double shooting
			can_shoot_timer = SHOOT_COOLDOWN
			last_shot_time = Time.get_ticks_msec()
			
			# Consume a bullet
			current_bullets -= 1
			update_bullet_ui()
			
			print("Shot fired! Bullets remaining: ", current_bullets, " | Time: ", Time.get_ticks_msec())
			
			# Play shoot effects
			play_shoot_effects.rpc()
			gunshot_sound.play()
			
			# Handle raycast collision
			if raycast.is_colliding():
				var hit_collider = raycast.get_collider()
				if hit_collider and hit_collider is CharacterBody3D:
					var target_id = hit_collider.get_multiplayer_authority()
					print("Hit collider: ", hit_collider, " | Authority: ", target_id)
					hit_collider.recieve_damage.rpc_id(target_id, 1)
			
		elif current_bullets == 0 and not is_reloading:
			print("Out of ammo! Press R to reload")
		elif can_shoot_timer > 0:
			print("Shooting too fast! Cooldown: ", can_shoot_timer)

	# Reload input
	if Input.is_action_just_pressed("ui_cancel"):  # R key (you can map this to "reload" action)
		start_reload()

	if Input.is_action_just_pressed("respawn"):
		recieve_damage(2)

	if Input.is_action_just_pressed("capture"):
		if mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			mouse_captured = false
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true

	# Debug key to manually check skin visibility
	if Input.is_action_just_pressed("ui_select"):  # Space key
		debug_skin_state()
		force_refresh_skin_visibility()

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
	
	# Update movement state for animation
	is_moving_for_animation = input_dir != Vector2.ZERO and is_on_floor()
	
	# Handle animations - NEW ANIMATION SYSTEM
	_update_player_animations()
	
	move_and_slide()

func _update_player_animations() -> void:
	# Debug: Check if animation player exists
	if not anim_player:
		print("ERROR: AnimationPlayer is null!")
		return
	
	# Don't interrupt shoot or reload animations
	if anim_player.current_animation == SHOOT_ANIMATION or anim_player.current_animation == RELOAD_ANIMATION:
		return
	
	var desired_animation: String
	
	# Determine which animation set to use based on player role
	if has_gun():
		# Host uses pistol animations
		desired_animation = HOST_WALK_ANIMATION if is_moving_for_animation else HOST_IDLE_ANIMATION
		print("DEBUG: Host player - desired animation: ", desired_animation, " | moving: ", is_moving_for_animation)
	else:
		# Client uses regular animations
		desired_animation = CLIENT_WALK_ANIMATION if is_moving_for_animation else CLIENT_IDLE_ANIMATION
		print("DEBUG: Client player - desired animation: ", desired_animation, " | moving: ", is_moving_for_animation)
	
	# Only change animation if it's different from current
	if desired_animation != current_animation_name:
		print("DEBUG: Changing animation from '", current_animation_name, "' to '", desired_animation, "'")
		_play_player_animation(desired_animation)
	else:
		# Debug: Show current state even when not changing
		print("DEBUG: Keeping current animation: ", current_animation_name)

func _play_player_animation(animation_name: String) -> void:
	if not anim_player:
		print("ERROR: AnimationPlayer is null!")
		return
	
	# Debug: List all available animations
	print("DEBUG: Available animations in AnimationPlayer:")
	var animation_list = anim_player.get_animation_list()
	for anim_name in animation_list:
		print("  - ", anim_name)
	
	# Check if the animation exists
	if not anim_player.has_animation(animation_name):
		print("ERROR: Animation '", animation_name, "' not found for player!")
		print("DEBUG: Trying fallback animations...")
		
		# Try common fallback names
		var fallbacks = ["idle", "walk", "Idle", "Walk", "default"]
		for fallback in fallbacks:
			if anim_player.has_animation(fallback):
				print("DEBUG: Using fallback animation: ", fallback)
				animation_name = fallback
				break
		
		if not anim_player.has_animation(animation_name):
			print("ERROR: No suitable animation found!")
			return
	
	current_animation_name = animation_name
	
	# Play the animation with smooth transition
	if anim_player.current_animation != "":
		print("DEBUG: Playing animation with transition: ", animation_name)
		anim_player.play(animation_name, ANIMATION_TRANSITION_SPEED)
	else:
		print("DEBUG: Playing animation: ", animation_name)
		anim_player.play(animation_name)
	
	print("SUCCESS: Playing animation: ", animation_name, " for player (has_gun: ", has_gun(), ")")

@rpc("call_local")
func play_shoot_effects() -> void:
	anim_player.stop()
	anim_player.play(SHOOT_ANIMATION)
	current_animation_name = SHOOT_ANIMATION  # Track the current animation
	muzzle_flash.restart()
	muzzle_flash.emitting = true

@rpc("any_peer", "call_local")
func recieve_damage(damage: int = 1) -> void:
	health -= damage
	if health <= 0:
		health = 1
		position = get_random_spawn_position()
		assign_player_color()
		
		# Reset bullets on respawn for host
		if is_multiplayer_authority() and has_gun():
			current_bullets = MAX_BULLETS
			is_reloading = false
			reload_timer = 0.0
			can_shoot_timer = 0.0  # Reset cooldown on respawn
			last_shot_time = 0.0
			if reload_progress:
				reload_progress.visible = false
			update_bullet_ui()
		
		# Add random skin selection on respawn for clients (non-host players)
		if is_multiplayer_authority() and not multiplayer.is_server():
			# Client gets random skin (excluding police skin at index 0)
			if available_skins.size() > 1:
				var random_index = randi_range(1, available_skins.size() - 1)
				print("Client respawning with new random skin (index ", random_index, ")")
				_select_and_sync_skin(random_index)

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
	
	# Only update visibility if this is actually a new value
	if old_index != new_index:
		print("Synced skin index changed from ", old_index, " to ", new_index, " for player ", name)
		# Update visibility immediately when sync changes
		call_deferred("_update_skin_visibility")

# FIXED: Added the missing synced_mesh_index setter
func _set_synced_mesh_index(new_index: int) -> void:
	var old_index = synced_mesh_index
	synced_mesh_index = new_index
	
	# Only update if this is actually a new value
	if old_index != new_index:
		print("Synced mesh index changed from ", old_index, " to ", new_index, " for player ", name)
		# Update visibility when mesh index changes
		call_deferred("_update_skin_visibility")

# Debug functions
func debug_skin_state() -> void:
	print("=== DEBUG SKIN STATE for player ", name, " ===")
	print("Available skins: ", available_skins.size())
	print("Selected skin index: ", selected_skin_index)
	print("Synced skin index: ", synced_skin_index)
	print("Synced mesh index: ", synced_mesh_index)
	print("Is multiplayer authority: ", is_multiplayer_authority())
	print("Skin setup complete: ", skin_setup_complete)
	for i in range(available_skins.size()):
		if is_instance_valid(available_skins[i]):
			print("Skin ", i, " (", available_skins[i].name, ") visible: ", available_skins[i].visible)
	print("=== END DEBUG ===")

func force_refresh_skin_visibility() -> void:
	print("Force refreshing skin visibility for player ", name)
	_update_skin_visibility()
