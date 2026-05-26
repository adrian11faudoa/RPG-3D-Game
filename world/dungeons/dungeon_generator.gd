## world/dungeons/dungeon_generator.gd
## Generates fully procedural dungeons using BSP (Binary Space Partitioning)
## room placement + corridor carving, then decorates with traps, loot, and enemies.
##
## Pipeline:
##   1. BSP splits a rectangular region into leaf nodes (rooms)
##   2. Corridors connect sibling BSP pairs
##   3. Special rooms assigned (boss, treasure, puzzle, entrance/exit)
##   4. Voxel fill writes to ChunkData tiles
##   5. Enemy + trap + chest placement pass

class_name DungeonGenerator
extends RefCounted

# ─── Config ───────────────────────────────────────────────────────────────────
class DungeonConfig extends RefCounted:
	var seed           : int    = 0
	var width          : int    = 128    # In voxels
	var height         : int    = 32
	var depth          : int    = 128
	var min_room_size  : int    = 7
	var max_room_size  : int    = 20
	var min_rooms      : int    = 8
	var max_rooms      : int    = 24
	var corridor_width : int    = 3
	var theme          : String = "stone_ruins"   # stone_ruins, ice_cavern, jungle_temple, undead_crypt
	var difficulty     : int    = 1
	var has_boss       : bool   = true
	var has_puzzle     : bool   = true
	var floor_level    : int    = 0   # World Y of dungeon floor

# ─── Room types ───────────────────────────────────────────────────────────────
enum RoomType {
	NORMAL, ENTRANCE, EXIT, BOSS, TREASURE, PUZZLE,
	BARRACKS, LIBRARY, SHRINE, TRAP_ROOM
}

# ─── Internal Data ────────────────────────────────────────────────────────────
class DungeonRoom extends RefCounted:
	var rect      : Rect2i
	var type      : RoomType = RoomType.NORMAL
	var enemies   : Array = []
	var chests    : Array = []
	var connected : Array = []   # Connected room indices

class BSPNode extends RefCounted:
	var rect     : Rect2i
	var left     : BSPNode  = null
	var right    : BSPNode  = null
	var room     : DungeonRoom = null

	func is_leaf() -> bool:
		return left == null and right == null


# ─── Generation Entry Point ───────────────────────────────────────────────────
func generate(config: DungeonConfig) -> DungeonData:
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed

	var data      := DungeonData.new()
	data.config    = config
	data.voxels    = _create_voxel_grid(config)

	# Fill with wall
	_fill_all(data, _get_wall_voxel(config.theme))

	# BSP partitioning
	var root_rect := Rect2i(0, 0, config.width, config.depth)
	var bsp_root  := _bsp_split(root_rect, config, rng)

	# Extract rooms from BSP leaves
	_extract_rooms(bsp_root, data, config, rng)

	# Connect rooms with corridors
	_connect_bsp(bsp_root, data, config, rng)

	# Assign special room types
	_assign_room_types(data, rng, config)

	# Carve voxels based on rooms and corridors
	_carve_rooms(data, config)
	_carve_corridors(data, config, rng)

	# Add floors, ceilings, walls
	_add_architecture(data, config, rng)

	# Decoration passes
	_place_lighting(data, config, rng)
	_place_enemies(data, config, rng)
	_place_treasure(data, config, rng)
	_place_traps(data, config, rng)
	_place_interactive(data, config, rng)

	# Find valid entrance/exit positions
	_finalize_entrance_exit(data, config)

	print("[Dungeon] Generated: %d rooms, seed %d" % [data.rooms.size(), config.seed])
	return data


# ─── BSP Partitioning ────────────────────────────────────────────────────────
func _bsp_split(rect: Rect2i, config: DungeonConfig,
		rng: RandomNumberGenerator, depth: int = 0) -> BSPNode:
	var node      := BSPNode.new()
	node.rect      = rect
	var max_depth  := 5

	# Stop splitting if too small or max depth
	if depth >= max_depth or \
	   rect.size.x < config.min_room_size * 2 + 2 or \
	   rect.size.y < config.min_room_size * 2 + 2:
		return node

	# Decide split direction: prefer the longer axis
	var split_horizontal := rect.size.y > rect.size.x if \
		rect.size.x != rect.size.y else rng.randi() % 2 == 0

	if split_horizontal:
		var split := rng.randi_range(
			config.min_room_size,
			rect.size.y - config.min_room_size
		)
		node.left  = _bsp_split(Rect2i(rect.position, Vector2i(rect.size.x, split)), config, rng, depth + 1)
		node.right = _bsp_split(Rect2i(rect.position + Vector2i(0, split), Vector2i(rect.size.x, rect.size.y - split)), config, rng, depth + 1)
	else:
		var split := rng.randi_range(
			config.min_room_size,
			rect.size.x - config.min_room_size
		)
		node.left  = _bsp_split(Rect2i(rect.position, Vector2i(split, rect.size.y)), config, rng, depth + 1)
		node.right = _bsp_split(Rect2i(rect.position + Vector2i(split, 0), Vector2i(rect.size.x - split, rect.size.y)), config, rng, depth + 1)

	return node


func _extract_rooms(node: BSPNode, data: DungeonData,
		config: DungeonConfig, rng: RandomNumberGenerator) -> void:
	if node == null:
		return
	if node.is_leaf():
		# Create a room within this leaf, with random padding
		var pad_x1 := rng.randi_range(1, maxi(1, (node.rect.size.x - config.min_room_size) / 2))
		var pad_z1 := rng.randi_range(1, maxi(1, (node.rect.size.y - config.min_room_size) / 2))
		var pad_x2 := rng.randi_range(1, maxi(1, (node.rect.size.x - config.min_room_size) / 2))
		var pad_z2 := rng.randi_range(1, maxi(1, (node.rect.size.y - config.min_room_size) / 2))

		var rx := node.rect.position.x + pad_x1
		var rz := node.rect.position.y + pad_z1
		var rw := node.rect.size.x - pad_x1 - pad_x2
		var rd := node.rect.size.y - pad_z1 - pad_z2

		if rw >= config.min_room_size and rd >= config.min_room_size:
			var room      := DungeonRoom.new()
			room.rect      = Rect2i(rx, rz, rw, rd)
			node.room      = room
			data.rooms.append(room)
	else:
		_extract_rooms(node.left,  data, config, rng)
		_extract_rooms(node.right, data, config, rng)


func _connect_bsp(node: BSPNode, data: DungeonData,
		config: DungeonConfig, rng: RandomNumberGenerator) -> void:
	if node == null or node.is_leaf():
		return

	_connect_bsp(node.left,  data, config, rng)
	_connect_bsp(node.right, data, config, rng)

	# Connect left and right subtree via their nearest rooms
	var left_room  := _get_random_leaf_room(node.left)
	var right_room := _get_random_leaf_room(node.right)

	if left_room and right_room:
		var corridor := DungeonCorridor.new()
		corridor.from = left_room.rect.get_center()
		corridor.to   = right_room.rect.get_center()
		corridor.width = config.corridor_width
		data.corridors.append(corridor)
		left_room.connected.append(right_room)
		right_room.connected.append(left_room)


func _get_random_leaf_room(node: BSPNode) -> DungeonRoom:
	if node == null:
		return null
	if node.is_leaf():
		return node.room
	var left_room  := _get_random_leaf_room(node.left)
	var right_room := _get_random_leaf_room(node.right)
	if left_room and right_room:
		return left_room if randi() % 2 == 0 else right_room
	return left_room if left_room else right_room


# ─── Room Type Assignment ─────────────────────────────────────────────────────
func _assign_room_types(data: DungeonData, rng: RandomNumberGenerator,
		config: DungeonConfig) -> void:
	if data.rooms.is_empty():
		return

	# Entrance = room closest to (0,0)
	var entrance := data.rooms[0]
	var min_dist  := INF
	for room: DungeonRoom in data.rooms:
		var d := room.rect.get_center().distance_to(Vector2i.ZERO)
		if d < min_dist:
			min_dist = d
			entrance = room
	entrance.type = RoomType.ENTRANCE

	# Boss = room farthest from entrance
	var boss_room := data.rooms[0]
	var max_dist  := 0.0
	for room: DungeonRoom in data.rooms:
		if room == entrance:
			continue
		var d := room.rect.get_center().distance_to(entrance.rect.get_center())
		if d > max_dist:
			max_dist = d
			boss_room = room
	if config.has_boss:
		boss_room.type = RoomType.BOSS

	# Treasure: second farthest
	var treasure := data.rooms[0]
	max_dist      = 0.0
	for room: DungeonRoom in data.rooms:
		if room == entrance or room == boss_room:
			continue
		var d := room.rect.get_center().distance_to(entrance.rect.get_center())
		if d > max_dist:
			max_dist = d
			treasure = room
	treasure.type = RoomType.TREASURE

	# Assign remaining types randomly
	var special_types := [RoomType.TRAP_ROOM, RoomType.SHRINE, RoomType.BARRACKS, RoomType.LIBRARY]
	for room: DungeonRoom in data.rooms:
		if room.type != RoomType.NORMAL:
			continue
		if rng.randf() < 0.25:
			room.type = special_types[rng.randi() % special_types.size()]

	data.entrance_room = entrance
	data.boss_room     = boss_room


# ─── Voxel Carving ────────────────────────────────────────────────────────────
func _carve_rooms(data: DungeonData, config: DungeonConfig) -> void:
	var floor_vox   := _get_floor_voxel(config.theme)
	var ceiling_vox := _get_ceiling_voxel(config.theme)

	for room: DungeonRoom in data.rooms:
		for x in range(room.rect.position.x, room.rect.end.x):
			for z in range(room.rect.position.y, room.rect.end.y):
				# Floor
				data.set_voxel(x, 0, z, floor_vox)
				# Open air in room height
				for y in range(1, config.height - 1):
					data.set_voxel(x, y, z, VoxelTypes.AIR)
				# Ceiling
				data.set_voxel(x, config.height - 1, z, ceiling_vox)


func _carve_corridors(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	var floor_vox := _get_floor_voxel(config.theme)

	for corridor: DungeonCorridor in data.corridors:
		var fx := corridor.from.x
		var fz := corridor.from.y
		var tx := corridor.to.x
		var tz := corridor.to.y

		# L-shaped corridor: horizontal then vertical
		var mid_x := tx if rng.randf() > 0.5 else fx
		_carve_corridor_segment(data, fx, fz, mid_x, fz, config, floor_vox)
		_carve_corridor_segment(data, mid_x, fz, mid_x, tz, config, floor_vox)
		_carve_corridor_segment(data, mid_x, tz, tx, tz, config, floor_vox)


func _carve_corridor_segment(data: DungeonData, x1: int, z1: int,
		x2: int, z2: int, config: DungeonConfig, floor_vox: int) -> void:
	var hw := config.corridor_width / 2
	var sx  := signi(x2 - x1) if x1 != x2 else 0
	var sz  := signi(z2 - z1) if z1 != z2 else 0
	var x   := x1
	var z   := z1

	while x != x2 or z != z2:
		for dx in range(-hw, hw + 1):
			for dz in range(-hw, hw + 1):
				var cx := x + dx
				var cz := z + dz
				if cx < 0 or cz < 0 or cx >= data.config.width or cz >= data.config.depth:
					continue
				data.set_voxel(cx, 0, cz, floor_vox)
				for h in range(1, 4):
					data.set_voxel(cx, h, cz, VoxelTypes.AIR)
		x += sx
		z += sz


# ─── Architecture Details ─────────────────────────────────────────────────────
func _add_architecture(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	var pillar_vox := _get_pillar_voxel(config.theme)

	for room: DungeonRoom in data.rooms:
		# Pillars in corners of large rooms
		if room.rect.size.x >= 12 and room.rect.size.y >= 12:
			var corners := [
				Vector2i(room.rect.position.x + 2, room.rect.position.y + 2),
				Vector2i(room.rect.end.x - 3,      room.rect.position.y + 2),
				Vector2i(room.rect.position.x + 2, room.rect.end.y - 3),
				Vector2i(room.rect.end.x - 3,      room.rect.end.y - 3),
			]
			for corner: Vector2i in corners:
				for h in range(1, 5):
					data.set_voxel(corner.x, h, corner.y, pillar_vox)

		# Boss room: altar
		if room.type == RoomType.BOSS:
			var cx := room.rect.get_center().x
			var cz := room.rect.get_center().y
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					data.set_voxel(cx + dx, 1, cz + dz, VoxelTypes.STONE_BRICK)
			data.set_voxel(cx, 2, cz, VoxelTypes.OBSIDIAN)

		# Treasure room: raised platform
		if room.type == RoomType.TREASURE:
			var cx := room.rect.get_center().x
			var cz := room.rect.get_center().y
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					data.set_voxel(cx + dx, 1, cz + dz, VoxelTypes.STONE_BRICK)


# ─── Enemy Placement ──────────────────────────────────────────────────────────
func _place_enemies(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	var spawn_table := _get_enemy_table(config.theme, config.difficulty)

	for room: DungeonRoom in data.rooms:
		match room.type:
			RoomType.ENTRANCE:
				pass   # No enemies at entrance

			RoomType.BOSS:
				var boss := _get_boss(config.theme, config.difficulty)
				var cx    := room.rect.get_center()
				room.enemies.append({
					"creature_id": boss,
					"position":    Vector3(cx.x, 1, cx.y),
					"is_boss":     true,
				})
				# Elite guards
				for i in rng.randi_range(2, 4):
					var pos := _random_floor_pos(room, rng)
					room.enemies.append({"creature_id": spawn_table[-1], "position": pos})

			RoomType.BARRACKS:
				for i in rng.randi_range(4, 8):
					var pos := _random_floor_pos(room, rng)
					var creature := spawn_table[rng.randi() % spawn_table.size()]
					room.enemies.append({"creature_id": creature, "position": pos})

			RoomType.TRAP_ROOM:
				for i in rng.randi_range(2, 5):
					var pos := _random_floor_pos(room, rng)
					var creature := spawn_table[rng.randi() % spawn_table.size()]
					room.enemies.append({"creature_id": creature, "position": pos})

			RoomType.NORMAL:
				var count := rng.randi_range(0, config.difficulty + 2)
				for i in count:
					var pos := _random_floor_pos(room, rng)
					var creature := spawn_table[rng.randi() % spawn_table.size()]
					room.enemies.append({"creature_id": creature, "position": pos})

	data.total_enemies = 0
	for room in data.rooms:
		data.total_enemies += room.enemies.size()


# ─── Treasure Placement ───────────────────────────────────────────────────────
func _place_treasure(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	for room: DungeonRoom in data.rooms:
		match room.type:
			RoomType.TREASURE:
				var cx := room.rect.get_center()
				room.chests.append({
					"position": Vector3(cx.x, 2, cx.y),
					"tier":     "gold",
					"loot_table": config.theme + "_treasure",
				})
				for _i in rng.randi_range(1, 3):
					room.chests.append({
						"position": _random_floor_pos(room, rng),
						"tier":     "silver",
						"loot_table": config.theme + "_common",
					})

			RoomType.BOSS:
				room.chests.append({
					"position": Vector3(
						room.rect.get_center().x + 1.5,
						2, room.rect.get_center().y
					),
					"tier":       "legendary",
					"loot_table": config.theme + "_boss",
				})

			RoomType.NORMAL:
				if rng.randf() < 0.25:
					room.chests.append({
						"position": _random_floor_pos(room, rng),
						"tier":     "bronze",
						"loot_table": config.theme + "_common",
					})


# ─── Traps ────────────────────────────────────────────────────────────────────
func _place_traps(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	var trap_types := _get_trap_types(config.theme)

	for room: DungeonRoom in data.rooms:
		if room.type == RoomType.ENTRANCE:
			continue
		var trap_count := 0
		if room.type == RoomType.TRAP_ROOM:
			trap_count = rng.randi_range(4, 8)
		elif room.type in [RoomType.BOSS, RoomType.TREASURE]:
			trap_count = rng.randi_range(1, 3)
		elif rng.randf() < 0.3:
			trap_count = rng.randi_range(1, 2)

		for _i in trap_count:
			var pos  := _random_floor_pos(room, rng)
			var trap := trap_types[rng.randi() % trap_types.size()]
			data.traps.append({"type": trap, "position": pos, "room": room})


func _place_lighting(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	var torch_vox := _get_torch_type(config.theme)

	for room: DungeonRoom in data.rooms:
		# Wall torches every ~6 units
		var rect := room.rect
		var x    := rect.position.x
		while x < rect.end.x:
			data.lights.append({"position": Vector3(x, 3, rect.position.y), "type": torch_vox})
			data.lights.append({"position": Vector3(x, 3, rect.end.y - 1), "type": torch_vox})
			x += 6
		var z := rect.position.y
		while z < rect.end.y:
			data.lights.append({"position": Vector3(rect.position.x, 3, z), "type": torch_vox})
			data.lights.append({"position": Vector3(rect.end.x - 1, 3, z), "type": torch_vox})
			z += 6


func _place_interactive(data: DungeonData, config: DungeonConfig,
		rng: RandomNumberGenerator) -> void:
	for room: DungeonRoom in data.rooms:
		if room.type == RoomType.SHRINE:
			var cx := room.rect.get_center()
			data.interactables.append({
				"type":     "shrine",
				"position": Vector3(cx.x, 1, cx.y),
				"effect":   "bless_player",
			})
		elif room.type == RoomType.PUZZLE:
			var cx := room.rect.get_center()
			data.interactables.append({
				"type":     "pressure_plate_puzzle",
				"position": Vector3(cx.x, 1, cx.y),
				"reward":   "open_secret_door",
			})


# ─── Theme Helpers ────────────────────────────────────────────────────────────
func _get_wall_voxel(theme: String) -> int:
	match theme:
		"stone_ruins":     return VoxelTypes.STONE_BRICK
		"ice_cavern":      return VoxelTypes.ICE
		"jungle_temple":   return VoxelTypes.STONE_MOSSY
		"undead_crypt":    return VoxelTypes.DARK_STONE
		"volcanic_forge":  return VoxelTypes.BASALT
		_:                 return VoxelTypes.STONE

func _get_floor_voxel(theme: String) -> int:
	match theme:
		"stone_ruins":     return VoxelTypes.STONE_TILE
		"ice_cavern":      return VoxelTypes.ICE_SMOOTH
		"jungle_temple":   return VoxelTypes.STONE_MOSSY
		"undead_crypt":    return VoxelTypes.DARK_STONE_TILE
		_:                 return VoxelTypes.STONE_TILE

func _get_ceiling_voxel(theme: String) -> int:
	return _get_wall_voxel(theme)

func _get_pillar_voxel(theme: String) -> int:
	match theme:
		"stone_ruins":     return VoxelTypes.STONE_PILLAR
		"ice_cavern":      return VoxelTypes.ICE
		"jungle_temple":   return VoxelTypes.STONE_PILLAR_MOSSY
		_:                 return VoxelTypes.STONE_PILLAR

func _get_torch_type(theme: String) -> String:
	match theme:
		"ice_cavern":      return "ice_crystal_lamp"
		"undead_crypt":    return "skull_candle"
		"volcanic_forge":  return "magma_vent"
		_:                 return "wall_torch"

func _get_enemy_table(theme: String, difficulty: int) -> Array:
	match theme:
		"stone_ruins":
			return ["skeleton", "zombie", "skeleton_archer", "stone_golem"]
		"ice_cavern":
			return ["frost_zombie", "ice_elemental", "ice_wolf", "yeti"]
		"jungle_temple":
			return ["lizardfolk", "jungle_spider", "corrupted_guardian", "poison_dart_trap"]
		"undead_crypt":
			return ["skeleton", "zombie", "wight", "revenant", "lich_apprentice"]
		_:
			return ["goblin", "orc", "skeleton", "cultist"]

func _get_boss(theme: String, difficulty: int) -> String:
	match theme:
		"stone_ruins":     return "lich_king" if difficulty >= 3 else "stone_golem_elder"
		"ice_cavern":      return "frost_dragon" if difficulty >= 4 else "yeti_warlord"
		"jungle_temple":   return "ancient_guardian" if difficulty >= 3 else "lizardfolk_chieftain"
		"undead_crypt":    return "death_knight" if difficulty >= 3 else "necromancer"
		_:                 return "dungeon_boss"

func _get_trap_types(theme: String) -> Array:
	match theme:
		"stone_ruins":     return ["arrow_trap", "spike_pit", "boulder_roll", "pressure_plate"]
		"ice_cavern":      return ["ice_spike", "freeze_trap", "cracking_floor"]
		"jungle_temple":   return ["dart_trap", "pit_trap", "swinging_blade", "poison_gas"]
		"undead_crypt":    return ["curse_rune", "bone_spike", "soul_drain_field"]
		_:                 return ["spike_trap", "arrow_trap"]


# ─── Utility ──────────────────────────────────────────────────────────────────
func _random_floor_pos(room: DungeonRoom, rng: RandomNumberGenerator) -> Vector3:
	var x := rng.randi_range(room.rect.position.x + 1, room.rect.end.x - 2)
	var z := rng.randi_range(room.rect.position.y + 1, room.rect.end.y - 2)
	return Vector3(x, 1, z)

func _create_voxel_grid(config: DungeonConfig) -> PackedByteArray:
	return PackedByteArray()   # Actual implementation uses flat array

func _fill_all(data: DungeonData, voxel: int) -> void:
	pass   # Fill all voxels in data grid

func _finalize_entrance_exit(data: DungeonData, config: DungeonConfig) -> void:
	if data.entrance_room:
		var c            := data.entrance_room.rect.get_center()
		data.entrance_pos = Vector3(c.x, 1, c.y)
	if data.boss_room:
		var c         := data.boss_room.rect.get_center()
		data.exit_pos  = Vector3(c.x, 1, c.y)


# ═══════════════════════════════════════════════════════════════════════════════
class DungeonCorridor extends RefCounted:
	var from  : Vector2i
	var to    : Vector2i
	var width : int = 3

class DungeonData extends RefCounted:
	var config         : DungeonConfig
	var rooms          : Array[DungeonRoom] = []
	var corridors      : Array[DungeonCorridor] = []
	var traps          : Array = []
	var lights         : Array = []
	var interactables  : Array = []
	var entrance_room  : DungeonRoom = null
	var boss_room      : DungeonRoom = null
	var entrance_pos   : Vector3 = Vector3.ZERO
	var exit_pos       : Vector3 = Vector3.ZERO
	var total_enemies  : int = 0
	var voxels         : PackedByteArray

	func set_voxel(x: int, y: int, z: int, voxel_type: int) -> void:
		var idx := x + y * config.width + z * config.width * config.height
		if idx >= 0 and idx < voxels.size():
			voxels[idx] = voxel_type

	func get_voxel(x: int, y: int, z: int) -> int:
		var idx := x + y * config.width + z * config.width * config.height
		if idx < 0 or idx >= voxels.size():
			return 0
		return voxels[idx]
