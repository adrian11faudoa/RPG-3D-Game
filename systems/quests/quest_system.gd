## systems/quests/quest_system.gd
## Data-driven quest system supporting: main story, side quests, faction quests,
## procedural bounties, and dynamic world events.
##
## Quest structure:
##   Quest → Stages → Objectives (AND/OR logic)
##   Each objective type: kill_count, gather_item, reach_location,
##                        talk_to_npc, escort, defend, survive, interact

class_name QuestSystem
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal quest_accepted(quest_id: String)
signal quest_completed(quest_id: String, rewards: QuestRewards)
signal quest_failed(quest_id: String, reason: String)
signal quest_stage_advanced(quest_id: String, new_stage: int)
signal objective_updated(quest_id: String, obj_id: String, progress: int, required: int)

# ─── Constants ────────────────────────────────────────────────────────────────
const QUEST_DEF_PATH  : String = "res://assets/definitions/quests.json"
const MAX_ACTIVE      : int    = 25

# ─── State ────────────────────────────────────────────────────────────────────
var _quest_defs    : Dictionary = {}   # quest_id -> QuestDefinition
var _active_quests : Dictionary = {}   # quest_id -> ActiveQuest
var _completed_ids : Array[String] = []
var _failed_ids    : Array[String] = []
var _owner         : Node3D


func _ready() -> void:
	_owner = get_parent()
	_load_quest_definitions()
	# Connect to world events
	var combat := get_node_or_null("/root/CombatSystem")
	if combat:
		combat.actor_killed.connect(_on_actor_killed)


func _load_quest_definitions() -> void:
	if not FileAccess.file_exists(QUEST_DEF_PATH):
		push_warning("[Quests] quests.json not found")
		return
	var text   := FileAccess.open(QUEST_DEF_PATH, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if not parsed is Dictionary:
		return
	for qid: String in parsed.keys():
		_quest_defs[qid] = QuestDefinition.from_dict(qid, parsed[qid])
	print("[Quests] Loaded %d quest definitions" % _quest_defs.size())


# ─── Quest Acceptance ─────────────────────────────────────────────────────────
func can_accept(quest_id: String) -> bool:
	var def := _quest_defs.get(quest_id) as QuestDefinition
	if def == null:
		return false
	if _active_quests.has(quest_id):
		return false
	if quest_id in _completed_ids and not def.repeatable:
		return false
	if _active_quests.size() >= MAX_ACTIVE:
		return false

	# Prerequisite quests
	for prereq: String in def.prerequisites:
		if prereq not in _completed_ids:
			return false

	# Level requirement
	var prog := _owner.get_node_or_null("ProgressionSystem") as ProgressionSystem
	if prog and def.min_level > prog.get_level():
		return false

	# Faction requirement
	var fac := _owner.get_node_or_null("FactionSystem") as FactionSystem
	if fac and not def.required_faction.is_empty():
		var tier := fac.get_reputation_tier(def.required_faction)
		if tier < def.required_faction_tier:
			return false

	return true


func accept_quest(quest_id: String) -> bool:
	if not can_accept(quest_id):
		return false
	var def := _quest_defs[quest_id] as QuestDefinition

	var aq              := ActiveQuest.new()
	aq.quest_id          = quest_id
	aq.definition        = def
	aq.current_stage     = 0
	aq.start_time        = Time.get_unix_time_from_system()
	aq.objective_progress = {}

	# Initialize objectives for stage 0
	_init_stage_objectives(aq, 0)

	_active_quests[quest_id] = aq
	quest_accepted.emit(quest_id)
	print("[Quests] Accepted: %s" % def.display_name)
	return true


func _init_stage_objectives(aq: ActiveQuest, stage_index: int) -> void:
	aq.objective_progress.clear()
	var stage := aq.definition.stages[stage_index] as QuestStage
	for obj: QuestObjective in stage.objectives:
		aq.objective_progress[obj.id] = 0


# ─── Objective Updates ────────────────────────────────────────────────────────
## Called by various game systems when relevant events occur.
func notify_kill(creature_id: String, position: Vector3) -> void:
	_update_objectives("kill_count", {"target_id": creature_id, "position": position})


func notify_item_gathered(item_id: String, amount: int) -> void:
	_update_objectives("gather_item", {"item_id": item_id, "amount": amount})


func notify_location_reached(location_id: String) -> void:
	_update_objectives("reach_location", {"location_id": location_id})


func notify_npc_talked(npc_id: String) -> void:
	_update_objectives("talk_to_npc", {"npc_id": npc_id})


func notify_interact(object_id: String) -> void:
	_update_objectives("interact", {"object_id": object_id})


func notify_item_delivered(item_id: String, to_npc: String) -> void:
	_update_objectives("deliver_item", {"item_id": item_id, "npc_id": to_npc})


func _update_objectives(event_type: String, event_data: Dictionary) -> void:
	for quest_id: String in _active_quests.keys():
		var aq    := _active_quests[quest_id] as ActiveQuest
		var stage := aq.definition.stages[aq.current_stage] as QuestStage

		for obj: QuestObjective in stage.objectives:
			if obj.type != event_type:
				continue
			if not _objective_matches(obj, event_data):
				continue

			var progress := aq.objective_progress.get(obj.id, 0) as int
			var add      := event_data.get("amount", 1) as int
			progress      = mini(progress + add, obj.required_count)
			aq.objective_progress[obj.id] = progress

			objective_updated.emit(quest_id, obj.id, progress, obj.required_count)

			# Check stage completion
			if _stage_complete(aq, stage):
				_advance_stage(quest_id, aq)
				return   # Restart loop after modification


func _objective_matches(obj: QuestObjective, data: Dictionary) -> bool:
	match obj.type:
		"kill_count":
			return data.get("target_id", "") == obj.target_id or \
			       (obj.target_tag != "" and _creature_has_tag(data.get("target_id",""), obj.target_tag))
		"gather_item":
			return data.get("item_id", "") == obj.target_id
		"reach_location":
			return data.get("location_id", "") == obj.target_id
		"talk_to_npc":
			return data.get("npc_id", "") == obj.target_id
		"interact":
			return data.get("object_id", "") == obj.target_id
		"deliver_item":
			return data.get("item_id", "") == obj.target_id and \
			       data.get("npc_id",  "") == obj.extra_data.get("npc_id", "")
		_:
			return false


func _creature_has_tag(creature_id: String, tag: String) -> bool:
	# Check creature definition tags
	var path := "res://assets/definitions/creatures.json"
	if FileAccess.file_exists(path):
		pass  # In full implementation, check creature registry
	return false


func _stage_complete(aq: ActiveQuest, stage: QuestStage) -> bool:
	if stage.completion_mode == "any":
		# OR: any objective complete
		for obj: QuestObjective in stage.objectives:
			var progress := aq.objective_progress.get(obj.id, 0) as int
			if progress >= obj.required_count:
				return true
		return false
	else:
		# AND: all objectives complete (default)
		for obj: QuestObjective in stage.objectives:
			var progress := aq.objective_progress.get(obj.id, 0) as int
			if progress < obj.required_count:
				return false
		return true


func _advance_stage(quest_id: String, aq: ActiveQuest) -> void:
	var next_stage := aq.current_stage + 1

	if next_stage >= aq.definition.stages.size():
		# Quest complete!
		_complete_quest(quest_id, aq)
		return

	aq.current_stage = next_stage
	_init_stage_objectives(aq, next_stage)
	quest_stage_advanced.emit(quest_id, next_stage)
	print("[Quests] Stage advanced: %s → stage %d" % [quest_id, next_stage])

	# Run stage entry script if defined
	var stage := aq.definition.stages[next_stage] as QuestStage
	if not stage.on_enter_script.is_empty():
		_run_quest_script(stage.on_enter_script, aq)


func _complete_quest(quest_id: String, aq: ActiveQuest) -> void:
	_active_quests.erase(quest_id)
	_completed_ids.append(quest_id)

	var rewards := aq.definition.rewards
	_grant_rewards(rewards)
	quest_completed.emit(quest_id, rewards)
	print("[Quests] Completed: %s" % aq.definition.display_name)

	# Follow-up quests
	for follow_up: String in aq.definition.follow_up_quests:
		if can_accept(follow_up):
			print("[Quests] Follow-up available: %s" % follow_up)


func fail_quest(quest_id: String, reason: String = "Quest failed") -> void:
	if not _active_quests.has(quest_id):
		return
	_active_quests.erase(quest_id)
	_failed_ids.append(quest_id)
	quest_failed.emit(quest_id, reason)


# ─── Rewards ──────────────────────────────────────────────────────────────────
func _grant_rewards(rewards: QuestRewards) -> void:
	var prog := _owner.get_node_or_null("ProgressionSystem") as ProgressionSystem
	var inv  := _owner.get_node_or_null("InventorySystem")   as InventorySystem
	var fac  := _owner.get_node_or_null("FactionSystem")     as FactionSystem

	if prog and rewards.xp > 0:
		prog.add_xp(rewards.xp, "quest")

	if inv:
		if rewards.gold > 0:
			inv.add_gold(rewards.gold)
		for item_reward: Dictionary in rewards.items:
			inv.add_item(str(item_reward["item_id"]), int(item_reward["amount"]))

	if fac:
		for rep_reward: Dictionary in rewards.reputation:
			fac.add_reputation(str(rep_reward["faction_id"]),
				int(rep_reward["amount"]), "quest_reward")


# ─── Procedural Bounties ──────────────────────────────────────────────────────
## Generates a random bounty quest targeting a creature type in current biome.
func generate_bounty(biome_id: String, difficulty: int) -> String:
	var bounty_id  := "bounty_%s_%d" % [biome_id, randi()]
	var creatures  := BiomeRegistry.get_hostile_creatures(biome_id)
	if creatures.is_empty():
		return ""

	var target    := creatures[randi() % creatures.size()]
	var count     := difficulty * randi_range(3, 8)
	var xp_reward := count * difficulty * 20
	var gold      := count * difficulty * 5

	var def                    := QuestDefinition.new()
	def.id                      = bounty_id
	def.display_name            = "Bounty: Hunt %s" % target
	def.description             = "The region needs %d %s culled. Seek them out." % [count, target]
	def.quest_type              = "bounty"
	def.repeatable              = true

	var stage           := QuestStage.new()
	stage.display_name   = "Hunt the %s" % target
	stage.completion_mode = "all"
	var obj              := QuestObjective.new()
	obj.id                = "kill_%s" % target
	obj.type              = "kill_count"
	obj.target_id         = target
	obj.required_count    = count
	obj.description       = "Kill %s (%d remaining)" % [target, count]
	stage.objectives      = [obj]
	def.stages            = [stage]

	var rewards         := QuestRewards.new()
	rewards.xp           = xp_reward
	rewards.gold         = gold
	def.rewards          = rewards

	_quest_defs[bounty_id] = def
	return bounty_id


# ─── Timed Quests ─────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	var to_fail: Array[String] = []
	for quest_id: String in _active_quests.keys():
		var aq  := _active_quests[quest_id] as ActiveQuest
		var def := aq.definition
		if def.time_limit <= 0.0:
			continue
		var elapsed := Time.get_unix_time_from_system() - aq.start_time
		if elapsed >= def.time_limit:
			to_fail.append(quest_id)
	for qid in to_fail:
		fail_quest(qid, "Time expired")


# ─── Script Runner ────────────────────────────────────────────────────────────
func _run_quest_script(script_id: String, aq: ActiveQuest) -> void:
	# In full implementation: execute Lua/GDScript quest event
	print("[Quests] Running script: %s for %s" % [script_id, aq.quest_id])


# ─── Event Hook ───────────────────────────────────────────────────────────────
func _on_actor_killed(attacker: Node3D, target: Node3D) -> void:
	if attacker != _owner:
		return
	var creature_id := target.get_meta("creature_id", "") as String
	notify_kill(creature_id, target.global_position)


# ─── Status Queries ───────────────────────────────────────────────────────────
func is_active(quest_id: String) -> bool:
	return _active_quests.has(quest_id)


func is_completed(quest_id: String) -> bool:
	return quest_id in _completed_ids


func get_active_quests() -> Array[ActiveQuest]:
	return _active_quests.values() as Array[ActiveQuest]


func get_objective_progress(quest_id: String, obj_id: String) -> Dictionary:
	var aq := _active_quests.get(quest_id) as ActiveQuest
	if aq == null:
		return {}
	var progress := aq.objective_progress.get(obj_id, 0) as int
	var stage    := aq.definition.stages[aq.current_stage] as QuestStage
	for obj: QuestObjective in stage.objectives:
		if obj.id == obj_id:
			return {"progress": progress, "required": obj.required_count,
					"description": obj.description}
	return {}


# ─── Serialization ────────────────────────────────────────────────────────────
func serialize() -> Dictionary:
	var active: Dictionary = {}
	for qid: String in _active_quests.keys():
		var aq := _active_quests[qid] as ActiveQuest
		active[qid] = {
			"current_stage":      aq.current_stage,
			"start_time":         aq.start_time,
			"objective_progress": aq.objective_progress.duplicate(),
		}
	return {
		"active":    active,
		"completed": _completed_ids.duplicate(),
		"failed":    _failed_ids.duplicate(),
	}


func deserialize(data: Dictionary) -> void:
	_completed_ids = data.get("completed", [])
	_failed_ids    = data.get("failed",    [])
	var active := data.get("active", {}) as Dictionary
	for qid: String in active.keys():
		if not _quest_defs.has(qid):
			continue
		var saved           := active[qid] as Dictionary
		var aq              := ActiveQuest.new()
		aq.quest_id          = qid
		aq.definition        = _quest_defs[qid]
		aq.current_stage     = int(saved.get("current_stage", 0))
		aq.start_time        = float(saved.get("start_time",   0))
		aq.objective_progress= saved.get("objective_progress", {})
		_active_quests[qid]  = aq


# ═══════════════════════════════════════════════════════════════════════════════
# Data Classes
# ═══════════════════════════════════════════════════════════════════════════════

class QuestObjective extends RefCounted:
	var id             : String
	var type           : String   # kill_count, gather_item, reach_location, etc.
	var description    : String
	var target_id      : String
	var target_tag     : String   # Alternative to target_id for category kills
	var required_count : int = 1
	var extra_data     : Dictionary = {}

class QuestStage extends RefCounted:
	var display_name    : String
	var objectives      : Array[QuestObjective] = []
	var completion_mode : String = "all"   # "all" or "any"
	var on_enter_script : String = ""

class QuestRewards extends RefCounted:
	var xp         : int = 0
	var gold       : int = 0
	var items      : Array = []   # [{item_id, amount}]
	var reputation : Array = []   # [{faction_id, amount}]
	var unlocks    : Array = []   # skill_ids or ability_ids

	static func from_dict(d: Dictionary) -> QuestRewards:
		var r          := QuestRewards.new()
		r.xp            = int(d.get("xp",         0))
		r.gold          = int(d.get("gold",        0))
		r.items         = d.get("items",        [])
		r.reputation    = d.get("reputation",   [])
		r.unlocks       = d.get("unlocks",      [])
		return r

class ActiveQuest extends RefCounted:
	var quest_id          : String
	var definition        : QuestDefinition
	var current_stage     : int = 0
	var start_time        : float = 0.0
	var objective_progress: Dictionary = {}

class QuestDefinition extends RefCounted:
	var id                  : String
	var display_name        : String
	var description         : String
	var quest_type          : String = "side"   # main, side, faction, bounty, event
	var icon_path           : String
	var giver_npc_id        : String
	var turn_in_npc_id      : String
	var prerequisites       : Array[String] = []
	var follow_up_quests    : Array[String] = []
	var stages              : Array[QuestStage] = []
	var rewards             : QuestRewards
	var min_level           : int = 0
	var required_faction    : String = ""
	var required_faction_tier: int = 0
	var repeatable          : bool = false
	var time_limit          : float = 0.0   # 0 = no limit (seconds)
	var journal_entries     : Array = []

	static func from_dict(qid: String, d: Dictionary) -> QuestDefinition:
		var q                   := QuestDefinition.new()
		q.id                     = qid
		q.display_name           = d.get("name",          qid)
		q.description            = d.get("description",   "")
		q.quest_type             = d.get("type",           "side")
		q.icon_path              = d.get("icon",           "")
		q.giver_npc_id           = d.get("giver",         "")
		q.turn_in_npc_id         = d.get("turn_in",       "")
		q.prerequisites          = d.get("prerequisites", [])
		q.follow_up_quests       = d.get("follow_ups",    [])
		q.min_level              = int(d.get("min_level", 0))
		q.required_faction       = d.get("required_faction", "")
		q.required_faction_tier  = int(d.get("required_faction_tier", 0))
		q.repeatable             = bool(d.get("repeatable", false))
		q.time_limit             = float(d.get("time_limit", 0.0))
		q.rewards                = QuestRewards.from_dict(d.get("rewards", {}))

		for stage_data: Dictionary in d.get("stages", []):
			var stage              := QuestStage.new()
			stage.display_name      = stage_data.get("name", "")
			stage.completion_mode   = stage_data.get("mode", "all")
			stage.on_enter_script   = stage_data.get("on_enter", "")
			for obj_data: Dictionary in stage_data.get("objectives", []):
				var obj            := QuestObjective.new()
				obj.id              = obj_data.get("id",          "obj_%d" % stage.objectives.size())
				obj.type            = obj_data.get("type",        "kill_count")
				obj.description     = obj_data.get("description", "")
				obj.target_id       = obj_data.get("target",      "")
				obj.target_tag      = obj_data.get("target_tag",  "")
				obj.required_count  = int(obj_data.get("count",   1))
				obj.extra_data      = obj_data.get("extra",       {})
				stage.objectives.append(obj)
			q.stages.append(stage)
		return q
