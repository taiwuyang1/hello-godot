extends Node3D

## Auto-run 3D Parkour — fully procedural
## Player runs forward (-Z) automatically; A/D to dodge, Space to jump.
## Hit an obstacle or fall off → Game Over → press R to restart.

# ───────── tunables ─────────
const RUN_SPEED       := 14.0     # auto-forward speed
const STRAFE_SPEED    := 10.0     # A/D lateral speed
const JUMP_VELOCITY   := 7.0
const GRAVITY         := 20.0
const SPRING_LENGTH   := 8.0      # camera distance
const CAM_PITCH_DEG   := -15.0    # camera angle (negative = above & behind)

const SPAWN_HORIZON   := 60.0     # pre-fill obstacles this far ahead
const SPAWN_Z_GAP_MIN := 8.0      # min Z gap between consecutive obstacles
const SPAWN_Z_GAP_MAX := 12.0     # max Z gap
const SPAWN_X_RANGE   := 4.0      # obstacles spawn in X ∈ [-4, +4]
const MAX_OBSTACLES   := 10       # hard cap on simultaneous obstacles
const CLEANUP_BEHIND  := 40.0     # destroy obstacles this far behind player

const FALL_LIMIT      := -10.0    # Y below which player is considered dead

# ───────── runtime refs ─────────
var player     : CharacterBody3D
var camera_rig : Node3D
var spring_arm : SpringArm3D
var ground     : StaticBody3D

# ───────── obstacle state ─────────
var next_spawn_z : float = 0.0    # Z of the next obstacle to create

# ───────── UI refs ─────────
var score_label    : Label
var gameover_label : Label

# ───────── game state ─────────
var game_over  : bool  = false
var score_time : float = 0.0

# ══════════════════════════════════════════════════════════════
#  Lifecycle
# ══════════════════════════════════════════════════════════════

func _ready() -> void:
	_register_actions()

	_build_environment()
	_build_ground()
	_build_player()
	_build_camera_rig()
	_build_ui()

	# First obstacle row starts 20 m ahead of the player
	next_spawn_z = player.global_position.z - 20.0

# ══════════════════════════════════════════════════════════════
#  Input-action registration  (zero manual InputMap setup)
# ══════════════════════════════════════════════════════════════

func _register_actions() -> void:
	_add_key_action("move_left",  KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("jump",       KEY_SPACE)
	_add_key_action("restart",    KEY_R)

func _add_key_action(action_name: String, keycode: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
		var ev := InputEventKey.new()
		ev.keycode = keycode
		InputMap.action_add_event(action_name, ev)

# ══════════════════════════════════════════════════════════════
#  Scene builders
# ══════════════════════════════════════════════════════════════

func _build_environment() -> void:
	# Sun
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled   = true
	sun.light_energy     = 1.2
	add_child(sun)

	# Sky colour + ambient
	var we  := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode      = Environment.BG_COLOR
	env.background_color     = Color(0.45, 0.65, 0.95)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color.WHITE
	env.ambient_light_energy = 0.4
	we.environment = env
	add_child(we)


func _build_ground() -> void:
	ground = StaticBody3D.new()
	ground.name            = "Ground"
	ground.collision_layer = 1        # layer 1
	ground.collision_mask  = 0
	add_child(ground)

	# 30 wide × 200 long track — follows player Z every frame
	var mi   := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(30, 1, 200)
	mi.mesh   = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.65, 0.3)
	mi.material_override = mat
	ground.add_child(mi)

	var cs    := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(30, 1, 200)
	cs.shape   = shape
	ground.add_child(cs)

	ground.position.y = -0.5          # surface at Y = 0


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.name            = "Player"
	player.collision_layer = 2        # layer 2
	player.collision_mask  = 1 | 4    # ground (1) + obstacles (4)
	add_child(player)
	player.position = Vector3(0, 1, 0)

	var mi   := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.0
	mi.mesh     = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.35, 0.85)
	mi.material_override = mat
	player.add_child(mi)

	var cs    := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.0
	cs.shape     = shape
	player.add_child(cs)


func _build_camera_rig() -> void:
	camera_rig = Node3D.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)

	spring_arm = SpringArm3D.new()
	spring_arm.name               = "SpringArm"
	spring_arm.spring_length      = SPRING_LENGTH
	spring_arm.collision_mask     = 1     # only collide with ground
	spring_arm.rotation_degrees.x = CAM_PITCH_DEG  # fixed behind & above
	camera_rig.add_child(spring_arm)

	var cam := Camera3D.new()
	cam.name    = "Camera"
	cam.current = true
	spring_arm.add_child(cam)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	# ── Score / survival timer (top-left) ──
	score_label = Label.new()
	score_label.name     = "ScoreLabel"
	score_label.text     = "Time: 0.0"
	score_label.position = Vector2(20, 20)
	score_label.add_theme_font_size_override("font_size", 28)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	score_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	score_label.add_theme_constant_override("shadow_offset_x", 2)
	score_label.add_theme_constant_override("shadow_offset_y", 2)
	canvas.add_child(score_label)

	# ── Game Over overlay (centered, hidden by default) ──
	gameover_label = Label.new()
	gameover_label.name = "GameOverLabel"
	gameover_label.text = "GAME OVER\nPress  R  to restart"
	gameover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gameover_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	gameover_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gameover_label.add_theme_font_size_override("font_size", 48)
	gameover_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	gameover_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	gameover_label.add_theme_constant_override("shadow_offset_x", 3)
	gameover_label.add_theme_constant_override("shadow_offset_y", 3)
	gameover_label.visible = false
	canvas.add_child(gameover_label)

# ══════════════════════════════════════════════════════════════
#  Obstacle system  (distance-based, not timer-based)
# ══════════════════════════════════════════════════════════════

func _try_spawn_obstacles() -> void:
	var count := get_tree().get_nodes_in_group("obstacles").size()

	# Keep filling the horizon, respecting the cap
	while next_spawn_z > player.global_position.z - SPAWN_HORIZON \
			and count < MAX_OBSTACLES:
		_create_obstacle(next_spawn_z)
		next_spawn_z -= randf_range(SPAWN_Z_GAP_MIN, SPAWN_Z_GAP_MAX)
		count += 1


func _create_obstacle(z: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 4          # layer 3 bit
	body.collision_mask  = 0
	body.add_to_group("obstacles")
	add_child(body)

	var half := randf_range(0.4, 1.2)
	body.global_position = Vector3(
		randf_range(-SPAWN_X_RANGE, SPAWN_X_RANGE),
		half,                         # bottom sits on ground (Y=0)
		z)

	# Mesh
	var side := half * 2.0
	var mi   := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(side, side, side)
	mi.mesh   = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(
		randf_range(0.7, 1.0),
		randf_range(0.1, 0.3),
		randf_range(0.1, 0.3))
	mi.material_override = mat
	body.add_child(mi)

	# Collision shape
	var cs    := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(side, side, side)
	cs.shape   = shape
	body.add_child(cs)


func _cleanup_obstacles() -> void:
	for obs in get_tree().get_nodes_in_group("obstacles"):
		# obstacle is more than CLEANUP_BEHIND metres behind the player
		if obs.global_position.z > player.global_position.z + CLEANUP_BEHIND:
			obs.queue_free()

# ══════════════════════════════════════════════════════════════
#  Game state
# ══════════════════════════════════════════════════════════════

func _die() -> void:
	game_over = true
	gameover_label.visible = true
	player.velocity = Vector3.ZERO

# ══════════════════════════════════════════════════════════════
#  Input
# ══════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart") and game_over:
		get_tree().reload_current_scene()

# ══════════════════════════════════════════════════════════════
#  Physics  (movement, collisions, obstacle management)
# ══════════════════════════════════════════════════════════════

func _physics_process(delta: float) -> void:
	if player == null or game_over:
		return

	# ── gravity ──
	if not player.is_on_floor():
		player.velocity.y -= GRAVITY * delta

	# ── jump ──
	if Input.is_action_just_pressed("jump") and player.is_on_floor():
		player.velocity.y = JUMP_VELOCITY

	# ── auto-run forward (−Z) ──
	player.velocity.z = -RUN_SPEED

	# ── A/D strafe ──
	player.velocity.x = Input.get_axis("move_left", "move_right") * STRAFE_SPEED

	# ── move ──
	player.move_and_slide()

	# ── obstacle collision → die ──
	for i in player.get_slide_collision_count():
		var collider := player.get_slide_collision(i).get_collider()
		if collider and collider.is_in_group("obstacles"):
			_die()
			return

	# ── fell off the world → die ──
	if player.global_position.y < FALL_LIMIT:
		_die()
		return

	# ── obstacle lifecycle ──
	_try_spawn_obstacles()
	_cleanup_obstacles()

# ══════════════════════════════════════════════════════════════
#  Render frame  (camera, ground scroll, UI)
# ══════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if player == null:
		return

	# Camera tracks player every render frame for smoothness
	if camera_rig:
		camera_rig.global_position = player.global_position

	# Rolling ground: keep ground centred under the player
	if ground:
		ground.position.z = player.global_position.z

	# Score ticker
	if not game_over:
		score_time += delta
		score_label.text = "Time: %.1f" % score_time
