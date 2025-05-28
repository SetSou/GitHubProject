extends CharacterBody3D

@onready var camera: Camera3D = $Camera3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var muzzle_flash: GPUParticles3D = $Camera3D/pistol/GPUParticles3D
@onready var raycast: RayCast3D = $Camera3D/RayCast3D
@onready var gunshot_sound: AudioStreamPlayer3D = %GunshotSound
### COLOR SYNC ###
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D  # Reference to capsule mesh
@onready var synchronizer: MultiplayerSynchronizer = $MultiplayerSynchronizer  # Reference to MultiplayerSynchronizer

## Number of shots before a player dies
@export var health: int = 2
## The xyz position of the random spawns
@export var spawns: PackedVector3Array = ([
	Vector3(-18, 0.2, 0),
	Vector3(18, 0.2, 0),
	Vector3(-2.8, 0.2, -6),
	Vector3(-17, 0, 17),
	Vector3(17, 0, 17),
	Vector3(17, 0, -17),
	Vector3(-17, 0, -17)
])
### COLOR SYNC ###
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
### COLOR SYNC ###
## Synced property for player color
@export var player_color: Color = Color.WHITE : set = _set_player_color

var sensitivity: float = 0.005
var controller_sensitivity: float = 0.010
var axis_vector: Vector2
var mouse_captured: bool = true

const SPEED = 5.5
const JUMP_VELOCITY = 4.5

func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())

func _ready() -> void:
	if not is_multiplayer_authority():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera.current = true
	position = spawns[randi() % spawns.size()]
	### COLOR SYNC ###
	if mesh_instance == null:
		print("ERROR: MeshInstance3D not found! Check node setup for peer: ", multiplayer.get_unique_id())
		return
	if synchronizer == null:
		print("ERROR: MultiplayerSynchronizer not found! Check node setup for peer: ", multiplayer.get_unique_id())
		return
	# Assign color on server, request for clients
	if multiplayer.is_server():
		player_color = possible_colors[randi() % possible_colors.size()]
		print("Server assigned color: ", player_color, " for peer: ", multiplayer.get_unique_id())
	else:
		# Clients request color from server
		request_color_from_server.rpc_id(1)
		# Fallback: apply current color to ensure immediate visual update
		_set_player_color(player_color)
		# Wait briefly for server to assign color
		await get_tree().create_timer(0.5).timeout
		_set_player_color(player_color)

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

	if Input.is_action_just_pressed("shoot") and anim_player.current_animation != "shoot":
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
	# Add the gravity
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration
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
	if not multiplayer.is_server():
		return
	health -= damage
	if health <= 0:
		health = 2
		position = spawns[randi() % spawns.size()]
		### COLOR SYNC ###
		# Assign new random color on respawn (server only)
		if multiplayer.is_server():
			player_color = possible_colors[randi() % possible_colors.size()]
			print("Server assigned respawn color: ", player_color, " for peer: ", multiplayer.get_unique_id())

### COLOR SYNC ###
func _set_player_color(new_color: Color) -> void:
	player_color = new_color
	# Apply color to the mesh
	if mesh_instance:
		var material = mesh_instance.get_surface_override_material(0)
		if material == null:
			material = StandardMaterial3D.new()
			mesh_instance.set_surface_override_material(0, material)
		material.albedo_color = new_color
		print("Player color set to: ", new_color, " at position: ", global_position, " for peer: ", multiplayer.get_unique_id())

### COLOR SYNC ###
@rpc("any_peer")
func request_color_from_server() -> void:
	if not multiplayer.is_server():
		return
	# Server assigns random color for the requesting client
	var peer_id = multiplayer.get_remote_sender_id()
	var player = get_node_or_null("/root/Main/" + str(peer_id))
	if player:
		player.player_color = possible_colors[randi() % possible_colors.size()]
		print("Server assigned color: ", player.player_color, " for peer: ", peer_id)
	else:
		print("ERROR: Player node not found for peer: ", peer_id)
