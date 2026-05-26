## core/networking/client_network_manager.gd
## Client-side network layer: snapshot interpolation, input prediction,
## server reconciliation, chunk request queue, and latency compensation.
##
## Architecture:
##   - Client sends input/position updates at 20Hz to server
##   - Server broadcasts authoritative snapshots at 20Hz
##   - Client interpolates between the two most recent snapshots
##   - Position corrections are smoothly lerped (not snapped) to hide latency
##   - Chunk requests are rate-limited to avoid flooding the server

class_name ClientNetworkManager
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal connected_to_server()
signal disconnected_from_server(reason: String)
signal auth_result(success: bool, reason: String)
signal chat_received(message: String, sender_id: int)
signal chunk_received(chunk_pos: Vector3i, data: PackedByteArray)
signal player_joined(peer_id: int, username: String, position: Vector3)
signal player_left(peer_id: int, username: String)

# ─── Constants ────────────────────────────────────────────────────────────────
const SNAPSHOT_BUFFER_SIZE  : int   = 8      # How many snapshots to buffer
const INTERP_DELAY_MS       : float = 100.0  # Render 100ms behind to ensure two snapshots available
const SEND_RATE_HZ          : float = 20.0
const CHUNK_REQUEST_INTERVAL: float = 0.1    # Min time between chunk requests
const MAX_CORRECTION_DIST   : float = 3.0    # Snap position if correction > this

# ─── Peer State ───────────────────────────────────────────────────────────────
class RemotePlayerState extends RefCounted:
	var peer_id    : int
	var position   : Vector3
	var rotation_y : float
	var velocity   : Vector3
	var hp         : float
	var anim_state : String
	var timestamp  : float

class SnapshotBuffer extends RefCounted:
	var states     : Array[Dictionary] = []   # [{timestamp, players: {id: state}}]
	var max_size   : int = SNAPSHOT_BUFFER_SIZE

	func push(snapshot: Dictionary) -> void:
		states.append(snapshot)
		if states.size() > max_size:
			states.pop_front()

	func get_interp_pair(render_time: float) -> Array:
		## Returns [older, newer] snapshots that bracket render_time
		for i in range(states.size() - 1, 0, -1):
			var newer := states[i]
			var older := states[i - 1]
			if older["timestamp"] <= render_time and render_time <= newer["timestamp"]:
				return [older, newer]
		if states.size() >= 2:
			return [states[-2], states[-1]]
		if states.size() == 1:
			return [states[0], states[0]]
		return []


# ─── State ────────────────────────────────────────────────────────────────────
var _peer               : ENetMultiplayerPeer
var _snapshot_buffer    := SnapshotBuffer.new()
var _remote_players     : Dictionary = {}      # peer_id -> RemotePlayerState
var _local_player       : Node3D
var _world_seed         : int    = 0
var _server_world_time  : float  = 0.0
var _client_time        : float  = 0.0
var _send_timer         : float  = 0.0
var _chunk_req_timer    : float  = 0.0
var _pending_chunks     : Array[Vector3i] = []
var _received_chunks    : Dictionary = {}      # Vector3i -> bool

# Correction smoothing
var _correction_pos     : Vector3 = Vector3.ZERO
var _correction_active  : bool    = false
var _correction_t       : float   = 0.0


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	set_process(true)


# ─── Connection ───────────────────────────────────────────────────────────────
func connect_to_server(address: String, port: int) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		push_error("[Client] Failed to create client: %s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = _peer
	print("[Client] Connecting to %s:%d..." % [address, port])
	return OK


func disconnect_from_server() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
	_remote_players.clear()
	_snapshot_buffer = SnapshotBuffer.new()


func _on_connected() -> void:
	print("[Client] Connected to server")
	connected_to_server.emit()


func _on_connection_failed() -> void:
	print("[Client] Connection failed")
	disconnected_from_server.emit("Connection failed")


func _on_server_disconnected() -> void:
	print("[Client] Server disconnected")
	disconnected_from_server.emit("Server closed connection")
	_remote_players.clear()


# ─── Authentication ───────────────────────────────────────────────────────────
func authenticate(username: String, token: String) -> void:
	_rpc_authenticate.rpc_id(1, username, token)


# ─── Update Loop ──────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_client_time += delta
	_send_timer  += delta
	_chunk_req_timer += delta

	# Send state at SEND_RATE_HZ
	if _send_timer >= 1.0 / SEND_RATE_HZ:
		_send_timer = 0.0
		_send_player_update()

	# Process chunk request queue
	if _chunk_req_timer >= CHUNK_REQUEST_INTERVAL and not _pending_chunks.is_empty():
		_chunk_req_timer = 0.0
		_send_next_chunk_request()

	# Update interpolated remote player positions
	_interpolate_remote_players()

	# Smooth position correction
	if _correction_active:
		_apply_position_correction(delta)


# ─── Player State Sending ─────────────────────────────────────────────────────
func _send_player_update() -> void:
	if _local_player == null or not multiplayer.has_multiplayer_peer():
		return
	var pos := _local_player.global_position
	var ctrl := _local_player.get_node_or_null("PlayerController") as PlayerController
	if ctrl == null:
		return
	var vel   := ctrl.velocity
	var rot_y := _local_player.rotation.y
	var state := PlayerController.LocomotionState.keys()[ctrl._state].to_lower()

	_rpc_player_update.rpc_id(1,
		[pos.x, pos.y, pos.z],
		rot_y,
		[vel.x, vel.y, vel.z],
		state
	)


# ─── Snapshot Interpolation ───────────────────────────────────────────────────
func _interpolate_remote_players() -> void:
	var render_time := _client_time - INTERP_DELAY_MS / 1000.0
	var pair        := _snapshot_buffer.get_interp_pair(render_time)

	if pair.is_empty():
		return

	var older : Dictionary = pair[0]
	var newer : Dictionary = pair[1]

	var dt    := newer["timestamp"] - older["timestamp"]
	var t     := 0.0 if dt <= 0.0 else \
	             (render_time - older["timestamp"]) / dt
	t          = clampf(t, 0.0, 1.0)

	var older_players : Dictionary = older.get("players", {})
	var newer_players : Dictionary = newer.get("players", {})

	for peer_id: int in newer_players.keys():
		if peer_id == multiplayer.get_unique_id():
			continue   # Skip local player

		var old_state := older_players.get(peer_id, newer_players[peer_id]) as Dictionary
		var new_state := newer_players[peer_id] as Dictionary

		var interp := _interpolate_state(old_state, new_state, t)

		# Apply to remote player node
		var remote_node := get_tree().get_nodes_in_group("players").filter(
			func(p): return p.get_multiplayer_authority() == peer_id
		)
		if not remote_node.is_empty():
			var rn := remote_node[0] as Node3D
			rn.global_position = interp["position"]
			rn.rotation.y      = interp["rotation_y"]
			# Update remote player animator
			var at := rn.get_node_or_null("AnimationTree") as AnimationTree
			if at:
				var speed := Vector2(interp["velocity"].x, interp["velocity"].z).length()
				at.set("parameters/speed/blend_position", speed)


func _interpolate_state(old_s: Dictionary, new_s: Dictionary, t: float) -> Dictionary:
	var op := old_s.get("pos", [0.0, 0.0, 0.0]) as Array
	var np := new_s.get("pos", [0.0, 0.0, 0.0]) as Array
	var ov := old_s.get("vel", [0.0, 0.0, 0.0]) as Array
	var nv := new_s.get("vel", [0.0, 0.0, 0.0]) as Array

	return {
		"position":   Vector3(
			lerpf(op[0], np[0], t),
			lerpf(op[1], np[1], t),
			lerpf(op[2], np[2], t)
		),
		"rotation_y": lerpf(float(old_s.get("rot", 0)), float(new_s.get("rot", 0)), t),
		"velocity":   Vector3(
			lerpf(ov[0], nv[0], t),
			lerpf(ov[1], nv[1], t),
			lerpf(ov[2], nv[2], t)
		),
		"hp":         lerpf(float(old_s.get("hp", 100)), float(new_s.get("hp", 100)), t),
		"anim_state": new_s.get("state", "idle"),
	}


# ─── Position Correction ──────────────────────────────────────────────────────
func _apply_position_correction(delta: float) -> void:
	if _local_player == null:
		return
	_correction_t += delta * 5.0   # Correct over ~0.2s
	if _correction_t >= 1.0:
		_local_player.global_position = _correction_pos
		_correction_active = false
		return
	_local_player.global_position = _local_player.global_position.lerp(_correction_pos, _correction_t)


# ─── Chunk Management ─────────────────────────────────────────────────────────
func request_chunk(chunk_pos: Vector3i) -> void:
	if _received_chunks.has(chunk_pos) or chunk_pos in _pending_chunks:
		return
	_pending_chunks.append(chunk_pos)


func _send_next_chunk_request() -> void:
	if _pending_chunks.is_empty():
		return
	var next := _pending_chunks.pop_front() as Vector3i
	_rpc_request_chunk.rpc_id(1, next)


func cancel_chunk_request(chunk_pos: Vector3i) -> void:
	_pending_chunks.erase(chunk_pos)


# ─── Chat ─────────────────────────────────────────────────────────────────────
func send_chat(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	_rpc_chat_message.rpc_id(1, message)


# ─── Remote Player Management ─────────────────────────────────────────────────
func _spawn_remote_player(peer_id: int, username: String, position: Vector3) -> void:
	var player_scene := preload("res://player/remote_player.tscn") as PackedScene
	if player_scene == null:
		return
	var player := player_scene.instantiate() as Node3D
	player.set_multiplayer_authority(peer_id)
	player.global_position = position
	player.set_meta("peer_id", peer_id)
	player.set_meta("username", username)
	player.add_to_group("players")
	player.add_to_group("remote_players")
	get_tree().root.add_child(player)
	print("[Client] Remote player spawned: %s (peer %d)" % [username, peer_id])


func _despawn_remote_player(peer_id: int) -> void:
	for p: Node3D in get_tree().get_nodes_in_group("remote_players"):
		if p.get_multiplayer_authority() == peer_id:
			p.queue_free()
			return


# ─── Server → Client RPCs ────────────────────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_handshake(seed: int, world_time: float, region: String) -> void:
	_world_seed       = seed
	_server_world_time = world_time
	print("[Client] Handshake: seed=%d, region=%s" % [seed, region])


@rpc("authority", "call_remote", "reliable")
func _rpc_auth_success(player_data: Dictionary) -> void:
	print("[Client] Auth success! Loading player data...")
	auth_result.emit(true, "")
	# Initialize local player systems from server data
	if _local_player:
		var inv  := _local_player.get_node_or_null("InventorySystem") as InventorySystem
		var prog := _local_player.get_node_or_null("ProgressionSystem") as ProgressionSystem
		var qs   := _local_player.get_node_or_null("QuestSystem") as QuestSystem
		if inv  and player_data.has("inventory"): inv.deserialize(player_data["inventory"])
		if prog and player_data.has("skills"):    prog.deserialize(player_data["skills"])
		if qs   and player_data.has("quests"):    qs.deserialize(player_data["quests"])


@rpc("authority", "call_remote", "reliable")
func _rpc_auth_failed(reason: String) -> void:
	print("[Client] Auth failed: %s" % reason)
	auth_result.emit(false, reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_player_joined(peer_id: int, username: String, position: Vector3) -> void:
	if peer_id != multiplayer.get_unique_id():
		_spawn_remote_player(peer_id, username, position)
	player_joined.emit(peer_id, username, position)


@rpc("authority", "call_remote", "reliable")
func _rpc_player_left(peer_id: int, username: String) -> void:
	_despawn_remote_player(peer_id)
	player_left.emit(peer_id, username)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_state_snapshot(snapshot: Dictionary, world_time: float) -> void:
	_server_world_time = world_time
	snapshot["timestamp"] = _client_time   # Tag with local time for interpolation
	_snapshot_buffer.push(snapshot)


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_chunk(chunk_pos: Vector3i, data: PackedByteArray) -> void:
	_received_chunks[chunk_pos] = true
	chunk_received.emit(chunk_pos, data)


@rpc("authority", "call_remote", "reliable")
func _rpc_position_correct(correct_pos: Vector3) -> void:
	if _local_player == null:
		return
	var dist := _local_player.global_position.distance_to(correct_pos)
	if dist > MAX_CORRECTION_DIST:
		# Large correction: snap immediately
		_local_player.global_position = correct_pos
	else:
		# Small correction: smooth lerp
		_correction_pos    = correct_pos
		_correction_t      = 0.0
		_correction_active = true


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_chat(message: String, sender_id: int) -> void:
	chat_received.emit(message, sender_id)


# ─── Client → Server RPCs ────────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_authenticate(_username: String, _token: String) -> void: pass

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_player_update(_pos: Array, _rot_y: float,
		_vel: Array, _anim_state: String) -> void: pass

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_chunk(_chunk_pos: Vector3i) -> void: pass

@rpc("any_peer", "call_remote", "reliable")
func _rpc_chat_message(_message: String) -> void: pass


# ─── Latency Utilities ────────────────────────────────────────────────────────
func get_latency_ms() -> float:
	if not multiplayer.has_multiplayer_peer():
		return 0.0
	return float(_peer.get_peer_statistic(1, ENetConnection.HOST_ROUNDTRIP_TIME))


func get_packet_loss() -> float:
	if not multiplayer.has_multiplayer_peer():
		return 0.0
	return float(_peer.get_peer_statistic(1, ENetConnection.HOST_PACKET_LOSS))


func is_connected_to_server() -> bool:
	return multiplayer.has_multiplayer_peer() and \
	       multiplayer.get_unique_id() != 1 and \
	       _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
