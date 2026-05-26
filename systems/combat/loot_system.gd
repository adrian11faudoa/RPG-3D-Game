## systems/combat/loot_system.gd
## Handles all loot generation: creature drops, chest contents, world drops.
## Loot tables are defined in loot_tables.json and support: weighted rolls,
## guaranteed items, rarity tiers, level-scaled quantities, and modifiers.

class_name LootSystem
extends Node

signal loot_dropped(position: Vector3, items: Array)
signal chest_opened(chest_id: String, items: Array)

const LOOT_TABLE_PATH : String = "res://assets/definitions/loot_tables.json"
const PICKUP_RANGE    : float  = 1.5    # Auto-pickup radius for dropped items
const DESPAWN_TIME    : float  = 300.0  # Items despawn after 5 minutes

# ─── State ────────────────────────────────────────────────────────────────────
var _loot_tables   : Dictionary = {}   # table_id -> LootTable
var _world_drops   : Array      = []   # Active dropped item piles


func _ready() -> void:
	_load_loot_tables()


func _load_loot_tables() -> void:
	if not FileAccess.file_exists(LOOT_TABLE_PATH):
		push_warning("[Loot] loot_tables.json not found")
		return
	var text   := FileAccess.open(LOOT_TABLE_PATH, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if parsed is Dictionary:
		for tid: String in parsed.keys():
			_loot_tables[tid] = LootTable.from_dict(tid, parsed[tid])
	print("[Loot] Loaded %d loot tables" % _loot_tables.size())


# ─── Loot Generation ──────────────────────────────────────────────────────────
## Roll a loot table and return the resulting items.
func roll_table(table_id: String, luck_bonus: float = 0.0,
		level_scale: int = 1) -> Array[LootDrop]:
	var table := _loot_tables.get(table_id) as LootTable
	if table == null:
		return []

	var results    : Array[LootDrop] = []
	var rng        := RandomNumberGenerator.new()
	rng.seed        = randi()

	# Guaranteed drops first
	for entry: LootEntry in table.guaranteed:
		var drop      := LootDrop.new()
		drop.item_id   = entry.item_id
		drop.amount    = _scale_amount(entry.min_amount, entry.max_amount, level_scale, rng)
		drop.rarity    = entry.override_rarity if entry.override_rarity >= 0 \
		                 else _roll_rarity(luck_bonus, rng)
		results.append(drop)

	# Random rolls (roll_count times from the pool)
	var roll_count := table.rolls + (1 if rng.randf() < luck_bonus * 0.5 else 0)
	for _i in roll_count:
		var entry := _weighted_pick(table.pool, rng)
		if entry == null:
			continue
		var drop      := LootDrop.new()
		drop.item_id   = entry.item_id
		drop.amount    = _scale_amount(entry.min_amount, entry.max_amount, level_scale, rng)
		drop.rarity    = entry.override_rarity if entry.override_rarity >= 0 \
		                 else _roll_rarity(luck_bonus, rng)
		results.append(drop)

	# Gold drop
	if table.gold_min > 0:
		var base_gold := rng.randi_range(table.gold_min, table.gold_max)
		var gold      := int(base_gold * (1.0 + luck_bonus * 0.3) * level_scale)
		if gold > 0:
			var gd      := LootDrop.new()
			gd.item_id   = "gold_coin"
			gd.amount    = gold
			gd.is_gold   = true
			results.append(gd)

	return results


func _weighted_pick(pool: Array[LootEntry], rng: RandomNumberGenerator) -> LootEntry:
	var total := 0.0
	for e: LootEntry in pool:
		total += e.weight
	if total <= 0.0:
		return null
	var roll := rng.randf() * total
	var accum := 0.0
	for e: LootEntry in pool:
		accum += e.weight
		if roll <= accum:
			return e
	return pool[-1]


func _scale_amount(min_a: int, max_a: int, level: int, rng: RandomNumberGenerator) -> int:
	var base   := rng.randi_range(min_a, max_a)
	var scaled := int(base * (1.0 + (level - 1) * 0.05))   # +5% per level above 1
	return maxi(1, scaled)


func _roll_rarity(luck: float, rng: RandomNumberGenerator) -> int:
	var roll := rng.randf()
	var l    := clampf(luck, 0.0, 1.0)
	# Luck shifts probabilities toward higher rarities
	if roll < lerpf(0.60, 0.40, l):  return InventorySystem.ItemRarity.COMMON
	if roll < lerpf(0.85, 0.68, l):  return InventorySystem.ItemRarity.UNCOMMON
	if roll < lerpf(0.95, 0.85, l):  return InventorySystem.ItemRarity.RARE
	if roll < lerpf(0.99, 0.96, l):  return InventorySystem.ItemRarity.EPIC
	if roll < lerpf(0.998,0.99, l):  return InventorySystem.ItemRarity.LEGENDARY
	return InventorySystem.ItemRarity.MYTHIC


# ─── World Drop Spawning ──────────────────────────────────────────────────────
## Spawns loot pile in the world (called by CombatSystem on enemy death).
func spawn_loot(position: Vector3, table_id: String, luck: float = 0.0,
		killer_level: int = 1) -> void:
	if table_id.is_empty():
		return

	var drops := roll_table(table_id, luck, killer_level)
	if drops.is_empty():
		return

	# Instantiate loot pile scene
	var pile_scene := preload("res://world/loot_pile.tscn") as PackedScene
	if pile_scene == null:
		# Fallback: just notify (for headless server or missing asset)
		loot_dropped.emit(position, _drops_to_dicts(drops))
		return

	var pile     := pile_scene.instantiate() as Node3D
	pile.position = position
	pile.set_meta("drops", drops)
	pile.set_meta("despawn_timer", DESPAWN_TIME)
	get_tree().root.add_child(pile)

	# Add a subtle sparkle based on highest rarity in the drop
	var max_rarity := 0
	for d: LootDrop in drops:
		if d.rarity > max_rarity:
			max_rarity = d.rarity
	_spawn_loot_sparkle(pile, max_rarity)

	_world_drops.append(pile)
	loot_dropped.emit(position, _drops_to_dicts(drops))


func _spawn_loot_sparkle(pile: Node3D, rarity: int) -> void:
	# Color-coded sparkle particles based on rarity
	var colors := [
		Color.WHITE,    # Common
		Color.GREEN,    # Uncommon
		Color.CYAN,     # Rare
		Color.PURPLE,   # Epic
		Color.GOLD,     # Legendary
		Color.RED,      # Mythic
	]
	if rarity < 1:
		return  # No sparkle for common
	var particles         := GPUParticles3D.new()
	particles.amount       = 8 + rarity * 4
	var mat                := ParticleProcessMaterial.new()
	mat.emission_shape      = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.3
	mat.color               = colors[mini(rarity, colors.size() - 1)]
	mat.gravity             = Vector3(0, 1.5, 0)
	mat.lifetime_randomness = 0.5
	particles.process_material = mat
	pile.add_child(particles)


func _drops_to_dicts(drops: Array[LootDrop]) -> Array:
	var result: Array = []
	for d: LootDrop in drops:
		result.append({"item_id": d.item_id, "amount": d.amount, "rarity": d.rarity, "is_gold": d.is_gold})
	return result


# ─── Chest System ─────────────────────────────────────────────────────────────
## Open a world chest. Server-authoritative — called by server only.
func open_chest(chest_id: String, table_id: String, opener_peer_id: int,
		opener_luck: float = 0.0, opener_level: int = 1) -> Array[LootDrop]:
	var drops := roll_table(table_id, opener_luck, opener_level)

	# Give items directly to opener
	var player := _get_player_by_peer(opener_peer_id)
	if player:
		var inv  := player.get_node_or_null("InventorySystem") as InventorySystem
		var prog := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
		if inv:
			for drop: LootDrop in drops:
				if drop.is_gold:
					inv.add_gold(drop.amount)
				else:
					inv.add_item(drop.item_id, drop.amount,
						{"rarity": drop.rarity})
		if prog:
			prog.add_xp(50 * opener_level, "chest")

	chest_opened.emit(chest_id, _drops_to_dicts(drops))
	return drops


# ─── Boss Loot ────────────────────────────────────────────────────────────────
## Rolls boss loot with guaranteed rare items and distributes to entire party.
func roll_boss_loot(boss_id: String, party_peer_ids: Array,
		luck_leader: float = 0.0, avg_level: int = 1) -> void:
	var table_id := boss_id + "_drops"
	var drops    := roll_table(table_id, luck_leader, avg_level)

	# Each party member gets their own roll (shared loot philosophy)
	for peer_id: int in party_peer_ids:
		var player := _get_player_by_peer(peer_id)
		if not player:
			continue
		var member_drops := roll_table(table_id, luck_leader, avg_level)
		var inv          := player.get_node_or_null("InventorySystem") as InventorySystem
		var prog         := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
		if inv:
			for drop: LootDrop in member_drops:
				if drop.is_gold:
					inv.add_gold(drop.amount)
				else:
					inv.add_item(drop.item_id, drop.amount, {"rarity": drop.rarity})
		if prog:
			prog.add_xp(500 * avg_level, "boss_kill")


# ─── Pickup Handling ──────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	var to_remove: Array[Node3D] = []

	for pile: Node3D in _world_drops:
		if not is_instance_valid(pile):
			to_remove.append(pile)
			continue

		# Tick despawn timer
		var timer := float(pile.get_meta("despawn_timer", 0.0))
		timer -= delta
		pile.set_meta("despawn_timer", timer)
		if timer <= 0.0:
			pile.queue_free()
			to_remove.append(pile)
			continue

		# Auto-pickup check (server only)
		if multiplayer.is_server():
			for player: Node3D in get_tree().get_nodes_in_group("players"):
				if player.global_position.distance_to(pile.global_position) <= PICKUP_RANGE:
					_auto_pickup(player, pile)
					to_remove.append(pile)
					break

	for p in to_remove:
		_world_drops.erase(p)


func _auto_pickup(player: Node3D, pile: Node3D) -> void:
	var drops := pile.get_meta("drops", []) as Array
	var inv   := player.get_node_or_null("InventorySystem") as InventorySystem
	if not inv:
		return
	for drop in drops:
		if drop is LootDrop:
			if drop.is_gold:
				inv.add_gold(drop.amount)
			else:
				inv.add_item(drop.item_id, drop.amount, {"rarity": drop.rarity})
	pile.queue_free()


func _get_player_by_peer(peer_id: int) -> Node3D:
	for p: Node3D in get_tree().get_nodes_in_group("players"):
		if p.get_multiplayer_authority() == peer_id:
			return p
	return null


# ─── Data Classes ─────────────────────────────────────────────────────────────
class LootDrop extends RefCounted:
	var item_id : String = ""
	var amount  : int    = 1
	var rarity  : int    = 0
	var is_gold : bool   = false


class LootEntry extends RefCounted:
	var item_id         : String
	var min_amount      : int   = 1
	var max_amount      : int   = 1
	var weight          : float = 1.0
	var override_rarity : int   = -1    # -1 = roll normally

	static func from_dict(d: Dictionary) -> LootEntry:
		var e               := LootEntry.new()
		e.item_id            = str(d.get("item_id",          ""))
		e.min_amount         = int(d.get("min",              1))
		e.max_amount         = int(d.get("max",              1))
		e.weight             = float(d.get("weight",         1.0))
		e.override_rarity    = int(d.get("override_rarity",  -1))
		return e


class LootTable extends RefCounted:
	var id         : String
	var rolls      : int           = 1
	var gold_min   : int           = 0
	var gold_max   : int           = 0
	var guaranteed : Array[LootEntry] = []
	var pool       : Array[LootEntry] = []

	static func from_dict(tid: String, d: Dictionary) -> LootTable:
		var t       := LootTable.new()
		t.id         = tid
		t.rolls      = int(d.get("rolls",    1))
		t.gold_min   = int(d.get("gold_min", 0))
		t.gold_max   = int(d.get("gold_max", 0))
		for entry_d: Dictionary in d.get("guaranteed", []):
			t.guaranteed.append(LootEntry.from_dict(entry_d))
		for entry_d: Dictionary in d.get("pool", []):
			t.pool.append(LootEntry.from_dict(entry_d))
		return t
