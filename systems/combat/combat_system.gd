## systems/combat/combat_system.gd
## Handles all combat logic: hit detection, damage calculation,
## combos, stagger, parry/dodge i-frames, and ability execution.
##
## Design:
##   - Autoload singleton accessed via /root/CombatSystem
##   - Weapons register their hitbox areas; CombatSystem subscribes
##   - Damage events flow through CombatEventBus (decoupled from actors)
##   - Status effects are component Resources attached to actors

class_name CombatSystem
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal damage_dealt(attacker: Node3D, target: Node3D, result: DamageResult)
signal actor_killed(attacker: Node3D, target: Node3D)
signal combo_advanced(actor: Node3D, combo_step: int)
signal status_applied(target: Node3D, status: StatusEffect)

# ─── Combat Constants ─────────────────────────────────────────────────────────
const CRIT_MULTIPLIER   : float = 2.2
const PARRY_WINDOW      : float = 0.18   # seconds
const STAGGER_THRESHOLD : float = 30.0   # damage in short window to stagger
const COMBO_TIMEOUT     : float = 1.2    # seconds between combo hits

# ─── Active Actors ────────────────────────────────────────────────────────────
var _registered_actors   : Dictionary = {}  # actor_id -> ActorCombatState
var _invincible_actors   : Dictionary = {}  # actor_id -> time_remaining
var _parry_actors        : Dictionary = {}  # actor_id -> time_remaining


# ─── Actor Registration ───────────────────────────────────────────────────────
func register_actor(actor: Node3D, stats: ActorStats) -> void:
	var state                 := ActorCombatState.new()
	state.actor                = actor
	state.stats                = stats
	state.current_hp           = stats.max_hp
	state.combo_step           = 0
	state.combo_timer          = 0.0
	state.stagger_accumulator  = 0.0
	state.stagger_decay_timer  = 0.0
	_registered_actors[actor.get_instance_id()] = state
	print("[Combat] Registered: %s" % actor.name)


func unregister_actor(actor: Node3D) -> void:
	_registered_actors.erase(actor.get_instance_id())


func _process(delta: float) -> void:
	_tick_invincibility(delta)
	_tick_parry(delta)
	_tick_combos(delta)
	_tick_stagger(delta)
	_tick_status_effects(delta)


# ─── Core Damage Processing ───────────────────────────────────────────────────
## Primary entry point for all damage application.
func apply_hit(attacker: Node3D, target: Node3D, hit_data: HitData) -> DamageResult:
	var result := DamageResult.new()
	var target_id := target.get_instance_id()

	# Check invincibility frames
	if _invincible_actors.has(target_id):
		result.blocked    = true
		result.damage     = 0
		return result

	# Check parry (only if target is parrying and hit is from front)
	if _check_parry(attacker, target, hit_data):
		result.parried = true
		result.damage  = 0
		_trigger_parry_riposte(attacker, target)
		return result

	# Check block
	if _check_block(attacker, target, hit_data):
		hit_data.damage = hit_data.damage * 0.3  # Reduce damage on block

	# Calculate final damage
	result.damage = _calculate_damage(attacker, target, hit_data)
	result.is_crit = hit_data.is_crit

	# Apply damage
	var state := _registered_actors.get(target_id) as ActorCombatState
	if state == null:
		return result

	state.current_hp -= result.damage

	# Stagger accumulation
	state.stagger_accumulator += result.damage
	state.stagger_decay_timer = 0.5
	if state.stagger_accumulator >= STAGGER_THRESHOLD:
		_trigger_stagger(target, attacker)
		state.stagger_accumulator = 0.0

	# Knockback
	if hit_data.knockback > 0.0:
		_apply_knockback(target, attacker, hit_data.knockback)

	# Status effects
	for effect: StatusEffect in hit_data.status_effects:
		_apply_status_effect(target, effect)

	# Death check
	if state.current_hp <= 0.0:
		state.current_hp = 0.0
		_handle_death(attacker, target, state)

	damage_dealt.emit(attacker, target, result)

	# Feedback to target node
	if target.has_method("on_hit"):
		target.on_hit(result)

	return result


func _calculate_damage(attacker: Node3D, target: Node3D, hit_data: HitData) -> float:
	var att_state  := _registered_actors.get(attacker.get_instance_id()) as ActorCombatState
	var def_state  := _registered_actors.get(target.get_instance_id())   as ActorCombatState

	var base       := hit_data.damage
	var att_bonus  := att_state.stats.attack if att_state else 0.0
	var def_value  := def_state.stats.defense if def_state else 0.0

	# Defense curve: diminishing returns
	var defense_factor := def_value / (def_value + 50.0)

	# Elemental multiplier
	var element_mult := _get_elemental_multiplier(
		hit_data.element,
		def_state.stats.resistances if def_state else {}
	)

	var raw    := (base + att_bonus * 0.5) * element_mult
	var final  := raw * (1.0 - defense_factor)

	# Critical hit
	if hit_data.is_crit:
		final *= CRIT_MULTIPLIER

	return maxf(1.0, final)


func _get_elemental_multiplier(element: String, resistances: Dictionary) -> float:
	if element.is_empty() or not resistances.has(element):
		return 1.0
	# Resistance ranges: -1.0 (immune) → 0 (normal) → 1.0 (weak)
	var res := float(resistances.get(element, 0.0))
	return 1.0 + res


# ─── Combo System ─────────────────────────────────────────────────────────────
## Returns the current combo step and advances it.
func advance_combo(actor: Node3D) -> int:
	var state := _registered_actors.get(actor.get_instance_id()) as ActorCombatState
	if state == null:
		return 0
	state.combo_step  = (state.combo_step + 1) % state.stats.max_combo_steps
	state.combo_timer = COMBO_TIMEOUT
	combo_advanced.emit(actor, state.combo_step)
	return state.combo_step


func reset_combo(actor: Node3D) -> void:
	var state := _registered_actors.get(actor.get_instance_id()) as ActorCombatState
	if state:
		state.combo_step  = 0
		state.combo_timer = 0.0


func _tick_combos(delta: float) -> void:
	for state: ActorCombatState in _registered_actors.values():
		if state.combo_timer > 0.0:
			state.combo_timer -= delta
			if state.combo_timer <= 0.0:
				state.combo_step = 0


# ─── Parry System ─────────────────────────────────────────────────────────────
func begin_parry(actor: Node3D) -> void:
	_parry_actors[actor.get_instance_id()] = PARRY_WINDOW


func _check_parry(attacker: Node3D, target: Node3D, hit_data: HitData) -> bool:
	var target_id := target.get_instance_id()
	if not _parry_actors.has(target_id):
		return false
	# Must be facing attacker within 120 degrees
	if not _is_facing(target, attacker, 60.0):
		return false
	# Only parryable attacks (not magic projectiles by default)
	return hit_data.parryable


func _trigger_parry_riposte(attacker: Node3D, parrying_actor: Node3D) -> void:
	# Brief i-frame on parrying actor
	set_invincible(parrying_actor, 0.5)
	# Stagger the attacker
	_trigger_stagger(attacker, parrying_actor)
	# Emit riposte opportunity signal
	if parrying_actor.has_method("on_parry_success"):
		parrying_actor.on_parry_success(attacker)


func _tick_parry(delta: float) -> void:
	for id in _parry_actors.keys():
		_parry_actors[id] -= delta
		if _parry_actors[id] <= 0.0:
			_parry_actors.erase(id)


# ─── Stagger ──────────────────────────────────────────────────────────────────
func _trigger_stagger(target: Node3D, attacker: Node3D) -> void:
	if target.has_method("on_stagger"):
		var dir := (target.global_position - attacker.global_position).normalized()
		target.on_stagger(dir)


func _tick_stagger(delta: float) -> void:
	for state: ActorCombatState in _registered_actors.values():
		if state.stagger_decay_timer > 0.0:
			state.stagger_decay_timer -= delta
		else:
			state.stagger_accumulator = move_toward(state.stagger_accumulator, 0.0, 15.0 * delta)


# ─── Knockback ────────────────────────────────────────────────────────────────
func _apply_knockback(target: Node3D, source: Node3D, force: float) -> void:
	var dir := (target.global_position - source.global_position).normalized()
	dir.y    = 0.3
	if target is CharacterBody3D:
		target.velocity += dir * force


# ─── Invincibility Frames ─────────────────────────────────────────────────────
func set_invincible(actor: Node3D, duration: float) -> void:
	var existing := _invincible_actors.get(actor.get_instance_id(), 0.0) as float
	_invincible_actors[actor.get_instance_id()] = maxf(existing, duration)


func _tick_invincibility(delta: float) -> void:
	for id in _invincible_actors.keys():
		_invincible_actors[id] -= delta
		if _invincible_actors[id] <= 0.0:
			_invincible_actors.erase(id)


# ─── Status Effects ───────────────────────────────────────────────────────────
## StatusEffect is a Resource with: type, duration, tick_interval, tick_damage, etc.
func _apply_status_effect(target: Node3D, effect: StatusEffect) -> void:
	var state := _registered_actors.get(target.get_instance_id()) as ActorCombatState
	if state == null:
		return
	# Check immunity
	if state.stats.resistances.get(effect.type, 0.0) >= 1.0:
		return
	# Stack or refresh existing
	for existing: ActiveStatusEffect in state.active_effects:
		if existing.effect.type == effect.type:
			existing.remaining_duration = effect.duration
			return
	var active       := ActiveStatusEffect.new()
	active.effect     = effect
	active.remaining_duration = effect.duration
	active.tick_timer = effect.tick_interval
	state.active_effects.append(active)
	status_applied.emit(target, effect)
	if target.has_method("on_status_applied"):
		target.on_status_applied(effect)


func _tick_status_effects(delta: float) -> void:
	for state: ActorCombatState in _registered_actors.values():
		var to_remove: Array[ActiveStatusEffect] = []
		for ase: ActiveStatusEffect in state.active_effects:
			ase.remaining_duration -= delta
			ase.tick_timer         -= delta
			if ase.tick_timer <= 0.0:
				ase.tick_timer = ase.effect.tick_interval
				_apply_dot_tick(state, ase)
			if ase.remaining_duration <= 0.0:
				to_remove.append(ase)
				if state.actor.has_method("on_status_expired"):
					state.actor.on_status_expired(ase.effect)
		for rem in to_remove:
			state.active_effects.erase(rem)


func _apply_dot_tick(state: ActorCombatState, ase: ActiveStatusEffect) -> void:
	match ase.effect.type:
		"burning":
			state.current_hp -= ase.effect.tick_damage
			if state.current_hp <= 0.0:
				_handle_death(null, state.actor, state)
		"poisoned":
			state.current_hp -= ase.effect.tick_damage
			if state.current_hp <= 0.0:
				_handle_death(null, state.actor, state)
		"regenerating":
			state.current_hp = minf(state.stats.max_hp, state.current_hp + ase.effect.tick_damage)
		"frozen":
			if state.actor is CharacterBody3D:
				state.actor.velocity = Vector3.ZERO


# ─── Ability System ───────────────────────────────────────────────────────────
## Execute a defined ability from the actor's skill tree.
func execute_ability(caster: Node3D, ability: AbilityData, target_point: Vector3) -> void:
	var caster_state := _registered_actors.get(caster.get_instance_id()) as ActorCombatState
	if caster_state == null:
		return

	# Cooldown check
	if caster_state.ability_cooldowns.get(ability.id, 0.0) > 0.0:
		return

	# Resource cost
	if not caster_state.stats.consume_resource(ability.resource_type, ability.cost):
		return

	# Set cooldown
	caster_state.ability_cooldowns[ability.id] = ability.cooldown

	# Spawn ability effect
	var effect_scene := load(ability.effect_scene) as PackedScene
	if effect_scene:
		var effect_node    := effect_scene.instantiate() as Node3D
		effect_node.caster  = caster
		effect_node.data    = ability
		effect_node.target  = target_point
		get_tree().root.add_child(effect_node)


# ─── Death ────────────────────────────────────────────────────────────────────
func _handle_death(attacker: Node3D, target: Node3D, state: ActorCombatState) -> void:
	actor_killed.emit(attacker, target)
	if target.has_method("on_death"):
		target.on_death(attacker)
	# Drop loot (server-authoritative)
	if multiplayer.is_server():
		LootSystem.spawn_loot(target.global_position, state.stats.loot_table)
	unregister_actor(target)


# ─── Utility ──────────────────────────────────────────────────────────────────
func _is_facing(actor: Node3D, target: Node3D, angle_tolerance: float) -> bool:
	var to_target := (target.global_position - actor.global_position).normalized()
	var forward   := -actor.global_basis.z
	var dot       := forward.dot(to_target)
	return dot >= cos(deg_to_rad(angle_tolerance))


func get_actor_hp(actor: Node3D) -> float:
	var state := _registered_actors.get(actor.get_instance_id()) as ActorCombatState
	return state.current_hp if state else 0.0


func get_actor_max_hp(actor: Node3D) -> float:
	var state := _registered_actors.get(actor.get_instance_id()) as ActorCombatState
	return state.stats.max_hp if state else 0.0


func heal(target: Node3D, amount: float) -> void:
	var state := _registered_actors.get(target.get_instance_id()) as ActorCombatState
	if state:
		state.current_hp = minf(state.stats.max_hp, state.current_hp + amount)
