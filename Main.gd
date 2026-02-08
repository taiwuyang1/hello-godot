extends Node3D

## 3D Parkour — fully procedural scene
## Attach to a root Node3D named "Main"
## All nodes are created in code — no manual scene tree needed.

# ───────── tunables ─────────
const PLAYER_SPEED       := 8.0
const JUMP_VELOCITY      := 7.0
const GRAVITY            := 20.0
const MOUSE_SENSITIVITY  := 0.002
const PITCH_MIN_DEG      := -50.0
const PITCH_MAX_DEG      := 30.0
const SPRING_LENGTH      := 6.0
const SPAWN_INTERVAL     := 1.0
const FALL_LIMIT         := -10.0

# ───────── runtime refs ─────────
var player     : CharacterBody3D
var camera_rig : Node3D
var spring_arm : SpringArm3D

# ══════════════════════════════════════
#  Lifecycle
# ══════════════════════════════════════

func _ready() -> void:
	_register_actions()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_build_environment()
	_build_ground()
	_build_player()
	_build_camera_rig()
	_build_obstacle_spawner()

# ══════════════════════════════════════
#  Input-action registration (no manual InputMap needed)
# ══════════════════════════════════════

func _register_actions() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("move_back",    KEY_S)
	_add_key_action("move_left",    KEY_A)
	_add_key_action("move_right",   KEY_D)
	_add_key_action("jump",         KEY_SPACE)

func _add_key_action(action_name: String, keycode: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
		var ev := InputEventKey.new()
		ev.keycode = keycode
		InputMap.action_add_event(action_name, ev)

# ══════════════════════════════════════
#  Scene builders
# ══════════════════════════════════════

func _build_environment() -> void:
	# Directional light (sun)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled   = true
	sun.light_energy     = 1.2
	add_child(sun)

	# Sky / ambient
	var we  := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode        = Environment.BG_COLOR
	env.background_color       = Color(0.45, 0.65, 0.95)
	env.ambient_light_source   = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color    = Color.WHITE
	env.ambient_light_energy   = 0.4
	we.environment = env
	add_child(we)


func _build_ground() -> void:
	# Collision layer 1 = ground
	var body := StaticBody3D.new()
	body.name            = "Ground"
	body.collision_layer = 1
	body.collision_mask  = 0
	add_child(body)

	var mi   := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(200, 1, 200)
	mi.mesh   = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.65, 0.3)
	mi.material_override = mat
	body.add_child(mi)

	var cs    := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(200, 1, 200)
	cs.shape   = shape
	body.add_child(cs)

	# Surface at y = 0 (box center at -0.5)
	body.position.y = -0.5


func _build_player() -> void:
	# Collision layer 2 = player,  mask = ground(1) | obstacles(4)
	player = CharacterBody3D.new()
	player.name            = "Player"
	player.collision_layer = 2
	player.collision_mask  = 1 | 4
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
	spring_arm.name           = "SpringArm"
	spring_arm.spring_length  = SPRING_LENGTH
	spring_arm.collision_mask = 1          # only bounce off ground
	camera_rig.add_child(spring_arm)

	var cam := Camera3D.new()
	cam.name    = "Camera"
	cam.current = true
	spring_arm.add_child(cam)


func _build_obstacle_spawner() -> void:
	var timer := Timer.new()
	timer.name      = "ObstacleSpawner"
	timer.wait_time = SPAWN_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_spawn_obstacle)
	add_child(timer)

# ══════════════════════════════════════
#  Obstacle factory
# ══════════════════════════════════════

func _spawn_obstacle() -> void:
	if player == null:
		return

	# Collision layer 4 (= layer-3 bit) = obstacles
	var body := StaticBody3D.new()
	body.collision_layer = 4
	body.collision_mask  = 0
	body.add_to_group("obstacles")
	add_child(body)

	# Spawn ahead of camera forward with random lateral offset
	var fwd := -camera_rig.global_transform.basis.z
	fwd.y = 0.0
	fwd   = fwd.normalized()
	var right := camera_rig.global_transform.basis.x
	right.y = 0.0
	right   = right.normalized()

	var dist   := randf_range(15.0, 30.0)
	var offset := randf_range(-8.0, 8.0)
	var half   := randf_range(0.4, 1.2)        # half-size of box

	body.global_position = player.global_position \
		+ fwd * dist + right * offset
	body.global_position.y = half               # sit on ground surface

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

	# Collision
	var cs    := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(side, side, side)
	cs.shape   = shape
	body.add_child(cs)

	# Auto-free after 20 s to avoid unlimited growth
	var ttl := Timer.new()
	ttl.wait_time = 20.0
	ttl.one_shot  = true
	ttl.autostart = true
	ttl.timeout.connect(body.queue_free)
	body.add_child(ttl)

# ══════════════════════════════════════
#  Input handling
# ══════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look (only while captured)
	if event is InputEventMouseMotion \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_rig.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		spring_arm.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		spring_arm.rotation.x = clampf(
			spring_arm.rotation.x,
			deg_to_rad(PITCH_MIN_DEG),
			deg_to_rad(PITCH_MAX_DEG))

	# Esc toggles mouse capture
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ══════════════════════════════════════
#  Physics
# ══════════════════════════════════════

func _physics_process(delta: float) -> void:
	if player == null:
		return

	# ---- gravity ----
	if not player.is_on_floor():
		player.velocity.y -= GRAVITY * delta

	# ---- jump ----
	if Input.is_action_just_pressed("jump") and player.is_on_floor():
		player.velocity.y = JUMP_VELOCITY

	# ---- horizontal movement (camera-relative) ----
	var input_dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_forward", "move_back"))

	var move_dir := camera_rig.global_transform.basis \
		* Vector3(input_dir.x, 0.0, input_dir.y)
	move_dir.y = 0.0
	if move_dir.length_squared() > 0.001:
		move_dir = move_dir.normalized()

	player.velocity.x = move_dir.x * PLAYER_SPEED
	player.velocity.z = move_dir.z * PLAYER_SPEED

	# ---- move & slide ----
	player.move_and_slide()

	# ---- obstacle collision → restart ----
	for i in player.get_slide_collision_count():
		var collider := player.get_slide_collision(i).get_collider()
		if collider and collider.is_in_group("obstacles"):
			get_tree().reload_current_scene()
			return

	# ---- fell off the world → restart ----
	if player.global_position.y < FALL_LIMIT:
		get_tree().reload_current_scene()
		return

# ══════════════════════════════════════
#  Smooth camera follow (runs every render frame)
# ══════════════════════════════════════

func _process(_delta: float) -> void:
	if player and camera_rig:
		camera_rig.global_position = player.global_position
