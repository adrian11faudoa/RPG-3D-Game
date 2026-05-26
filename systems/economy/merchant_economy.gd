## systems/economy/merchant_economy.gd
## Dynamic merchant economy with supply/demand pricing.
## Prices fluctuate based on: faction rep, server-wide supply, regional rarity.
## Supports: buy, sell, buyback, barter, travelling merchants.

class_name MerchantEconomy
extends Node

signal trade_completed(buyer_id: int, seller_id: int, item_id: String, amount: int, price: int)
signal price_changed(merchant_id: String, item_id: String, old_price: int, new_price: int)

const ECONOMY_DEF_PATH : String = "res://assets/definitions/merchants.json"
const PRICE_UPDATE_INTERVAL : float = 300.0   # 5 minutes
const BUYBACK_SLOTS         : int   = 12
const MAX_PRICE_VARIANCE    : float = 0.40   # ±40% from base price
const SUPPLY_DECAY          : float = 0.02   # Supply normalizes 2% per interval

# ─── State ────────────────────────────────────────────────────────────────────
var _merchant_defs  : Dictionary = {}   # merchant_id -> MerchantDef
var _active_stocks  : Dictionary = {}   # merchant_id -> {item_id -> StockEntry}
var _global_supply  : Dictionary = {}   # item_id -> float (0=scarce, 1=abundant)
var _price_timer    : float = 0.0
var _buyback_queues : Dictionary = {}   # peer_id -> Array[{item_id, amount, sell_price}]


func _ready() -> void:
	_load_merchant_defs()
	_init_all_stocks()


func _load_merchant_defs() -> void:
	if not FileAccess.file_exists(ECONOMY_DEF_PATH):
		push_warning("[Economy] merchants.json not found")
		return
	var text   := FileAccess.open(ECONOMY_DEF_PATH, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if parsed is Dictionary:
		for mid: String in parsed.keys():
			_merchant_defs[mid] = MerchantDef.from_dict(mid, parsed[mid])
	print("[Economy] Loaded %d merchant definitions" % _merchant_defs.size())


func _init_all_stocks() -> void:
	for mid: String in _merchant_defs.keys():
		_restock_merchant(mid)


func _process(delta: float) -> void:
	_price_timer += delta
	if _price_timer >= PRICE_UPDATE_INTERVAL:
		_price_timer = 0.0
		_update_all_prices()
		_decay_supply()


# ─── Pricing ──────────────────────────────────────────────────────────────────
## Calculate buy price (player pays merchant) for an item.
func get_buy_price(merchant_id: String, item_id: String,
		amount: int, buyer_faction: FactionSystem) -> int:
	var stock := _get_stock(merchant_id, item_id)
	if stock == null or stock.quantity <= 0:
		return -1   # Not available

	var base_price  := _get_base_price(item_id)
	var supply_mult := _get_supply_multiplier(item_id)
	var rep_discount := 0.0
	if buyer_faction:
		var def := _merchant_defs.get(merchant_id) as MerchantDef
		if def:
			rep_discount = buyer_faction.get_vendor_discount(def.faction_id)

	var price := int(base_price * supply_mult * stock.price_modifier * (1.0 - rep_discount))
	return maxi(1, price) * amount


## Calculate sell price (merchant pays player) for an item.
func get_sell_price(merchant_id: String, item_id: String, amount: int) -> int:
	var def := _merchant_defs.get(merchant_id) as MerchantDef
	if def == null:
		return 0
	if not def.buys_categories.is_empty():
		var item_def := InventorySystem.get_item_def(item_id)
		if item_def and item_def.category not in def.buys_categories:
			return 0   # Merchant doesn't buy this category

	var base_price  := _get_base_price(item_id)
	var supply_mult := _get_supply_multiplier(item_id)
	# Sell at 40-60% of buy price
	var sell_ratio  := lerpf(0.4, 0.6, def.generosity)
	return maxi(1, int(base_price * supply_mult * sell_ratio)) * amount


func _get_base_price(item_id: String) -> int:
	var def := InventorySystem.get_item_def(item_id)
	return def.value_gold if def else 1


func _get_supply_multiplier(item_id: String) -> float:
	var supply := _global_supply.get(item_id, 0.5) as float
	# Low supply = high price (up to +40%), high supply = low price (down to -40%)
	return 1.0 + (0.5 - supply) * MAX_PRICE_VARIANCE * 2.0


# ─── Transactions ─────────────────────────────────────────────────────────────
func player_buy(peer_id: int, merchant_id: String, item_id: String,
		amount: int, player_inv: InventorySystem,
		player_fac: FactionSystem) -> TransactionResult:
	var result := TransactionResult.new()

	var price := get_buy_price(merchant_id, item_id, amount, player_fac)
	if price < 0:
		result.success = false
		result.reason  = "Item not in stock"
		return result

	if not player_inv.spend_gold(price):
		result.success = false
		result.reason  = "Insufficient gold (%d needed)" % price
		return result

	var stock := _get_stock(merchant_id, item_id)
	if stock.quantity != -1:   # -1 = unlimited stock
		stock.quantity -= amount
		if stock.quantity <= 0:
			stock.quantity = 0

	if not player_inv.add_item(item_id, amount):
		# Refund — inventory full
		player_inv.add_gold(price)
		result.success = false
		result.reason  = "Inventory full"
		return result

	# Update global supply (buying reduces supply)
	_adjust_supply(item_id, -0.05 * amount)

	result.success     = true
	result.gold_spent  = price
	trade_completed.emit(peer_id, 0, item_id, amount, price)
	return result


func player_sell(peer_id: int, merchant_id: String, item_id: String,
		amount: int, player_inv: InventorySystem) -> TransactionResult:
	var result := TransactionResult.new()

	if not player_inv.has_item(item_id, amount):
		result.success = false
		result.reason  = "Item not in inventory"
		return result

	var price := get_sell_price(merchant_id, item_id, amount)
	if price <= 0:
		result.success = false
		result.reason  = "Merchant doesn't buy this"
		return result

	player_inv.remove_item(item_id, amount)
	player_inv.add_gold(price)

	# Add to buyback queue
	_add_to_buyback(peer_id, item_id, amount, price)

	# Update global supply (selling increases supply)
	_adjust_supply(item_id, 0.03 * amount)

	# Restock merchant's inventory
	var stock := _get_stock(merchant_id, item_id)
	if stock:
		stock.quantity = mini(stock.max_quantity, stock.quantity + amount)
	else:
		var new_stock          := StockEntry.new()
		new_stock.item_id       = item_id
		new_stock.quantity      = amount
		new_stock.max_quantity  = amount * 3
		new_stock.price_modifier = 0.9   # Slightly cheaper since player sold it
		_active_stocks[merchant_id][item_id] = new_stock

	result.success    = true
	result.gold_earned = price
	trade_completed.emit(0, peer_id, item_id, amount, price)
	return result


func player_buyback(peer_id: int, slot_index: int,
		player_inv: InventorySystem) -> TransactionResult:
	var result := TransactionResult.new()
	var queue  := _buyback_queues.get(peer_id, []) as Array

	if slot_index < 0 or slot_index >= queue.size():
		result.success = false
		result.reason  = "Invalid buyback slot"
		return result

	var entry    := queue[slot_index] as Dictionary
	var buy_back := int(entry.get("sell_price", 0)) * 2   # Buyback at 2x sell price

	if not player_inv.spend_gold(buy_back):
		result.success = false
		result.reason  = "Insufficient gold (%d needed)" % buy_back
		return result

	var item_id := str(entry.get("item_id", ""))
	var amount  := int(entry.get("amount", 1))

	if not player_inv.add_item(item_id, amount):
		player_inv.add_gold(buy_back)
		result.success = false
		result.reason  = "Inventory full"
		return result

	queue.remove_at(slot_index)
	result.success    = true
	result.gold_spent = buy_back
	return result


# ─── Barter System ────────────────────────────────────────────────────────────
## Trade items directly without gold (used by remote traders and special merchants).
func propose_barter(merchant_id: String,
		offer_items: Array,      # [{item_id, amount}] player offers
		request_items: Array,    # [{item_id, amount}] player requests
		player_fac: FactionSystem) -> BarterResult:
	var result := BarterResult.new()

	var offer_value   := 0
	var request_value := 0

	for item: Dictionary in offer_items:
		offer_value += get_sell_price(merchant_id, str(item["item_id"]), int(item["amount"]))

	for item: Dictionary in request_items:
		var price := get_buy_price(merchant_id, str(item["item_id"]), int(item["amount"]), player_fac)
		if price < 0:
			result.accepted = false
			result.reason   = "%s not available from this merchant" % item["item_id"]
			return result
		request_value += price

	# Merchant accepts if offer covers at least 80% of request value
	var def           := _merchant_defs.get(merchant_id) as MerchantDef
	var required_ratio := 0.8 if not def else lerpf(0.7, 0.95, 1.0 - def.generosity)

	if float(offer_value) / float(maxi(1, request_value)) >= required_ratio:
		result.accepted     = true
		result.surplus_gold = maxi(0, offer_value - request_value)
	else:
		result.accepted = false
		result.reason   = "Offer too low (need ~%d gold value, offered %d)" % [
			int(request_value * required_ratio), offer_value
		]

	return result


# ─── Restocking ───────────────────────────────────────────────────────────────
func _restock_merchant(merchant_id: String) -> void:
	var def := _merchant_defs.get(merchant_id) as MerchantDef
	if def == null:
		return

	_active_stocks[merchant_id] = {}

	for item_entry: Dictionary in def.stock:
		var stock              := StockEntry.new()
		stock.item_id           = str(item_entry.get("item_id", ""))
		stock.quantity          = int(item_entry.get("quantity", 10))
		stock.max_quantity      = stock.quantity
		stock.price_modifier    = float(item_entry.get("price_modifier", 1.0))
		stock.is_infinite       = bool(item_entry.get("infinite", false))
		if stock.is_infinite:
			stock.quantity = -1
		_active_stocks[merchant_id][stock.item_id] = stock


func _update_all_prices() -> void:
	for mid: String in _active_stocks.keys():
		var stock_map := _active_stocks[mid] as Dictionary
		for item_id: String in stock_map.keys():
			var stock := stock_map[item_id] as StockEntry
			var old_mod := stock.price_modifier
			# Random walk ±5% per interval
			stock.price_modifier = clampf(
				stock.price_modifier + randf_range(-0.05, 0.05),
				0.6, 1.4
			)
			if absf(stock.price_modifier - old_mod) > 0.02:
				var base := _get_base_price(item_id)
				var old_p := int(base * old_mod)
				var new_p := int(base * stock.price_modifier)
				price_changed.emit(mid, item_id, old_p, new_p)

		# Daily restock of depleted items
		for item_id: String in stock_map.keys():
			var stock := stock_map[item_id] as StockEntry
			if stock.quantity != -1:
				stock.quantity = mini(stock.max_quantity, stock.quantity + int(stock.max_quantity * 0.25))


# ─── Supply System ────────────────────────────────────────────────────────────
func _adjust_supply(item_id: String, delta: float) -> void:
	_global_supply[item_id] = clampf(
		_global_supply.get(item_id, 0.5) + delta,
		0.1, 0.9
	)


func _decay_supply() -> void:
	# Supply drifts back toward 0.5 (neutral) over time
	for item_id: String in _global_supply.keys():
		var current := _global_supply[item_id] as float
		_global_supply[item_id] = lerpf(current, 0.5, SUPPLY_DECAY)


# ─── Buyback ──────────────────────────────────────────────────────────────────
func _add_to_buyback(peer_id: int, item_id: String, amount: int, price: int) -> void:
	if not _buyback_queues.has(peer_id):
		_buyback_queues[peer_id] = []
	var queue := _buyback_queues[peer_id] as Array
	queue.push_front({"item_id": item_id, "amount": amount, "sell_price": price})
	if queue.size() > BUYBACK_SLOTS:
		queue.resize(BUYBACK_SLOTS)


func get_buyback_items(peer_id: int) -> Array:
	return _buyback_queues.get(peer_id, [])


# ─── Travelling Merchants ─────────────────────────────────────────────────────
## Spawns a temporary travelling merchant NPC at the given position.
func spawn_travelling_merchant(position: Vector3, biome_id: String) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(position)

	var mid              := "travelling_%s_%d" % [biome_id, randi()]
	var def              := MerchantDef.new()
	def.id                = mid
	def.display_name      = "Wandering Merchant"
	def.faction_id        = "traders_guild"
	def.generosity        = randf_range(0.3, 0.7)
	def.buys_categories   = ["material", "consumable"]

	# Random selection of rare biome-specific items
	var biome_items := _get_biome_specialty_items(biome_id)
	def.stock = []
	for item_id: String in biome_items:
		def.stock.append({
			"item_id":       item_id,
			"quantity":      rng.randi_range(2, 8),
			"price_modifier": rng.randf_range(1.1, 1.5),  # Rare items cost more
		})

	_merchant_defs[mid] = def
	_restock_merchant(mid)

	# Auto-despawn after 20 minutes
	get_tree().create_timer(1200.0).timeout.connect(func(): _despawn_merchant(mid))
	return mid


func _despawn_merchant(merchant_id: String) -> void:
	_merchant_defs.erase(merchant_id)
	_active_stocks.erase(merchant_id)


func _get_biome_specialty_items(biome_id: String) -> Array[String]:
	match biome_id:
		"desert":        return ["desert_glass", "scorpion_venom", "ancient_coin", "sun_crystal"]
		"tundra":        return ["frostite_shard", "yeti_fur", "glacier_water", "permafrost_ore"]
		"dark_forest":   return ["shadowite_dust", "cursed_tome", "wraith_essence", "nightbloom"]
		"volcanic":      return ["magmatite_core", "fire_essence", "lava_gem", "dragon_scale"]
		"magic_forest":  return ["moonshard", "starcrystal", "fairy_dust", "enchanted_bark"]
		_:               return ["iron_ore", "coal", "wildroot", "wolf_pelt"]


# ─── Queries ──────────────────────────────────────────────────────────────────
func get_merchant_stock(merchant_id: String) -> Array[Dictionary]:
	var stock_map := _active_stocks.get(merchant_id, {}) as Dictionary
	var result    : Array[Dictionary] = []
	for item_id: String in stock_map.keys():
		var s := stock_map[item_id] as StockEntry
		result.append({
			"item_id":  item_id,
			"quantity": s.quantity,
			"infinite": s.is_infinite,
			"modifier": s.price_modifier,
		})
	return result


func _get_stock(merchant_id: String, item_id: String) -> StockEntry:
	return _active_stocks.get(merchant_id, {}).get(item_id, null)


# ─── Data Classes ─────────────────────────────────────────────────────────────
class StockEntry extends RefCounted:
	var item_id        : String
	var quantity       : int    = 10
	var max_quantity   : int    = 10
	var price_modifier : float  = 1.0
	var is_infinite    : bool   = false


class MerchantDef extends RefCounted:
	var id              : String
	var display_name    : String
	var faction_id      : String
	var generosity      : float   = 0.5    # 0=greedy, 1=generous
	var buys_categories : Array   = []
	var stock           : Array   = []

	static func from_dict(mid: String, d: Dictionary) -> MerchantDef:
		var m             := MerchantDef.new()
		m.id               = mid
		m.display_name     = d.get("name",          mid)
		m.faction_id       = d.get("faction",        "")
		m.generosity       = float(d.get("generosity", 0.5))
		m.buys_categories  = d.get("buys",           [])
		m.stock            = d.get("stock",          [])
		return m


class TransactionResult extends RefCounted:
	var success     : bool   = false
	var reason      : String = ""
	var gold_spent  : int    = 0
	var gold_earned : int    = 0


class BarterResult extends RefCounted:
	var accepted      : bool   = false
	var reason        : String = ""
	var surplus_gold  : int    = 0
