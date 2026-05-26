## core/terrain/chunk_manager.gd
## Manages chunk lifecycle: generation, streaming, LOD, and unloading.
## This is the heart of the open-world system.
##
## Architecture notes:
##   - World is divided into CHUNK_SIZE^3 voxel regions
##   - Chunks are generated on background threads using WorkerThreadPool
##   - LOD levels: 0=full, 1=half, 2=quarter, 3=distant mesh
##   - Server owns chunk authority; clients receive mesh data via RPC
##   - Chunk data is persisted to disk with run-length encoding

class_name ChunkManager
extends Node3D

# ─── Constants ────────────────────────────────────────────────────────────────
const CHUNK_SIZE       : int   = 32        # voxels per chunk axis
const VOXEL_SIZE       : float = 1.0       # world units per voxel
const RENDER_DISTANCE  : int   = 8         # chunks in each direction
const GENERATE_DISTANCE: int   = 10        # pre-generate beyond render
const UNLOAD_DISTANCE  : int   = 14        # unload chunks beyond this
const LOD_DISTANCES    : Array = [4, 7, 10, 13]  # LOD level thresholds
const THREAD_POOL_SIZE : int   = 4

# ─── Signals ──────────────────────────────────────────────────────────────────
signal chunk_loaded(chunk_pos: Vector3i)
signal chunk_unloaded(chunk_pos: Vector3i)
signal chunk_modified(chunk_pos: Vector3i)

# ─── State ────────────────────────────────────────────────────────────────────
var _active_chunks   : Dictionary = {}   # Vector3i -> ChunkData
var _mesh_instances  : Dictionary = {}   # Vector3i -> MeshInstance3D
var _pending_gen     : Dictionary = {}   # Vector3i -> bool (generating)
var _pending_mesh    : Dictionary = {}   # Vector3i -> bool (meshing)
var _player_chunk    : Vector3i   = Vector3i.ZERO
var _world_seed      : int        = 0
var _terrain_gen     : TerrainGenerator
var _mesher          : ChunkMesher
var _save_dir        : String     = "user://chunks/"

@onready var _debug_overlay: ChunkDebugOverlay = $DebugOverlay


# ─── Init ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_terrain_gen = TerrainGenerator.new()
	_mesher      = ChunkMesher.new()
	DirAccess.make_dir_recursive_absolute(_save_dir)
	set_process(true)


func initialize(seed: int) -> void:
	_world_seed = seed
	_terrain_gen.initialize(seed)
	print("[ChunkManager] Initialized with seed: %d" % seed)


# ─── Main Update ──────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	_update_player_chunk()
	_queue_needed_chunks()
	_unload_distant_chunks()
	_update_lod()


func _update_player_chunk() -> void:
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	# Use the local player or average position in multiplayer
	var player_pos: Vector3 = players[0].global_position
	var new_chunk  := world_to_chunk(player_pos)
	if new_chunk != _player_chunk:
		_player_chunk = new_chunk


func _queue_needed_chunks() -> void:
	for x in range(-GENERATE_DISTANCE, GENERATE_DISTANCE + 1):
		for z in range(-GENERATE_DISTANCE, GENERATE_DISTANCE + 1):
			for y in range(-2, 3):  # Limited vertical range
				var cpos := _player_chunk + Vector3i(x, y, z)
				if not _active_chunks.has(cpos) and not _pending_gen.has(cpos):
					_request_chunk_generation(cpos)


func _unload_distant_chunks() -> void:
	var to_unload: Array[Vector3i] = []
	for cpos: Vector3i in _active_chunks.keys():
		var dist := (_player_chunk - cpos).length()
		if dist > UNLOAD_DISTANCE:
			to_unload.append(cpos)
	for cpos in to_unload:
		_unload_chunk(cpos)


# ─── Chunk Generation ─────────────────────────────────────────────────────────
func _request_chunk_generation(cpos: Vector3i) -> void:
	_pending_gen[cpos] = true
	# Check disk cache first
	var cache_path := _chunk_cache_path(cpos)
	if FileAccess.file_exists(cache_path):
		WorkerThreadPool.add_task(_load_chunk_from_disk.bind(cpos, cache_path))
	else:
		WorkerThreadPool.add_task(_generate_chunk_threaded.bind(cpos))


func _generate_chunk_threaded(cpos: Vector3i) -> void:
	var chunk := ChunkData.new(cpos, CHUNK_SIZE)
	_terrain_gen.fill_chunk(chunk, _world_seed)
	# Post-gen decoration (ores, trees, structures)
	_terrain_gen.decorate_chunk(chunk, _world_seed)
	call_deferred("_on_chunk_generated", cpos, chunk)


func _load_chunk_from_disk(cpos: Vector3i, path: String) -> void:
	var chunk := ChunkData.load_from_file(path)
	call_deferred("_on_chunk_generated", cpos, chunk)


func _on_chunk_generated(cpos: Vector3i, chunk: ChunkData) -> void:
	_pending_gen.erase(cpos)
	_active_chunks[cpos] = chunk
	_request_mesh_build(cpos)
	chunk_loaded.emit(cpos)


# ─── Mesh Building ────────────────────────────────────────────────────────────
func _request_mesh_build(cpos: Vector3i) -> void:
	_pending_mesh[cpos] = true
	var lod := _get_lod_for_chunk(cpos)
	WorkerThreadPool.add_task(_build_mesh_threaded.bind(cpos, lod))


func _build_mesh_threaded(cpos: Vector3i, lod: int) -> void:
	if not _active_chunks.has(cpos):
		return
	var chunk: ChunkData = _active_chunks[cpos]
	# Gather neighbor data for seam-free meshing
	var neighbors := _get_neighbor_chunks(cpos)
	var mesh_data := _mesher.build_mesh(chunk, neighbors, lod)
	call_deferred("_on_mesh_built", cpos, mesh_data, lod)


func _on_mesh_built(cpos: Vector3i, mesh_data: MeshData, lod: int) -> void:
	_pending_mesh.erase(cpos)
	# Remove old mesh
	if _mesh_instances.has(cpos):
		_mesh_instances[cpos].queue_free()
	# Create new mesh instance
	var mi        := MeshInstance3D.new()
	mi.mesh        = mesh_data.array_mesh
	mi.position    = Vector3(cpos) * CHUNK_SIZE * VOXEL_SIZE
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Apply terrain material with biome blend
	mi.material_override = _get_terrain_material(cpos)
	add_child(mi)
	_mesh_instances[cpos] = mi
	# Add collision for LOD 0 and 1
	if lod <= 1:
		var static_body := StaticBody3D.new()
		var collision   := CollisionShape3D.new()
		collision.shape = mesh_data.trimesh_shape
		static_body.add_child(collision)
		mi.add_child(static_body)


# ─── LOD Management ───────────────────────────────────────────────────────────
func _update_lod() -> void:
	for cpos: Vector3i in _mesh_instances.keys():
		var new_lod := _get_lod_for_chunk(cpos)
		var mi      := _mesh_instances[cpos] as MeshInstance3D
		# Tag for rebuild if LOD changed significantly
		if mi.get_meta("lod", 0) != new_lod:
			mi.set_meta("lod", new_lod)
			_request_mesh_build(cpos)


func _get_lod_for_chunk(cpos: Vector3i) -> int:
	var dist := float((_player_chunk - cpos).length())
	for i in LOD_DISTANCES.size():
		if dist <= LOD_DISTANCES[i]:
			return i
	return LOD_DISTANCES.size()


# ─── Voxel Manipulation ───────────────────────────────────────────────────────
## Set a voxel at world position. Used for mining, building, destruction.
func set_voxel(world_pos: Vector3i, voxel_type: int) -> void:
	var cpos   := world_to_chunk(Vector3(world_pos))
	var local  := world_pos - cpos * CHUNK_SIZE
	if not _active_chunks.has(cpos):
		return
	var chunk: ChunkData = _active_chunks[cpos]
	chunk.set_voxel(local, voxel_type)
	chunk.mark_dirty()
	_request_mesh_build(cpos)
	# Rebuild neighboring chunks if on border
	_rebuild_border_neighbors(cpos, local)
	chunk_modified.emit(cpos)
	# Propagate to server if client
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_rpc_set_voxel.rpc_id(1, world_pos, voxel_type)


func get_voxel(world_pos: Vector3i) -> int:
	var cpos  := world_to_chunk(Vector3(world_pos))
	var local := world_pos - cpos * CHUNK_SIZE
	if not _active_chunks.has(cpos):
		return 0
	return _active_chunks[cpos].get_voxel(local)


func _rebuild_border_neighbors(cpos: Vector3i, local: Vector3i) -> void:
	var offsets: Array[Vector3i] = []
	if local.x == 0:               offsets.append(Vector3i(-1, 0, 0))
	if local.x == CHUNK_SIZE - 1:  offsets.append(Vector3i(1, 0, 0))
	if local.z == 0:               offsets.append(Vector3i(0, 0, -1))
	if local.z == CHUNK_SIZE - 1:  offsets.append(Vector3i(0, 0, 1))
	for offset in offsets:
		var neighbor := cpos + offset
		if _active_chunks.has(neighbor):
			_request_mesh_build(neighbor)


# ─── Helpers ──────────────────────────────────────────────────────────────────
func world_to_chunk(world_pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(world_pos.x / CHUNK_SIZE),
		floori(world_pos.y / CHUNK_SIZE),
		floori(world_pos.z / CHUNK_SIZE)
	)


func chunk_to_world(cpos: Vector3i) -> Vector3:
	return Vector3(cpos) * CHUNK_SIZE * VOXEL_SIZE


func _get_neighbor_chunks(cpos: Vector3i) -> Dictionary:
	var neighbors: Dictionary = {}
	for x in [-1, 0, 1]:
		for z in [-1, 0, 1]:
			for y in [-1, 0, 1]:
				var npos := cpos + Vector3i(x, y, z)
				if _active_chunks.has(npos):
					neighbors[Vector3i(x, y, z)] = _active_chunks[npos]
	return neighbors


func _unload_chunk(cpos: Vector3i) -> void:
	if _active_chunks.has(cpos):
		var chunk: ChunkData = _active_chunks[cpos]
		if chunk.is_dirty():
			chunk.save_to_file(_chunk_cache_path(cpos))
		_active_chunks.erase(cpos)
	if _mesh_instances.has(cpos):
		_mesh_instances[cpos].queue_free()
		_mesh_instances.erase(cpos)
	chunk_unloaded.emit(cpos)


func _chunk_cache_path(cpos: Vector3i) -> String:
	return "%s%d_%d_%d.chunk" % [_save_dir, cpos.x, cpos.y, cpos.z]


func _get_terrain_material(cpos: Vector3i) -> ShaderMaterial:
	# Returns biome-blended material for this chunk
	var biome := _terrain_gen.get_dominant_biome(cpos)
	return TerrainMaterialCache.get_material(biome)


# ─── Multiplayer RPC ──────────────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_voxel(world_pos: Vector3i, voxel_type: int) -> void:
	# Server validates and applies
	if multiplayer.is_server():
		var sender := multiplayer.get_remote_sender_id()
		if _validate_voxel_edit(sender, world_pos):
			set_voxel(world_pos, voxel_type)
			# Broadcast to all other clients
			_rpc_set_voxel.rpc(world_pos, voxel_type)


func _validate_voxel_edit(peer_id: int, world_pos: Vector3i) -> bool:
	# Anti-cheat: check player is within reach distance
	var player := _get_player_by_peer(peer_id)
	if player == null:
		return false
	return player.global_position.distance_to(Vector3(world_pos)) < 8.0


func _get_player_by_peer(peer_id: int) -> Node3D:
	for p in get_tree().get_nodes_in_group("players"):
		if p.get_multiplayer_authority() == peer_id:
			return p
	return null
