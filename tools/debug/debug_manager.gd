## tools/debug/debug_manager.gd
## In-game debug overlay with: chunk visualizer, AI state inspector,
## performance profiler, spawn tools, and admin command console.
## Toggle with F3 (like Minecraft debug screen).

class_name DebugManager
extends CanvasLayer

# ─── Signals ──────────────────────────────────────────────────────────────────
signal command_executed(cmd: String, result: String)

# ─── Nodes ────────────────────────────────────────────────────────────────────
@onready var _root_panel       : Panel          = $DebugPanel
@onready var _perf_label       : RichTextLabel  = $DebugPanel/VBox/PerfLabel
@onready var _world_label      : RichTextLabel  = $DebugPanel/VBox/WorldLabel
@onready var _player_label     : RichTextLabel  = $DebugPanel/VBox/PlayerLabel
@onready var _network_label    : RichTextLabel  = $DebugPanel/VBox/NetworkLabel
@onready var _console_input    : LineEdit        = $ConsolePanel/Input
@onready var _console_output   : RichTextLabel  = $ConsolePanel/Output
@onready var _console_panel    : Panel          = $ConsolePanel
@onready var _chunk_overlay    : Node3D          = $ChunkOverlay3D
@onready var _ai_overlay       : Node3D          = $AIOverlay3D

# ─── State ────────────────────────────────────────────────────────────────────
var _visible          : bool = false
var _console_open     : bool = false
var _show_chunks      : bool = false
var _show_ai          : bool = false
var _show_collision   : bool = false
var _cmd_history      : Array[String] = []
var _history_index    : int = -1
var _chunk_manager    : ChunkManager
var _update_timer     : float = 0.0
const UPDATE_INTERVAL : float = 0.1

# Command registry
var _commands         : Dictionary = {}


func _ready() -> void:
	_root_panel.hide()
	_console_panel.hide()
	_register_commands()
	_console_input.text_submitted.connect(_on_command_submitted)
	set_process(true)
	set_process_input(true)
	print("[Debug] DebugManager initialized. Press F3 to toggle.")


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_toggle"):           # F3
		_toggle_debug()
	elif event.is_action_pressed("debug_console"):        # ~  or  `
		_toggle_console()
	elif event.is_action_pressed("debug_chunks"):         # F4
		_toggle_chunk_overlay()
	elif event.is_action_pressed("debug_ai"):             # F5
		_toggle_ai_overlay()
	elif _console_open and event.is_action_pressed("ui_up"):
		_history_navigate(-1)
	elif _console_open and event.is_action_pressed("ui_down"):
		_history_navigate(1)


func _process(delta: float) -> void:
	if not _visible:
		return
	_update_timer += delta
	if _update_timer < UPDATE_INTERVAL:
		return
	_update_timer = 0.0
	_refresh_panels()


# ─── Panel Updates ────────────────────────────────────────────────────────────
func _refresh_panels() -> void:
	_update_performance()
	_update_world_info()
	_update_player_info()
	_update_network_info()
	if _show_chunks: _update_chunk_overlay()
	if _show_ai:     _update_ai_overlay()


func _update_performance() -> void:
	var fps        := Engine.get_frames_per_second()
	var frame_ms   := 1000.0 / maxf(fps, 1.0)
	var mem_static := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var mem_peak   := Performance.get_monitor(Performance.MEMORY_STATIC_MAX) / 1048576.0
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var triangles  := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var objects    := Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0

	var fps_color := "green" if fps >= 55 else ("yellow" if fps >= 30 else "red")
	_perf_label.clear()
	_perf_label.append_text("[b]PERFORMANCE[/b]\n")
	_perf_label.append_text("[color=%s]FPS: %d (%.1f ms)[/color]\n" % [fps_color, fps, frame_ms])
	_perf_label.append_text("Physics: %.2f ms\n" % physics_ms)
	_perf_label.append_text("Memory: %.1f / %.1f MB\n" % [mem_static, mem_peak])
	_perf_label.append_text("Draw Calls: %d\n" % draw_calls)
	_perf_label.append_text("Triangles: %d\n" % int(triangles))
	_perf_label.append_text("Objects: %d\n" % int(objects))


func _update_world_info() -> void:
	var cm       := _get_chunk_manager()
	var weather  := get_node_or_null("/root/WeatherSystem") as WeatherSystem

	_world_label.clear()
	_world_label.append_text("[b]WORLD[/b]\n")

	if cm:
		var player := _get_local_player()
		if player:
			var cpos := cm.world_to_chunk(player.global_position)
			_world_label.append_text("Chunk: %s\n" % str(cpos))
		_world_label.append_text("Active Chunks: %d\n" % cm._active_chunks.size())
		_world_label.append_text("Pending Gen: %d\n"   % cm._pending_gen.size())
		_world_label.append_text("Pending Mesh: %d\n"  % cm._pending_mesh.size())
		_world_label.append_text("Seed: %d\n"          % cm._world_seed)

	if weather:
		_world_label.append_text("Time: %s\n"    % weather.get_time_string())
		_world_label.append_text("Weather: %s\n" % WeatherSystem.WeatherState.keys()[weather._current_weather])
		_world_label.append_text("Biome: %s\n"   % weather._current_biome)


func _update_player_info() -> void:
	var player := _get_local_player()
	_player_label.clear()
	_player_label.append_text("[b]PLAYER[/b]\n")

	if not player:
		_player_label.append_text("No local player\n")
		return

	var pos := player.global_position
	_player_label.append_text("Pos: (%.1f, %.1f, %.1f)\n" % [pos.x, pos.y, pos.z])

	if player.has_node("PlayerController"):
		var ctrl := player.get_node("PlayerController") as PlayerController
		var vel  := ctrl.velocity
		_player_label.append_text("Vel: (%.1f, %.1f, %.1f)\n" % [vel.x, vel.y, vel.z])
		_player_label.append_text("Speed: %.1f\n" % Vector2(vel.x, vel.z).length())
		_player_label.append_text("State: %s\n"   % PlayerController.LocomotionState.keys()[ctrl._state])
		_player_label.append_text("Stamina: %.0f/%.0f\n" % [ctrl._stamina, ctrl.max_stamina])

	if player.has_node("ProgressionSystem"):
		var prog := player.get_node("ProgressionSystem") as ProgressionSystem
		_player_label.append_text("Level: %d | XP: %d\n" % [prog.get_level(), prog.get_current_xp()])

	if player.has_node("InventorySystem"):
		var inv := player.get_node("InventorySystem") as InventorySystem
		_player_label.append_text("Weight: %.1f\n" % inv.get_total_weight())
		_player_label.append_text("Gold: %d\n"     % inv.get_gold())


func _update_network_info() -> void:
	_network_label.clear()
	_network_label.append_text("[b]NETWORK[/b]\n")

	if not multiplayer.has_multiplayer_peer():
		_network_label.append_text("Offline\n")
		return

	_network_label.append_text("Peer ID: %d\n"     % multiplayer.get_unique_id())
	_network_label.append_text("Is Server: %s\n"   % str(multiplayer.is_server()))
	_network_label.append_text("Connected Peers: %d\n" % multiplayer.get_peers().size())


# ─── Chunk Overlay ────────────────────────────────────────────────────────────
func _update_chunk_overlay() -> void:
	# Clear old mesh
	for child in _chunk_overlay.get_children():
		child.queue_free()

	var cm := _get_chunk_manager()
	if not cm:
		return

	var player := _get_local_player()
	if not player:
		return

	var player_chunk := cm.world_to_chunk(player.global_position)

	for cpos: Vector3i in cm._active_chunks.keys():
		var dist    := (player_chunk - cpos).length()
		var lod     := cm._get_lod_for_chunk(cpos)
		var color   := _get_chunk_color(lod, cpos in cm._pending_mesh)
		_draw_chunk_box(cpos, cm.CHUNK_SIZE, color)


func _draw_chunk_box(cpos: Vector3i, size: int, color: Color) -> void:
	var world_pos := Vector3(cpos) * size
	var mi        := MeshInstance3D.new()
	var im        := ImmediateMesh.new()
	mi.mesh        = im
	mi.material_override = _make_wire_material(color)
	_chunk_overlay.add_child(mi)

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var s := float(size)
	var corners := [
		Vector3(0,0,0), Vector3(s,0,0), Vector3(s,0,s), Vector3(0,0,s),
		Vector3(0,s,0), Vector3(s,s,0), Vector3(s,s,s), Vector3(0,s,s),
	]
	var edges := [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]
	for edge in edges:
		im.surface_add_vertex(world_pos + corners[edge[0]])
		im.surface_add_vertex(world_pos + corners[edge[1]])
	im.surface_end()


func _get_chunk_color(lod: int, pending: bool) -> Color:
	if pending: return Color.YELLOW
	match lod:
		0: return Color.GREEN
		1: return Color.CYAN
		2: return Color.BLUE
		_: return Color(0.5, 0.5, 0.5, 0.5)


func _make_wire_material(color: Color) -> StandardMaterial3D:
	var mat             := StandardMaterial3D.new()
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color     = color
	mat.flags_no_depth_test = true
	return mat


# ─── AI Overlay ───────────────────────────────────────────────────────────────
func _update_ai_overlay() -> void:
	for child in _ai_overlay.get_children():
		child.queue_free()

	for creature: Node3D in get_tree().get_nodes_in_group("creatures"):
		var ai := creature.get_node_or_null("CreatureAI") as CreatureAI
		if not ai:
			continue

		# State label above creature
		var label  := Label3D.new()
		label.text  = "[%s]\nTarget: %s\nHP: %.0f" % [
			_get_state_label(ai.bb),
			ai.bb["target"].name if ai.bb["target"] and is_instance_valid(ai.bb["target"]) else "None",
			CombatSystem.get_actor_hp(creature),
		]
		label.font_size      = 32
		label.billboard      = BaseMaterial3D.BILLBOARD_ENABLED
		label.position       = Vector3.UP * 3.0
		label.modulate       = _get_ai_state_color(ai.bb)
		creature.add_child(label)

		# Draw line to target
		if ai.bb["target"] and is_instance_valid(ai.bb["target"]):
			_draw_line_3d(creature.global_position + Vector3.UP,
				ai.bb["target"].global_position + Vector3.UP, Color.RED)

		# Patrol target
		if ai.bb.get("patrol_target"):
			_draw_line_3d(creature.global_position, ai.bb["patrol_target"], Color.GREEN)


func _get_state_label(bb: Dictionary) -> String:
	if bb["in_combat"]:   return "COMBAT"
	if bb["alerted"]:     return "ALERT"
	if bb["target"]:      return "CHASE"
	return "PATROL"

func _get_ai_state_color(bb: Dictionary) -> Color:
	if bb["in_combat"]:   return Color.RED
	if bb["alerted"]:     return Color.ORANGE
	return Color.WHITE


func _draw_line_3d(from: Vector3, to: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	mi.material_override = _make_wire_material(color)
	_ai_overlay.add_child(mi)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from)
	im.surface_add_vertex(to)
	im.surface_end()


# ─── Console Commands ─────────────────────────────────────────────────────────
func _register_commands() -> void:
	_commands = {
		"help":      _cmd_help,
		"tp":        _cmd_teleport,
		"spawn":     _cmd_spawn,
		"kill":      _cmd_kill_all,
		"give":      _cmd_give,
		"time":      _cmd_set_time,
		"weather":   _cmd_set_weather,
		"level":     _cmd_set_level,
		"god":       _cmd_god_mode,
		"noclip":    _cmd_noclip,
		"fps":       _cmd_show_fps,
		"chunks":    _cmd_chunk_stats,
		"reload":    _cmd_reload_defs,
		"xp":        _cmd_add_xp,
		"gold":      _cmd_add_gold,
		"dungeon":   _cmd_generate_dungeon,
		"biome":     _cmd_biome_info,
		"quest":     _cmd_quest_control,
		"rep":       _cmd_set_rep,
		"clear":     func(_a): _console_output.clear(),
	}


func _on_command_submitted(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	_cmd_history.append(text)
	_history_index = _cmd_history.size()
	_console_input.clear()

	var parts   := text.strip_edges().split(" ")
	var cmd     := parts[0].to_lower()
	var args    := parts.slice(1)

	_console_log("> " + text, Color.GRAY)

	if _commands.has(cmd):
		var result := (_commands[cmd] as Callable).call(args) as String
		if not result.is_empty():
			_console_log(result, Color.WHITE)
		command_executed.emit(text, result)
	else:
		_console_log("Unknown command: '%s'. Type 'help' for list." % cmd, Color.ORANGE)


func _console_log(text: String, color: Color = Color.WHITE) -> void:
	_console_output.push_color(color)
	_console_output.append_text(text + "\n")
	_console_output.pop()


func _history_navigate(dir: int) -> void:
	_history_index = clampi(_history_index + dir, 0, _cmd_history.size())
	if _history_index < _cmd_history.size():
		_console_input.text = _cmd_history[_history_index]
	else:
		_console_input.text = ""


# ─── Command Implementations ──────────────────────────────────────────────────
func _cmd_help(_args: Array) -> String:
	return "Commands: " + ", ".join(_commands.keys())

func _cmd_teleport(args: Array) -> String:
	if args.size() < 3:
		return "Usage: tp <x> <y> <z>"
	var player := _get_local_player()
	if not player:
		return "No local player"
	player.global_position = Vector3(float(args[0]), float(args[1]), float(args[2]))
	return "Teleported to (%.1f, %.1f, %.1f)" % [float(args[0]), float(args[1]), float(args[2])]

func _cmd_spawn(args: Array) -> String:
	if args.size() < 1:
		return "Usage: spawn <creature_id>"
	var player := _get_local_player()
	if not player:
		return "No local player"
	var em := get_node_or_null("/root/EntityManager")
	if em:
		em.call("spawn_creature", args[0], player.global_position + Vector3(3, 0, 0))
	return "Spawned: " + args[0]

func _cmd_kill_all(_args: Array) -> String:
	var count := 0
	for c: Node3D in get_tree().get_nodes_in_group("creatures"):
		c.queue_free()
		count += 1
	return "Killed %d creatures" % count

func _cmd_give(args: Array) -> String:
	if args.size() < 1:
		return "Usage: give <item_id> [amount]"
	var player := _get_local_player()
	if not player:
		return "No local player"
	var inv    := player.get_node_or_null("InventorySystem") as InventorySystem
	if not inv:
		return "Player has no inventory"
	var amount := int(args[1]) if args.size() >= 2 else 1
	inv.add_item(args[0], amount)
	return "Added %d x %s" % [amount, args[0]]

func _cmd_set_time(args: Array) -> String:
	if args.size() < 1:
		return "Usage: time <hour> (0-24)"
	var ws := get_node_or_null("/root/WeatherSystem") as WeatherSystem
	if not ws:
		return "No weather system"
	var hour := float(args[0])
	ws._world_time = (hour / 24.0) * WeatherSystem.DAY_LENGTH_SECONDS
	return "Time set to %.1f:00" % hour

func _cmd_set_weather(args: Array) -> String:
	if args.size() < 1:
		return "Usage: weather <CLEAR|RAIN|STORM|SNOW|FOG>"
	var ws := get_node_or_null("/root/WeatherSystem") as WeatherSystem
	if not ws:
		return "No weather system"
	var name_map := {
		"clear": WeatherSystem.WeatherState.CLEAR,
		"rain":  WeatherSystem.WeatherState.HEAVY_RAIN,
		"storm": WeatherSystem.WeatherState.THUNDERSTORM,
		"snow":  WeatherSystem.WeatherState.BLIZZARD,
		"fog":   WeatherSystem.WeatherState.FOG,
	}
	var key := args[0].to_lower()
	if name_map.has(key):
		ws.request_weather(name_map[key])
		return "Weather changed to: " + args[0]
	return "Unknown weather: " + args[0]

func _cmd_set_level(args: Array) -> String:
	if args.size() < 1:
		return "Usage: level <number>"
	var player := _get_local_player()
	if not player:
		return "No local player"
	var prog := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
	if not prog:
		return "No progression system"
	var target := int(args[0])
	while prog.get_level() < target:
		prog.add_xp(prog.xp_for_level(prog.get_level() + 1), "debug")
	return "Level set to %d" % prog.get_level()

func _cmd_god_mode(args: Array) -> String:
	# Toggle invincibility
	var player := _get_local_player()
	if not player:
		return "No local player"
	var god := not player.get_meta("god_mode", false)
	player.set_meta("god_mode", god)
	return "God mode: %s" % ("ON" if god else "OFF")

func _cmd_noclip(_args: Array) -> String:
	var player := _get_local_player()
	if not player:
		return "No local player"
	var nc := not player.get_meta("noclip", false)
	player.set_meta("noclip", nc)
	if player is CharacterBody3D:
		player.collision_mask = 0 if nc else 1
	return "Noclip: %s" % ("ON" if nc else "OFF")

func _cmd_show_fps(_args: Array) -> String:
	return "FPS: %d | Frame: %.2f ms" % [
		Engine.get_frames_per_second(),
		1000.0 / maxf(Engine.get_frames_per_second(), 1)
	]

func _cmd_chunk_stats(_args: Array) -> String:
	var cm := _get_chunk_manager()
	if not cm:
		return "No chunk manager"
	return "Active: %d | Pending Gen: %d | Pending Mesh: %d" % [
		cm._active_chunks.size(), cm._pending_gen.size(), cm._pending_mesh.size()
	]

func _cmd_reload_defs(_args: Array) -> String:
	InventorySystem._registry_loaded = false
	InventorySystem._load_item_registry()
	return "Reloaded item registry (%d items)" % InventorySystem._item_registry.size()

func _cmd_add_xp(args: Array) -> String:
	if args.size() < 1:
		return "Usage: xp <amount>"
	var player := _get_local_player()
	if not player:
		return "No local player"
	var prog := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
	if not prog:
		return "No progression system"
	var amt := int(args[0])
	prog.add_xp(amt, "debug")
	return "Added %d XP. Level: %d" % [amt, prog.get_level()]

func _cmd_add_gold(args: Array) -> String:
	if args.size() < 1:
		return "Usage: gold <amount>"
	var player := _get_local_player()
	if not player:
		return "No local player"
	var inv := player.get_node_or_null("InventorySystem") as InventorySystem
	if not inv:
		return "No inventory"
	inv.add_gold(int(args[0]))
	return "Added %d gold. Total: %d" % [int(args[0]), inv.get_gold()]

func _cmd_generate_dungeon(args: Array) -> String:
	var theme := args[0] if args.size() > 0 else "stone_ruins"
	var diff  := int(args[1]) if args.size() > 1 else 2
	var player := _get_local_player()
	if not player:
		return "No player"
	var cfg           := DungeonGenerator.DungeonConfig.new()
	cfg.seed           = randi()
	cfg.theme          = theme
	cfg.difficulty     = diff
	cfg.floor_level    = int(player.global_position.y)
	var gen            := DungeonGenerator.new()
	var data           := gen.generate(cfg)
	return "Generated dungeon: %d rooms, %d enemies, theme=%s" % [data.rooms.size(), data.total_enemies, theme]

func _cmd_biome_info(_args: Array) -> String:
	var ws := get_node_or_null("/root/WeatherSystem") as WeatherSystem
	if ws:
		return "Current biome: %s" % ws._current_biome
	return "No weather system"

func _cmd_quest_control(args: Array) -> String:
	if args.size() < 2:
		return "Usage: quest <accept|complete|fail> <quest_id>"
	var player := _get_local_player()
	if not player:
		return "No player"
	var qs := player.get_node_or_null("QuestSystem") as QuestSystem
	if not qs:
		return "No quest system"
	match args[0]:
		"accept":   return "Accepted: %s" % str(qs.accept_quest(args[1]))
		"complete": qs.notify_kill("debug", Vector3.ZERO); return "Notified kill"
		"fail":     qs.fail_quest(args[1], "Debug forced"); return "Failed: " + args[1]
	return "Unknown subcommand"

func _cmd_set_rep(args: Array) -> String:
	if args.size() < 2:
		return "Usage: rep <faction_id> <amount>"
	var player := _get_local_player()
	if not player:
		return "No player"
	var fs := player.get_node_or_null("FactionSystem") as FactionSystem
	if not fs:
		return "No faction system"
	fs.add_reputation(args[0], int(args[1]), "debug")
	return "%s rep: %d" % [args[0], fs.get_reputation(args[0])]


# ─── Toggles ──────────────────────────────────────────────────────────────────
func _toggle_debug() -> void:
	_visible = not _visible
	_root_panel.visible = _visible


func _toggle_console() -> void:
	_console_open = not _console_open
	_console_panel.visible = _console_open
	if _console_open:
		_console_input.grab_focus()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _toggle_chunk_overlay() -> void:
	_show_chunks = not _show_chunks
	if not _show_chunks:
		for child in _chunk_overlay.get_children():
			child.queue_free()
	_console_log("Chunk overlay: %s" % ("ON" if _show_chunks else "OFF"))


func _toggle_ai_overlay() -> void:
	_show_ai = not _show_ai
	if not _show_ai:
		for child in _ai_overlay.get_children():
			child.queue_free()
	_console_log("AI overlay: %s" % ("ON" if _show_ai else "OFF"))


# ─── Utility ──────────────────────────────────────────────────────────────────
func _get_local_player() -> Node3D:
	for p: Node3D in get_tree().get_nodes_in_group("players"):
		if p.is_multiplayer_authority():
			return p
	return null


func _get_chunk_manager() -> ChunkManager:
	if _chunk_manager and is_instance_valid(_chunk_manager):
		return _chunk_manager
	_chunk_manager = get_node_or_null("/root/ChunkManager")
	return _chunk_manager
