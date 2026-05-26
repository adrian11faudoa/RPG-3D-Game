## world/creatures/creature_ai.gd
## Behavior tree-based AI for all creatures and NPCs.
## Supports: patrol, idle, investigate, flee, chase, group combat, pack hunting.
##
## BT Node types:
##   Selector    - runs children left-to-right, returns success on first success
##   Sequence    - runs children left-to-right, returns failure on first failure
##   Condition   - leaf, returns success/failure based on blackboard
##   Action      - leaf, executes behavior, returns running/success/failure
##
## Blackboard: shared dictionary of state (target, last_seen_pos, threat_level, etc.)

class_name CreatureAI
extends Node

# ─── BT Status ────────────────────────────────────────────────────────────────
enum BTStatus { RUNNING, SUCCESS, FAILURE }

# ─── Configuration ────────────────────────────────────────────────────────────
@export var creature_data    : CreatureData     # JSON-loaded creature definition
@export var detection_range  : float = 20.0
@export var attack_range     : float = 2.5
@export var flee_hp_percent  : float = 0.2      # flee below 20% HP
@export var patrol_radius    : float = 15.0
@export var group_radius     : float = 25.0     # radius to call allies

# ─── References ───────────────────────────────────────────────────────────────
@onready var _nav_agent     : NavigationAgent3D = $NavigationAgent3D
@onready var _detection_area: Area3D            = $DetectionArea
@onready var _attack_area   : Area3D            = $AttackArea
@onready var _animator      : AnimationTree     = $AnimationTree
@onready var _actor         : CharacterBody3D   = get_parent()

# ─── Blackboard ───────────────────────────────────────────────────────────────
var bb: Dictionary = {
	"target":         null,
	"last_seen_pos":  Vector3.ZERO,
	"patrol_origin":  Vector3.ZERO,
	"patrol_target":  Vector3.ZERO,
	"threat_level":   0.0,
	"alerted":        false,
	"in_combat":      false,
	"pack_members":   [],
	"current_action": "",
	"action_timer":   0.0,
	"can_attack":     true,
}

# ─── Behavior Tree Root ───────────────────────────────────────────────────────
var _bt_root: BTNode

# ─── Init ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	bb["patrol_origin"] = _actor.global_position
	bb["patrol_target"] = _get_random_patrol_point()
	_detection_area.body_entered.connect(_on_body_entered_detection)
	_detection_area.body_exited.connect(_on_body_exited_detection)
	_attack_area.body_entered.connect(_on_body_entered_attack)
	_bt_root = _build_behavior_tree()
	set_process(true)


func _process(delta: float) -> void:
	_update_blackboard(delta)
	_bt_root.tick(bb, _actor, delta)
	_update_movement(delta)
	_update_animation()


# ─── Behavior Tree Construction ───────────────────────────────────────────────
func _build_behavior_tree() -> BTNode:
	# Root Selector: try high-priority behaviors first
	return BTSelector.new([
		# 1. DEATH (highest priority — handled externally, included for completeness)
		BTSequence.new([
			BTCondition.new(func(_b, _a): return _b["current_action"] == "dying"),
			BTAction.new(_action_die),
		]),

		# 2. FLEE if low HP and target exists
		BTSequence.new([
			BTCondition.new(func(b, a): return _should_flee(b, a)),
			BTAction.new(_action_flee),
		]),

		# 3. COMBAT if in range
		BTSequence.new([
			BTCondition.new(func(b, _a): return b["target"] != null),
			BTSelector.new([
				# 3a. Attack if in attack range
				BTSequence.new([
					BTCondition.new(func(b, a): return _target_in_attack_range(b, a)),
					BTCondition.new(func(b, _a): return b["can_attack"]),
					BTAction.new(_action_attack),
				]),
				# 3b. Chase if target visible but out of range
				BTSequence.new([
					BTCondition.new(func(b, a): return _can_see_target(b, a)),
					BTAction.new(_action_chase),
				]),
				# 3c. Move to last seen position
				BTAction.new(_action_investigate),
			]),
		]),

		# 4. ALERT: heard something (investigate sound)
		BTSequence.new([
			BTCondition.new(func(b, _a): return b["alerted"] and b["target"] == null),
			BTAction.new(_action_alert_investigate),
		]),

		# 5. PATROL (default)
		BTSequence.new([
			BTCondition.new(func(b, a): return _at_patrol_target(b, a)),
			BTAction.new(_action_pick_patrol_point),
		]),
		BTAction.new(_action_patrol),
	])


# ─── Actions ──────────────────────────────────────────────────────────────────
func _action_attack(b: Dictionary, _a: Node3D, delta: float) -> BTStatus:
	if not b["can_attack"]:
		return BTStatus.FAILURE
	var target := b["target"] as Node3D
	if target == null:
		return BTStatus.FAILURE

	# Face target
	_face_target(target.global_position)

	# Play attack animation → triggers hitbox via AnimationEvent
	_animator.set("parameters/OneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	b["can_attack"] = false
	b["action_timer"] = creature_data.attack_cooldown

	# Deal damage through CombatSystem
	var hit   := HitData.new()
	hit.damage = creature_data.attack_damage
	hit.knockback = creature_data.attack_knockback
	hit.element   = creature_data.attack_element
	CombatSystem.apply_hit(_actor, target, hit)

	return BTStatus.SUCCESS


func _action_chase(b: Dictionary, _a: Node3D, _delta: float) -> BTStatus:
	var target := b["target"] as Node3D
	if target == null:
		return BTStatus.FAILURE
	b["last_seen_pos"] = target.global_position

	# Pack hunting: call nearby allies
	if creature_data.is_pack_hunter:
		_call_pack_to_target(target)

	_nav_agent.target_position = target.global_position
	return BTStatus.RUNNING


func _action_investigate(b: Dictionary, _a: Node3D, _delta: float) -> BTStatus:
	_nav_agent.target_position = b["last_seen_pos"]
	# Lost target — check if we've arrived at last seen
	if _actor.global_position.distance_to(b["last_seen_pos"]) < 2.0:
		b["target"]    = null
		b["in_combat"] = false
		return BTStatus.SUCCESS
	return BTStatus.RUNNING


func _action_alert_investigate(b: Dictionary, _a: Node3D, _delta: float) -> BTStatus:
	_nav_agent.target_position = b["last_seen_pos"]
	b["action_timer"] -= get_process_delta_time()
	if b["action_timer"] <= 0.0:
		b["alerted"] = false
		return BTStatus.SUCCESS
	return BTStatus.RUNNING


func _action_flee(b: Dictionary, a: Node3D, _delta: float) -> BTStatus:
	var target := b["target"] as Node3D
	if target == null:
		return BTStatus.FAILURE
	# Run in opposite direction
	var flee_dir := (a.global_position - target.global_position).normalized()
	var flee_pos := a.global_position + flee_dir * 20.0
	_nav_agent.target_position = flee_pos
	return BTStatus.RUNNING


func _action_patrol(b: Dictionary, _a: Node3D, _delta: float) -> BTStatus:
	_nav_agent.target_position = b["patrol_target"]
	return BTStatus.RUNNING


func _action_pick_patrol_point(b: Dictionary, _a: Node3D, _delta: float) -> BTStatus:
	b["patrol_target"] = _get_random_patrol_point()
	b["action_timer"]  = randf_range(2.0, 5.0)  # Idle time at patrol point
	return BTStatus.SUCCESS


func _action_die(_b: Dictionary, a: Node3D, _delta: float) -> BTStatus:
	a.queue_free()
	return BTStatus.SUCCESS


# ─── Conditions ───────────────────────────────────────────────────────────────
func _should_flee(b: Dictionary, _a: Node3D) -> bool:
	if b["target"] == null or not creature_data.can_flee:
		return false
	var hp := CombatSystem.get_actor_hp(_actor)
	var max_hp := CombatSystem.get_actor_max_hp(_actor)
	return (hp / max_hp) <= flee_hp_percent


func _target_in_attack_range(b: Dictionary, a: Node3D) -> bool:
	var target := b["target"] as Node3D
	return target != null and a.global_position.distance_to(target.global_position) <= attack_range


func _can_see_target(b: Dictionary, a: Node3D) -> bool:
	var target := b["target"] as Node3D
	if target == null:
		return false
	var space  := a.get_world_3d().direct_space_state
	var from    := a.global_position + Vector3.UP * 1.0
	var to      := target.global_position + Vector3.UP * 1.0
	var query   := PhysicsRayQueryParameters3D.create(from, to, 1)  # Layer 1 = terrain
	var result  := space.intersect_ray(query)
	return result.is_empty()  # No terrain obstruction


func _at_patrol_target(b: Dictionary, a: Node3D) -> bool:
	return a.global_position.distance_to(b["patrol_target"]) < 2.0


# ─── Blackboard Updates ───────────────────────────────────────────────────────
func _update_blackboard(delta: float) -> void:
	# Cool down attack
	if not bb["can_attack"]:
		bb["action_timer"] -= delta
		if bb["action_timer"] <= 0.0:
			bb["can_attack"] = true

	# Threat decay
	bb["threat_level"] = maxf(0.0, bb["threat_level"] - delta * 5.0)

	# Lose target if out of detection range and not recently seen
	if bb["target"] != null:
		var t := bb["target"] as Node3D
		if not is_instance_valid(t):
			bb["target"]    = null
			bb["in_combat"] = false
		elif _actor.global_position.distance_to(t.global_position) > detection_range * 2.0:
			bb["last_seen_pos"] = t.global_position
			bb["target"]        = null
			bb["in_combat"]     = false


# ─── Detection ────────────────────────────────────────────────────────────────
func _on_body_entered_detection(body: Node3D) -> void:
	if body.is_in_group("players") and bb["target"] == null:
		if _is_hostile_to(body):
			bb["target"]    = body
			bb["in_combat"] = true
			bb["alerted"]   = true
			bb["threat_level"] += 50.0
			_animator.set("parameters/alerted/transition_request", "alerted")


func _on_body_exited_detection(body: Node3D) -> void:
	if body == bb["target"]:
		bb["last_seen_pos"] = body.global_position


func _on_body_entered_attack(body: Node3D) -> void:
	if body == bb["target"]:
		pass  # Attack handled in BT action


func _is_hostile_to(body: Node3D) -> bool:
	# Check creature faction vs player reputation
	if body.has_method("get_faction"):
		var player_faction := body.get_faction()
		return creature_data.hostile_factions.has(player_faction)
	return creature_data.hostile_to_players


# ─── Pack Hunting ─────────────────────────────────────────────────────────────
func _call_pack_to_target(target: Node3D) -> void:
	var nearby := get_tree().get_nodes_in_group(creature_data.pack_group)
	for member: Node3D in nearby:
		if member == _actor:
			continue
		if _actor.global_position.distance_to(member.global_position) > group_radius:
			continue
		var member_ai := member.get_node_or_null("CreatureAI") as CreatureAI
		if member_ai and member_ai.bb["target"] == null:
			member_ai.bb["target"]    = target
			member_ai.bb["in_combat"] = true
			member_ai.bb["alerted"]   = true


func alert_nearby(sound_pos: Vector3) -> void:
	# Call this when a loud event (combat, explosion) happens nearby
	if _actor.global_position.distance_to(sound_pos) < detection_range:
		if bb["target"] == null:
			bb["alerted"]       = true
			bb["last_seen_pos"] = sound_pos
			bb["action_timer"]  = 5.0


# ─── Navigation ───────────────────────────────────────────────────────────────
func _update_movement(delta: float) -> void:
	if _nav_agent.is_navigation_finished():
		_actor.velocity = Vector3.ZERO
		return

	var next_pos := _nav_agent.get_next_path_position()
	var dir      := (_actor.global_position).direction_to(next_pos)
	var speed    := _get_current_speed()

	_actor.velocity.x = dir.x * speed
	_actor.velocity.z = dir.z * speed
	_actor.velocity.y += -22.0 * delta  # Gravity
	_actor.move_and_slide()
	_face_target(next_pos)


func _get_current_speed() -> float:
	if bb["target"] != null and bb["in_combat"]:
		return creature_data.run_speed
	if _should_flee(bb, _actor):
		return creature_data.run_speed * 1.3
	return creature_data.walk_speed


func _face_target(pos: Vector3) -> void:
	var dir := (_actor.global_position).direction_to(pos)
	if dir.length_squared() < 0.001:
		return
	dir.y = 0.0
	_actor.rotation.y = lerp_angle(
		_actor.rotation.y, atan2(dir.x, dir.z), 8.0 * get_process_delta_time()
	)


func _get_random_patrol_point() -> Vector3:
	var origin := bb["patrol_origin"] as Vector3
	var angle  := randf() * TAU
	var dist   := randf_range(patrol_radius * 0.3, patrol_radius)
	return origin + Vector3(cos(angle), 0.0, sin(angle)) * dist


func _update_animation() -> void:
	var speed_h := Vector2(_actor.velocity.x, _actor.velocity.z).length()
	_animator.set("parameters/movement/blend_position", speed_h / creature_data.run_speed)
	_animator.set("parameters/in_combat/active", bb["in_combat"])


# ═══════════════════════════════════════════════════════════════════════════════
# BT Node Base Classes
# ═══════════════════════════════════════════════════════════════════════════════

class BTNode:
	func tick(_bb: Dictionary, _actor: Node3D, _delta: float) -> BTStatus:
		return BTStatus.FAILURE

class BTSelector extends BTNode:
	var _children: Array[BTNode]
	func _init(children: Array[BTNode]) -> void:
		_children = children
	func tick(bb: Dictionary, actor: Node3D, delta: float) -> BTStatus:
		for child in _children:
			var result := child.tick(bb, actor, delta)
			if result != BTStatus.FAILURE:
				return result
		return BTStatus.FAILURE

class BTSequence extends BTNode:
	var _children: Array[BTNode]
	func _init(children: Array[BTNode]) -> void:
		_children = children
	func tick(bb: Dictionary, actor: Node3D, delta: float) -> BTStatus:
		for child in _children:
			var result := child.tick(bb, actor, delta)
			if result != BTStatus.SUCCESS:
				return result
		return BTStatus.SUCCESS

class BTCondition extends BTNode:
	var _check: Callable
	func _init(check: Callable) -> void:
		_check = check
	func tick(bb: Dictionary, actor: Node3D, _delta: float) -> BTStatus:
		return BTStatus.SUCCESS if _check.call(bb, actor) else BTStatus.FAILURE

class BTAction extends BTNode:
	var _fn: Callable
	func _init(fn: Callable) -> void:
		_fn = fn
	func tick(bb: Dictionary, actor: Node3D, delta: float) -> BTStatus:
		return _fn.call(bb, actor, delta)
