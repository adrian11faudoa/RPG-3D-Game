## systems/factions/faction_system.gd
## Tracks player reputation with factions, drives NPC behavior, unlocks
## quests/vendors, and simulates inter-faction wars on the server.
##
## Reputation tiers (same scale as classic MMOs):
##   -3000  Hated     → Kill on sight
##   -2000  Hostile   → Refuse service, attack if provoked
##    -500  Unfriendly→ No services, avoid player
##       0  Neutral   → Default
##    1000  Friendly  → Basic services available
##    3000  Honored   → Discounts, side quests
##    6000  Revered   → Rare quests, unique items
##    9000  Exalted   → Title, max discounts, unique cosmetics

class_name FactionSystem
extends Node

signal reputation_changed(faction_id: String, old_val: int, new_val: int)
signal tier_changed(faction_id: String, old_tier: ReputationTier, new_tier: ReputationTier)
signal faction_war_started(faction_a: String, faction_b: String)
signal faction_war_ended(faction_a: String, faction_b: String, victor: String)

enum ReputationTier {
	HATED, HOSTILE, UNFRIENDLY, NEUTRAL,
	FRIENDLY, HONORED, REVERED, EXALTED
}

const TIER_THRESHOLDS : Array[int] = [-3000, -2000, -500, 0, 1000, 3000, 6000, 9000]
const MAX_REP         : int = 10000
const MIN_REP         : int = -3000

# ─── Faction Definitions (loaded from factions.json) ─────────────────────────
var _factions        : Dictionary = {}   # faction_id -> FactionData
var _player_rep      : Dictionary = {}   # faction_id -> int (reputation value)
var _faction_relations: Dictionary = {}  # faction_id -> {faction_id: relation (-1..1)}
var _active_wars     : Array = []        # [{faction_a, faction_b, start_time, intensity}]


func _ready() -> void:
	_load_factions()
	_init_default_rep()


func _load_factions() -> void:
	var path   := "res://assets/definitions/factions.json"
	if not FileAccess.file_exists(path):
		push_warning("[Factions] factions.json not found")
		return
	var text   := FileAccess.open(path, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if not parsed is Dictionary:
		return
	for fid: String in parsed.keys():
		_factions[fid] = FactionData.from_dict(fid, parsed[fid])
		_faction_relations[fid] = parsed[fid].get("relations", {})
	print("[Factions] Loaded %d factions" % _factions.size())


func _init_default_rep() -> void:
	for fid: String in _factions.keys():
		var def := _factions[fid] as FactionData
		_player_rep[fid] = def.default_rep


# ─── Reputation Management ────────────────────────────────────────────────────
func add_reputation(faction_id: String, amount: int, reason: String = "") -> void:
	if not _player_rep.has(faction_id):
		_player_rep[faction_id] = 0

	var old_val  := _player_rep[faction_id]
	var new_val  := clampi(old_val + amount, MIN_REP, MAX_REP)
	_player_rep[faction_id] = new_val

	var old_tier := get_reputation_tier(faction_id, old_val)
	var new_tier := get_reputation_tier(faction_id, new_val)

	reputation_changed.emit(faction_id, old_val, new_val)
	if old_tier != new_tier:
		tier_changed.emit(faction_id, old_tier, new_tier)
		_on_tier_changed(faction_id, new_tier)

	# Spillover reputation to allied/enemy factions
	_apply_rep_spillover(faction_id, amount)

	if reason:
		print("[Factions] %s rep: %+d (%s) → %d [%s]" % [
			faction_id, amount, reason, new_val, ReputationTier.keys()[new_tier]
		])


func get_reputation(faction_id: String) -> int:
	return _player_rep.get(faction_id, 0)


func get_reputation_tier(faction_id: String, rep_override: int = -99999) -> ReputationTier:
	var rep := rep_override if rep_override != -99999 else get_reputation(faction_id)
	for i in TIER_THRESHOLDS.size():
		if rep < TIER_THRESHOLDS[i]:
			return maxi(0, i - 1) as ReputationTier
	return ReputationTier.EXALTED


func get_rep_progress_in_tier(faction_id: String) -> float:
	var rep  := get_reputation(faction_id)
	var tier := get_reputation_tier(faction_id) as int
	if tier >= ReputationTier.EXALTED:
		return 1.0
	var low  := TIER_THRESHOLDS[tier]
	var high := TIER_THRESHOLDS[tier + 1]
	return float(rep - low) / float(high - low)


func _on_tier_changed(faction_id: String, new_tier: ReputationTier) -> void:
	match new_tier:
		ReputationTier.FRIENDLY:
			print("[Factions] '%s' now offers basic services!" % faction_id)
		ReputationTier.HONORED:
			print("[Factions] '%s' respects you — discounts unlocked!" % faction_id)
		ReputationTier.REVERED:
			print("[Factions] '%s' trusts you deeply — rare quests available!" % faction_id)
		ReputationTier.EXALTED:
			print("[Factions] EXALTED with '%s' — unique title and cosmetics!" % faction_id)
		ReputationTier.HOSTILE:
			print("[Factions] '%s' is now HOSTILE toward you!" % faction_id)
		ReputationTier.HATED:
			print("[Factions] '%s' HATES you — kill on sight!" % faction_id)


func _apply_rep_spillover(source_faction: String, amount: int) -> void:
	var relations := _faction_relations.get(source_faction, {}) as Dictionary
	for other_id: String in relations.keys():
		var relation := float(relations[other_id])  # -1 (enemy) → 1 (ally)
		if absf(relation) < 0.1:
			continue
		var spillover := int(amount * relation * 0.35)
		if spillover != 0:
			add_reputation(other_id, spillover)


# ─── NPC Behavior Based on Rep ────────────────────────────────────────────────
func get_npc_disposition(faction_id: String) -> String:
	match get_reputation_tier(faction_id):
		ReputationTier.HATED:       return "kill_on_sight"
		ReputationTier.HOSTILE:     return "hostile"
		ReputationTier.UNFRIENDLY:  return "unfriendly"
		ReputationTier.NEUTRAL:     return "neutral"
		ReputationTier.FRIENDLY:    return "friendly"
		ReputationTier.HONORED:     return "honored"
		ReputationTier.REVERED:     return "revered"
		ReputationTier.EXALTED:     return "exalted"
		_:                          return "neutral"


func can_trade_with(faction_id: String) -> bool:
	var tier := get_reputation_tier(faction_id)
	return tier >= ReputationTier.NEUTRAL


func get_vendor_discount(faction_id: String) -> float:
	match get_reputation_tier(faction_id):
		ReputationTier.HONORED:   return 0.10
		ReputationTier.REVERED:   return 0.20
		ReputationTier.EXALTED:   return 0.30
		_:                        return 0.0


func can_enter_territory(faction_id: String) -> bool:
	return get_reputation_tier(faction_id) > ReputationTier.HOSTILE


## Returns list of factions that currently want to kill the player.
func get_hostile_factions() -> Array[String]:
	var result: Array[String] = []
	for fid: String in _player_rep.keys():
		if get_reputation_tier(fid) <= ReputationTier.HOSTILE:
			result.append(fid)
	return result


# ─── Quest Availability ───────────────────────────────────────────────────────
func get_available_faction_quests(faction_id: String) -> Array[String]:
	var tier   := get_reputation_tier(faction_id)
	var faction := _factions.get(faction_id) as FactionData
	if faction == null:
		return []
	var quests: Array[String] = []
	for quest_entry: Dictionary in faction.quests:
		var min_tier := int(quest_entry.get("min_tier", ReputationTier.NEUTRAL))
		if tier >= min_tier:
			quests.append(str(quest_entry.get("quest_id", "")))
	return quests


# ─── Faction War Simulation (Server-side) ────────────────────────────────────
func _process(_delta: float) -> void:
	if not multiplayer.is_server():
		return
	_tick_wars(_delta)
	_check_war_triggers()


var _war_tick_timer: float = 0.0

func _tick_wars(delta: float) -> void:
	_war_tick_timer += delta
	if _war_tick_timer < 30.0:  # Simulate every 30 seconds
		return
	_war_tick_timer = 0.0

	for war: Dictionary in _active_wars:
		# Simulate skirmish outcome
		var fa     := war["faction_a"] as String
		var fb     := war["faction_b"] as String
		var outcome := randf()

		var power_a := _get_faction_power(fa)
		var power_b := _get_faction_power(fb)
		var total   := power_a + power_b

		if outcome < power_a / total:
			war["score_a"] = int(war.get("score_a", 0)) + 1
		else:
			war["score_b"] = int(war.get("score_b", 0)) + 1

		# Check for war end
		var victory_score := 10
		if int(war.get("score_a", 0)) >= victory_score:
			_end_war(fa, fb, fa)
		elif int(war.get("score_b", 0)) >= victory_score:
			_end_war(fa, fb, fb)


func _check_war_triggers() -> void:
	# Check if any factions' relation has deteriorated enough to declare war
	for fa: String in _faction_relations.keys():
		for fb: String in (_faction_relations[fa] as Dictionary).keys():
			var relation := float(_faction_relations[fa][fb])
			if relation < -0.8 and not _factions_at_war(fa, fb):
				if randf() < 0.01:  # 1% chance per tick to declare war
					_start_war(fa, fb)


func _start_war(faction_a: String, faction_b: String) -> void:
	_active_wars.append({
		"faction_a": faction_a,
		"faction_b": faction_b,
		"start_time": Time.get_unix_time_from_system(),
		"score_a":    0,
		"score_b":    0,
	})
	faction_war_started.emit(faction_a, faction_b)
	print("[Factions] WAR declared: %s vs %s" % [faction_a, faction_b])


func _end_war(faction_a: String, faction_b: String, victor: String) -> void:
	for i in _active_wars.size():
		var war: Dictionary = _active_wars[i]
		if (war["faction_a"] == faction_a and war["faction_b"] == faction_b) or \
		   (war["faction_a"] == faction_b and war["faction_b"] == faction_a):
			_active_wars.remove_at(i)
			break
	faction_war_ended.emit(faction_a, faction_b, victor)
	print("[Factions] War ended: %s VICTORY over %s" % [victor, faction_b if victor == faction_a else faction_a])

	# Update relations after war
	_faction_relations[faction_a][faction_b] = -0.3
	_faction_relations[faction_b][faction_a] = -0.3


func _factions_at_war(fa: String, fb: String) -> bool:
	for war: Dictionary in _active_wars:
		if (war["faction_a"] == fa and war["faction_b"] == fb) or \
		   (war["faction_a"] == fb and war["faction_b"] == fa):
			return true
	return false


func _get_faction_power(faction_id: String) -> float:
	var faction := _factions.get(faction_id) as FactionData
	if faction == null:
		return 1.0
	return float(faction.military_power)


# ─── Serialization ────────────────────────────────────────────────────────────
func serialize() -> Dictionary:
	return { "reputation": _player_rep.duplicate() }


func deserialize(data: Dictionary) -> void:
	var saved := data.get("reputation", {}) as Dictionary
	for fid: String in saved.keys():
		_player_rep[fid] = int(saved[fid])


# ─── Data Classes ─────────────────────────────────────────────────────────────
class FactionData extends RefCounted:
	var id             : String
	var display_name   : String
	var description    : String
	var icon_path      : String
	var color          : Color
	var default_rep    : int     = 0
	var military_power : float   = 1.0
	var quests         : Array   = []
	var home_region    : String  = ""
	var enemy_factions : Array   = []

	static func from_dict(fid: String, d: Dictionary) -> FactionData:
		var f              := FactionData.new()
		f.id                = fid
		f.display_name      = d.get("name",          fid)
		f.description       = d.get("description",   "")
		f.icon_path         = d.get("icon",           "")
		f.default_rep       = int(d.get("default_rep",  0))
		f.military_power    = float(d.get("military_power", 1.0))
		f.quests            = d.get("quests",         [])
		f.home_region       = d.get("home_region",    "")
		f.enemy_factions    = d.get("enemies",        [])
		var col := d.get("color", [1, 1, 1]) as Array
		f.color = Color(float(col[0]), float(col[1]), float(col[2]))
		return f
