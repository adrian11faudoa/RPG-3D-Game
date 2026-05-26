## core/terrain/terrain_generator.gd
## Procedural terrain generation using layered noise, domain warping, and biome blending.
## Uses FastNoiseLite (built into Godot 4) for all noise operations.
##
## Biome determination pipeline:
##   1. Temperature map  (large-scale simplex)
##   2. Humidity map     (large-scale simplex, offset seed)
##   3. Altitude map     (ridge + domain-warped simplex)
##   4. Biome table lookup → blend weights for neighboring biomes
##   5. Per-biome density functions → voxel fill
##   6. Post-pass decoration → ores, trees, structures

class_name TerrainGenerator
extends RefCounted

# ─── Noise Layers ─────────────────────────────────────────────────────────────
var _continent_noise  : FastNoiseLite   # Large landmass shapes
var _mountain_noise   : FastNoiseLite   # Ridge mountains
var _detail_noise     : FastNoiseLite   # Small surface detail
var _warp_noise       : FastNoiseLite   # Domain warp source
var _cave_noise       : FastNoiseLite   # 3D cave carving
var _ore_noise        : FastNoiseLite   # Ore cluster placement
var _temp_noise       : FastNoiseLite   # Biome temperature
var _humid_noise      : FastNoiseLite   # Biome humidity
var _biome_registry   : BiomeRegistry

# ─── World Constants ──────────────────────────────────────────────────────────
const SEA_LEVEL       : int   = 64
const MAX_HEIGHT      : int   = 256
const MIN_HEIGHT      : int   = -128
const CAVE_THRESHOLD  : float = 0.45
const WARP_STRENGTH   : float = 64.0


func initialize(seed: int) -> void:
	_biome_registry = BiomeRegistry.new()
	_biome_registry.load_all()

	_continent_noise = _make_noise(seed,         FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0015, 5)
	_mountain_noise  = _make_noise(seed + 1,     FastNoiseLite.TYPE_SIMPLEX,        0.005,  4)
	_detail_noise    = _make_noise(seed + 2,     FastNoiseLite.TYPE_SIMPLEX,        0.03,   3)
	_warp_noise      = _make_noise(seed + 3,     FastNoiseLite.TYPE_SIMPLEX,        0.008,  2)
	_cave_noise      = _make_noise(seed + 4,     FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.025,  3)
	_ore_noise       = _make_noise(seed + 5,     FastNoiseLite.TYPE_CELLULAR,       0.04,   1)
	_temp_noise      = _make_noise(seed + 100,   FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0008, 2)
	_humid_noise     = _make_noise(seed + 200,   FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0008, 2)


func _make_noise(seed: int, type: FastNoiseLite.NoiseType,
		freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type    = type
	n.seed          = seed
	n.frequency     = freq
	n.fractal_octaves = octaves
	return n


# ─── Main Fill ────────────────────────────────────────────────────────────────
## Fills a ChunkData with voxel types based on procedural generation.
func fill_chunk(chunk: ChunkData, _seed: int) -> void:
	var origin := chunk.world_origin()  # Vector3i: chunk's (0,0,0) in world space

	for x in ChunkManager.CHUNK_SIZE:
		for z in ChunkManager.CHUNK_SIZE:
			var wx := float(origin.x + x)
			var wz := float(origin.z + z)

			# Domain warp the sample position for more organic terrain
			var warp_x := wx + _warp_noise.get_noise_2d(wx, wz)       * WARP_STRENGTH
			var warp_z := wz + _warp_noise.get_noise_2d(wx + 100, wz) * WARP_STRENGTH

			# Continent shape: -1 (ocean) → 1 (deep land)
			var continent := _continent_noise.get_noise_2d(warp_x, warp_z)

			# Ridge mountains (squared for sharp peaks)
			var mountain_raw  := _mountain_noise.get_noise_2d(warp_x, warp_z)
			var mountain_ridg := 1.0 - absf(mountain_raw)
			var mountain      := pow(mountain_ridg, 2.5) * 0.8

			# Surface height calculation
			var base_height := SEA_LEVEL + (continent * 40.0) + (mountain * 120.0)
			base_height    += _detail_noise.get_noise_2d(wx, wz) * 6.0
			var surf_y     := int(base_height)

			# Biome at this column
			var biome := _get_biome(wx, wz, continent, surf_y)

			for y in ChunkManager.CHUNK_SIZE:
				var wy := origin.y + y
				var voxel := _get_voxel_at(wx, float(wy), wz, surf_y, biome, continent)
				chunk.set_voxel(Vector3i(x, y, z), voxel)


func _get_voxel_at(wx: float, wy: float, wz: float,
		surf_y: int, biome: BiomeData, continent: float) -> int:

	var iy := int(wy)

	# ── Air above surface ─────────────────────────────────────────────────────
	if iy > surf_y:
		# Water fill for ocean biomes below sea level
		if iy <= SEA_LEVEL and continent < -0.1:
			return VoxelTypes.WATER
		return VoxelTypes.AIR

	# ── Cave carving ──────────────────────────────────────────────────────────
	if iy < surf_y - 4 and iy > MIN_HEIGHT + 10:
		var cave_val := _cave_noise.get_noise_3d(wx, wy, wz)
		if cave_val > CAVE_THRESHOLD:
			# Leave water in flooded caves near sea level
			if iy < SEA_LEVEL - 20:
				return VoxelTypes.WATER if cave_val < CAVE_THRESHOLD + 0.05 else VoxelTypes.AIR
			return VoxelTypes.AIR

	# ── Surface layer ─────────────────────────────────────────────────────────
	if iy == surf_y:
		return biome.surface_voxel

	# ── Sub-surface layers ────────────────────────────────────────────────────
	var depth := surf_y - iy
	if depth <= biome.topsoil_depth:
		return biome.topsoil_voxel

	# ── Ore injection ─────────────────────────────────────────────────────────
	var ore := _get_ore_at(wx, wy, wz, iy)
	if ore != VoxelTypes.NONE:
		return ore

	# ── Bedrock floor ─────────────────────────────────────────────────────────
	if iy <= MIN_HEIGHT + 4:
		return VoxelTypes.BEDROCK

	return VoxelTypes.STONE


func _get_ore_at(wx: float, wy: float, wz: float, world_y: int) -> int:
	# Each ore type has a depth range and noise threshold
	var ore_val := _ore_noise.get_noise_3d(wx, wy, wz)

	if world_y < -60 and ore_val > 0.85:   return VoxelTypes.ORE_DIAMOND
	if world_y < -20 and ore_val > 0.78:   return VoxelTypes.ORE_GOLD
	if world_y <  20 and ore_val > 0.72:   return VoxelTypes.ORE_IRON
	if world_y <  40 and ore_val > 0.68:   return VoxelTypes.ORE_COAL
	if world_y <  60 and ore_val > 0.74:   return VoxelTypes.ORE_COPPER
	return VoxelTypes.NONE


# ─── Biome System ─────────────────────────────────────────────────────────────
func _get_biome(wx: float, wz: float, continent: float, surf_y: int) -> BiomeData:
	var temperature := _temp_noise.get_noise_2d(wx, wz)   # -1 cold → 1 hot
	var humidity    := _humid_noise.get_noise_2d(wx, wz)  # -1 dry  → 1 wet

	# Altitude modifies temperature
	var altitude_factor := float(surf_y - SEA_LEVEL) / 80.0
	temperature -= altitude_factor * 0.4

	# Ocean override
	if continent < -0.2:
		return _biome_registry.get_biome("ocean")
	if continent < 0.0:
		return _biome_registry.get_biome("beach")

	# Mountain override at high altitude
	if surf_y > SEA_LEVEL + 90:
		return _biome_registry.get_biome("alpine" if temperature > -0.2 else "tundra")

	# Biome lookup table (temperature x humidity)
	return _biome_registry.lookup(temperature, humidity)


func get_dominant_biome(chunk_pos: Vector3i) -> BiomeData:
	# Returns biome at chunk center (for material selection)
	var wx := float(chunk_pos.x * ChunkManager.CHUNK_SIZE + ChunkManager.CHUNK_SIZE / 2)
	var wz := float(chunk_pos.z * ChunkManager.CHUNK_SIZE + ChunkManager.CHUNK_SIZE / 2)
	var continent := _continent_noise.get_noise_2d(wx, wz)
	var surf_y    := SEA_LEVEL + int(continent * 40.0)
	return _get_biome(wx, wz, continent, surf_y)


func get_surface_height(wx: float, wz: float) -> int:
	var warp_x    := wx + _warp_noise.get_noise_2d(wx, wz)       * WARP_STRENGTH
	var warp_z    := wz + _warp_noise.get_noise_2d(wx + 100, wz) * WARP_STRENGTH
	var continent := _continent_noise.get_noise_2d(warp_x, warp_z)
	var mountain_raw  := _mountain_noise.get_noise_2d(warp_x, warp_z)
	var mountain_ridg := 1.0 - absf(mountain_raw)
	var mountain      := pow(mountain_ridg, 2.5) * 0.8
	var base_height   := SEA_LEVEL + (continent * 40.0) + (mountain * 120.0)
	base_height      += _detail_noise.get_noise_2d(wx, wz) * 6.0
	return int(base_height)


# ─── Decoration Pass ──────────────────────────────────────────────────────────
## Places trees, rocks, structures after terrain voxels are set.
func decorate_chunk(chunk: ChunkData, seed: int) -> void:
	var origin  := chunk.world_origin()
	var rng     := RandomNumberGenerator.new()
	var biome   := get_dominant_biome(chunk.chunk_pos)

	for feature: BiomeFeature in biome.features:
		var count := int(feature.density * ChunkManager.CHUNK_SIZE * ChunkManager.CHUNK_SIZE)
		for _i in count:
			rng.seed = hash(Vector3i(origin.x + _i, seed, origin.z + _i))
			var lx   := rng.randi_range(1, ChunkManager.CHUNK_SIZE - 2)
			var lz   := rng.randi_range(1, ChunkManager.CHUNK_SIZE - 2)
			var surf  := _find_surface_in_chunk(chunk, lx, lz)
			if surf == -1:
				continue
			var surf_voxel := chunk.get_voxel(Vector3i(lx, surf, lz))
			if surf_voxel != biome.surface_voxel:
				continue
			_place_feature(chunk, feature, lx, surf + 1, lz, rng)


func _find_surface_in_chunk(chunk: ChunkData, lx: int, lz: int) -> int:
	for y in range(ChunkManager.CHUNK_SIZE - 1, -1, -1):
		if chunk.get_voxel(Vector3i(lx, y, lz)) != VoxelTypes.AIR:
			return y
	return -1


func _place_feature(chunk: ChunkData, feature: BiomeFeature,
		lx: int, ly: int, lz: int, rng: RandomNumberGenerator) -> void:
	match feature.type:
		"tree_oak":     _place_oak_tree(chunk, lx, ly, lz)
		"tree_pine":    _place_pine_tree(chunk, lx, ly, lz, rng)
		"tree_palm":    _place_palm_tree(chunk, lx, ly, lz)
		"rock_cluster": _place_rock_cluster(chunk, lx, ly, lz, rng)
		"mushroom":     _place_mushroom(chunk, lx, ly, lz)
		"cactus":       _place_cactus(chunk, lx, ly, lz, rng)
		"ruins_small":  _place_ruins(chunk, lx, ly, lz, rng)


func _place_oak_tree(chunk: ChunkData, lx: int, ly: int, lz: int) -> void:
	var trunk_h := 4
	for y in trunk_h:
		chunk.try_set_voxel(Vector3i(lx, ly + y, lz), VoxelTypes.WOOD_OAK)
	# Leaf sphere
	for dx in range(-2, 3):
		for dy in range(-1, 4):
			for dz in range(-2, 3):
				if Vector3i(dx, dy, dz).length_squared() <= 6:
					chunk.try_set_voxel(Vector3i(lx + dx, ly + trunk_h + dy, lz + dz), VoxelTypes.LEAVES_OAK)


func _place_pine_tree(chunk: ChunkData, lx: int, ly: int, lz: int,
		rng: RandomNumberGenerator) -> void:
	var height := rng.randi_range(6, 10)
	for y in height:
		chunk.try_set_voxel(Vector3i(lx, ly + y, lz), VoxelTypes.WOOD_PINE)
	# Conical layers
	for layer in range(height - 1, -1, -2):
		var r := (height - layer) / 3
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if absi(dx) + absi(dz) <= r:
					chunk.try_set_voxel(Vector3i(lx + dx, ly + layer, lz + dz), VoxelTypes.LEAVES_PINE)


func _place_palm_tree(chunk: ChunkData, lx: int, ly: int, lz: int) -> void:
	for y in 6:
		chunk.try_set_voxel(Vector3i(lx, ly + y, lz), VoxelTypes.WOOD_PALM)
	for dx in range(-3, 4):
		chunk.try_set_voxel(Vector3i(lx + dx, ly + 6, lz), VoxelTypes.LEAVES_PALM)
	for dz in range(-3, 4):
		chunk.try_set_voxel(Vector3i(lx, ly + 6, lz + dz), VoxelTypes.LEAVES_PALM)


func _place_cactus(chunk: ChunkData, lx: int, ly: int, lz: int,
		rng: RandomNumberGenerator) -> void:
	var h := rng.randi_range(2, 4)
	for y in h:
		chunk.try_set_voxel(Vector3i(lx, ly + y, lz), VoxelTypes.CACTUS)


func _place_rock_cluster(chunk: ChunkData, lx: int, ly: int, lz: int,
		rng: RandomNumberGenerator) -> void:
	var count := rng.randi_range(2, 6)
	for i in count:
		var ox := rng.randi_range(-1, 1)
		var oz := rng.randi_range(-1, 1)
		var h  := rng.randi_range(1, 3)
		for y in h:
			chunk.try_set_voxel(Vector3i(lx + ox, ly + y, lz + oz), VoxelTypes.STONE_MOSSY)


func _place_mushroom(chunk: ChunkData, lx: int, ly: int, lz: int) -> void:
	chunk.try_set_voxel(Vector3i(lx, ly,     lz), VoxelTypes.MUSHROOM_STEM)
	chunk.try_set_voxel(Vector3i(lx, ly + 1, lz), VoxelTypes.MUSHROOM_CAP)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			chunk.try_set_voxel(Vector3i(lx + dx, ly + 1, lz + dz), VoxelTypes.MUSHROOM_CAP)


func _place_ruins(chunk: ChunkData, lx: int, ly: int, lz: int,
		rng: RandomNumberGenerator) -> void:
	var size := rng.randi_range(3, 6)
	for x in size:
		for z in size:
			if rng.randf() > 0.3:
				chunk.try_set_voxel(Vector3i(lx + x, ly, lz + z), VoxelTypes.STONE_BRICK)
	# Partial walls
	for w in range(0, size, 2):
		var wall_h := rng.randi_range(1, 3)
		for h in wall_h:
			chunk.try_set_voxel(Vector3i(lx + w, ly + 1 + h, lz), VoxelTypes.STONE_BRICK)
