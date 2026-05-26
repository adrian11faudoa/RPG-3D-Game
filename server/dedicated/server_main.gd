## server/dedicated/server_main.gd
## Dedicated server entry point. Manages player connections, world authority,
## chunk distribution, and authoritative game state.
##
## Run as: godot --headless --script server/dedicated/server_main.gd
##           [--port 7777] [--max-players 64] [--world-seed 12345]
##
## Architecture:
##   - Server is authoritative for: positions, combat, loot, world state
##   - Clients predict locally, server corrects via periodic snapshots
##   - Chunks streamed to clients on demand (per player view distance)
##   - SQLite database stores persistent world state

class_name ServerMain
extends SceneTree

# ─── Configuration ────────────────────────────────────────────────────────────
var _port         : int    = 7777
var _max_players  : int    = 64
var _world_seed   : int    = 0
var _tick_rate    : int    = 20    # State broadcast Hz
var _region       : String = "Unnamed Realm"

# ─── State ────────────────────────────────────────────────────────────────────
var _peer             : ENetMultiplayerPeer
var _connected_players: Dictionary = {}  # peer_id -> ServerPlayerData
var _world_db         : SQLiteDatabase
var _chunk_manager    : ChunkManager
var _entity_manager   : ServerEntityManager
var _tick_timer       : float = 0.0
var _world_time       : float = 0.0  # Seconds since server start (drives day/night)


func _initialize() -> void:
	_parse_args()
	_init_database()
	_init_world()
	_start_network()
	print("[Server] Veilborn dedicated server started on port %d" % _port)
	print("[Server] Max players: %d | Seed: %d | Region: %s" % [_max_players, _world_seed, _region])


func _parse_args() -> void:
	var args := OS.get_cmdline_args()
	for i in args.size():
		match args[i]:
			"--port":        if i + 1 < args.size(): _port        = int(args[i + 1])
			"--max-players": if i + 1 < args.size(): _max_players = int(args[i + 1])
			"--world-seed":  if i + 1 < args.size(): _world_seed  = int(args[i + 1])
			"--region":      if i + 1 < args.size(): _region      = args[i + 1]
	if _world_seed == 0:
		_world_seed = randi()


func _init_database() -> void:
	_world_db = SQLiteDatabase.new()
	_world_db.open("user://server_world.db")
	_world_db.execute("""
		CREATE TABLE IF NOT EXISTS players (
			peer_id    INTEGER,
			username   TEXT UNIQUE,
			position_x REAL, position_y REAL, position_z REAL,
			hp         REAL,
			xp         INTEGER,
			level      INTEGER DEFAULT 1,
			inventory  TEXT,
			skills     TEXT,
			last_seen  INTEGER
		)
	""")
	_world_db.execute("""
		CREATE TABLE IF NOT EXISTS world_state (
			key   TEXT PRIMARY KEY,
			value TEXT
		)
	""")
	_world_db.execute("""
		CREATE TABLE IF NOT EXISTS killed_bosses (
			boss_id TEXT, killed_at INTEGER, killer_peer INTEGER
		)
	""")


func _init_world() -> void:
	# Load or generate world seed from DB
	var stored_seed := _world_db.query_one("SELECT value FROM world_state WHERE key='seed'")
	if stored_seed:
		_world_seed = int(stored_seed["value"])
	else:
		_world_db.execute("INSERT INTO world_state VALUES ('seed', '%d')" % _world_seed)

	_chunk_manager  = ChunkManager.new()
	_chunk_manager.initialize(_world_seed)
	root.add_child(_chunk_manager)

	_entity_manager = ServerEntityManager.new()
	root.add_child(_entity_manager)

	# World time
	var stored_time := _world_db.query_one("SELECT value FROM world_state WHERE key='world_time'")
	if stored_time:
		_world_time = float(stored_time["value"])


func _start_network() -> void:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(_port, _max_players)
	if err != OK:
		push_error("[Server] Failed to bind port %d: %s" % [_port, error_string(err)])
		quit(1)
		return

	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] Listening on port %d" % _port)


# ─── Connection Handling ──────────────────────────────────────────────────────
func _on_peer_connected(peer_id: int) -> void:
	print("[Server] Peer connected: %d (total: %d)" % [peer_id, _connected_players.size() + 1])
	# Send initial handshake
	_rpc_handshake.rpc_id(peer_id, _world_seed, _world_time, _region)


func _on_peer_disconnected(peer_id: int) -> void:
	if not _connected_players.has(peer_id):
		return
	var pd := _connected_players[peer_id] as ServerPlayerData
	print("[Server] Player '%s' disconnected" % pd.username)
	_save_player_data(peer_id)
	# Notify other players
	_rpc_player_left.rpc(peer_id, pd.username)
	_entity_manager.despawn_player(peer_id)
	_connected_players.erase(peer_id)


# ─── Client Authentication ────────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_authenticate(username: String, token: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	# Validate token (in production: verify against auth server)
	if not _validate_token(username, token):
		_rpc_auth_failed.rpc_id(peer_id, "Invalid credentials")
		return

	if _connected_players.size() >= _max_players:
		_rpc_auth_failed.rpc_id(peer_id, "Server full")
		return

	# Check duplicate login
	for pd: ServerPlayerData in _connected_players.values():
		if pd.username == username:
			_rpc_auth_failed.rpc_id(peer_id, "Already logged in")
			return

	# Load or create player data
	var pd := _load_player_data(peer_id, username)
	_connected_players[peer_id] = pd

	# Spawn player entity
	_entity_manager.spawn_player(peer_id, pd)

	# Send player their own state
	_rpc_auth_success.rpc_id(peer_id, pd.to_dict())

	# Notify all others of new player
	_rpc_player_joined.rpc(peer_id, username, pd.position)

	# Send existing players to new client
	for other_id: int in _connected_players.keys():
		if other_id != peer_id:
			var other := _connected_players[other_id] as ServerPlayerData
			_rpc_player_joined.rpc_id(peer_id, other_id, other.username, other.position)

	print("[Server] '%s' authenticated as peer %d" % [username, peer_id])


func _validate_token(username: String, _token: String) -> bool:
	# Stub: in production validate JWT or session token against auth server
	return username.length() >= 3 and username.length() <= 24


func _load_player_data(peer_id: int, username: String) -> ServerPlayerData:
	var pd  := ServerPlayerData.new()
	pd.peer_id   = peer_id
	pd.username  = username
	var row := _world_db.query_one(
		"SELECT * FROM players WHERE username='%s'" % username.replace("'", "''")
	)
	if row:
		pd.position = Vector3(float(row["position_x"]), float(row["position_y"]), float(row["position_z"]))
		pd.hp       = float(row["hp"])
		pd.xp       = int(row["xp"])
		pd.level    = int(row["level"])
		pd.inventory = JSON.parse_string(str(row["inventory"])) if row["inventory"] else {}
		pd.skills    = JSON.parse_string(str(row["skills"]))    if row["skills"]    else {}
	else:
		# New player: find spawn point
		pd.position = _find_spawn_point()
		pd.hp       = 100.0
		pd.xp       = 0
		pd.level    = 1
		pd.inventory = {}
		pd.skills    = {}
	return pd


func _save_player_data(peer_id: int) -> void:
	var pd := _connected_players.get(peer_id) as ServerPlayerData
	if pd == null:
		return
	var pos := pd.position
	_world_db.execute("""
		INSERT OR REPLACE INTO players
		(peer_id, username, position_x, position_y, position_z, hp, xp, level, inventory, skills, last_seen)
		VALUES (%d, '%s', %f, %f, %f, %f, %d, %d, '%s', '%s', %d)
	""" % [
		peer_id, pd.username.replace("'", "''"),
		pos.x, pos.y, pos.z,
		pd.hp, pd.xp, pd.level,
		JSON.stringify(pd.inventory).replace("'", "''"),
		JSON.stringify(pd.skills).replace("'", "''"),
		Time.get_unix_time_from_system()
	])


func _find_spawn_point() -> Vector3:
	# Find a safe surface spawn near world origin
	var attempts := 20
	for _i in attempts:
		var rx := randf_range(-200.0, 200.0)
		var rz := randf_range(-200.0, 200.0)
		var sy  := float(_chunk_manager._terrain_gen.get_surface_height(rx, rz))
		if sy > ChunkManager.SEA_LEVEL + 2:
			return Vector3(rx, sy + 1.5, rz)
	return Vector3(0, ChunkManager.SEA_LEVEL + 10, 0)


# ─── Game State Broadcast ─────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_world_time += delta
	_tick_timer  += delta

	if _tick_timer >= 1.0 / _tick_rate:
		_tick_timer = 0.0
		_broadcast_world_state()
		_save_world_time()


func _broadcast_world_state() -> void:
	if _connected_players.is_empty():
		return

	# Build snapshot of all player positions
	var snapshot := {}
	for peer_id: int in _connected_players.keys():
		var pd := _connected_players[peer_id] as ServerPlayerData
		snapshot[peer_id] = {
			"pos": [pd.position.x, pd.position.y, pd.position.z],
			"rot": pd.rotation_y,
			"vel": [pd.velocity.x, pd.velocity.y, pd.velocity.z],
			"hp":  pd.hp,
			"state": pd.anim_state,
		}

	# Send to each client (only nearby players to save bandwidth)
	for peer_id: int in _connected_players.keys():
		var pd      := _connected_players[peer_id] as ServerPlayerData
		var nearby  := _get_nearby_snapshot(pd.position, snapshot, 200.0)
		_rpc_state_snapshot.rpc_id(peer_id, nearby, _world_time)


func _get_nearby_snapshot(origin: Vector3, snapshot: Dictionary, max_dist: float) -> Dictionary:
	var result: Dictionary = {}
	for pid: int in snapshot.keys():
		var pdata := snapshot[pid]
		var pos   := Vector3(pdata["pos"][0], pdata["pos"][1], pdata["pos"][2])
		if origin.distance_to(pos) <= max_dist:
			result[pid] = pdata
	return result


func _save_world_time() -> void:
	_world_db.execute(
		"INSERT OR REPLACE INTO world_state VALUES ('world_time', '%f')" % _world_time
	)


# ─── Player Update RPC (Client → Server) ─────────────────────────────────────
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_player_update(pos: Array, rot_y: float, vel: Array, anim_state: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var pd      := _connected_players.get(peer_id) as ServerPlayerData
	if pd == null:
		return

	# Server-side position validation (anti-cheat)
	var reported_pos := Vector3(pos[0], pos[1], pos[2])
	var max_move     := 15.0  # max distance per tick at sprint speed
	if pd.position.distance_to(reported_pos) > max_move:
		# Reject and correct client
		_rpc_position_correct.rpc_id(peer_id, pd.position)
		return

	pd.position   = reported_pos
	pd.rotation_y = rot_y
	pd.velocity   = Vector3(vel[0], vel[1], vel[2])
	pd.anim_state = anim_state


# ─── Chunk Request Handling ───────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_chunk(chunk_pos: Vector3i) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	# Verify client is near enough to need this chunk
	var pd      := _connected_players.get(peer_id) as ServerPlayerData
	if pd == null:
		return
	var world_pos := _chunk_manager.chunk_to_world(chunk_pos)
	if pd.position.distance_to(world_pos) > ChunkManager.CHUNK_SIZE * ChunkManager.GENERATE_DISTANCE * 1.5:
		return
	# Ensure chunk is generated
	if not _chunk_manager._active_chunks.has(chunk_pos):
		await _chunk_manager.chunk_loaded
	# Serialize and send chunk data
	var chunk := _chunk_manager._active_chunks.get(chunk_pos) as ChunkData
	if chunk:
		var data := chunk.serialize_rle()   # Run-length encoded voxel data
		_rpc_receive_chunk.rpc_id(peer_id, chunk_pos, data)


# ─── Chat System ─────────────────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_chat_message(message: String) -> void:
	var peer_id  := multiplayer.get_remote_sender_id()
	var pd       := _connected_players.get(peer_id) as ServerPlayerData
	if pd == null or message.is_empty() or message.length() > 256:
		return

	# Sanitize
	message = message.strip_edges().replace("<", "&lt;")

	# Check for admin commands
	if message.begins_with("/") and pd.is_admin:
		_handle_admin_command(peer_id, message)
		return

	# Broadcast to nearby players
	var formatted := "[%s]: %s" % [pd.username, message]
	print("[Chat] " + formatted)
	for other_id: int in _connected_players.keys():
		var other := _connected_players[other_id] as ServerPlayerData
		if pd.position.distance_to(other.position) < 100.0:
			_rpc_receive_chat.rpc_id(other_id, formatted, peer_id)


func _handle_admin_command(peer_id: int, cmd: String) -> void:
	var parts := cmd.split(" ")
	match parts[0]:
		"/tp":
			if parts.size() >= 4:
				var target_pos := Vector3(float(parts[1]), float(parts[2]), float(parts[3]))
				var pd         := _connected_players[peer_id] as ServerPlayerData
				pd.position     = target_pos
				_rpc_position_correct.rpc_id(peer_id, target_pos)
		"/spawn":
			if parts.size() >= 2:
				var pd := _connected_players[peer_id] as ServerPlayerData
				_entity_manager.spawn_creature(parts[1], pd.position + Vector3(3, 0, 0))
		"/kick":
			if parts.size() >= 2:
				var target_name := parts[1]
				for id: int in _connected_players.keys():
					if (_connected_players[id] as ServerPlayerData).username == target_name:
						_peer.disconnect_peer(id)
		"/time":
			if parts.size() >= 2:
				_world_time = float(parts[1]) * 60.0


# ─── RPC Declarations (Server → Client) ──────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_handshake(seed: int, world_time: float, region: String) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_auth_success(player_data: Dictionary) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_auth_failed(reason: String) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_player_joined(peer_id: int, username: String, position: Vector3) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_player_left(peer_id: int, username: String) -> void: pass

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_state_snapshot(snapshot: Dictionary, world_time: float) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_chunk(chunk_pos: Vector3i, data: PackedByteArray) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_position_correct(correct_pos: Vector3) -> void: pass

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_chat(message: String, sender_id: int) -> void: pass
