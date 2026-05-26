## systems/crafting/crafting_system.gd
## Data-driven crafting with categories: smithing, alchemy, cooking, woodworking.
## Recipes loaded from crafting_recipes.json. Handles skill checks and quality tiers.

class_name CraftingSystem
extends Node

signal crafting_started(recipe_id: String, duration: float)
signal crafting_completed(recipe_id: String, result_items: Array)
signal crafting_failed(recipe_id: String, reason: String)
signal resource_gathered(item_id: String, amount: int, tool_used: String)

const RECIPE_PATH := "res://assets/definitions/crafting_recipes.json"

enum CraftingCategory { SMITHING, ALCHEMY, COOKING, WOODWORKING, TAILORING, ENCHANTING }
enum ItemQuality      { CRUDE, COMMON, FINE, EXCEPTIONAL, MASTERWORK, LEGENDARY }

var _recipes       : Dictionary = {}   # recipe_id -> RecipeData
var _active_crafts : Dictionary = {}   # player_id -> ActiveCraft
var _player_ref    : Node3D


func _ready() -> void:
	_player_ref = get_parent()
	_load_recipes()


func _load_recipes() -> void:
	if not FileAccess.file_exists(RECIPE_PATH):
		push_warning("[Crafting] crafting_recipes.json not found")
		return
	var text   := FileAccess.open(RECIPE_PATH, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("[Crafting] Failed to parse crafting_recipes.json")
		return
	for recipe_id: String in parsed.keys():
		_recipes[recipe_id] = RecipeData.from_dict(recipe_id, parsed[recipe_id])
	print("[Crafting] Loaded %d recipes" % _recipes.size())


func _process(delta: float) -> void:
	_tick_active_crafts(delta)


# ─── Crafting ─────────────────────────────────────────────────────────────────
func can_craft(recipe_id: String, inventory: InventorySystem,
		progression: ProgressionSystem) -> CraftCheckResult:
	var result := CraftCheckResult.new()
	var recipe := _recipes.get(recipe_id) as RecipeData
	if recipe == null:
		result.can_craft = false
		result.reason    = "Unknown recipe"
		return result

	# Skill level check
	if progression and recipe.required_skill_level > 0:
		var skill_rank := progression.get_skill_rank(recipe.required_skill)
		if skill_rank < recipe.required_skill_level:
			result.can_craft = false
			result.reason    = "Requires %s rank %d" % [recipe.required_skill, recipe.required_skill_level]
			return result

	# Ingredient check
	for ingredient: Dictionary in recipe.ingredients:
		var have := inventory.get_item_count(ingredient["item_id"])
		if have < int(ingredient["amount"]):
			result.can_craft   = false
			result.reason      = "Need %d x %s" % [ingredient["amount"], ingredient["item_id"]]
			result.missing.append(ingredient)
			return result

	# Workstation check (if required)
	if not recipe.workstation.is_empty():
		if not _is_near_workstation(recipe.workstation):
			result.can_craft = false
			result.reason    = "Requires " + recipe.workstation
			return result

	result.can_craft = true
	return result


func begin_craft(recipe_id: String, inventory: InventorySystem,
		progression: ProgressionSystem, player_id: int) -> bool:
	var check := can_craft(recipe_id, inventory, progression)
	if not check.can_craft:
		crafting_failed.emit(recipe_id, check.reason)
		return false

	if _active_crafts.has(player_id):
		crafting_failed.emit(recipe_id, "Already crafting")
		return false

	var recipe := _recipes[recipe_id] as RecipeData

	# Consume ingredients
	for ingredient: Dictionary in recipe.ingredients:
		inventory.remove_item(ingredient["item_id"], int(ingredient["amount"]))

	# Start craft timer
	var quality_bonus := _get_quality_bonus(recipe, progression)
	var duration      := recipe.craft_time * (1.0 - quality_bonus * 0.2)

	var craft       := ActiveCraft.new()
	craft.recipe_id  = recipe_id
	craft.player_id  = player_id
	craft.timer      = duration
	craft.quality    = _roll_quality(recipe, progression)
	_active_crafts[player_id] = craft

	crafting_started.emit(recipe_id, duration)
	return true


func _tick_active_crafts(delta: float) -> void:
	for player_id: int in _active_crafts.keys():
		var craft := _active_crafts[player_id] as ActiveCraft
		craft.timer -= delta
		if craft.timer <= 0.0:
			_complete_craft(player_id, craft)


func _complete_craft(player_id: int, craft: ActiveCraft) -> void:
	_active_crafts.erase(player_id)
	var recipe := _recipes[craft.recipe_id] as RecipeData

	# Build result items with quality modifiers
	var result_items: Array[Dictionary] = []
	for output: Dictionary in recipe.outputs:
		var item_id := str(output["item_id"])
		var amount  := int(output["amount"])
		var item    := {
			"item_id": item_id,
			"amount":  amount,
			"quality": ItemQuality.keys()[craft.quality],
		}
		result_items.append(item)

	# Add result to player inventory
	var player := _get_player_by_id(player_id)
	if player:
		var inv := player.get_node("InventorySystem") as InventorySystem
		for item: Dictionary in result_items:
			inv.add_item(item["item_id"], item["amount"], {"quality": item["quality"]})
		# Award crafting XP
		var prog := player.get_node("ProgressionSystem") as ProgressionSystem
		if prog:
			prog.add_xp(recipe.xp_reward, "crafting:" + recipe.category)

	crafting_completed.emit(craft.recipe_id, result_items)


func cancel_craft(player_id: int) -> void:
	if not _active_crafts.has(player_id):
		return
	# Return half the ingredients on cancel
	var craft  := _active_crafts[player_id] as ActiveCraft
	var recipe := _recipes[craft.recipe_id] as RecipeData
	_active_crafts.erase(player_id)
	var player := _get_player_by_id(player_id)
	if player:
		var inv := player.get_node("InventorySystem") as InventorySystem
		for ingredient: Dictionary in recipe.ingredients:
			inv.add_item(ingredient["item_id"], int(ingredient["amount"]) / 2)


# ─── Quality System ───────────────────────────────────────────────────────────
func _roll_quality(recipe: RecipeData, prog: ProgressionSystem) -> ItemQuality:
	var skill_rank := 0
	if prog:
		skill_rank = prog.get_skill_rank(recipe.required_skill)

	var quality_weights := _get_quality_weights(recipe, skill_rank)
	var roll             := randf()
	var accum            := 0.0
	for i in quality_weights.size():
		accum += quality_weights[i]
		if roll <= accum:
			return i as ItemQuality
	return ItemQuality.COMMON


func _get_quality_weights(recipe: RecipeData, skill_rank: int) -> Array[float]:
	# Higher skill = more chance of better quality
	var bonus := float(skill_rank) / 10.0
	match recipe.category:
		"smithing":
			return [
				maxf(0.0, 0.15 - bonus * 0.05),   # CRUDE
				maxf(0.0, 0.45 - bonus * 0.1),    # COMMON
				minf(1.0, 0.25 + bonus * 0.05),   # FINE
				minf(1.0, 0.10 + bonus * 0.05),   # EXCEPTIONAL
				minf(1.0, 0.04 + bonus * 0.03),   # MASTERWORK
				minf(1.0, 0.01 + bonus * 0.02),   # LEGENDARY
			]
		_:
			return [0.15, 0.50, 0.25, 0.07, 0.02, 0.01]


func _get_quality_bonus(recipe: RecipeData, prog: ProgressionSystem) -> float:
	if prog == null:
		return 0.0
	return float(prog.get_skill_rank(recipe.required_skill)) / 10.0


# ─── Resource Gathering ───────────────────────────────────────────────────────
## Called when player mines/chops/picks resources from the world.
func gather_resource(resource_node: Node3D, tool_item: Dictionary,
		player_inv: InventorySystem, player_prog: ProgressionSystem) -> void:
	var resource_type := str(resource_node.get_meta("resource_type", "unknown"))
	var gather_data   := _get_gather_data(resource_type, tool_item, player_prog)

	for item: Dictionary in gather_data:
		player_inv.add_item(str(item["item_id"]), int(item["amount"]))
		resource_gathered.emit(item["item_id"], item["amount"], tool_item.get("id", "hand"))

	# XP
	var xp := _get_gather_xp(resource_type)
	player_prog.add_xp(xp, "gathering:" + resource_type)

	# Deplete the resource node
	if resource_node.has_method("on_gathered"):
		resource_node.on_gathered()


func _get_gather_data(resource_type: String, tool: Dictionary,
		prog: ProgressionSystem) -> Array[Dictionary]:
	var has_axe   := tool.get("tag", "") == "axe"
	var has_pick  := tool.get("tag", "") == "pickaxe"
	var mining_sk := prog.get_skill_rank("mining")     if prog else 0
	var logging_sk:= prog.get_skill_rank("woodcutting") if prog else 0

	match resource_type:
		"oak_tree":
			var logs   := 2 + (2 if has_axe else 0) + logging_sk / 3
			var chance := 0.1 + logging_sk * 0.05
			var result := [{"item_id": "oak_log", "amount": logs}]
			if randf() < chance:
				result.append({"item_id": "oak_seed", "amount": 1})
			return result
		"pine_tree":
			return [
				{"item_id": "pine_log", "amount": 2 + (2 if has_axe else 0)},
				{"item_id": "pine_resin", "amount": 1},
			]
		"iron_ore":
			return [{"item_id": "iron_ore",
				"amount": 1 + (2 if has_pick else 0) + mining_sk / 4}]
		"coal_deposit":
			return [{"item_id": "coal",
				"amount": 2 + (3 if has_pick else 0) + mining_sk / 3}]
		"gold_ore":
			return [{"item_id": "gold_ore",
				"amount": 1 + (1 if has_pick else 0) + mining_sk / 5}]
		"mithril_ore":
			if mining_sk < 5:
				return []   # Need mining skill 5+
			return [{"item_id": "mithril_ore", "amount": 1}]
		"herb_patch":
			var herbs := ["wildroot", "moonpetal", "firebloom", "frostleaf"]
			return [{"item_id": herbs[randi() % herbs.size()], "amount": randi_range(1, 3)}]
		"mushroom":
			return [{"item_id": "forest_mushroom", "amount": randi_range(1, 3)}]
		_:
			return []


func _get_gather_xp(resource_type: String) -> int:
	match resource_type:
		"oak_tree":    return 15
		"pine_tree":   return 18
		"iron_ore":    return 20
		"coal_deposit":return 12
		"gold_ore":    return 35
		"mithril_ore": return 80
		"herb_patch":  return 10
		_:             return 5


# ─── Workstation Detection ────────────────────────────────────────────────────
func _is_near_workstation(workstation_type: String) -> bool:
	# Check for workstation nodes near the player
	var stations := get_tree().get_nodes_in_group("workstations")
	for station: Node3D in stations:
		if station.get_meta("type", "") == workstation_type:
			if _player_ref.global_position.distance_to(station.global_position) <= 4.0:
				return true
	return false


# ─── Recipe Discovery ─────────────────────────────────────────────────────────
## Returns all recipes the player could potentially craft given their skills.
func get_available_recipes(progression: ProgressionSystem,
		category_filter: String = "") -> Array[RecipeData]:
	var result: Array[RecipeData] = []
	for recipe: RecipeData in _recipes.values():
		if not category_filter.is_empty() and recipe.category != category_filter:
			continue
		var skill_rank := progression.get_skill_rank(recipe.required_skill) if progression else 0
		if skill_rank >= recipe.required_skill_level:
			result.append(recipe)
	return result


func _get_player_by_id(player_id: int) -> Node3D:
	for p: Node3D in get_tree().get_nodes_in_group("players"):
		if p.get_multiplayer_authority() == player_id:
			return p
	return null


# ─── Data Classes ─────────────────────────────────────────────────────────────
class RecipeData extends RefCounted:
	var id                   : String
	var display_name         : String
	var category             : String
	var ingredients          : Array      # [{item_id, amount}]
	var outputs              : Array      # [{item_id, amount}]
	var craft_time           : float
	var workstation          : String
	var required_skill       : String
	var required_skill_level : int
	var xp_reward            : int
	var icon_path            : String

	static func from_dict(recipe_id: String, d: Dictionary) -> RecipeData:
		var r                    := RecipeData.new()
		r.id                      = recipe_id
		r.display_name            = d.get("name",          recipe_id)
		r.category                = d.get("category",      "general")
		r.ingredients             = d.get("ingredients",   [])
		r.outputs                 = d.get("outputs",       [])
		r.craft_time              = float(d.get("craft_time", 3.0))
		r.workstation             = d.get("workstation",   "")
		r.required_skill          = d.get("required_skill","")
		r.required_skill_level    = int(d.get("required_level", 0))
		r.xp_reward               = int(d.get("xp_reward", 10))
		r.icon_path               = d.get("icon",          "")
		return r


class ActiveCraft extends RefCounted:
	var recipe_id : String
	var player_id : int
	var timer     : float
	var quality   : int   # ItemQuality enum value


class CraftCheckResult extends RefCounted:
	var can_craft : bool  = false
	var reason    : String = ""
	var missing   : Array  = []
