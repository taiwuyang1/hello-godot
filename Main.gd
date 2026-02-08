extends Node3D

## Auto-run 3D Parkour — fully procedural
## Player runs forward (-Z) automatically; A/D to dodge, Space to jump.
## Collect gold pickups for points; hit an obstacle or fall off → Game Over.

# ───────── tunables ─────────
const RUN_SPEED       := 16.0
const STRAFE_SPEED    := 10.0
const JUMP_VELOCITY   := 7.0
const GRAVITY         := 20.0
const SPRING_LENGTH   := 8.0
const CAM_PITCH_DEG   := -15.0

const SPAWN_HORIZON   := 60.0
const SPAWN_Z_GAP_MIN := 6.2
const SPAWN_Z_GAP_MAX := 9.2
const SPAWN_X_RANGE   := 13.0
const SPAWN_FOLLOW_WEIGHT := 0.90
const SPAWN_LANE_HALF_WIDTH := 2.2
const MAX_OBSTACLES   := 14
const CLEANUP_BEHIND  := 40.0

const PICKUP_Z_MIN    := 25.0     # pickups spawn 25–40 m ahead
const PICKUP_Z_MAX    := 40.0
const PICKUP_X_RANGE  := 6.0      # X ∈ [-6, +6]
const PICKUP_Y_MIN    := 1.0
const PICKUP_Y_MAX    := 1.5
const PICKUP_TTL      := 17.0     # auto-destroy seconds

const FALL_LIMIT      := -10.0

@export var pickup_points: int = 10

class HeadScoreFloat:
	var label: Label
	var base_offset: Vector3 = Vector3.ZERO
	var rise_height: float = 0.9
	var drift_x: float = 0.0
	var duration: float = 0.5
	var age: float = 0.0

# ───────── runtime refs ─────────
var player       : CharacterBody3D
var camera_rig   : Node3D
var spring_arm   : SpringArm3D
var ground       : StaticBody3D
var pickup_timer : Timer
var model_root      : Node3D
var body_mesh_instance : MeshInstance3D
var head_mesh_instance : MeshInstance3D
var left_arm_pivot  : Node3D
var right_arm_pivot : Node3D
var left_leg_pivot  : Node3D
var right_leg_pivot : Node3D
var run_anim_phase  : float = 0.0
var run_anim_blend  : float = 0.0

# ───────── obstacle state ─────────
var next_spawn_z : float = 0.0

# ───────── UI refs ─────────
var time_label     : Label
var points_label   : Label
var gameover_label : Label
var ui_root        : Control
var score_card     : PanelContainer
var head_score_floats: Array[HeadScoreFloat] = []

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

	model_root = Node3D.new()
	model_root.name = "ModelRoot"
	model_root.position = Vector3(0, 0.08, 0)
	player.add_child(model_root)

	body_mesh_instance = MeshInstance3D.new()
	body_mesh_instance.name = "Body"
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.23
	body_mesh.height = 0.60
	body_mesh_instance.mesh = body_mesh
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.15, 0.35, 0.85)
	body_mat.roughness = 0.85
	body_mesh_instance.material_override = body_mat
	body_mesh_instance.position = Vector3(0, 0.54, 0)
	model_root.add_child(body_mesh_instance)

	head_mesh_instance = MeshInstance3D.new()
	head_mesh_instance.name = "Head"
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.18
	head_mesh.height = 0.36
	head_mesh_instance.mesh = head_mesh
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.95, 0.83, 0.70)
	head_mat.roughness = 0.95
	head_mesh_instance.material_override = head_mat
	head_mesh_instance.position = Vector3(0, 1.05, 0)
	model_root.add_child(head_mesh_instance)

	left_arm_pivot = _create_limb_pivot("LeftArm", 0.48, 0.065, Color(0.16, 0.38, 0.92))
	left_arm_pivot.position = Vector3(-0.30, 0.82, 0)
	left_arm_pivot.rotation.z = -0.10
	model_root.add_child(left_arm_pivot)

	right_arm_pivot = _create_limb_pivot("RightArm", 0.48, 0.065, Color(0.16, 0.38, 0.92))
	right_arm_pivot.position = Vector3(0.30, 0.82, 0)
	right_arm_pivot.rotation.z = 0.10
	model_root.add_child(right_arm_pivot)

	left_leg_pivot = _create_limb_pivot("LeftLeg", 0.56, 0.08, Color(0.18, 0.22, 0.35))
	left_leg_pivot.position = Vector3(-0.14, 0.40, 0)
	model_root.add_child(left_leg_pivot)

	right_leg_pivot = _create_limb_pivot("RightLeg", 0.56, 0.08, Color(0.18, 0.22, 0.35))
	right_leg_pivot.position = Vector3(0.14, 0.40, 0)
	model_root.add_child(right_leg_pivot)

	var cs    := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.0
	cs.shape     = shape
	player.add_child(cs)


func _create_limb_pivot(name: String, length: float, radius: float, color: Color) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = name

	var limb := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.height = length
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	limb.mesh = mesh
	limb.position = Vector3(0, -length * 0.5, 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	limb.material_override = mat
	pivot.add_child(limb)

	return pivot


func _update_player_model_animation(delta: float) -> void:
	if model_root == null or player == null:
		return

	var planar_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var on_floor := player.is_on_floor()
	var speed_ratio := clampf(planar_speed / RUN_SPEED, 0.0, 1.0)

	var target_blend := 0.0
	if on_floor and planar_speed > 0.1:
		target_blend = speed_ratio
	elif not on_floor:
		target_blend = 0.22

	run_anim_blend = lerpf(run_anim_blend, target_blend, minf(1.0, delta * 9.0))

	var cadence := lerpf(5.8, 11.5, speed_ratio)
	run_anim_phase = fmod(run_anim_phase + delta * cadence, TAU)

	var phase := run_anim_phase
	var double_phase := phase * 2.0
	var left_step := sin(phase)
	var right_step := sin(phase + PI)
	var left_lift := maxf(0.0, sin(phase + PI * 0.5))
	var right_lift := maxf(0.0, sin(phase + PI * 1.5))

	var bob: float = absf(sin(double_phase)) * 0.065 * run_anim_blend
	var sway := sin(phase) * 0.05 * run_anim_blend
	var hip_pitch := 0.03 * run_anim_blend + sin(double_phase + 0.4) * 0.02 * run_anim_blend
	var hip_yaw := sin(phase) * 0.08 * run_anim_blend
	var hip_roll := sin(phase + PI * 0.5) * 0.035 * run_anim_blend

	if not on_floor:
		bob = lerpf(bob, 0.01, 0.7)
		sway = lerpf(sway, 0.0, 0.6)
		hip_pitch = lerpf(hip_pitch, -0.06, 0.5)
		hip_yaw *= 0.5
		hip_roll *= 0.45

	model_root.position = Vector3(sway, 0.08 + bob, 0)
	model_root.rotation = Vector3(hip_pitch, hip_yaw, hip_roll)

	if body_mesh_instance:
		var body_twist := -hip_yaw * 0.9
		var body_lean := 0.06 * run_anim_blend + sin(double_phase + PI) * 0.03 * run_anim_blend
		body_mesh_instance.position = Vector3(0, 0.54, 0)
		body_mesh_instance.rotation = Vector3(body_lean, body_twist, 0.0)

	if head_mesh_instance:
		var head_nod := sin(double_phase + PI * 0.35) * 0.07 * run_anim_blend
		var head_counter := -hip_pitch * 0.35
		var head_tilt := sin(phase + PI * 0.5) * 0.02 * run_anim_blend
		head_mesh_instance.position = Vector3(0, 1.05 + sin(double_phase + 0.9) * 0.015 * run_anim_blend, 0)
		head_mesh_instance.rotation = Vector3(head_counter + head_nod, 0.0, head_tilt)

	var arm_secondary := sin(double_phase + 0.35) * 0.14 * run_anim_blend
	var left_arm_pitch := right_step * 0.92 * run_anim_blend + arm_secondary
	var right_arm_pitch := left_step * 0.92 * run_anim_blend - arm_secondary
	if not on_floor:
		left_arm_pitch = lerpf(left_arm_pitch, -0.28, 0.5)
		right_arm_pitch = lerpf(right_arm_pitch, -0.28, 0.5)

	if left_arm_pivot:
		left_arm_pivot.position = Vector3(-0.30, 0.82 + bob * 0.25, 0)
		left_arm_pivot.rotation = Vector3(left_arm_pitch, 0.05 * run_anim_blend, -0.10 + sin(double_phase) * 0.04 * run_anim_blend)
	if right_arm_pivot:
		right_arm_pivot.position = Vector3(0.30, 0.82 + bob * 0.25, 0)
		right_arm_pivot.rotation = Vector3(right_arm_pitch, -0.05 * run_anim_blend, 0.10 - sin(double_phase) * 0.04 * run_anim_blend)

	var left_leg_pitch := -left_step * 0.90 * run_anim_blend + left_lift * 0.28 * run_anim_blend
	var right_leg_pitch := -right_step * 0.90 * run_anim_blend + right_lift * 0.28 * run_anim_blend
	if not on_floor:
		left_leg_pitch = lerpf(left_leg_pitch, 0.32, 0.4)
		right_leg_pitch = lerpf(right_leg_pitch, 0.32, 0.4)

	if left_leg_pivot:
		left_leg_pivot.position = Vector3(-0.14, 0.40 + left_lift * 0.035 * run_anim_blend, 0)
		left_leg_pivot.rotation = Vector3(left_leg_pitch, 0.0, 0.03 * run_anim_blend)
	if right_leg_pivot:
		right_leg_pivot.position = Vector3(0.14, 0.40 + right_lift * 0.035 * run_anim_blend, 0)
		right_leg_pivot.rotation = Vector3(right_leg_pitch, 0.0, -0.03 * run_anim_blend)


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

	ui_root = Control.new()
	ui_root.name = "UIRoot"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_PASS
	canvas.add_child(ui_root)

	# Time chip (top-left, keep existing timer label)
	var time_card := PanelContainer.new()
	time_card.name = "TimeCard"
	time_card.anchor_left = 0.0
	time_card.anchor_top = 0.0
	time_card.anchor_right = 0.0
	time_card.anchor_bottom = 0.0
	time_card.offset_left = 20
	time_card.offset_top = 20
	time_card.offset_right = 300
	time_card.offset_bottom = 86
	time_card.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var time_style := StyleBoxFlat.new()
	time_style.bg_color = Color(0.07, 0.1, 0.16, 0.62)
	time_style.corner_radius_top_left = 18
	time_style.corner_radius_top_right = 18
	time_style.corner_radius_bottom_right = 18
	time_style.corner_radius_bottom_left = 18
	time_style.border_width_left = 2
	time_style.border_width_top = 2
	time_style.border_width_right = 2
	time_style.border_width_bottom = 2
	time_style.border_color = Color(0.75, 0.88, 1.0, 0.6)
	time_style.shadow_color = Color(0, 0, 0, 0.5)
	time_style.shadow_size = 9
	time_style.shadow_offset = Vector2(0, 4)
	time_card.add_theme_stylebox_override("panel", time_style)
	ui_root.add_child(time_card)

	var time_margin := MarginContainer.new()
	time_margin.add_theme_constant_override("margin_left", 18)
	time_margin.add_theme_constant_override("margin_top", 8)
	time_margin.add_theme_constant_override("margin_right", 18)
	time_margin.add_theme_constant_override("margin_bottom", 8)
	time_card.add_child(time_margin)

	time_label = Label.new()
	time_label.name = "TimeLabel"
	time_label.text = "Time: 0.0"
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	time_label.add_theme_font_size_override("font_size", 32)
	time_label.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	time_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	time_label.add_theme_constant_override("shadow_offset_x", 2)
	time_label.add_theme_constant_override("shadow_offset_y", 2)
	time_margin.add_child(time_label)

	# Score card (top-right)
	score_card = PanelContainer.new()
	score_card.name = "ScoreCard"
	score_card.anchor_left = 1.0
	score_card.anchor_top = 0.0
	score_card.anchor_right = 1.0
	score_card.anchor_bottom = 0.0
	score_card.offset_left = -300
	score_card.offset_top = 20
	score_card.offset_right = -20
	score_card.offset_bottom = 86
	score_card.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var score_style := StyleBoxFlat.new()
	score_style.bg_color = Color(0.07, 0.1, 0.16, 0.62)
	score_style.corner_radius_top_left = 18
	score_style.corner_radius_top_right = 18
	score_style.corner_radius_bottom_right = 18
	score_style.corner_radius_bottom_left = 18
	score_style.border_width_left = 2
	score_style.border_width_top = 2
	score_style.border_width_right = 2
	score_style.border_width_bottom = 2
	score_style.border_color = Color(0.75, 0.88, 1.0, 0.6)
	score_style.shadow_color = Color(0, 0, 0, 0.5)
	score_style.shadow_size = 9
	score_style.shadow_offset = Vector2(0, 4)
	score_card.add_theme_stylebox_override("panel", score_style)
	ui_root.add_child(score_card)

	var score_margin := MarginContainer.new()
	score_margin.add_theme_constant_override("margin_left", 18)
	score_margin.add_theme_constant_override("margin_top", 8)
	score_margin.add_theme_constant_override("margin_right", 18)
	score_margin.add_theme_constant_override("margin_bottom", 8)
	score_card.add_child(score_margin)

	points_label = Label.new()
	points_label.name = "PointsLabel"
	points_label.text = "Score: 0000"
	points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	points_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	points_label.add_theme_font_size_override("font_size", 32)
	points_label.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	points_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	points_label.add_theme_constant_override("shadow_offset_x", 2)
	points_label.add_theme_constant_override("shadow_offset_y", 2)
	score_margin.add_child(points_label)

	# Game Over overlay (centered, hidden by default)
	gameover_label = Label.new()
	gameover_label.name = "GameOverLabel"
	gameover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gameover_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gameover_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gameover_label.add_theme_font_size_override("font_size", 48)
	gameover_label.add_theme_color_override("font_color", Color(1.0, 0.25, 0.25))
	gameover_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	gameover_label.add_theme_constant_override("shadow_offset_x", 3)
	gameover_label.add_theme_constant_override("shadow_offset_y", 3)
	gameover_label.visible = false
	ui_root.add_child(gameover_label)

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

	var half := randf_range(0.55, 1.35)
	var player_x := 0.0
	if player != null:
		player_x = player.global_position.x
	var clamped_player_x := clampf(player_x, -SPAWN_X_RANGE, SPAWN_X_RANGE)
	var random_center := randf_range(-SPAWN_X_RANGE, SPAWN_X_RANGE)
	var spawn_center := lerpf(random_center, clamped_player_x, SPAWN_FOLLOW_WEIGHT)
	var x_min := clampf(spawn_center - SPAWN_LANE_HALF_WIDTH, -SPAWN_X_RANGE, SPAWN_X_RANGE)
	var x_max := clampf(spawn_center + SPAWN_LANE_HALF_WIDTH, -SPAWN_X_RANGE, SPAWN_X_RANGE)
	if x_max - x_min < 0.2:
		x_min = -SPAWN_X_RANGE
		x_max = SPAWN_X_RANGE
	var spawn_x := randf_range(x_min, x_max)
	body.global_position = Vector3(spawn_x, half, z)

	var side := half * 2.0
	var floor_y := -half
	var style := randi_range(0, 2)

	var base_mat := _make_obstacle_material(
		Color(randf_range(0.18, 0.35), randf_range(0.24, 0.42), randf_range(0.46, 0.72)),
		0.78,
		0.15)
	var accent_mat := _make_obstacle_material(
		Color(randf_range(0.85, 1.0), randf_range(0.52, 0.78), randf_range(0.16, 0.36)),
		0.55,
		0.4)
	var metal_mat := _make_obstacle_material(
		Color(randf_range(0.58, 0.82), randf_range(0.58, 0.82), randf_range(0.62, 0.92)),
		0.25,
		0.75)

	match style:
		0:
			# Barricade: base + two poles + guard beam
			var base := BoxMesh.new()
			base.size = Vector3(side * 1.70, side * 0.28, side * 0.90)
			_add_obstacle_mesh(
				body, base,
				Vector3(0, floor_y + base.size.y * 0.5, 0),
				Vector3.ZERO,
				base_mat)

			var pole := CylinderMesh.new()
			pole.height = side * 0.95
			pole.top_radius = side * 0.09
			pole.bottom_radius = side * 0.10
			_add_obstacle_mesh(
				body, pole,
				Vector3(-side * 0.52, floor_y + base.size.y + pole.height * 0.5, 0),
				Vector3.ZERO,
				metal_mat)
			_add_obstacle_mesh(
				body, pole,
				Vector3(side * 0.52, floor_y + base.size.y + pole.height * 0.5, 0),
				Vector3.ZERO,
				metal_mat)

			var guard_beam := BoxMesh.new()
			guard_beam.size = Vector3(side * 1.25, side * 0.15, side * 0.20)
			_add_obstacle_mesh(
				body, guard_beam,
				Vector3(0, floor_y + base.size.y + pole.height * 0.72, 0),
				Vector3.ZERO,
				accent_mat)

			var stripe := BoxMesh.new()
			stripe.size = Vector3(side * 0.86, side * 0.08, side * 0.16)
			_add_obstacle_mesh(
				body, stripe,
				Vector3(0, floor_y + base.size.y + pole.height * 0.50, 0),
				Vector3(0, 0, 18),
				accent_mat)

			body.set_meta("spin_y_speed", randf_range(-0.38, 0.38))

		1:
			# Rotating hammer: pedestal + pillar + spinning beam
			var pedestal := BoxMesh.new()
			pedestal.size = Vector3(side * 1.15, side * 0.32, side * 1.15)
			_add_obstacle_mesh(
				body, pedestal,
				Vector3(0, floor_y + pedestal.size.y * 0.5, 0),
				Vector3.ZERO,
				base_mat)

			var pillar := CylinderMesh.new()
			pillar.height = side * 1.40
			pillar.top_radius = side * 0.11
			pillar.bottom_radius = side * 0.13
			_add_obstacle_mesh(
				body, pillar,
				Vector3(0, floor_y + pedestal.size.y + pillar.height * 0.5, 0),
				Vector3.ZERO,
				metal_mat)

			var rotor := Node3D.new()
			rotor.name = "Rotor"
			rotor.position = Vector3(0, floor_y + pedestal.size.y + pillar.height * 0.80, 0)
			body.add_child(rotor)

			var beam := BoxMesh.new()
			beam.size = Vector3(side * 1.55, side * 0.16, side * 0.16)
			_add_obstacle_mesh(
				rotor, beam,
				Vector3.ZERO,
				Vector3.ZERO,
				accent_mat)

			var hammer_head := BoxMesh.new()
			hammer_head.size = Vector3(side * 0.35, side * 0.35, side * 0.35)
			_add_obstacle_mesh(
				rotor, hammer_head,
				Vector3(side * 0.78, 0, 0),
				Vector3.ZERO,
				metal_mat)

			body.set_meta("spin_y_speed", randf_range(-0.24, 0.24))
			body.set_meta("rotor_path", NodePath("Rotor"))
			body.set_meta("rotor_axis", Vector3(0, 0, 1))
			body.set_meta("rotor_speed", randf_range(1.1, 1.9))

		_:
			# Pillar: base + core + top + rotating fins
			var plinth := CylinderMesh.new()
			plinth.height = side * 0.36
			plinth.top_radius = side * 0.38
			plinth.bottom_radius = side * 0.46
			_add_obstacle_mesh(
				body, plinth,
				Vector3(0, floor_y + plinth.height * 0.5, 0),
				Vector3.ZERO,
				base_mat)

			var core := CylinderMesh.new()
			core.height = side * 1.55
			core.top_radius = side * 0.22
			core.bottom_radius = side * 0.24
			_add_obstacle_mesh(
				body, core,
				Vector3(0, floor_y + plinth.height + core.height * 0.5, 0),
				Vector3.ZERO,
				metal_mat)

			var cap := SphereMesh.new()
			cap.radius = side * 0.22
			cap.height = side * 0.44
			_add_obstacle_mesh(
				body, cap,
				Vector3(0, floor_y + plinth.height + core.height + cap.radius * 0.7, 0),
				Vector3.ZERO,
				accent_mat)

			var fin_rotor := Node3D.new()
			fin_rotor.name = "FinRotor"
			fin_rotor.position = Vector3(0, floor_y + plinth.height + core.height * 0.55, 0)
			body.add_child(fin_rotor)

			for i in range(3):
				var fin := BoxMesh.new()
				fin.size = Vector3(side * 1.05, side * 0.10, side * 0.14)
				_add_obstacle_mesh(
					fin_rotor, fin,
					Vector3.ZERO,
					Vector3(0, i * 120.0, 0),
					accent_mat)

			body.set_meta("spin_y_speed", randf_range(-0.42, 0.42))
			body.set_meta("rotor_path", NodePath("FinRotor"))
			body.set_meta("rotor_axis", Vector3.UP)
			body.set_meta("rotor_speed", randf_range(-0.9, 0.9))

	var cs    := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(side, side, side)
	cs.shape   = shape
	body.add_child(cs)


func _make_obstacle_material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	return mat


func _add_obstacle_mesh(
	parent: Node3D, mesh: Mesh, pos: Vector3, rot_deg: Vector3, mat: StandardMaterial3D
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _animate_obstacles(delta: float) -> void:
	for obs in get_tree().get_nodes_in_group("obstacles"):
		if not (obs is Node3D):
			continue
		var obs_node := obs as Node3D

		var spin_y := float(obs_node.get_meta("spin_y_speed", 0.0))
		if spin_y != 0.0:
			obs_node.rotate_y(spin_y * delta)

		var rotor_path: NodePath = obs_node.get_meta("rotor_path", NodePath(""))
		if rotor_path == NodePath(""):
			continue

		var rotor := obs_node.get_node_or_null(rotor_path) as Node3D
		if rotor == null:
			continue

		var rotor_axis: Vector3 = obs_node.get_meta("rotor_axis", Vector3.ZERO)
		var rotor_speed := float(obs_node.get_meta("rotor_speed", 0.0))
		if rotor_speed == 0.0:
			continue
		if rotor_axis.length_squared() > 0.0:
			rotor.rotate(rotor_axis.normalized(), rotor_speed * delta)


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
	_play_score_feedback(pickup_points)

	# Prevent double-collection
	pickup.set_deferred("monitoring", false)

	# Quick "pop" scale-up then free
	var tween := pickup.create_tween()
	tween.tween_property(pickup, "scale", Vector3.ONE * 2.5, 0.12)
	tween.tween_callback(pickup.queue_free)


func _update_points_label() -> void:
	points_label.text = "Score: %04d" % score


func _play_score_feedback(added_points: int) -> void:
	var card_scale := 1.08
	var text_scale := 1.15
	if score > 0 and score % 100 == 0:
		card_scale = 1.13
		text_scale = 1.20

	if score_card:
		score_card.scale = Vector2.ONE
		score_card.modulate = Color(1.0, 0.98, 0.90, 1.0)

		var card_tween := create_tween()
		card_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		card_tween.tween_property(score_card, "scale", Vector2.ONE * card_scale, 0.08)
		card_tween.tween_property(score_card, "scale", Vector2.ONE, 0.14)

		var card_color_tween := create_tween()
		card_color_tween.tween_property(score_card, "modulate", Color.WHITE, 0.22)

	if points_label:
		points_label.scale = Vector2.ONE
		points_label.modulate = Color(1.0, 1.0, 0.86, 1.0)

		var text_tween := create_tween()
		text_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		text_tween.tween_property(points_label, "scale", Vector2.ONE * text_scale, 0.08)
		text_tween.tween_property(points_label, "scale", Vector2.ONE, 0.12)

		var text_color_tween := create_tween()
		text_color_tween.tween_property(points_label, "modulate", Color(1.0, 0.95, 0.72, 1.0), 0.10)
		text_color_tween.tween_property(points_label, "modulate", Color.WHITE, 0.12)

	if ui_root:
		var float_label := Label.new()
		float_label.name = "ScoreFloatLabel"
		float_label.text = "+%d" % added_points
		float_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		float_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		float_label.anchor_left = 1.0
		float_label.anchor_right = 1.0
		float_label.anchor_top = 0.0
		float_label.anchor_bottom = 0.0
		float_label.offset_left = -220
		float_label.offset_top = 90
		float_label.offset_right = -20
		float_label.offset_bottom = 124
		float_label.add_theme_font_size_override("font_size", 24)
		float_label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.58, 1.0))
		float_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
		float_label.add_theme_constant_override("shadow_offset_x", 1)
		float_label.add_theme_constant_override("shadow_offset_y", 1)
		float_label.modulate = Color(1, 1, 1, 0)
		ui_root.add_child(float_label)

		var rise_top := float_label.offset_top - 34.0
		var rise_bottom := float_label.offset_bottom - 34.0

		var float_tween := create_tween()
		float_tween.tween_property(float_label, "modulate:a", 1.0, 0.06)
		float_tween.parallel().tween_property(float_label, "offset_top", float_label.offset_top - 8.0, 0.06)
		float_tween.parallel().tween_property(float_label, "offset_bottom", float_label.offset_bottom - 8.0, 0.06)
		float_tween.tween_property(float_label, "modulate:a", 0.0, 0.34)
		float_tween.parallel().tween_property(float_label, "offset_top", rise_top, 0.34)
		float_tween.parallel().tween_property(float_label, "offset_bottom", rise_bottom, 0.34)
		float_tween.tween_callback(float_label.queue_free)

	_spawn_head_score_feedback(added_points)


func _spawn_head_score_feedback(added_points: int) -> void:
	if ui_root == null or player == null:
		return

	var head_label := Label.new()
	head_label.name = "HeadScoreFloatLabel"
	head_label.text = "+%d" % added_points
	head_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head_label.custom_minimum_size = Vector2(96, 30)
	head_label.add_theme_font_size_override("font_size", 24)
	head_label.add_theme_color_override("font_color", Color(1.0, 0.96, 0.70, 1.0))
	head_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	head_label.add_theme_constant_override("shadow_offset_x", 2)
	head_label.add_theme_constant_override("shadow_offset_y", 2)
	head_label.modulate = Color(1, 1, 1, 0)
	ui_root.add_child(head_label)

	var float_data: HeadScoreFloat = HeadScoreFloat.new()
	float_data.label = head_label
	float_data.base_offset = Vector3(randf_range(-0.14, 0.14), 1.9, 0)
	float_data.rise_height = randf_range(0.6, 0.95)
	float_data.drift_x = randf_range(-0.15, 0.15)
	float_data.duration = randf_range(0.42, 0.56)
	head_score_floats.append(float_data)


func _update_head_score_feedbacks(delta: float) -> void:
	if head_score_floats.is_empty() or player == null:
		return

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return

	for i in range(head_score_floats.size() - 1, -1, -1):
		var float_data: HeadScoreFloat = head_score_floats[i]
		if float_data.label == null:
			head_score_floats.remove_at(i)
			continue

		float_data.age += delta
		var t := clampf(float_data.age / float_data.duration, 0.0, 1.0)
		if t >= 1.0:
			float_data.label.queue_free()
			head_score_floats.remove_at(i)
			continue

		var world_pos := player.global_position + float_data.base_offset
		world_pos.y += float_data.rise_height * t
		world_pos.x += float_data.drift_x * t

		if cam.is_position_behind(world_pos):
			float_data.label.visible = false
			continue

		float_data.label.visible = true
		var screen_pos := cam.unproject_position(world_pos)
		float_data.label.position = screen_pos + Vector2(-48, -20)

		var fade_in := clampf(t / 0.18, 0.0, 1.0)
		var fade_out := clampf((1.0 - t) / 0.45, 0.0, 1.0)
		var alpha := minf(fade_in, fade_out)
		float_data.label.modulate = Color(1, 1, 1, alpha)
		float_data.label.scale = Vector2.ONE * (0.92 + 0.15 * fade_in)


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

	_update_player_model_animation(delta)
	_animate_obstacles(delta)

	if camera_rig:
		camera_rig.global_position = player.global_position

	if ground:
		ground.position.z = player.global_position.z

	_update_head_score_feedbacks(delta)

	if not game_over:
		score_time += delta
		time_label.text = "Time: %.1f" % score_time
