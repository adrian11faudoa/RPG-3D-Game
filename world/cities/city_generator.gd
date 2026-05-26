## world/cities/city_generator.gd
## Procedurally generates towns and cities using district-based layout.
## Cities have: a market district, residential areas, a keep/castle, walls,
## gates, fountains, notice boards, merchants, quest givers, and guards.
##
## Generation pipeline:
##   1. Choose city footprint (small town / large city / capital)
##   2. Place central landmark (market square, town hall)
##   3. Divide into districts by radial sectors
##   4. Fill districts with buildings (road network first)
##   5. Place NPCs, merchants, guards at fixed anchor points
##   6. Generate walls + gates for defended cities

class_name CityGenerator
extends RefCounted

# ─── Config ───────────────────────────────────────────────────────────────────
class CityConfig extends RefCounted:
	var seed           : int    = 0
	var name           : String = "Unnamed Town"
	var faction_id     : String = "ironmarch_guard"
	var city_type      : String = "town"     # hamlet, town, city, capital
	var biome          : String = "plains"
	var position       : Vector3 = Vector3.ZERO
	var danger_level   : int    = 1
	var population     : int    = 50
	var has_walls      : bool   = true
	var has_keep       : bool   = false

# ─── Output ───────────────────────────────────────────────────────────────────
class CityData extends RefCounted:
	var config         : CityConfig
	var buildings      : Array[BuildingPlacement] = []
	var road_network   : Array[Dictionary] = []   # {from: Vector2i, to: Vector2i}
	var npc_spawns     : Array[Dictionary] = []
	var merchant_spawns: Array[Dictionary] = []
	var guard_patrols  : Array[Dictionary] = []
	var notice_board_pos: Vector3 = Vector3.ZERO
	var inn_pos        : Vector3  = Vector3.ZERO
	var market_pos     : Vector3  = Vector3.ZERO
	var gate_positions : Array[Vector3] = []
	var bounds         : Rect2    = Rect2()

class BuildingPlacement extends RefCounted:
	var position    : Vector3
	var rotation_y  : float
	var building_type: String    # house_small, house_large, inn, smithy, market, church, keep, wall_section, gate, tower
	var faction_id  : String
	var district    : String

# ─── District types ───────────────────────────────────────────────────────────
const DISTRICTS := ["market", "residential", "craftsmen", "temple", "guard"]


func generate(config: CityConfig) -> CityData:
	var rng   := RandomNumberGenerator.new()
	rng.seed   = config.seed

	var data           := CityData.new()
	data.config         = config

	var radius         := _get_city_radius(config.city_type)
	data.bounds         = Rect2(
		Vector2(config.position.x - radius, config.position.z - radius),
		Vector2(radius * 2, radius * 2)
	)

	# 1. Road network (main + secondary roads)
	_generate_roads(data, config, radius, rng)

	# 2. Place central plaza
	_place_central_plaza(data, config, rng)

	# 3. District sectors
	_assign_districts(data, config, radius, rng)

	# 4. Fill districts with buildings
	_place_buildings(data, config, radius, rng)

	# 5. Walls and gates
	if config.has_walls:
		_place_walls(data, config, radius, rng)

	# 6. Keep / castle
	if config.has_keep or config.city_type == "capital":
		_place_keep(data, config, radius, rng)

	# 7. NPC placement
	_place_npcs(data, config, rng)

	# 8. Merchant stalls
	_place_merchants(data, config, rng)

	# 9. Guard patrols
	_place_guard_patrols(data, config, radius, rng)

	print("[CityGen] Generated '%s' (%s): %d buildings, %d NPCs" % [
		config.name, config.city_type,
		data.buildings.size(), data.npc_spawns.size()
	])
	return data


# ─── Road Network ─────────────────────────────────────────────────────────────
func _generate_roads(data: CityData, config: CityConfig,
		radius: float, rng: RandomNumberGenerator) -> void:
	# Main roads: cardinal cross through center
	var center := Vector2(config.position.x, config.position.z)
	data.road_network.append({"from": center + Vector2(-radius, 0),
	                          "to":   center + Vector2(radius, 0), "width": 6})
	data.road_network.append({"from": center + Vector2(0, -radius),
	                          "to":   center + Vector2(0, radius), "width": 6})

	# Secondary roads: diagonal spokes
	if config.city_type in ["city", "capital"]:
		for i in 4:
			var angle  := PI * 0.25 + i * PI * 0.5
			var spoke  := center + Vector2(cos(angle), sin(angle)) * radius * 0.85
			data.road_network.append({"from": center, "to": spoke, "width": 4})

	# Ring road
	if config.city_type in ["city", "capital"]:
		var ring_r := radius * 0.6
		var steps  := 8
		for i in steps:
			var a1 := i * TAU / steps
			var a2 := (i + 1) * TAU / steps
			data.road_network.append({
				"from": center + Vector2(cos(a1), sin(a1)) * ring_r,
				"to":   center + Vector2(cos(a2), sin(a2)) * ring_r,
				"width": 4
			})


# ─── Central Plaza ────────────────────────────────────────────────────────────
func _place_central_plaza(data: CityData, config: CityConfig,
		rng: RandomNumberGenerator) -> void:
	var center := config.position

	# Market square / town hall
	var plaza_building        := BuildingPlacement.new()
	plaza_building.position    = center
	plaza_building.rotation_y  = 0.0
	plaza_building.building_type = "market_hall"
	plaza_building.faction_id  = config.faction_id
	plaza_building.district    = "market"
	data.buildings.append(plaza_building)
	data.market_pos = center

	# Fountain in market
	var fountain              := BuildingPlacement.new()
	fountain.position          = center + Vector3(8, 0, 0)
	fountain.building_type     = "fountain"
	fountain.district          = "market"
	data.buildings.append(fountain)

	# Notice board
	data.notice_board_pos      = center + Vector3(-8, 0, 0)


# ─── District Assignment ──────────────────────────────────────────────────────
func _assign_districts(data: CityData, config: CityConfig,
		radius: float, rng: RandomNumberGenerator) -> void:
	# Districts are pie slices; store in config for building pass
	# (Simplified: sectors assigned implicitly by angle from center)
	pass


# ─── Buildings ────────────────────────────────────────────────────────────────
func _place_buildings(data: CityData, config: CityConfig,
		radius: float, rng: RandomNumberGenerator) -> void:
	var center := Vector2(config.position.x, config.position.z)
	var count  := _get_building_count(config.city_type)
	var placed := 0
	var attempts := 0

	# Placed building footprints for overlap checking
	var footprints: Array[Rect2] = []

	while placed < count and attempts < count * 10:
		attempts += 1
		var dist     := rng.randf_range(12.0, radius * 0.9)
		var angle    := rng.randf() * TAU
		var bx       := center.x + cos(angle) * dist
		var bz       := center.y + sin(angle) * dist
		var sector   := int(angle / (TAU / DISTRICTS.size())) % DISTRICTS.size()
		var district := DISTRICTS[sector]

		var btype    := _pick_building_type(district, config, rng)
		var bsize    := _get_building_size(btype)
		var footprint := Rect2(Vector2(bx - bsize.x/2, bz - bsize.y/2), bsize)

		# Overlap check
		var overlaps := false
		for fp: Rect2 in footprints:
			if fp.grow(2.0).intersects(footprint):
				overlaps = true
				break
		if overlaps:
			continue

		footprints.append(footprint)

		var b              := BuildingPlacement.new()
		b.position          = Vector3(bx, config.position.y, bz)
		b.rotation_y        = rng.randf_range(0, TAU)
		b.building_type     = btype
		b.faction_id        = config.faction_id
		b.district          = district
		data.buildings.append(b)
		placed += 1

		# Track special buildings
		if btype == "inn" and data.inn_pos == Vector3.ZERO:
			data.inn_pos = b.position


func _pick_building_type(district: String, config: CityConfig,
		rng: RandomNumberGenerator) -> String:
	match district:
		"market":
			return rng.randf_range_weighted([
				{"type": "shop_general",   "weight": 0.3},
				{"type": "shop_weapons",   "weight": 0.15},
				{"type": "shop_armor",     "weight": 0.15},
				{"type": "shop_alchemy",   "weight": 0.15},
				{"type": "inn",            "weight": 0.15},
				{"type": "house_large",    "weight": 0.1},
			])
		"craftsmen":
			return rng.randf_range_weighted([
				{"type": "smithy",         "weight": 0.3},
				{"type": "tannery",        "weight": 0.2},
				{"type": "carpenter",      "weight": 0.2},
				{"type": "house_medium",   "weight": 0.3},
			])
		"temple":
			return rng.randf_range_weighted([
				{"type": "temple",         "weight": 0.4},
				{"type": "house_medium",   "weight": 0.4},
				{"type": "library",        "weight": 0.2},
			])
		"guard":
			return rng.randf_range_weighted([
				{"type": "barracks",       "weight": 0.35},
				{"type": "watchtower",     "weight": 0.25},
				{"type": "armory",         "weight": 0.15},
				{"type": "house_small",    "weight": 0.25},
			])
		_:  # residential
			return rng.randf_range_weighted([
				{"type": "house_small",    "weight": 0.5},
				{"type": "house_medium",   "weight": 0.3},
				{"type": "house_large",    "weight": 0.1},
				{"type": "stable",         "weight": 0.1},
			])


# ─── Walls & Gates ────────────────────────────────────────────────────────────
func _place_walls(data: CityData, config: CityConfig,
		radius: float, rng: RandomNumberGenerator) -> void:
	var center := config.position
	var wall_r  := radius * 1.0
	var steps   := _get_wall_segments(config.city_type)
	var gate_dir:= [0, 2, 4, 6]   # N, S, E, W gates at every quarter

	for i in steps:
		var a1   := i * TAU / steps
		var a2   := (i + 1) * TAU / steps
		var amid  := (a1 + a2) * 0.5

		# Check if this is a gate segment
		var is_gate := false
		for gate_idx in gate_dir:
			var gate_angle := gate_idx * TAU / 8.0
			if absf(amid - gate_angle) < TAU / steps:
				is_gate = true
				break

		if is_gate:
			var gate          := BuildingPlacement.new()
			gate.position      = center + Vector3(cos(amid) * wall_r, 0, sin(amid) * wall_r)
			gate.rotation_y    = amid + PI * 0.5
			gate.building_type = "city_gate"
			gate.district      = "guard"
			data.buildings.append(gate)
			data.gate_positions.append(gate.position)
		else:
			# Wall segment
			var wall_mid := center + Vector3(
				cos(amid) * wall_r, 0, sin(amid) * wall_r
			)
			var wall_seg         := BuildingPlacement.new()
			wall_seg.position     = wall_mid
			wall_seg.rotation_y   = amid + PI * 0.5
			wall_seg.building_type = "wall_section"
			wall_seg.district     = "guard"
			data.buildings.append(wall_seg)

		# Wall towers at every 4th segment
		if i % 4 == 0:
			var tower_pos        := center + Vector3(cos(a1) * wall_r, 0, sin(a1) * wall_r)
			var tower            := BuildingPlacement.new()
			tower.position        = tower_pos
			tower.rotation_y      = a1
			tower.building_type   = "wall_tower"
			tower.district        = "guard"
			data.buildings.append(tower)


# ─── Keep / Castle ────────────────────────────────────────────────────────────
func _place_keep(data: CityData, config: CityConfig,
		radius: float, rng: RandomNumberGenerator) -> void:
	var center := config.position
	# Keep at the back of the city (north)
	var keep_pos := center + Vector3(0, 0, -(radius * 0.75))

	var keep           := BuildingPlacement.new()
	keep.position       = keep_pos
	keep.rotation_y     = 0.0
	keep.building_type  = "keep"
	keep.faction_id     = config.faction_id
	keep.district       = "guard"
	data.buildings.append(keep)

	# Keep towers
	for dx in [-10, 10]:
		for dz in [-10, 10]:
			var t             := BuildingPlacement.new()
			t.position         = keep_pos + Vector3(dx, 0, dz)
			t.building_type    = "keep_tower"
			t.district         = "guard"
			data.buildings.append(t)


# ─── NPC Placement ────────────────────────────────────────────────────────────
func _place_npcs(data: CityData, config: CityConfig,
		rng: RandomNumberGenerator) -> void:
	var npc_templates := _get_npc_templates(config.faction_id, config.biome)

	# Place NPCs near relevant building types
	for building: BuildingPlacement in data.buildings:
		var npc_type := _get_npc_for_building(building.building_type, rng)
		if npc_type.is_empty():
			continue

		data.npc_spawns.append({
			"npc_id":       npc_type,
			"position":     building.position + Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3)),
			"faction_id":   config.faction_id,
			"home_building":building.building_type,
			"has_schedule": true,
			"schedule": _generate_npc_schedule(npc_type, building, rng),
		})

	# Quest givers (one per town, more per city)
	var quest_count := {"hamlet": 1, "town": 2, "city": 4, "capital": 6}.get(config.city_type, 2) as int
	for i in quest_count:
		data.npc_spawns.append({
			"npc_id":       "quest_giver_%s" % config.faction_id,
			"position":     data.market_pos + Vector3(rng.randf_range(-10, 10), 0, rng.randf_range(-10, 10)),
			"faction_id":   config.faction_id,
			"is_quest_giver": true,
			"quest_pool":   _get_faction_quest_pool(config.faction_id),
		})


func _get_npc_for_building(building_type: String, rng: RandomNumberGenerator) -> String:
	match building_type:
		"smithy":        return "blacksmith"
		"inn":           return "innkeeper" if rng.randf() < 0.6 else "bard"
		"shop_general":  return "general_merchant"
		"shop_weapons":  return "weapons_merchant"
		"shop_armor":    return "armor_merchant"
		"shop_alchemy":  return "alchemist"
		"temple":        return "priest"
		"barracks":      return "guard_captain"
		"library":       return "scholar"
		"stable":        return "stable_hand"
		"market_hall":   return "town_herald"
		_:               return "civilian" if rng.randf() < 0.4 else ""


func _generate_npc_schedule(npc_type: String, building: BuildingPlacement,
		rng: RandomNumberGenerator) -> Dictionary:
	# Simple 24-hour schedule: work hours, break, sleep
	var work_start := 8.0 + rng.randf_range(-1, 1)
	var work_end   := 18.0 + rng.randf_range(-1, 2)
	return {
		"work_start":   work_start,
		"work_end":     work_end,
		"work_pos":     building.position,
		"sleep_pos":    building.position + Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2)),
		"wander_radius":6.0,
		"meal_time":    12.5,
		"tavern_time":  20.0,
		"tavern_pos":   Vector3.ZERO,   # Filled by post-process referencing inn_pos
	}


func _get_faction_quest_pool(faction_id: String) -> Array:
	match faction_id:
		"ironmarch_guard":    return ["patrol_duty", "bandit_hunt", "escort_merchant", "find_deserter"]
		"traders_guild":      return ["trade_run", "recover_goods", "price_negotiation", "clear_road"]
		"mages_circle":       return ["collect_reagents", "test_subject", "lost_tome", "ley_survey"]
		"forest_wardens":     return ["poacher_hunt", "heal_treant", "wolf_census", "ruin_survey"]
		_:                    return ["basic_fetch", "basic_kill"]


# ─── Merchant Spawns ──────────────────────────────────────────────────────────
func _place_merchants(data: CityData, config: CityConfig,
		rng: RandomNumberGenerator) -> void:
	for building: BuildingPlacement in data.buildings:
		var merchant_id := _get_merchant_for_building(building.building_type)
		if merchant_id.is_empty():
			continue
		data.merchant_spawns.append({
			"merchant_id": merchant_id,
			"position":    building.position,
			"building":    building.building_type,
			"faction_id":  config.faction_id,
		})


func _get_merchant_for_building(btype: String) -> String:
	match btype:
		"shop_general":  return "merchant_general_%s" % btype
		"shop_weapons":  return "merchant_weapons"
		"shop_armor":    return "merchant_armor"
		"shop_alchemy":  return "merchant_alchemy"
		"smithy":        return "merchant_smithy"
		_:               return ""


# ─── Guard Patrols ────────────────────────────────────────────────────────────
func _place_guard_patrols(data: CityData, config: CityConfig,
		radius: float, rng: RandomNumberGenerator) -> void:
	var guard_count := _get_guard_count(config.city_type)

	for i in guard_count:
		# Patrol route: 3-5 waypoints around the city
		var waypoints: Array[Vector3] = []
		var route_radius := rng.randf_range(radius * 0.3, radius * 0.8)
		var start_angle  := rng.randf() * TAU
		var stops        := rng.randi_range(3, 5)

		for s in stops:
			var angle := start_angle + s * TAU / stops
			waypoints.append(config.position + Vector3(
				cos(angle) * route_radius, 0, sin(angle) * route_radius
			))

		data.guard_patrols.append({
			"npc_id":    "city_guard",
			"faction_id": config.faction_id,
			"waypoints":  waypoints,
			"patrol_speed": 2.5,
			"aggro_range":  12.0,
		})


# ─── NPC Templates ────────────────────────────────────────────────────────────
func _get_npc_templates(faction_id: String, biome: String) -> Array:
	return [
		{"id": "civilian",        "hp": 60,  "dialogue": "civilian_generic"},
		{"id": "blacksmith",      "hp": 120, "dialogue": "blacksmith_greet"},
		{"id": "innkeeper",       "hp": 80,  "dialogue": "innkeeper_greet"},
		{"id": "city_guard",      "hp": 150, "dialogue": "guard_challenge"},
		{"id": "general_merchant","hp": 70,  "dialogue": "merchant_greet"},
		{"id": "priest",          "hp": 90,  "dialogue": "priest_bless"},
		{"id": "alchemist",       "hp": 80,  "dialogue": "alchemist_greet"},
	]


# ─── Size Helpers ─────────────────────────────────────────────────────────────
func _get_city_radius(city_type: String) -> float:
	match city_type:
		"hamlet":  return 40.0
		"town":    return 80.0
		"city":    return 150.0
		"capital": return 250.0
		_:         return 80.0


func _get_building_count(city_type: String) -> int:
	match city_type:
		"hamlet":  return 8
		"town":    return 25
		"city":    return 60
		"capital": return 120
		_:         return 25


func _get_wall_segments(city_type: String) -> int:
	match city_type:
		"hamlet":  return 8
		"town":    return 16
		"city":    return 24
		"capital": return 32
		_:         return 16


func _get_guard_count(city_type: String) -> int:
	match city_type:
		"hamlet":  return 2
		"town":    return 5
		"city":    return 12
		"capital": return 24
		_:         return 5


func _get_building_size(btype: String) -> Vector2:
	match btype:
		"house_small":   return Vector2(8, 8)
		"house_medium":  return Vector2(10, 10)
		"house_large":   return Vector2(14, 12)
		"inn":           return Vector2(16, 14)
		"smithy":        return Vector2(12, 10)
		"market_hall":   return Vector2(20, 18)
		"temple":        return Vector2(18, 16)
		"barracks":      return Vector2(20, 16)
		"keep":          return Vector2(24, 24)
		_:               return Vector2(10, 10)
