## player/skills/progression_system.gd
## Handles XP, leveling, classless skill trees, and stat allocation.
## Skill tree is data-driven from assets/definitions/skills.json

class_name ProgressionSystem
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal xp_gained(amount: int, source: String)
signal level_up(new_level: int, stat_points: int)
signal skill_unlocked(skill_id: String)
signal skill_upgraded(skill_id: String, new_rank: int)

# ─── Constants ────────────────────────────────────────────────────────────────
const MAX_LEVEL        : int = 100
const BASE_XP_PER_LEVEL: int = 100
const XP_SCALE_FACTOR  : float = 1.15   # Each level requires 15% more XP
const STAT_POINTS_PER_LEVEL: int = 3

# ─── State ────────────────────────────────────────────────────────────────────
var _level          : int   = 1
var _current_xp     : int   = 0
var _stat_points    : int   = 0
var _skill_points   : int   = 0
var _unlocked_skills: Dictionary = {}  # skill_id -> rank (1..max_rank)
var _base_stats     : Dictionary = {
	"strength":    5,
	"dexterity":   5,
	"intelligence":5,
	"endurance":   5,
	"spirit":      5,
}
var _skill_registry : Dictionary = {}  # Loaded from skills.json
var _owner_actor    : Node3D


# ─── Init ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_owner_actor = get_parent()
	_load_skill_registry()


func _load_skill_registry() -> void:
	var path := "res://assets/definitions/skills.json"
	if not FileAccess.file_exists(path):
		push_warning("[Progression] skills.json not found")
		return
	var text     := FileAccess.open(path, FileAccess.READ).get_as_text()
	var parsed   := JSON.parse_string(text)
	if parsed is Dictionary:
		for skill_id: String in parsed.keys():
			_skill_registry[skill_id] = SkillDefinition.from_dict(skill_id, parsed[skill_id])
	print("[Progression] Loaded %d skills" % _skill_registry.size())


# ─── XP & Leveling ────────────────────────────────────────────────────────────
func add_xp(amount: int, source: String = "") -> void:
	if _level >= MAX_LEVEL:
		return
	_current_xp += amount
	xp_gained.emit(amount, source)
	# Check for level-up(s)
	while _current_xp >= xp_for_level(_level + 1) and _level < MAX_LEVEL:
		_level    += 1
		_current_xp -= xp_for_level(_level)
		_stat_points  += STAT_POINTS_PER_LEVEL
		_skill_points += 1
		level_up.emit(_level, _stat_points)
		_apply_level_up_bonuses()
		print("[Progression] Level up! Now level %d" % _level)


func xp_for_level(level: int) -> int:
	# XP required to REACH `level` (not total accumulated)
	return int(BASE_XP_PER_LEVEL * pow(XP_SCALE_FACTOR, level - 1))


func xp_to_next_level() -> int:
	return xp_for_level(_level + 1) - _current_xp


func get_level() -> int:
	return _level


func get_current_xp() -> int:
	return _current_xp


func get_xp_progress() -> float:
	return float(_current_xp) / float(xp_for_level(_level + 1))


func _apply_level_up_bonuses() -> void:
	# Recalculate derived stats and update ActorStats
	var stats := _calculate_derived_stats()
	if _owner_actor.has_method("refresh_stats"):
		_owner_actor.refresh_stats(stats)


# ─── Stat Allocation ──────────────────────────────────────────────────────────
func allocate_stat(stat: String, points: int = 1) -> bool:
	if not _base_stats.has(stat):
		push_warning("[Progression] Unknown stat: %s" % stat)
		return false
	if _stat_points < points:
		return false
	_base_stats[stat] += points
	_stat_points      -= points
	_apply_level_up_bonuses()
	return true


func get_stat(stat: String) -> int:
	var base := _base_stats.get(stat, 0) as int
	# Add bonuses from unlocked skills
	var bonus := 0
	for skill_id: String in _unlocked_skills.keys():
		var rank := _unlocked_skills[skill_id] as int
		var def  := _skill_registry.get(skill_id) as SkillDefinition
		if def and def.stat_bonuses.has(stat):
			bonus += int(def.stat_bonuses[stat]) * rank
	return base + bonus


func _calculate_derived_stats() -> Dictionary:
	var str_val := get_stat("strength")
	var dex_val := get_stat("dexterity")
	var int_val := get_stat("intelligence")
	var end_val := get_stat("endurance")
	var spi_val := get_stat("spirit")
	return {
		"max_hp":      80  + end_val * 12 + str_val * 3,
		"max_stamina": 80  + end_val * 8  + dex_val * 4,
		"max_mana":    40  + int_val * 10 + spi_val * 5,
		"attack":      10  + str_val * 2  + dex_val,
		"magic_power": 5   + int_val * 3  + spi_val * 2,
		"defense":     5   + end_val * 2  + str_val,
		"speed":       5.0 + dex_val * 0.1,
		"crit_chance": 0.05 + dex_val * 0.005,
	}


# ─── Skill Tree ───────────────────────────────────────────────────────────────
func unlock_skill(skill_id: String) -> bool:
	var def := _skill_registry.get(skill_id) as SkillDefinition
	if def == null:
		push_warning("[Progression] Unknown skill: %s" % skill_id)
		return false

	# Check prerequisites
	for prereq: String in def.prerequisites:
		if not _unlocked_skills.has(prereq):
			push_warning("[Progression] Missing prereq: %s for %s" % [prereq, skill_id])
			return false

	# Check already at max rank
	var current_rank := _unlocked_skills.get(skill_id, 0) as int
	if current_rank >= def.max_rank:
		return false

	# Cost check
	var cost := def.point_cost_per_rank
	if _skill_points < cost:
		return false

	_skill_points -= cost

	if _unlocked_skills.has(skill_id):
		_unlocked_skills[skill_id] += 1
		skill_upgraded.emit(skill_id, _unlocked_skills[skill_id])
	else:
		_unlocked_skills[skill_id] = 1
		skill_unlocked.emit(skill_id)

	_apply_level_up_bonuses()
	return true


func has_skill(skill_id: String, min_rank: int = 1) -> bool:
	return _unlocked_skills.get(skill_id, 0) >= min_rank


func get_skill_rank(skill_id: String) -> int:
	return _unlocked_skills.get(skill_id, 0)


## Returns all skills available to unlock given current state.
func get_available_skills() -> Array[SkillDefinition]:
	var result: Array[SkillDefinition] = []
	for skill_id: String in _skill_registry.keys():
		var def := _skill_registry[skill_id] as SkillDefinition
		if _unlocked_skills.get(skill_id, 0) >= def.max_rank:
			continue
		var prereqs_met := true
		for prereq: String in def.prerequisites:
			if not _unlocked_skills.has(prereq):
				prereqs_met = false
				break
		if prereqs_met:
			result.append(def)
	return result


## Returns skill tree as a graph for UI rendering
func get_skill_tree_graph() -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	for skill_id: String in _skill_registry.keys():
		var def := _skill_registry[skill_id] as SkillDefinition
		nodes.append({
			"id":          skill_id,
			"name":        def.display_name,
			"description": def.description,
			"icon":        def.icon_path,
			"category":    def.category,
			"rank":        _unlocked_skills.get(skill_id, 0),
			"max_rank":    def.max_rank,
			"cost":        def.point_cost_per_rank,
			"unlocked":    _unlocked_skills.has(skill_id),
			"available":   _can_unlock(skill_id),
			"position":    def.tree_position,
		})
		for prereq: String in def.prerequisites:
			edges.append({"from": prereq, "to": skill_id})
	return {"nodes": nodes, "edges": edges}


func _can_unlock(skill_id: String) -> bool:
	var def := _skill_registry.get(skill_id) as SkillDefinition
	if def == null:
		return false
	for prereq in def.prerequisites:
		if not _unlocked_skills.has(prereq):
			return false
	return _skill_points >= def.point_cost_per_rank


# ─── Serialization ────────────────────────────────────────────────────────────
func serialize() -> Dictionary:
	return {
		"level":           _level,
		"current_xp":      _current_xp,
		"stat_points":     _stat_points,
		"skill_points":    _skill_points,
		"base_stats":      _base_stats.duplicate(),
		"unlocked_skills": _unlocked_skills.duplicate(),
	}


func deserialize(data: Dictionary) -> void:
	_level           = data.get("level",           1)
	_current_xp      = data.get("current_xp",      0)
	_stat_points     = data.get("stat_points",      0)
	_skill_points    = data.get("skill_points",     0)
	_base_stats      = data.get("base_stats",       _base_stats.duplicate())
	_unlocked_skills = data.get("unlocked_skills",  {})
	_apply_level_up_bonuses()


# ═══════════════════════════════════════════════════════════════════════════════
# Data Classes
# ═══════════════════════════════════════════════════════════════════════════════

class SkillDefinition extends RefCounted:
	var id             : String
	var display_name   : String
	var description    : String
	var icon_path      : String
	var category       : String    # "combat", "magic", "survival", "crafting", "exploration"
	var prerequisites  : Array     # Array of skill_id strings
	var max_rank       : int
	var point_cost_per_rank: int
	var stat_bonuses   : Dictionary  # e.g. {"strength": 2, "dexterity": 1}
	var ability_grant  : String    # ability_id to grant when unlocked
	var passive_effects: Array     # Array of passive_effect dicts
	var tree_position  : Vector2   # Position in skill tree UI

	static func from_dict(skill_id: String, d: Dictionary) -> SkillDefinition:
		var s                 := SkillDefinition.new()
		s.id                   = skill_id
		s.display_name         = d.get("name",          skill_id)
		s.description          = d.get("description",   "")
		s.icon_path            = d.get("icon",          "")
		s.category             = d.get("category",      "combat")
		s.prerequisites        = d.get("prerequisites", [])
		s.max_rank             = d.get("max_rank",      1)
		s.point_cost_per_rank  = d.get("cost",          1)
		s.stat_bonuses         = d.get("stat_bonuses",  {})
		s.ability_grant        = d.get("ability_grant", "")
		s.passive_effects      = d.get("passive_effects",[])
		var pos                := d.get("tree_position", [0, 0]) as Array
		s.tree_position        = Vector2(float(pos[0]), float(pos[1]))
		return s
