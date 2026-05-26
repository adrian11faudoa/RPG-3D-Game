## world/cities/npc_dialogue.gd
## Data-driven NPC dialogue system with branching conversations,
## reputation checks, quest hooks, and dynamic responses.
##
## Dialogue trees are loaded from assets/definitions/dialogues.json.
## Each NPC references a dialogue_id; the system resolves branches at runtime.

class_name NPCDialogue
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal dialogue_started(npc: Node3D, dialogue_id: String)
signal dialogue_ended(npc: Node3D)
signal choice_selected(npc: Node3D, choice_id: String)
signal quest_offered(npc: Node3D, quest_id: String)
signal trade_requested(npc: Node3D, merchant_id: String)

const DIALOGUE_PATH : String = "res://assets/definitions/dialogues.json"
const INTERACT_RANGE: float  = 3.5

# ─── State ────────────────────────────────────────────────────────────────────
var _dialogues       : Dictionary = {}   # dialogue_id -> DialogueTree
var _active_session  : DialogueSession = null
var _npc_owner       : Node3D


func _ready() -> void:
	_npc_owner = get_parent()
	_load_dialogues()


func _load_dialogues() -> void:
	if not FileAccess.file_exists(DIALOGUE_PATH):
		push_warning("[Dialogue] dialogues.json not found")
		return
	var text   := FileAccess.open(DIALOGUE_PATH, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if parsed is Dictionary:
		for did: String in parsed.keys():
			_dialogues[did] = DialogueTree.from_dict(did, parsed[did])
	print("[Dialogue] Loaded %d dialogue trees" % _dialogues.size())


# ─── Interaction ──────────────────────────────────────────────────────────────
func try_interact(player: Node3D) -> bool:
	if _active_session != null:
		return false
	if _npc_owner.global_position.distance_to(player.global_position) > INTERACT_RANGE:
		return false

	var dialogue_id := str(_npc_owner.get_meta("dialogue_id", "generic_npc"))
	return start_dialogue(dialogue_id, player)


func start_dialogue(dialogue_id: String, player: Node3D) -> bool:
	var tree := _dialogues.get(dialogue_id) as DialogueTree
	if tree == null:
		push_warning("[Dialogue] Unknown dialogue: %s" % dialogue_id)
		return false

	_active_session            := DialogueSession.new()
	_active_session.tree        = tree
	_active_session.player      = player
	_active_session.current_node_id = tree.entry_node
	_active_session.variables   = {}

	# Face player
	var dir := (player.global_position - _npc_owner.global_position).normalized()
	dir.y = 0.0
	if dir.length_squared() > 0.01:
		_npc_owner.rotation.y = atan2(dir.x, dir.z)

	dialogue_started.emit(_npc_owner, dialogue_id)
	return true


func get_current_node() -> DialogueNode:
	if _active_session == null:
		return null
	return _active_session.tree.nodes.get(_active_session.current_node_id) as DialogueNode


## Returns the currently visible dialogue text (with variable substitution).
func get_current_text() -> String:
	var node := get_current_node()
	if node == null:
		return ""
	return _substitute_variables(node.text, _active_session)


## Returns the choices available to the player right now.
func get_available_choices() -> Array[DialogueChoice]:
	var node := get_current_node()
	if node == null:
		return []
	var result: Array[DialogueChoice] = []
	for choice: DialogueChoice in node.choices:
		if _check_choice_condition(choice, _active_session):
			result.append(choice)
	return result


## Player selects a choice. Executes effects and advances to next node.
func select_choice(choice_id: String) -> bool:
	var node := get_current_node()
	if node == null:
		return false

	var chosen: DialogueChoice = null
	for c: DialogueChoice in node.choices:
		if c.id == choice_id:
			chosen = c
			break

	if chosen == null:
		return false

	choice_selected.emit(_npc_owner, choice_id)

	# Execute choice effects
	_execute_effects(chosen.effects, _active_session)

	# Advance to next node
	if chosen.next_node.is_empty() or chosen.next_node == "END":
		end_dialogue()
		return true

	_active_session.current_node_id = chosen.next_node

	# Auto-execute node effects
	var next := get_current_node()
	if next and not next.effects.is_empty():
		_execute_effects(next.effects, _active_session)

	# If new node has no choices, it's a terminal: auto-advance to its target
	if next and next.choices.is_empty():
		if next.auto_next.is_empty() or next.auto_next == "END":
			end_dialogue()
		else:
			_active_session.current_node_id = next.auto_next

	return true


func end_dialogue() -> void:
	if _active_session == null:
		return
	dialogue_ended.emit(_npc_owner)
	_active_session = null


# ─── Condition Checking ───────────────────────────────────────────────────────
func _check_choice_condition(choice: DialogueChoice, session: DialogueSession) -> bool:
	if choice.condition.is_empty():
		return true

	var player := session.player
	match choice.condition:
		"always":
			return true
		"has_quest_active":
			var qs := player.get_node_or_null("QuestSystem") as QuestSystem
			return qs and qs.is_active(str(choice.condition_data.get("quest_id", "")))
		"quest_complete":
			var qs := player.get_node_or_null("QuestSystem") as QuestSystem
			return qs and qs.is_completed(str(choice.condition_data.get("quest_id", "")))
		"quest_not_started":
			var qs := player.get_node_or_null("QuestSystem") as QuestSystem
			return qs and not qs.is_active(str(choice.condition_data.get("quest_id", ""))) \
			           and not qs.is_completed(str(choice.condition_data.get("quest_id", "")))
		"faction_friendly":
			var fs := player.get_node_or_null("FactionSystem") as FactionSystem
			var fid := str(choice.condition_data.get("faction_id", ""))
			return fs and fs.get_reputation_tier(fid) >= FactionSystem.ReputationTier.FRIENDLY
		"faction_honored":
			var fs := player.get_node_or_null("FactionSystem") as FactionSystem
			var fid := str(choice.condition_data.get("faction_id", ""))
			return fs and fs.get_reputation_tier(fid) >= FactionSystem.ReputationTier.HONORED
		"has_item":
			var inv := player.get_node_or_null("InventorySystem") as InventorySystem
			var iid := str(choice.condition_data.get("item_id", ""))
			var amt := int(choice.condition_data.get("amount", 1))
			return inv and inv.has_item(iid, amt)
		"min_level":
			var prog := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
			return prog and prog.get_level() >= int(choice.condition_data.get("level", 1))
		"session_var":
			var key := str(choice.condition_data.get("key", ""))
			var val := choice.condition_data.get("value", true)
			return session.variables.get(key, null) == val
		_:
			return true


# ─── Effect Execution ─────────────────────────────────────────────────────────
func _execute_effects(effects: Array, session: DialogueSession) -> void:
	for effect: Dictionary in effects:
		var etype := str(effect.get("type", ""))
		match etype:
			"offer_quest":
				var qid    := str(effect.get("quest_id", ""))
				var qs     := session.player.get_node_or_null("QuestSystem") as QuestSystem
				if qs and qs.can_accept(qid):
					quest_offered.emit(_npc_owner, qid)
			"accept_quest":
				var qid    := str(effect.get("quest_id", ""))
				var qs     := session.player.get_node_or_null("QuestSystem") as QuestSystem
				if qs: qs.accept_quest(qid)
			"complete_quest":
				var qid    := str(effect.get("quest_id", ""))
				var qs     := session.player.get_node_or_null("QuestSystem") as QuestSystem
				if qs: qs.notify_npc_talked(str(_npc_owner.get_meta("npc_id", "")))
			"give_item":
				var iid    := str(effect.get("item_id", ""))
				var amt    := int(effect.get("amount", 1))
				var inv    := session.player.get_node_or_null("InventorySystem") as InventorySystem
				if inv: inv.add_item(iid, amt)
			"take_item":
				var iid    := str(effect.get("item_id", ""))
				var amt    := int(effect.get("amount", 1))
				var inv    := session.player.get_node_or_null("InventorySystem") as InventorySystem
				if inv: inv.remove_item(iid, amt)
			"give_gold":
				var amt    := int(effect.get("amount", 0))
				var inv    := session.player.get_node_or_null("InventorySystem") as InventorySystem
				if inv: inv.add_gold(amt)
			"give_xp":
				var amt    := int(effect.get("amount", 0))
				var prog   := session.player.get_node_or_null("ProgressionSystem") as ProgressionSystem
				if prog: prog.add_xp(amt, "dialogue")
			"change_reputation":
				var fid    := str(effect.get("faction_id", ""))
				var amt    := int(effect.get("amount", 0))
				var fs     := session.player.get_node_or_null("FactionSystem") as FactionSystem
				if fs: fs.add_reputation(fid, amt, "dialogue")
			"open_trade":
				var mid    := str(effect.get("merchant_id", _npc_owner.get_meta("merchant_id", "")))
				trade_requested.emit(_npc_owner, mid)
			"open_rest":
				# Trigger inn rest screen
				if session.player.has_method("open_rest_screen"):
					session.player.open_rest_screen(float(effect.get("cost", 10)))
			"heal_player":
				var pct    := float(effect.get("percent", 1.0))
				var cs     := get_node_or_null("/root/CombatSystem") as CombatSystem
				if cs:
					var max_hp := cs.get_actor_max_hp(session.player)
					cs.heal(session.player, max_hp * pct)
			"set_session_var":
				var key    := str(effect.get("key", ""))
				var val    := effect.get("value", true)
				session.variables[key] = val
			"play_animation":
				var anim   := str(effect.get("animation", "talk"))
				var at     := _npc_owner.get_node_or_null("AnimationTree") as AnimationTree
				if at: at.set("parameters/OneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			"spawn_creature":
				var cid    := str(effect.get("creature_id", ""))
				var offset := effect.get("offset", [5, 0, 0]) as Array
				var pos    := _npc_owner.global_position + Vector3(float(offset[0]), float(offset[1]), float(offset[2]))
				var em     := get_node_or_null("/root/EntityManager")
				if em: em.call("spawn_creature", cid, pos)


# ─── Variable Substitution ────────────────────────────────────────────────────
func _substitute_variables(text: String, session: DialogueSession) -> String:
	var result := text
	var player := session.player

	# Player name
	result = result.replace("{player_name}",
		str(player.get_meta("username", "Traveler")))

	# NPC name
	result = result.replace("{npc_name}",
		str(_npc_owner.get_meta("display_name", "NPC")))

	# Player level
	var prog := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
	if prog:
		result = result.replace("{player_level}", str(prog.get_level()))

	# Time of day
	var ws := get_node_or_null("/root/WeatherSystem") as WeatherSystem
	if ws:
		var hour := ws.get_hour()
		var greeting := "Good morning" if hour < 12 else ("Good afternoon" if hour < 18 else "Good evening")
		result = result.replace("{time_greeting}", greeting)
		result = result.replace("{time}", ws.get_time_string())

	# Session variables
	for key: String in session.variables.keys():
		result = result.replace("{%s}" % key, str(session.variables[key]))

	return result


# ─── Data Classes ─────────────────────────────────────────────────────────────
class DialogueChoice extends RefCounted:
	var id             : String
	var text           : String
	var condition      : String = ""
	var condition_data : Dictionary = {}
	var effects        : Array = []
	var next_node      : String = "END"

	static func from_dict(d: Dictionary) -> DialogueChoice:
		var c              := DialogueChoice.new()
		c.id                = str(d.get("id",              "choice"))
		c.text              = str(d.get("text",            "..."))
		c.condition         = str(d.get("condition",       "always"))
		c.condition_data    = d.get("condition_data",   {})
		c.effects           = d.get("effects",          [])
		c.next_node         = str(d.get("next",            "END"))
		return c


class DialogueNode extends RefCounted:
	var id          : String
	var speaker     : String    # "npc" or "narrator"
	var text        : String
	var portrait    : String    # Portrait image path (optional)
	var choices     : Array[DialogueChoice] = []
	var effects     : Array = []
	var auto_next   : String = ""   # If no choices, auto-advance to this node

	static func from_dict(nid: String, d: Dictionary) -> DialogueNode:
		var n         := DialogueNode.new()
		n.id           = nid
		n.speaker      = str(d.get("speaker",   "npc"))
		n.text         = str(d.get("text",       ""))
		n.portrait     = str(d.get("portrait",  ""))
		n.effects      = d.get("effects",     [])
		n.auto_next    = str(d.get("auto_next", ""))
		for cd: Dictionary in d.get("choices", []):
			n.choices.append(DialogueChoice.from_dict(cd))
		return n


class DialogueTree extends RefCounted:
	var id         : String
	var entry_node : String
	var nodes      : Dictionary = {}    # node_id -> DialogueNode

	static func from_dict(did: String, d: Dictionary) -> DialogueTree:
		var t          := DialogueTree.new()
		t.id            = did
		t.entry_node    = str(d.get("entry", "start"))
		for nid: String in d.get("nodes", {}).keys():
			t.nodes[nid] = DialogueNode.from_dict(nid, d["nodes"][nid])
		return t


class DialogueSession extends RefCounted:
	var tree            : DialogueTree
	var player          : Node3D
	var current_node_id : String
	var variables       : Dictionary = {}
