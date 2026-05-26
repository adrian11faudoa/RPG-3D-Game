## player/inventory/inventory_system.gd
## Full inventory management: item stacks, equipment slots, loot rarity,
## drag-drop, sorting, and serialization. Server-authoritative on item changes.

class_name InventorySystem
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal item_added(item_id: String, amount: int, slot: int)
signal item_removed(item_id: String, amount: int, slot: int)
signal item_equipped(item_id: String, slot: EquipSlot)
signal item_unequipped(item_id: String, slot: EquipSlot)
signal inventory_changed()
signal equipment_changed()

# ─── Enums ────────────────────────────────────────────────────────────────────
enum EquipSlot {
	HEAD, CHEST, LEGS, FEET, HANDS,
	MAIN_HAND, OFF_HAND, RANGED,
	NECK, RING_L, RING_R, BACK
}

enum ItemRarity {
	COMMON, UNCOMMON, RARE, EPIC, LEGENDARY, MYTHIC
}

# ─── Constants ────────────────────────────────────────────────────────────────
const MAX_SLOTS        : int = 40
const MAX_STACK_SIZE   : int = 999
const EQUIP_SLOT_COUNT : int = 12

# ─── Item Registry ────────────────────────────────────────────────────────────
static var _item_registry : Dictionary = {}   # item_id -> ItemDefinition
static var _registry_loaded : bool = false

# ─── State ────────────────────────────────────────────────────────────────────
var _slots      : Array[ItemStack]       # MAX_SLOTS slots
var _equipment  : Dictionary             # EquipSlot -> ItemStack
var _gold       : int = 0
var _owner      : Node3D


func _ready() -> void:
	_owner  = get_parent()
	_slots  = []
	_slots.resize(MAX_SLOTS)
	_equipment = {}
	_load_item_registry()


static func _load_item_registry() -> void:
	if _registry_loaded:
		return
	var path   := "res://assets/definitions/items.json"
	if not FileAccess.file_exists(path):
		push_warning("[Inventory] items.json not found")
		return
	var text   := FileAccess.open(path, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if parsed is Dictionary:
		for item_id: String in parsed.keys():
			_item_registry[item_id] = ItemDefinition.from_dict(item_id, parsed[item_id])
	_registry_loaded = true
	print("[Inventory] Loaded %d item definitions" % _item_registry.size())


# ─── Adding Items ─────────────────────────────────────────────────────────────
## Returns true if all items fit, false if inventory is full (partial add possible).
func add_item(item_id: String, amount: int, metadata: Dictionary = {}) -> bool:
	if amount <= 0:
		return true
	var def := get_item_def(item_id)
	if def == null:
		push_warning("[Inventory] Unknown item: %s" % item_id)
		return false

	var remaining := amount

	# First: try to stack onto existing stacks
	if def.stackable:
		for i in MAX_SLOTS:
			if _slots[i] == null:
				continue
			if _slots[i].item_id == item_id:
				var space := MAX_STACK_SIZE - _slots[i].amount
				var add   := mini(space, remaining)
				_slots[i].amount += add
				remaining        -= add
				item_added.emit(item_id, add, i)
				if remaining == 0:
					inventory_changed.emit()
					return true

	# Second: find empty slots
	for i in MAX_SLOTS:
		if _slots[i] != null:
			continue
		var stack         := ItemStack.new()
		stack.item_id      = item_id
		stack.amount       = mini(remaining, MAX_STACK_SIZE if def.stackable else 1)
		stack.metadata     = metadata.duplicate()
		stack.rarity       = metadata.get("rarity", _roll_rarity(def)) as ItemRarity
		stack.quality      = metadata.get("quality", "common")
		_slots[i]          = stack
		remaining         -= stack.amount
		item_added.emit(item_id, stack.amount, i)
		if remaining == 0:
			inventory_changed.emit()
			return true

	inventory_changed.emit()
	return remaining == 0  # false if we couldn't fit everything


func remove_item(item_id: String, amount: int) -> int:
	var removed := 0
	for i in MAX_SLOTS:
		if _slots[i] == null or _slots[i].item_id != item_id:
			continue
		var take    := mini(_slots[i].amount, amount - removed)
		_slots[i].amount -= take
		removed          += take
		item_removed.emit(item_id, take, i)
		if _slots[i].amount <= 0:
			_slots[i] = null
		if removed >= amount:
			break
	inventory_changed.emit()
	return removed


func remove_item_from_slot(slot_index: int, amount: int = 1) -> ItemStack:
	if slot_index < 0 or slot_index >= MAX_SLOTS or _slots[slot_index] == null:
		return null
	var stack := _slots[slot_index]
	var taken := mini(stack.amount, amount)
	stack.amount -= taken
	item_removed.emit(stack.item_id, taken, slot_index)
	if stack.amount <= 0:
		_slots[slot_index] = null
		inventory_changed.emit()
		return stack
	inventory_changed.emit()
	var result        := ItemStack.new()
	result.item_id     = stack.item_id
	result.amount      = taken
	result.metadata    = stack.metadata.duplicate()
	result.rarity      = stack.rarity
	result.quality     = stack.quality
	return result


func get_item_count(item_id: String) -> int:
	var total := 0
	for stack in _slots:
		if stack != null and stack.item_id == item_id:
			total += stack.amount
	return total


func has_item(item_id: String, amount: int = 1) -> bool:
	return get_item_count(item_id) >= amount


# ─── Equipment ────────────────────────────────────────────────────────────────
func equip_item(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= MAX_SLOTS or _slots[slot_index] == null:
		return false
	var stack := _slots[slot_index]
	var def   := get_item_def(stack.item_id)
	if def == null or def.equip_slot < 0:
		return false   # Not equippable

	var equip_slot := def.equip_slot as EquipSlot

	# Swap if something is already equipped
	if _equipment.has(equip_slot):
		var old_stack := _equipment[equip_slot] as ItemStack
		_slots[slot_index] = old_stack
		item_unequipped.emit(old_stack.item_id, equip_slot)
	else:
		_slots[slot_index] = null

	_equipment[equip_slot] = stack
	_apply_equipment_stats()
	item_equipped.emit(stack.item_id, equip_slot)
	equipment_changed.emit()
	inventory_changed.emit()
	return true


func unequip_slot(equip_slot: EquipSlot) -> bool:
	if not _equipment.has(equip_slot):
		return false
	var stack := _equipment[equip_slot] as ItemStack
	if not add_item(stack.item_id, stack.amount, stack.metadata):
		return false   # Inventory full
	_equipment.erase(equip_slot)
	_apply_equipment_stats()
	item_unequipped.emit(stack.item_id, equip_slot)
	equipment_changed.emit()
	return true


func get_equipped(equip_slot: EquipSlot) -> ItemStack:
	return _equipment.get(equip_slot, null)


func _apply_equipment_stats() -> void:
	# Recalculate total equipment bonuses and push to ActorStats
	var bonuses := {}
	for slot in _equipment.keys():
		var stack : ItemStack  = _equipment[slot]
		var def   : ItemDefinition = get_item_def(stack.item_id)
		if def == null:
			continue
		for stat: String in def.stat_bonuses.keys():
			var val   := float(def.stat_bonuses[stat])
			var mult  := _get_quality_multiplier(stack.quality)
			var rarity_mult := _get_rarity_multiplier(stack.rarity)
			bonuses[stat]    = bonuses.get(stat, 0.0) + val * mult * rarity_mult

	if _owner.has_method("set_equipment_bonuses"):
		_owner.set_equipment_bonuses(bonuses)


func _get_quality_multiplier(quality: String) -> float:
	match quality:
		"crude":       return 0.7
		"common":      return 1.0
		"fine":        return 1.2
		"exceptional": return 1.4
		"masterwork":  return 1.7
		"legendary":   return 2.2
		_:             return 1.0


func _get_rarity_multiplier(rarity: ItemRarity) -> float:
	match rarity:
		ItemRarity.COMMON:   return 1.0
		ItemRarity.UNCOMMON: return 1.15
		ItemRarity.RARE:     return 1.35
		ItemRarity.EPIC:     return 1.6
		ItemRarity.LEGENDARY:return 2.0
		ItemRarity.MYTHIC:   return 2.8
		_:                   return 1.0


# ─── Loot Rarity Rolling ──────────────────────────────────────────────────────
func _roll_rarity(def: ItemDefinition) -> ItemRarity:
	# Base rarity from item definition; player luck could modify this
	var roll := randf()
	if roll < 0.60: return ItemRarity.COMMON
	if roll < 0.85: return ItemRarity.UNCOMMON
	if roll < 0.95: return ItemRarity.RARE
	if roll < 0.99: return ItemRarity.EPIC
	if roll < 0.998:return ItemRarity.LEGENDARY
	return ItemRarity.MYTHIC


# ─── Slot Operations ──────────────────────────────────────────────────────────
func swap_slots(slot_a: int, slot_b: int) -> void:
	if slot_a < 0 or slot_b < 0 or slot_a >= MAX_SLOTS or slot_b >= MAX_SLOTS:
		return
	var temp     := _slots[slot_a]
	_slots[slot_a] = _slots[slot_b]
	_slots[slot_b] = temp
	inventory_changed.emit()


func sort_inventory() -> void:
	# Group by item_id, merge stacks, then sort by category
	var merged: Dictionary = {}   # item_id -> {total, metadata, rarity, quality}
	for stack in _slots:
		if stack == null:
			continue
		if not merged.has(stack.item_id):
			merged[stack.item_id] = {
				"total": 0, "metadata": stack.metadata,
				"rarity": stack.rarity, "quality": stack.quality
			}
		merged[stack.item_id]["total"] += stack.amount

	# Clear and re-add sorted
	for i in MAX_SLOTS:
		_slots[i] = null

	var sorted_ids := merged.keys()
	sorted_ids.sort_custom(func(a, b): return _sort_priority(a) < _sort_priority(b))

	var slot_idx := 0
	for item_id: String in sorted_ids:
		var data := merged[item_id]
		var total : int = data["total"]
		while total > 0 and slot_idx < MAX_SLOTS:
			var stack         := ItemStack.new()
			stack.item_id      = item_id
			stack.amount       = mini(total, MAX_STACK_SIZE)
			stack.metadata     = data["metadata"]
			stack.rarity       = data["rarity"]
			stack.quality      = data["quality"]
			_slots[slot_idx]   = stack
			total             -= stack.amount
			slot_idx          += 1

	inventory_changed.emit()


func _sort_priority(item_id: String) -> int:
	var def := get_item_def(item_id)
	if def == null:
		return 99
	match def.category:
		"weapon":    return 0
		"armor":     return 1
		"accessory": return 2
		"consumable":return 3
		"material":  return 4
		"quest":     return 5
		_:           return 6


# ─── Gold ─────────────────────────────────────────────────────────────────────
func add_gold(amount: int) -> void:
	_gold += amount
	inventory_changed.emit()


func spend_gold(amount: int) -> bool:
	if _gold < amount:
		return false
	_gold -= amount
	inventory_changed.emit()
	return true


func get_gold() -> int:
	return _gold


# ─── Serialization ────────────────────────────────────────────────────────────
func serialize() -> Dictionary:
	var slots_data: Array = []
	for i in MAX_SLOTS:
		if _slots[i] == null:
			slots_data.append(null)
		else:
			slots_data.append(_slots[i].to_dict())

	var equip_data: Dictionary = {}
	for slot_key in _equipment.keys():
		equip_data[str(slot_key)] = (_equipment[slot_key] as ItemStack).to_dict()

	return {
		"slots":     slots_data,
		"equipment": equip_data,
		"gold":      _gold,
	}


func deserialize(data: Dictionary) -> void:
	_gold = int(data.get("gold", 0))

	var slots_data := data.get("slots", []) as Array
	for i in mini(slots_data.size(), MAX_SLOTS):
		if slots_data[i] == null:
			_slots[i] = null
		else:
			_slots[i] = ItemStack.from_dict(slots_data[i])

	var equip_data := data.get("equipment", {}) as Dictionary
	for slot_str: String in equip_data.keys():
		var slot_key := int(slot_str) as EquipSlot
		_equipment[slot_key] = ItemStack.from_dict(equip_data[slot_str])

	_apply_equipment_stats()
	inventory_changed.emit()


# ─── Helpers ──────────────────────────────────────────────────────────────────
static func get_item_def(item_id: String) -> ItemDefinition:
	return _item_registry.get(item_id, null)


func get_slot(index: int) -> ItemStack:
	if index < 0 or index >= MAX_SLOTS:
		return null
	return _slots[index]


func get_all_slots() -> Array[ItemStack]:
	return _slots.duplicate()


func get_total_weight() -> float:
	var total := 0.0
	for stack in _slots:
		if stack == null:
			continue
		var def := get_item_def(stack.item_id)
		if def:
			total += def.weight * stack.amount
	return total


func is_full() -> bool:
	for i in MAX_SLOTS:
		if _slots[i] == null:
			return false
	return true


# ═══════════════════════════════════════════════════════════════════════════════
# Data Classes
# ═══════════════════════════════════════════════════════════════════════════════

class ItemStack extends RefCounted:
	var item_id  : String
	var amount   : int    = 1
	var metadata : Dictionary = {}
	var rarity   : int    = 0   # ItemRarity
	var quality  : String = "common"

	func to_dict() -> Dictionary:
		return {
			"item_id":  item_id,
			"amount":   amount,
			"metadata": metadata,
			"rarity":   rarity,
			"quality":  quality,
		}

	static func from_dict(d: Dictionary) -> ItemStack:
		var s         := ItemStack.new()
		s.item_id      = str(d.get("item_id",  ""))
		s.amount       = int(d.get("amount",   1))
		s.metadata     = d.get("metadata",  {})
		s.rarity       = int(d.get("rarity",   0))
		s.quality      = str(d.get("quality",  "common"))
		return s


class ItemDefinition extends RefCounted:
	var id           : String
	var display_name : String
	var description  : String
	var category     : String   # weapon, armor, consumable, material, quest
	var subcategory  : String   # sword, shield, helmet, potion, ore, etc.
	var icon_path    : String
	var model_path   : String
	var stackable    : bool   = true
	var max_stack    : int    = 99
	var weight       : float  = 0.1
	var equip_slot   : int    = -1   # -1 = not equippable; EquipSlot value
	var stat_bonuses : Dictionary = {}
	var use_effect   : String = ""   # script/ability to trigger on use
	var value_gold   : int    = 1
	var lore         : String = ""
	var tags         : Array  = []

	static func from_dict(item_id: String, d: Dictionary) -> ItemDefinition:
		var def              := ItemDefinition.new()
		def.id                = item_id
		def.display_name      = d.get("name",        item_id)
		def.description       = d.get("description", "")
		def.category          = d.get("category",    "misc")
		def.subcategory       = d.get("subcategory",  "")
		def.icon_path         = d.get("icon",         "")
		def.model_path        = d.get("model",        "")
		def.stackable         = bool(d.get("stackable", true))
		def.max_stack         = int(d.get("max_stack", 99))
		def.weight            = float(d.get("weight", 0.1))
		def.equip_slot        = int(d.get("equip_slot", -1))
		def.stat_bonuses      = d.get("stat_bonuses",  {})
		def.use_effect        = d.get("use_effect",    "")
		def.value_gold        = int(d.get("value",     1))
		def.lore              = d.get("lore",          "")
		def.tags              = d.get("tags",          [])
		return def
