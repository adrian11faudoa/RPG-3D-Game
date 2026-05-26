## core/terrain/chunk_data.gd
## Stores the raw voxel grid for a single chunk.
## Uses a flat PackedByteArray for memory efficiency.
## Supports run-length encoding for disk storage and network transmission.
##
## Memory layout: voxels[x + y*SIZE + z*SIZE*SIZE]
## Each voxel: 1 byte (256 voxel types, expandable to uint16 if needed)

class_name ChunkData
extends RefCounted

const CHUNK_SIZE : int = 32
const VOXEL_COUNT: int = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE   # 32768

var chunk_pos    : Vector3i
var _voxels      : PackedByteArray
var _dirty       : bool = false
var _generated   : bool = false


func _init(pos: Vector3i, _size: int = CHUNK_SIZE) -> void:
	chunk_pos = pos
	_voxels   = PackedByteArray()
	_voxels.resize(VOXEL_COUNT)
	_voxels.fill(VoxelTypes.AIR)


# ─── Voxel Access ─────────────────────────────────────────────────────────────
func get_voxel(local_pos: Vector3i) -> int:
	return _voxels[_idx(local_pos)]


func set_voxel(local_pos: Vector3i, voxel_type: int) -> void:
	var idx := _idx(local_pos)
	if _voxels[idx] != voxel_type:
		_voxels[idx] = voxel_type
		_dirty = true


## Set voxel only if position is within chunk bounds. Safe for decoration passes
## that may attempt to place features in neighbor chunks.
func try_set_voxel(local_pos: Vector3i, voxel_type: int) -> bool:
	if local_pos.x < 0 or local_pos.x >= CHUNK_SIZE or \
	   local_pos.y < 0 or local_pos.y >= CHUNK_SIZE or \
	   local_pos.z < 0 or local_pos.z >= CHUNK_SIZE:
		return false
	set_voxel(local_pos, voxel_type)
	return true


func get_voxel_world(world_pos: Vector3i) -> int:
	return get_voxel(world_pos - world_origin())


func set_voxel_world(world_pos: Vector3i, voxel_type: int) -> void:
	set_voxel(world_pos - world_origin(), voxel_type)


# ─── Batch Fill ───────────────────────────────────────────────────────────────
func fill(voxel_type: int) -> void:
	_voxels.fill(voxel_type)
	_dirty = true


func fill_region(from: Vector3i, to: Vector3i, voxel_type: int) -> void:
	for x in range(from.x, to.x + 1):
		for y in range(from.y, to.y + 1):
			for z in range(from.z, to.z + 1):
				set_voxel(Vector3i(x, y, z), voxel_type)


# ─── Queries ──────────────────────────────────────────────────────────────────
func is_empty() -> bool:
	for i in VOXEL_COUNT:
		if _voxels[i] != VoxelTypes.AIR:
			return false
	return true


func is_dirty() -> bool:
	return _dirty


func mark_dirty() -> void:
	_dirty = true


func clear_dirty() -> void:
	_dirty = false


func world_origin() -> Vector3i:
	return chunk_pos * CHUNK_SIZE


## Find highest non-air voxel at local (x, z) column. Returns -1 if all air.
func get_surface_y(lx: int, lz: int) -> int:
	for y in range(CHUNK_SIZE - 1, -1, -1):
		if _voxels[_idx(Vector3i(lx, y, lz))] != VoxelTypes.AIR:
			return y
	return -1


## Count voxels of a given type in the chunk (useful for ores/features).
func count_voxel_type(voxel_type: int) -> int:
	var count := 0
	for i in VOXEL_COUNT:
		if _voxels[i] == voxel_type:
			count += 1
	return count


# ─── Serialization ─── Run-Length Encoding ────────────────────────────────────
## Encodes voxel data with RLE. Reduces typical terrain by 60-80%.
## Format: [voxel_type: u8, run_length: u16_le, ...]
func serialize_rle() -> PackedByteArray:
	var out    := PackedByteArray()
	var i      := 0

	while i < VOXEL_COUNT:
		var v     := _voxels[i]
		var count := 1
		while i + count < VOXEL_COUNT and _voxels[i + count] == v and count < 65535:
			count += 1
		out.append(v)
		# Encode count as 2 bytes little-endian
		out.append(count & 0xFF)
		out.append((count >> 8) & 0xFF)
		i += count

	return out


func deserialize_rle(data: PackedByteArray) -> void:
	var idx  := 0
	var vpos := 0

	while idx + 2 < data.size() and vpos < VOXEL_COUNT:
		var voxel  := data[idx]
		var count  := data[idx + 1] | (data[idx + 2] << 8)
		idx        += 3
		for _i in count:
			if vpos < VOXEL_COUNT:
				_voxels[vpos] = voxel
				vpos          += 1

	_dirty = false


## Disk format: 4-byte magic + 4-byte chunk pos (3×i32) + RLE voxel data
func save_to_file(path: String) -> void:
	var rle    := serialize_rle()
	var file   := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[ChunkData] Cannot write to: %s" % path)
		return

	# Magic header
	file.store_32(0x56454C43)   # "VELC"
	# Chunk position
	file.store_32(chunk_pos.x)
	file.store_32(chunk_pos.y)
	file.store_32(chunk_pos.z)
	# RLE payload length + data
	file.store_32(rle.size())
	file.store_buffer(rle)
	file.close()
	_dirty = false


static func load_from_file(path: String) -> ChunkData:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[ChunkData] Cannot read: %s" % path)
		return null

	var magic := file.get_32()
	if magic != 0x56454C43:
		push_error("[ChunkData] Invalid chunk file: %s" % path)
		file.close()
		return null

	var cx    := file.get_32()
	var cy    := file.get_32()
	var cz    := file.get_32()
	var chunk := ChunkData.new(Vector3i(cx, cy, cz))

	var rle_size := file.get_32()
	var rle      := file.get_buffer(rle_size)
	file.close()

	chunk.deserialize_rle(rle)
	return chunk


# ─── Network Helpers ──────────────────────────────────────────────────────────
## Compact delta encoding: only send changed voxels vs a known previous state.
## Returns [count: u16, (index: u32, voxel: u8)...] for each changed voxel.
func serialize_delta(previous: ChunkData) -> PackedByteArray:
	if previous == null:
		return serialize_rle()

	var changed := PackedByteArray()
	var count   := 0

	for i in VOXEL_COUNT:
		if _voxels[i] != previous._voxels[i]:
			# 4-byte index + 1-byte voxel
			changed.append_array([
				i & 0xFF, (i >> 8) & 0xFF,
				(i >> 16) & 0xFF, (i >> 24) & 0xFF,
				_voxels[i],
			])
			count += 1

	var out := PackedByteArray()
	out.append(count & 0xFF)
	out.append((count >> 8) & 0xFF)
	out.append_array(changed)
	return out


func apply_delta(delta: PackedByteArray) -> void:
	if delta.is_empty():
		return
	var count := delta[0] | (delta[1] << 8)
	var pos   := 2
	for _i in count:
		if pos + 4 >= delta.size():
			break
		var idx   := delta[pos] | (delta[pos+1] << 8) | (delta[pos+2] << 16) | (delta[pos+3] << 24)
		var voxel := delta[pos + 4]
		if idx < VOXEL_COUNT:
			_voxels[idx] = voxel
		pos += 5
	_dirty = true


# ─── Internal ─────────────────────────────────────────────────────────────────
@inline
func _idx(local_pos: Vector3i) -> int:
	return local_pos.x + local_pos.y * CHUNK_SIZE + local_pos.z * CHUNK_SIZE * CHUNK_SIZE


# ─── Debug ────────────────────────────────────────────────────────────────────
func print_slice_y(y: int) -> void:
	print("Chunk %s — Y=%d slice:" % [chunk_pos, y])
	for z in CHUNK_SIZE:
		var row := ""
		for x in CHUNK_SIZE:
			var v := get_voxel(Vector3i(x, y, z))
			row  += "%2d " % v
		print(row)
