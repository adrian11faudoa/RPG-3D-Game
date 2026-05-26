## player/controller/player_controller.gd
## Full third-person character controller with climbing, swimming, gliding,
## dodge rolling, and stamina. Built on CharacterBody3D.
##
## State machine approach — each locomotion state is a method that:
##   1. Reads input
##   2. Computes desired velocity
##   3. Transitions to another state if needed
##
## Physics tick: _physics_process() calls the current state handler.

class_name PlayerController
extends CharacterBody3D

# ─── Signals ──────────────────────────────────────────────────────────────────
signal state_changed(old_state: LocomotionState, new_state: LocomotionState)
signal stamina_changed(current: float, max_val: float)
signal landed(impact_speed: float)

# ─── Enums ────────────────────────────────────────────────────────────────────
enum LocomotionState {
	GROUNDED,
	AIRBORNE,
	SWIMMING,
	CLIMBING,
	GLIDING,
	DODGING,
	DEAD,
}

# ─── Export Params ────────────────────────────────────────────────────────────
@export_group("Movement")
@export var walk_speed       : float = 5.0
@export var sprint_speed     : float = 9.5
@export var acceleration     : float = 15.0
@export var friction         : float = 10.0
@export var air_control      : float = 0.3
@export var jump_velocity    : float = 7.0
@export var coyote_time      : float = 0.12   # seconds after cliff edge to still jump
@export var jump_buffer_time : float = 0.10   # seconds to buffer jump input

@export_group("Stamina")
@export var max_stamina      : float = 100.0
@export var sprint_drain     : float = 15.0   # per second
@export var jump_cost        : float = 10.0
@export var dodge_cost       : float = 20.0
@export var climb_drain      : float = 8.0
@export var regen_rate       : float = 12.0
@export var regen_delay      : float = 1.5    # seconds before regen starts

@export_group("Climbing")
@export var climb_speed      : float = 3.5
@export var climb_detect_dist: float = 0.6
@export var max_climb_angle  : float = 75.0   # degrees

@export_group("Swimming")
@export var swim_speed       : float = 4.0
@export var swim_up_speed    : float = 3.0
@export var buoyancy         : float = 4.0

@export_group("Gliding")
@export var glide_gravity    : float = 2.0    # reduced gravity while gliding
@export var glide_forward    : float = 8.0
@export var glide_turn_speed : float = 1.2

@export_group("Dodge")
@export var dodge_speed      : float = 12.0
@export var dodge_duration   : float = 0.35
@export var dodge_invincible : float = 0.2    # i-frames

# ─── Node References ──────────────────────────────────────────────────────────
@onready var _camera_pivot    : Node3D       = $CameraPivot
@onready var _camera          : Camera3D     = $CameraPivot/SpringArm3D/Camera3D
@onready var _spring_arm      : SpringArm3D  = $CameraPivot/SpringArm3D
@onready var _animator        : AnimationTree= $AnimationTree
@onready var _climb_detector  : RayCast3D    = $ClimbDetector
@onready var _water_detector  : Area3D       = $WaterDetector
@onready var _mesh_root       : Node3D       = $MeshRoot
@onready var _stamina_regen_timer: Timer     = $StaminaRegenTimer
@onready var _coyote_timer    : Timer        = $CoyoteTimer
@onready var _jump_buffer_timer: Timer       = $JumpBufferTimer
@onready var _dodge_timer     : Timer        = $DodgeTimer

# ─── Runtime State ────────────────────────────────────────────────────────────
var _state          : LocomotionState = LocomotionState.GROUNDED
var _stamina        : float           = 100.0
var _in_water       : bool            = false
var _water_surface  : float           = 0.0
var _is_sprinting   : bool            = false
var _dodge_dir      : Vector3         = Vector3.ZERO
var _pre_land_vel   : float           = 0.0
var _cam_yaw        : float           = 0.0
var _cam_pitch      : float           = -15.0
var _input_dir      : Vector2         = Vector2.ZERO
var _look_dir       : Vector3         = Vector3.FORWARD
var _can_coyote_jump: bool            = false
var _jump_buffered  : bool            = false

const GRAVITY       : float           = -22.0
const SWIM_SURFACE_OFFSET: float      = 0.6


# ─── Lifecycle ────────────────────────────────────────────────────────────────
func _ready() -> void:
	_stamina               = max_stamina
	_camera.current        = is_multiplayer_authority()
	_water_detector.body_entered.connect(_on_water_entered)
	_water_detector.body_exited.connect(_on_water_exited)
	_coyote_timer.timeout.connect(func(): _can_coyote_jump = false)
	_jump_buffer_timer.timeout.connect(func(): _jump_buffered = false)
	_dodge_timer.timeout.connect(_on_dodge_finished)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion:
		_cam_yaw   -= event.relative.x * 0.15
		_cam_pitch  = clampf(_cam_pitch - event.relative.y * 0.15, -80.0, 80.0)
		_camera_pivot.rotation_degrees.y = _cam_yaw
		_camera_pivot.rotation_degrees.x = _cam_pitch

	if event.is_action_pressed("jump"):
		_jump_buffered = true
		_jump_buffer_timer.start(jump_buffer_time)

	if event.is_action_pressed("dodge") and _state != LocomotionState.DODGING:
		_try_dodge()


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_read_input()
	_in_water = _water_detector.has_overlapping_bodies()

	match _state:
		LocomotionState.GROUNDED:  _state_grounded(delta)
		LocomotionState.AIRBORNE:  _state_airborne(delta)
		LocomotionState.SWIMMING:  _state_swimming(delta)
		LocomotionState.CLIMBING:  _state_climbing(delta)
		LocomotionState.GLIDING:   _state_gliding(delta)
		LocomotionState.DODGING:   _state_dodging(delta)

	_regen_stamina(delta)
	_update_animation()
	move_and_slide()


# ─── Input ────────────────────────────────────────────────────────────────────
func _read_input() -> void:
	_input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	_is_sprinting = Input.is_action_pressed("sprint") and _stamina > 5.0

	# World-space move direction relative to camera
	var cam_basis  := _camera_pivot.global_basis
	var forward    := -cam_basis.z
	var right      :=  cam_basis.x
	forward.y      = 0.0
	right.y        = 0.0
	forward        = forward.normalized()
	right          = right.normalized()
	_look_dir      = (forward * _input_dir.y + right * _input_dir.x)


# ─── State: Grounded ──────────────────────────────────────────────────────────
func _state_grounded(delta: float) -> void:
	# Transition: fell off edge
	if not is_on_floor():
		_can_coyote_jump = true
		_coyote_timer.start(coyote_time)
		_change_state(LocomotionState.AIRBORNE)
		return

	# Transition: jump
	if _jump_buffered and _consume_stamina(jump_cost):
		_jump_buffered = false
		_pre_land_vel  = 0.0
		velocity.y     = jump_velocity
		_change_state(LocomotionState.AIRBORNE)
		return

	# Transition: climb
	if _check_climbable():
		_change_state(LocomotionState.CLIMBING)
		return

	# Transition: water
	if _in_water:
		_change_state(LocomotionState.SWIMMING)
		return

	# Horizontal movement
	var speed      := sprint_speed if _is_sprinting else walk_speed
	var target_vel := _look_dir * speed

	if _is_sprinting and _look_dir.length_squared() > 0.01:
		_drain_stamina(sprint_drain * delta)

	velocity.x = move_toward(velocity.x, target_vel.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, acceleration * delta)
	velocity.y = -0.5  # Keep grounded on slopes

	# Face movement direction smoothly
	if _look_dir.length_squared() > 0.01:
		var target_angle := atan2(_look_dir.x, _look_dir.z)
		_mesh_root.rotation.y = rotate_toward(
			_mesh_root.rotation.y, target_angle, 10.0 * delta
		)


# ─── State: Airborne ──────────────────────────────────────────────────────────
func _state_airborne(delta: float) -> void:
	# Transition: landed
	if is_on_floor():
		var impact := absf(_pre_land_vel)
		landed.emit(impact)
		_change_state(LocomotionState.GROUNDED)
		return

	# Transition: glide
	if Input.is_action_pressed("glide") and velocity.y < 0.0:
		_change_state(LocomotionState.GLIDING)
		return

	# Transition: water
	if _in_water:
		_change_state(LocomotionState.SWIMMING)
		return

	# Coyote jump
	if _jump_buffered and _can_coyote_jump and _consume_stamina(jump_cost):
		_jump_buffered    = false
		_can_coyote_jump  = false
		velocity.y        = jump_velocity

	# Air control
	var target_vel := _look_dir * walk_speed
	velocity.x = move_toward(velocity.x, target_vel.x, acceleration * air_control * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, acceleration * air_control * delta)

	_pre_land_vel = velocity.y
	velocity.y   += GRAVITY * delta


# ─── State: Swimming ──────────────────────────────────────────────────────────
func _state_swimming(delta: float) -> void:
	if not _in_water:
		_change_state(LocomotionState.AIRBORNE)
		return

	var depth_offset := global_position.y - _water_surface

	# At surface: allow small jump out
	if depth_offset > -SWIM_SURFACE_OFFSET and _jump_buffered:
		_jump_buffered = false
		velocity.y     = jump_velocity * 0.7
		_change_state(LocomotionState.AIRBORNE)
		return

	# Buoyancy toward surface
	var buoy_force := 0.0
	if depth_offset < -SWIM_SURFACE_OFFSET:
		buoy_force = buoyancy * (-SWIM_SURFACE_OFFSET - depth_offset)

	var vertical_input := 0.0
	if Input.is_action_pressed("jump"):    vertical_input =  1.0
	if Input.is_action_pressed("crouch"):  vertical_input = -1.0

	velocity.x = move_toward(velocity.x, _look_dir.x * swim_speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, _look_dir.z * swim_speed, acceleration * delta)
	velocity.y = move_toward(velocity.y,
		vertical_input * swim_up_speed + buoy_force,
		acceleration * delta
	)


# ─── State: Climbing ──────────────────────────────────────────────────────────
func _state_climbing(delta: float) -> void:
	if not _check_climbable():
		_change_state(LocomotionState.AIRBORNE)
		return

	if _in_water:
		_change_state(LocomotionState.SWIMMING)
		return

	# Jump off wall
	if _jump_buffered and _consume_stamina(jump_cost):
		_jump_buffered = false
		var wall_normal := _climb_detector.get_collision_normal()
		velocity = wall_normal * 5.0 + Vector3.UP * jump_velocity * 0.8
		_change_state(LocomotionState.AIRBORNE)
		return

	_drain_stamina(climb_drain * delta)

	# Run out of stamina: fall
	if _stamina <= 0.0:
		_change_state(LocomotionState.AIRBORNE)
		return

	var vertical   := _input_dir.y * climb_speed   # forward = up on wall
	var horizontal := _input_dir.x * climb_speed

	var wall_normal := _climb_detector.get_collision_normal()
	var wall_right  := wall_normal.cross(Vector3.UP).normalized()
	var wall_up     := wall_right.cross(wall_normal).normalized()

	velocity = -wall_up * vertical + wall_right * horizontal


func _check_climbable() -> bool:
	if not Input.is_action_pressed("climb"):
		return false
	_climb_detector.force_raycast_update()
	if not _climb_detector.is_colliding():
		return false
	var normal := _climb_detector.get_collision_normal()
	var angle  := rad_to_deg(normal.angle_to(Vector3.UP))
	return angle > max_climb_angle


# ─── State: Gliding ───────────────────────────────────────────────────────────
func _state_gliding(delta: float) -> void:
	if not Input.is_action_pressed("glide") or is_on_floor():
		_change_state(LocomotionState.AIRBORNE if not is_on_floor() else LocomotionState.GROUNDED)
		return

	if _in_water:
		_change_state(LocomotionState.SWIMMING)
		return

	var cam_forward := -_camera_pivot.global_basis.z
	cam_forward.y   = 0.0
	cam_forward     = cam_forward.normalized()

	velocity.x  = move_toward(velocity.x, cam_forward.x * glide_forward, glide_turn_speed * delta)
	velocity.z  = move_toward(velocity.z, cam_forward.z * glide_forward, glide_turn_speed * delta)
	velocity.y += glide_gravity * GRAVITY * delta
	velocity.y  = maxf(velocity.y, -3.0)  # Terminal glide descent speed


# ─── State: Dodging ───────────────────────────────────────────────────────────
func _try_dodge() -> void:
	if _state == LocomotionState.DEAD:
		return
	if not _consume_stamina(dodge_cost):
		return
	_dodge_dir = _look_dir if _look_dir.length_squared() > 0.01 else -_mesh_root.global_basis.z
	_dodge_timer.start(dodge_duration)
	_change_state(LocomotionState.DODGING)
	# Signal invincibility frames to combat system
	get_node("/root/GameState/CombatBus").emit_signal(
		"player_invincible", get_multiplayer_authority(), dodge_invincible
	)


func _state_dodging(delta: float) -> void:
	velocity.x = _dodge_dir.x * dodge_speed
	velocity.z = _dodge_dir.z * dodge_speed
	if not is_on_floor():
		velocity.y += GRAVITY * delta


func _on_dodge_finished() -> void:
	if _state == LocomotionState.DODGING:
		_change_state(LocomotionState.GROUNDED if is_on_floor() else LocomotionState.AIRBORNE)


# ─── Stamina ──────────────────────────────────────────────────────────────────
func _drain_stamina(amount: float) -> void:
	_stamina = maxf(0.0, _stamina - amount)
	_stamina_regen_timer.start(regen_delay)
	stamina_changed.emit(_stamina, max_stamina)


func _consume_stamina(amount: float) -> bool:
	if _stamina < amount:
		return false
	_drain_stamina(amount)
	return true


func _regen_stamina(delta: float) -> void:
	if _stamina_regen_timer.is_stopped() and _stamina < max_stamina:
		_stamina = minf(max_stamina, _stamina + regen_rate * delta)
		stamina_changed.emit(_stamina, max_stamina)


# ─── Animation ────────────────────────────────────────────────────────────────
func _update_animation() -> void:
	var speed_h := Vector2(velocity.x, velocity.z).length()
	_animator.set("parameters/speed/blend_position", speed_h)
	_animator.set("parameters/state/transition_request", LocomotionState.keys()[_state].to_lower())
	_animator.set("parameters/in_air/blend_position", velocity.y)


# ─── Helpers ──────────────────────────────────────────────────────────────────
func _change_state(new_state: LocomotionState) -> void:
	var old := _state
	_state   = new_state
	state_changed.emit(old, new_state)


func _on_water_entered(body: Node3D) -> void:
	if body.is_in_group("water_volume"):
		_water_surface = body.global_position.y + body.get_node("CollisionShape3D").shape.size.y * 0.5


func _on_water_exited(_body: Node3D) -> void:
	pass  # _in_water handled by area overlap check


func rotate_toward(from: float, to: float, max_delta: float) -> float:
	var diff := wrapf(to - from, -PI, PI)
	return from + clampf(diff, -max_delta, max_delta)


# ─── Multiplayer Sync ─────────────────────────────────────────────────────────
@onready var _sync := $MultiplayerSynchronizer

func _setup_sync() -> void:
	# Synchronize position, rotation, velocity, and animation state
	_sync.root_path         = get_path()
	_sync.replication_interval = 0.05  # 20Hz
