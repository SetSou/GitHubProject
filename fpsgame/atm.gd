extends StaticBody3D

# ATM Configuration
@export var rob_time: float = 5.0  # Time to complete robbery
@export var cooldown_time: float = 30.0  # Time before ATM can be robbed again
@export var money_reward: int = 100  # Money given per successful robbery
@export var interaction_distance: float = 3.0  # How close player must be

# Node references
@onready var interaction_area: Area3D = $InteractionArea
@onready var progress_bar: ProgressBar
@onready var status_label: Label3D
@onready var atm_mesh: MeshInstance3D = $ATMMesh  # Reference to your ATM model

# State variables
var is_being_robbed: bool = false
var rob_progress: float = 0.0
var is_on_cooldown: bool = false
var cooldown_progress: float = 0.0
var current_robber: Node = null
var color_tween: Tween = null  # Store tween reference to stop it later

# UI elements
var ui_container: Control
var progress_ui: ProgressBar
var status_ui: Label
var money_ui: Label

# Synced properties for multiplayer
@export var synced_is_robbed: bool = false : set = _set_synced_is_robbed
@export var synced_cooldown: float = 0.0 : set = _set_synced_cooldown

func _ready() -> void:
	# Setup interaction area
	if not interaction_area:
		interaction_area = Area3D.new()
		interaction_area.name = "InteractionArea"
		add_child(interaction_area)
		
		var collision_shape = CollisionShape3D.new()
		var sphere_shape = SphereShape3D.new()
		sphere_shape.radius = interaction_distance
		collision_shape.shape = sphere_shape
		interaction_area.add_child(collision_shape)
		
		#print("[ATM] Created InteractionArea with radius: ", interaction_distance)
	
	# CRITICAL: Set collision layers so it can detect players
	# Layer 0 means it's not on any layer (doesn't collide with anything physically)
	# Mask 2 means it monitors/detects things on layer 2 (players)
	interaction_area.set_collision_layer_value(1, false)  # Not on layer 1
	interaction_area.set_collision_layer_value(2, false)  # Not on layer 2
	interaction_area.set_collision_mask_value(1, false)   # Don't detect layer 1
	interaction_area.set_collision_mask_value(2, true)    # DO detect layer 2 (players)
	
	interaction_area.monitorable = false  # Other areas don't need to detect this
	interaction_area.monitoring = true    # This area monitors for bodies
	
	#print("[ATM] InteractionArea collision setup complete")
	#print("[ATM] Monitoring: ", interaction_area.monitoring, " | Monitorable: ", interaction_area.monitorable)
	
	# Connect signals
	if not interaction_area.body_entered.is_connected(_on_body_entered):
		interaction_area.body_entered.connect(_on_body_entered)
		#print("[ATM] Connected body_entered signal")
	
	if not interaction_area.body_exited.is_connected(_on_body_exited):
		interaction_area.body_exited.connect(_on_body_exited)
		#print("[ATM] Connected body_exited signal")
	
	# Setup 3D label for world space status
	_setup_world_label()
	
	# Setup collision for ATM body (the ATM itself should be solid)
	if not get_node_or_null("CollisionShape3D"):
		var collision = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(1, 2, 0.5)
		collision.shape = box_shape
		add_child(collision)
	
	# Set the ATM body to layer 1 so it's solid but doesn't interfere with detection
	set_collision_layer_value(1, true)
	set_collision_layer_value(2, false)
	set_collision_mask_value(1, true)
	set_collision_mask_value(2, false)
	
	#print("[ATM] Ready! Position: ", global_position)

func _setup_world_label() -> void:
	# Don't create 3D label - we'll use 2D UI instead
	# The 3D label is visible to all players, which we don't want
	pass

func _process(delta: float) -> void:
	# Handle cooldown
	if is_on_cooldown:
		cooldown_progress -= delta
		synced_cooldown = cooldown_progress
		
		# Update cooldown text if UI exists
		if status_ui and ui_container:
			status_ui.text = "ATM on cooldown: " + str(int(cooldown_progress)) + "s"
		
		if cooldown_progress <= 0:
			is_on_cooldown = false
			synced_is_robbed = false
		return
	
	# Handle robbery progress
	if is_being_robbed and current_robber:
		rob_progress += delta
		
		# Update UI
		if progress_ui:
			progress_ui.value = (rob_progress / rob_time) * 100
		
		if status_ui:
			status_ui.text = "Robbing... " + str(int((rob_progress / rob_time) * 100)) + "%"
		
		# Check if robbery complete
		if rob_progress >= rob_time:
			_complete_robbery()

func _on_body_entered(body: Node3D) -> void:
	#print("[ATM] Body entered detection area: ", body.name, " (Type: ", body.get_class(), ")")
	#print("[ATM] Body position: ", body.global_position, " | ATM position: ", global_position)
	#print("[ATM] Distance: ", body.global_position.distance_to(global_position))
	
	# Check if it's a CharacterBody3D (player type)
	if not body is CharacterBody3D:
		#print("[ATM] Not a CharacterBody3D, ignoring")
		return
	
	# Check if it has the has_gun method (player check)
	if not body.has_method("has_gun"):
		#print("[ATM] Not a player (no has_gun method), ignoring")
		return
	
	#print("[ATM] Valid player detected!")
	
	# Check if it's a client (not host)
	if body.has_gun():
		#print("[ATM] Host player detected - cannot rob ATMs")
		# Don't show any UI or labels to the host
		return
	
	#print("[ATM] Client player detected!")
	
	# Check ATM availability
	if is_on_cooldown:
		#print("[ATM] ATM is on cooldown")
		# Only create UI for clients showing cooldown
		if body.is_multiplayer_authority():
			_create_cooldown_ui(body)
		return
	
	if is_being_robbed:
		#print("[ATM] ATM is already being robbed")
		return
	
	# ATM is available!
	#print("[ATM] ATM is available for robbery!")
	
	# Tell the player about this ATM
	if body.has_method("set_nearby_atm"):
		body.set_nearby_atm(self)
		#print("[ATM] Notified player about nearby ATM")
	
	# Create UI for the player (only if they're the authority/owner)
	if body.is_multiplayer_authority():
		_create_robbery_ui(body)
		#print("[ATM] Created robbery UI for player")

func _on_body_exited(body: Node3D) -> void:
	#print("[ATM] Body exited detection area: ", body.name)
	
	if body == current_robber:
		_cancel_robbery()
	
	if body.has_method("has_gun"):
		# Don't do anything for host player
		if body.has_gun():
			return
		
		# Tell player they left the ATM
		if body.has_method("clear_nearby_atm"):
			body.clear_nearby_atm()
			#print("[ATM] Player left ATM area")
		
		# Remove UI
		if body.is_multiplayer_authority():
			_remove_robbery_ui()
			#print("[ATM] Removed robbery UI")

func _create_robbery_ui(player: Node) -> void:
	# Create UI container
	ui_container = Control.new()
	ui_container.name = "ATM_UI"
	ui_container.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ui_container.position = Vector2(-150, 200)
	ui_container.size = Vector2(300, 100)
	
	# Create background panel
	var panel = Panel.new()
	panel.size = Vector2(300, 100)
	panel.modulate = Color(0, 0, 0, 0.7)
	ui_container.add_child(panel)
	
	# Create status label
	status_ui = Label.new()
	status_ui.name = "StatusLabel"
	status_ui.text = "Press E to start robbery"
	status_ui.position = Vector2(10, 10)
	status_ui.size = Vector2(280, 30)
	status_ui.add_theme_font_size_override("font_size", 18)
	status_ui.add_theme_color_override("font_color", Color.GREEN)
	ui_container.add_child(status_ui)
	
	# Create progress bar
	progress_ui = ProgressBar.new()
	progress_ui.name = "RobberyProgress"
	progress_ui.position = Vector2(10, 45)
	progress_ui.size = Vector2(280, 25)
	progress_ui.min_value = 0
	progress_ui.max_value = 100
	progress_ui.value = 0
	progress_ui.visible = false
	ui_container.add_child(progress_ui)
	
	# Add to scene
	get_tree().current_scene.add_child(ui_container)

func _create_cooldown_ui(player: Node) -> void:
	# Create simple cooldown UI
	ui_container = Control.new()
	ui_container.name = "ATM_UI"
	ui_container.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ui_container.position = Vector2(-150, 200)
	ui_container.size = Vector2(300, 60)
	
	# Create background panel
	var panel = Panel.new()
	panel.size = Vector2(300, 60)
	panel.modulate = Color(0, 0, 0, 0.7)
	ui_container.add_child(panel)
	
	# Create status label
	status_ui = Label.new()
	status_ui.name = "StatusLabel"
	status_ui.text = "ATM on cooldown: " + str(int(cooldown_progress)) + "s"
	status_ui.position = Vector2(10, 15)
	status_ui.size = Vector2(280, 30)
	status_ui.add_theme_font_size_override("font_size", 18)
	status_ui.add_theme_color_override("font_color", Color.RED)
	ui_container.add_child(status_ui)
	
	# Add to scene
	get_tree().current_scene.add_child(ui_container)

func _remove_robbery_ui() -> void:
	if ui_container and is_instance_valid(ui_container):
		ui_container.queue_free()
		ui_container = null

func start_robbery(robber: Node) -> void:
	#print("[ATM] start_robbery called by: ", robber.name)
	
	if is_on_cooldown:
		#print("[ATM] Cannot start - ATM on cooldown")
		return
	
	if is_being_robbed:
		#print("[ATM] Cannot start - ATM already being robbed")
		return
	
	#print("[ATM] Starting robbery!")
	is_being_robbed = true
	current_robber = robber
	rob_progress = 0.0
	
	if progress_ui:
		progress_ui.visible = true
		progress_ui.value = 0
		#print("[ATM] Progress UI shown")
	
	if status_ui:
		status_ui.text = "Robbing ATM... Hold E!"
		#print("[ATM] Status UI updated")
	
	# Visual feedback - change ATM material color
	if atm_mesh:
		# Stop any existing tween
		if color_tween:
			color_tween.kill()
		
		var material = atm_mesh.get_active_material(0)
		if material:
			# Create a tween to flash the material color
			color_tween = create_tween()
			color_tween.set_loops()
			color_tween.tween_method(_set_atm_color, Color.WHITE, Color.RED, 0.5)
			color_tween.tween_method(_set_atm_color, Color.RED, Color.WHITE, 0.5)
			#print("[ATM] Started flashing animation")
	
	#print("[ATM] Robbery started successfully!")

# Helper function to change ATM color
func _set_atm_color(color: Color) -> void:
	if atm_mesh:
		var material = atm_mesh.get_active_material(0)
		if material and material is StandardMaterial3D:
			material.albedo_color = color

func _cancel_robbery() -> void:
	if not is_being_robbed:
		return
	
	is_being_robbed = false
	rob_progress = 0.0
	current_robber = null
	
	# Stop the flashing animation
	if color_tween:
		color_tween.kill()
		color_tween = null
	
	if progress_ui:
		progress_ui.visible = false
		progress_ui.value = 0
	
	if status_ui:
		status_ui.text = "Robbery cancelled!"
	
	# Reset ATM appearance to white
	if atm_mesh:
		_set_atm_color(Color.WHITE)
	
	#print("[ATM] Robbery cancelled")

func _complete_robbery() -> void:
	is_being_robbed = false
	is_on_cooldown = true
	cooldown_progress = cooldown_time
	synced_is_robbed = true
	synced_cooldown = cooldown_progress
	
	# Stop the flashing animation
	if color_tween:
		color_tween.kill()
		color_tween = null
	
	# Give money to robber
	if current_robber and current_robber.has_method("add_money"):
		current_robber.add_money(money_reward)
	
	if status_ui:
		status_ui.text = "Robbery successful! +$" + str(money_reward)
	
	if progress_ui:
		progress_ui.visible = false
	
	# Reset ATM appearance to gray
	if atm_mesh:
		_set_atm_color(Color.GRAY)
	
	# Sync to all clients
	if multiplayer.is_server():
		sync_robbery_complete.rpc()
	
	current_robber = null
	#print("[ATM] Robbery complete! Awarded $", money_reward)
	
	# Remove UI after delay
	await get_tree().create_timer(2.0).timeout
	_remove_robbery_ui()

@rpc("call_local", "reliable")
func sync_robbery_complete() -> void:
	if atm_mesh:
		_set_atm_color(Color.GRAY)

func _set_synced_is_robbed(new_value: bool) -> void:
	synced_is_robbed = new_value
	is_on_cooldown = new_value

func _set_synced_cooldown(new_value: float) -> void:
	synced_cooldown = new_value
	cooldown_progress = new_value

# Debug function to check what bodies are in the area
func debug_check_bodies() -> void:
	if interaction_area:
		var bodies = interaction_area.get_overlapping_bodies()
		#print("[ATM DEBUG] Bodies in interaction area: ", bodies.size())
		#for body in bodies:
			#print("  - ", body.name, " (Type: ", body.get_class(), ")")
			#if body.has_method("has_gun"):
				#print("    Has has_gun method! Value: ", body.has_gun())
	#else:
		#print("[ATM DEBUG] No interaction area!")
