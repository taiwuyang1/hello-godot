extends Node3D

## Auto-run 3D Parkour — fully procedural
## Player runs forward (-Z) automatically; A/D to dodge, Space to jump.
## Collect gold pickups for points; hit an obstacle or fall off → Game Over.

# ───────── tunables ─────────
const RUN_SPEED       := 14.0
const STRAFE_SPEED    := 10.0
const JUMP_VELOCITY   := 7.0
const GRAVITY         := 20.0
const SPRING_LENGTH   := 8.0
const CAM_PITCH_DEG   := -15.0

const SPAWN_HORIZON   := 60.0
const SPAWN_Z_GAP_MIN := 8.0
const SPAWN_Z_GAP_MAX := 12.0
const SPAWN_X_RANGE   := 4.0
const MAX_OBSTACLES   := 10
const CLEANUP_BEHIND  := 40.0

const PICKUP_Z_MIN    := 25.0     # pickups spawn 25–40 m ahead
const PICKUP_Z_MAX    := 40.0
const PICKUP_X_RANGE  := 6.0      # X ∈ [-6, +6]
const PICKUP_Y_MIN    := 1.0
const PICKUP_Y_MAX    := 1.5
const PICKUP_TTL      := 17.0     # auto-destroy seconds

const FALL_LIMIT      := -10.0

@export var pickup_points: int = 10

# ───────── runtime refs ─────────
var player       : CharacterBody3D
var camera_rig   : Node3D
var spring_arm   : SpringArm3D
var ground       : StaticBody3D
var pickup_timer : Timer

# ───────── obstacle state ─────────
var next_spawn_z : float = 0.0

# ───────── UI refs ─────────
var time_label     : Label
var points_label   : Label
var gameover_label : Label

# ───────── game state ─────────
var game_over  : bool  = false
var score_time : float = 0.0
var score      : int   = 0

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
	_build_pickup_spawner()

	next_spawn_z = player.global_position.z - 20.0

# ══════════════════════════════════════════════════════════════
#  Input-action registration
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
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled   = true
	sun.light_energy     = 1.2
	add_child(sun)

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
	ground.collision_layer = 1
	ground.collision_mask  = 0
	add_child(ground)

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

	ground.position.y = -0.5


func _build_player() -> void:
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
	spring_arm.name               = "SpringArm"
	spring_arm.spring_length      = SPRING_LENGTH
	spring_arm.collision_mask     = 1
	spring_arm.rotation_degrees.x = CAM_PITCH_DEG
	camera_rig.add_child(spring_arm)

	var cam := Camera3D.new()
	cam.name    = "Camera"
	cam.current = true
	spring_arm.add_child(cam)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	# ── Survival timer (top-left) ──
	time_label = Label.new()
	time_label.name     = "TimeLabel"
	time_label.text     = "Time: 0.0"
	time_label.position = Vector2(20, 20)
	time_label.add_theme_font_size_override("font_size", 28)
	time_label.add_theme_color_override("font_color", Color.WHITE)
	time_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	time_label.add_theme_constant_override("shadow_offset_x", 2)
	time_label.add_theme_constant_override("shadow_offset_y", 2)
	canvas.add_child(time_label)

	# ── Pickup score (top-right) ──
	points_label = Label.new()
	points_label.name = "PointsLabel"
	points_label.text = "Score: 0000"
	points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	points_label.anchor_left   = 1.0
	points_label.anchor_right  = 1.0
	points_label.offset_left   = -220
	points_label.offset_top    = 20
	points_label.offset_right  = -20
	points_label.offset_bottom = 60
	points_label.add_theme_font_size_override("font_size", 28)
	points_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.3))
	points_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	points_label.add_theme_constant_override("shadow_offset_x", 2)
	points_label.add_theme_constant_override("shadow_offset_y", 2)
	canvas.add_child(points_label)

	# ── Game Over overlay (centered, hidden by default) ──
	gameover_label = Label.new()
	gameover_label.name = "GameOverLabel"
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


func _build_pickup_spawner() -> void:
	pickup_timer = Timer.new()
	pickup_timer.name     = "PickupSpawner"
	pickup_timer.one_shot = true
	pickup_timer.autostart = false
	add_child(pickup_timer)
	pickup_timer.timeout.connect(_on_pickup_timer)
	pickup_timer.start(randf_range(0.6, 1.2))

# ══════════════════════════════════════════════════════════════
#  Obstacle system
# ══════════════════════════════════════════════════════════════

func _try_spawn_obstacles() -> void:
	var count := get_tree().get_nodes_in_group("obstacles").size()
	while next_spawn_z > player.global_position.z - SPAWN_HORIZON \
			and count < MAX_OBSTACLES:
		_create_obstacle(next_spawn_z)
		next_spawn_z -= randf_range(SPAWN_Z_GAP_MIN, SPAWN_Z_GAP_MAX)
		count += 1


func _create_obstacle(z: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 4
	body.collision_mask  = 0
	body.add_to_group("obstacles")
	add_child(body)

	var half := randf_range(0.4, 1.2)
	body.global_position = Vector3(
		randf_range(-SPAWN_X_RANGE, SPAWN_X_RANGE), half, z)

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

	var cs    := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(side, side, side)
	cs.shape   = shape
	body.add_child(cs)


func _cleanup_obstacles() -> void:
	for obs in get_tree().get_nodes_in_group("obstacles"):
		if obs.global_position.z > player.global_position.z + CLEANUP_BEHIND:
			obs.queue_free()

# ══════════════════════════════════════════════════════════════
#  Pickup system
# ══════════════════════════════════════════════════════════════

func _on_pickup_timer() -> void:
	if game_over or player == null:
		return
	_create_pickup()
	pickup_timer.start(randf_range(0.6, 1.2))


func _create_pickup() -> void:
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask  = 2          # detect player (layer 2)
	area.monitoring      = true
	area.monitorable     = false
	area.add_to_group("pickups")
	add_child(area)

	# Position: ahead of player, random lateral, floating height
	area.global_position = Vector3(
		randf_range(-PICKUP_X_RANGE, PICKUP_X_RANGE),
		randf_range(PICKUP_Y_MIN, PICKUP_Y_MAX),
		player.global_position.z - randf_range(PICKUP_Z_MIN, PICKUP_Z_MAX))

	# Gold sphere mesh
	var mi   := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	mi.mesh     = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color              = Color(1.0, 0.84, 0.0)
	mat.metallic                  = 0.8
	mat.roughness                 = 0.2
	mat.emission_enabled          = true
	mat.emission                  = Color(1.0, 0.84, 0.0)
	mat.emission_energy_multiplier = 0.4
	mi.material_override = mat
	area.add_child(mi)

	# Detection shape (slightly larger than mesh for forgiving pickup)
	var cs    := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.5
	cs.shape     = shape
	area.add_child(cs)

	# Signal → collection
	area.body_entered.connect(_on_pickup_collected.bind(area))

	# TTL auto-destroy
	var ttl := Timer.new()
	ttl.wait_time = PICKUP_TTL
	ttl.one_shot  = true
	ttl.autostart = true
	ttl.timeout.connect(area.queue_free)
	area.add_child(ttl)


func _on_pickup_collected(body: Node3D, pickup: Area3D) -> void:
	if body != player or game_over:
		return
	if not pickup.monitoring:
		return                        # already collected (tween in progress)

	score += pickup_points
	_update_points_label()

	# Prevent double-collection
	pickup.set_deferred("monitoring", false)

	# Quick "pop" scale-up then free
	var tween := pickup.create_tween()
	tween.tween_property(pickup, "scale", Vector3.ONE * 2.5, 0.12)
	tween.tween_callback(pickup.queue_free)


func _update_points_label() -> void:
	points_label.text = "Score: %04d" % score


func _cleanup_pickups() -> void:
	for p in get_tree().get_nodes_in_group("pickups"):
		if p.global_position.z > player.global_position.z + CLEANUP_BEHIND:
			p.queue_free()

# ══════════════════════════════════════════════════════════════
#  Game state
# ══════════════════════════════════════════════════════════════

func _die() -> void:
	game_over = true
	gameover_label.text = "GAME OVER\nTime: %.1f    Score: %04d\nPress  R  to restart" \
		% [score_time, score]
	gameover_label.visible = true
	player.velocity = Vector3.ZERO

# ══════════════════════════════════════════════════════════════
#  Input
# ══════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart") and game_over:
		get_tree().reload_current_scene()

# ══════════════════════════════════════════════════════════════
#  Physics
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

	# ── obstacle & pickup lifecycle ──
	_try_spawn_obstacles()
	_cleanup_obstacles()
	_cleanup_pickups()

# ══════════════════════════════════════════════════════════════
#  Render frame
# ══════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if player == null:
		return

	if camera_rig:
		camera_rig.global_position = player.global_position

	if ground:
		ground.position.z = player.global_position.z

	if not game_over:
		score_time += delta
		time_label.text = "Time: %.1f" % score_time
