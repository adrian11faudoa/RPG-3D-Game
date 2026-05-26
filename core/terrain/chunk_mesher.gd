## core/terrain/chunk_mesher.gd
## Greedy meshing algorithm for voxel terrain.
## Reduces face count by 80-95% vs naive cube-per-voxel approach.
##
## Algorithm (per axis):
##   1. Sweep through each slice of the chunk in each axis direction
##   2. Build a 2D mask of visible faces (voxel type vs empty/different neighbor)
##   3. Greedily merge adjacent same-type faces into quads
##   4. Emit merged quads as triangles into the surface array
##
## Supports: per-biome UV tiling, ambient occlusion baked into vertex colors,
##           transparent voxels (water, glass) in a second surface pass.

class_name ChunkMesher
extends RefCounted

const CHUNK_SIZE : int = ChunkManager.CHUNK_SIZE

# Face normals for each of 6 directions
const FACE_NORMALS : Array[Vector3] = [
	Vector3( 1,  0,  0),   # +X (East)
	Vector3(-1,  0,  0),   # -X (West)
	Vector3( 0,  1,  0),   # +Y (Up)
	Vector3( 0, -1,  0),   # -Y (Down)
	Vector3( 0,  0,  1),   # +Z (South)
	Vector3( 0,  0, -1),   # -Z (North)
]

# Per-face UV atlas columns (each voxel type maps to an atlas column)
# Atlas layout: 16 voxel types × 4 faces (top/bottom/side/side) at 16x16 per tile
const ATLAS_SIZE   : int   = 16
const ATLAS_TILE   : float = 1.0 / ATLAS_SIZE

# ─── Voxel transparency table ─────────────────────────────────────────────────
const TRANSPARENT_VOXELS : Array[int] = [
	VoxelTypes.AIR, VoxelTypes.WATER,
	VoxelTypes.LEAVES_OAK, VoxelTypes.LEAVES_PINE, VoxelTypes.LEAVES_PALM,
]


class MeshData extends RefCounted:
	var array_mesh    : ArrayMesh
	var trimesh_shape : ConcavePolygonShape3D


# ─── Main entry point ─────────────────────────────────────────────────────────
func build_mesh(chunk: ChunkData, neighbors: Dictionary, lod: int) -> MeshData:
	var data := MeshData.new()

	# Opaque surface
	var opaque_arrays := _greedy_mesh(chunk, neighbors, lod, false)
	# Transparent surface (water, leaves)
	var trans_arrays  := _greedy_mesh(chunk, neighbors, lod, true)

	var mesh := ArrayMesh.new()
	if not opaque_arrays.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, opaque_arrays)
		mesh.surface_set_material(0, _get_surface_material(chunk, false))

	if not trans_arrays.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trans_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _get_surface_material(chunk, true))

	data.array_mesh = mesh

	# Collision shape (only for opaque, LOD 0+1)
	if lod <= 1 and not opaque_arrays.is_empty():
		var shape          := ConcavePolygonShape3D.new()
		var verts          := opaque_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idxs           := opaque_arrays[Mesh.ARRAY_INDEX]  as PackedInt32Array
		var face_verts     := PackedVector3Array()
		face_verts.resize(idxs.size())
		for i in idxs.size():
			face_verts[i] = verts[idxs[i]]
		shape.set_faces(face_verts)
		data.trimesh_shape = shape

	return data


# ─── Greedy Meshing ───────────────────────────────────────────────────────────
func _greedy_mesh(chunk: ChunkData, neighbors: Dictionary,
		lod: int, transparent_pass: bool) -> Array:

	var step := 1 << lod    # LOD step size (1, 2, 4, 8)

	var vertices  := PackedVector3Array()
	var normals   := PackedVector3Array()
	var uvs       := PackedVector2Array()
	var colors    := PackedColorArray()    # AO baked here
	var indices   := PackedInt32Array()

	# Sweep along each of the 3 axes, in both directions
	for axis in 3:
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3

		var q          := Vector3i.ZERO
		var x          := Vector3i.ZERO
		var mask       := []                # 2D mask for this slice
		mask.resize(CHUNK_SIZE * CHUNK_SIZE)

		# +axis face, then -axis face
		for backface in [false, true]:
			var dir    := -1 if backface else 1
			x[axis]    = -1

			while x[axis] < CHUNK_SIZE:
				# Build mask for this slice
				for v in range(0, CHUNK_SIZE, step):
					for u in range(0, CHUNK_SIZE, step):
						x[u_axis] = u
						x[v_axis] = v

						# Current voxel
						var voxel_here := _get_voxel_safe(chunk, neighbors, x)
						# Neighbor voxel in axis direction
						var neighbor_pos := x
						neighbor_pos[axis] += dir
						var voxel_next := _get_voxel_safe(chunk, neighbors, neighbor_pos)

						var should_draw := _should_draw_face(
							voxel_here, voxel_next, backface, transparent_pass
						)
						mask[v * CHUNK_SIZE + u] = voxel_here if should_draw else 0

				x[axis] += step

				# Greedy merge
				var i := 0
				for v in range(0, CHUNK_SIZE, step):
					var j := 0
					while j < CHUNK_SIZE:
						var mask_val := mask[v * CHUNK_SIZE + j]
						if mask_val == 0:
							j += step
							continue

						# Find width of this run (same voxel type, same row)
						var w := step
						while j + w < CHUNK_SIZE and mask[(v) * CHUNK_SIZE + (j + w)] == mask_val:
							w += step

						# Find height of rectangle (all rows same)
						var h := step
						var done := false
						while v + h < CHUNK_SIZE and not done:
							for k in range(j, j + w, step):
								if mask[(v + h) * CHUNK_SIZE + k] != mask_val:
									done = true
									break
							if not done:
								h += step

						# Emit quad
						x[u_axis] = j
						x[v_axis] = v

						var du := Vector3i.ZERO
						var dv := Vector3i.ZERO
						du[u_axis] = w
						dv[v_axis] = h

						var base_y := x[axis] - (0 if backface else step)
						var quad_start := Vector3i(x)
						quad_start[axis] = base_y

						_emit_quad(
							vertices, normals, uvs, colors, indices,
							quad_start, du, dv,
							mask_val, axis, backface, w, h,
							chunk, neighbors
						)

						# Clear mask region
						for row in range(v, v + h, step):
							for col in range(j, j + w, step):
								mask[row * CHUNK_SIZE + col] = 0

						j += w
					i += step

	if vertices.is_empty():
		return []

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR]  = colors
	arrays[Mesh.ARRAY_INDEX]  = indices
	return arrays


# ─── Quad Emission ────────────────────────────────────────────────────────────
func _emit_quad(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs:   PackedVector2Array,
	cols:  PackedColorArray,
	idxs:  PackedInt32Array,
	origin: Vector3i,
	du:     Vector3i,
	dv:     Vector3i,
	voxel:  int,
	axis:   int,
	backface: bool,
	width: int,
	height: int,
	chunk: ChunkData,
	neighbors: Dictionary
) -> void:
	var base_idx := verts.size()
	var normal   := FACE_NORMALS[axis * 2 + (1 if backface else 0)]

	var v0 := Vector3(origin)
	var v1 := Vector3(origin + du)
	var v2 := Vector3(origin + du + dv)
	var v3 := Vector3(origin + dv)

	# Compute AO for each vertex
	var ao0 := _compute_ao(origin,           normal, chunk, neighbors)
	var ao1 := _compute_ao(origin + du,      normal, chunk, neighbors)
	var ao2 := _compute_ao(origin + du + dv, normal, chunk, neighbors)
	var ao3 := _compute_ao(origin + dv,      normal, chunk, neighbors)

	# UV from texture atlas
	var uv_col := _get_atlas_column(voxel, axis, backface)
	var uv_row := _get_atlas_row(voxel)
	var u0     := uv_col * ATLAS_TILE
	var u1     := u0 + ATLAS_TILE
	var v_top  := uv_row * ATLAS_TILE
	var v_bot  := v_top + ATLAS_TILE

	verts.append_array([v0, v1, v2, v3])
	norms.append_array([normal, normal, normal, normal])
	uvs.append_array([
		Vector2(u0, v_bot),
		Vector2(u1, v_bot),
		Vector2(u1, v_top),
		Vector2(u0, v_top),
	])
	cols.append_array([
		Color(ao0, ao0, ao0),
		Color(ao1, ao1, ao1),
		Color(ao2, ao2, ao2),
		Color(ao3, ao3, ao3),
	])

	# Winding order: flip for backface to maintain correct normals
	if backface:
		idxs.append_array([base_idx, base_idx+2, base_idx+1,
		                   base_idx, base_idx+3, base_idx+2])
	else:
		idxs.append_array([base_idx, base_idx+1, base_idx+2,
		                   base_idx, base_idx+2, base_idx+3])


# ─── Ambient Occlusion ────────────────────────────────────────────────────────
## Simple AO: check 3 neighbors around each vertex corner.
## Returns value 0.6 (fully occluded) → 1.0 (open)
func _compute_ao(vertex_pos: Vector3i, face_normal: Vector3,
		chunk: ChunkData, neighbors: Dictionary) -> float:
	var n := Vector3i(face_normal)
	# Two tangent directions for this face
	var t1 : Vector3i
	var t2 : Vector3i

	if n.x != 0:
		t1 = Vector3i(0, 1, 0)
		t2 = Vector3i(0, 0, 1)
	elif n.y != 0:
		t1 = Vector3i(1, 0, 0)
		t2 = Vector3i(0, 0, 1)
	else:
		t1 = Vector3i(1, 0, 0)
		t2 = Vector3i(0, 1, 0)

	# Check 3 neighbors
	var s1 := _is_solid(_get_voxel_safe(chunk, neighbors, vertex_pos + t1 - n))
	var s2 := _is_solid(_get_voxel_safe(chunk, neighbors, vertex_pos + t2 - n))
	var sc := _is_solid(_get_voxel_safe(chunk, neighbors, vertex_pos + t1 + t2 - n))

	var occluded := 0
	if s1: occluded += 1
	if s2: occluded += 1
	if sc and (s1 or s2): occluded += 1

	return 1.0 - occluded * 0.13   # 0 occluders = 1.0, 3 occluders = 0.61


# ─── Face Visibility ──────────────────────────────────────────────────────────
func _should_draw_face(voxel_here: int, voxel_next: int,
		backface: bool, transparent_pass: bool) -> bool:
	if voxel_here == VoxelTypes.AIR:
		return false

	var here_transparent := voxel_here in TRANSPARENT_VOXELS
	var next_transparent := voxel_next in TRANSPARENT_VOXELS

	if transparent_pass:
		# Transparent pass: only draw faces of transparent non-air voxels
		if here_transparent and voxel_here != VoxelTypes.AIR:
			return next_transparent and voxel_next != voxel_here
		return false
	else:
		# Opaque pass: draw face if neighbor is transparent/air
		if here_transparent:
			return false
		return next_transparent


# ─── Safe Voxel Lookup ───────────────────────────────────────────────────────
## Gets voxel at local position, crossing into neighbor chunks as needed.
func _get_voxel_safe(chunk: ChunkData, neighbors: Dictionary, lpos: Vector3i) -> int:
	if lpos.x >= 0 and lpos.x < CHUNK_SIZE and \
	   lpos.y >= 0 and lpos.y < CHUNK_SIZE and \
	   lpos.z >= 0 and lpos.z < CHUNK_SIZE:
		return chunk.get_voxel(lpos)

	# Out of bounds — check neighbor chunk
	var noffset := Vector3i(
		-1 if lpos.x < 0 else (1 if lpos.x >= CHUNK_SIZE else 0),
		-1 if lpos.y < 0 else (1 if lpos.y >= CHUNK_SIZE else 0),
		-1 if lpos.z < 0 else (1 if lpos.z >= CHUNK_SIZE else 0),
	)
	var neighbor := neighbors.get(noffset) as ChunkData
	if neighbor == null:
		return VoxelTypes.AIR   # Treat missing chunk as air

	var nl := Vector3i(
		(lpos.x + CHUNK_SIZE) % CHUNK_SIZE,
		(lpos.y + CHUNK_SIZE) % CHUNK_SIZE,
		(lpos.z + CHUNK_SIZE) % CHUNK_SIZE,
	)
	return neighbor.get_voxel(nl)


# ─── Atlas Lookup ─────────────────────────────────────────────────────────────
func _get_atlas_column(voxel: int, axis: int, backface: bool) -> int:
	# axis 1 = Y axis
	if axis == 1 and not backface:
		return VoxelAtlas.get_top_column(voxel)
	if axis == 1 and backface:
		return VoxelAtlas.get_bottom_column(voxel)
	return VoxelAtlas.get_side_column(voxel)


func _get_atlas_row(voxel: int) -> int:
	return VoxelAtlas.get_row(voxel)


func _is_solid(voxel: int) -> bool:
	return voxel != VoxelTypes.AIR and voxel not in TRANSPARENT_VOXELS


func _get_surface_material(chunk: ChunkData, transparent: bool) -> Material:
	return TerrainMaterialCache.get_material_for(chunk, transparent)
