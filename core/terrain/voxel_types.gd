## core/terrain/voxel_types.gd
## Central registry of all voxel type IDs and their atlas layout.
## IDs are stable — never change existing values, only append new ones.
## Atlas layout: 16-tile-wide texture atlas, each tile 16×16 px.

class_name VoxelTypes

# ─── Core ─────────────────────────────────────────────────────────────────────
const NONE          = 0
const AIR           = 0
const STONE         = 1
const DIRT          = 2
const GRASS         = 3
const SAND          = 4
const GRAVEL        = 5
const BEDROCK       = 6
const WATER         = 7
const SNOW          = 8

# ─── Wood & Leaves ────────────────────────────────────────────────────────────
const WOOD_OAK      = 10
const WOOD_PINE     = 11
const WOOD_PALM     = 12
const WOOD_DARK     = 13
const LEAVES_OAK    = 14
const LEAVES_PINE   = 15
const LEAVES_PALM   = 16

# ─── Stone Variants ───────────────────────────────────────────────────────────
const STONE_BRICK   = 20
const STONE_MOSSY   = 21
const STONE_TILE    = 22
const STONE_PILLAR  = 23
const STONE_PILLAR_MOSSY = 24
const DARK_STONE    = 25
const DARK_STONE_TILE    = 26
const SANDSTONE     = 27
const BASALT        = 28
const OBSIDIAN      = 29

# ─── Ores ─────────────────────────────────────────────────────────────────────
const ORE_COAL      = 30
const ORE_IRON      = 31
const ORE_COPPER    = 32
const ORE_GOLD      = 33
const ORE_SILVER    = 34
const ORE_DIAMOND   = 35
const ORE_MITHRIL   = 36

# ─── Nature ───────────────────────────────────────────────────────────────────
const CACTUS        = 40
const MUSHROOM_STEM = 41
const MUSHROOM_CAP  = 42
const PEAT          = 43
const MUD           = 44
const DARK_GRASS    = 45
const DARK_DIRT     = 46
const ENCHANTED_GRASS = 47
const ARCANE_DIRT   = 48
const FROZEN_DIRT   = 49

# ─── Ice & Snow ───────────────────────────────────────────────────────────────
const ICE           = 50
const ICE_SMOOTH    = 51
const PACKED_ICE    = 52

# ─── Crafted / Placed ─────────────────────────────────────────────────────────
const WOOD_PLANKS   = 60
const STONE_SLAB    = 61
const GLASS         = 62
const LANTERN       = 63
const CAMPFIRE      = 64
const CHEST_VOXEL   = 65

# ─── Special ──────────────────────────────────────────────────────────────────
const LAVA          = 70
const MAGMA_ROCK    = 71


# ─── VoxelAtlas mapping ───────────────────────────────────────────────────────
## Returns atlas column (0-15) for the top face of a voxel
class VoxelAtlas:
	static func get_top_column(voxel: int) -> int:
		match voxel:
			VoxelTypes.GRASS:       return 0
			VoxelTypes.DIRT:        return 2
			VoxelTypes.STONE:       return 1
			VoxelTypes.SAND:        return 3
			VoxelTypes.SNOW:        return 4
			VoxelTypes.WOOD_OAK:    return 5
			VoxelTypes.WOOD_PINE:   return 5
			VoxelTypes.STONE_BRICK: return 6
			VoxelTypes.OBSIDIAN:    return 7
			VoxelTypes.WATER:       return 8
			VoxelTypes.LEAVES_OAK:  return 9
			VoxelTypes.LEAVES_PINE: return 10
			VoxelTypes.ORE_COAL:    return 11
			VoxelTypes.ORE_IRON:    return 12
			VoxelTypes.ORE_GOLD:    return 13
			VoxelTypes.ICE:         return 14
			_:                      return 15   # Fallback magenta (debug)

	static func get_bottom_column(voxel: int) -> int:
		match voxel:
			VoxelTypes.GRASS:  return 2   # Dirt underneath grass
			_:                 return get_top_column(voxel)

	static func get_side_column(voxel: int) -> int:
		match voxel:
			VoxelTypes.GRASS:  return 15  # Side = grass-dirt mix
			_:                 return get_top_column(voxel)

	static func get_row(voxel: int) -> int:
		# Row 0 = natural, Row 1 = stone/ore, Row 2 = wood/crafted
		if voxel in [VoxelTypes.STONE, VoxelTypes.STONE_BRICK, VoxelTypes.DARK_STONE,
		             VoxelTypes.ORE_COAL, VoxelTypes.ORE_IRON, VoxelTypes.ORE_GOLD,
		             VoxelTypes.ORE_DIAMOND, VoxelTypes.OBSIDIAN, VoxelTypes.BASALT]:
			return 1
		if voxel in [VoxelTypes.WOOD_OAK, VoxelTypes.WOOD_PINE, VoxelTypes.WOOD_PLANKS,
		             VoxelTypes.CHEST_VOXEL]:
			return 2
		return 0
