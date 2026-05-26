## assets/mods/mod_loader.gd
## Veilborn Modding API — loads mods from user://mods/<mod_name>/
## Each mod has a manifest.json and can provide:
##   - Custom biomes (JSON)
##   - Custom items (JSON)
##   - Custom creatures (JSON)
##   - Custom quests (JSON)
##   - Custom crafting recipes (JSON)
##   - GDScript hooks (event listeners)
##   - Custom scenes (buildings, NPCs, abilities)
##
## Mod load order is determined by manifest dependencies.
## Mods can override base-game definitions by using the same ID.

class_name ModLoader
extends Node

signal mod_loaded(mod_id: String)
signal mod_failed(mod_id: String, reason: String)
signal all_mods_loaded(count: int)

const MOD_DIR          : String = "user://mods/"
const MANIFEST_FILE    : String = "manifest.json"
const MAX_LOAD_ORDER   : int    = 100

# ─── State ────────────────────────────────────────────────────────────────────
var _loaded_mods    : Dictionary = {}   # mod_id -> ModManifest
var _load_order     : Array[String] = []
var _hooks          : Dictionary = {}   # event_name -> Array[Callable]
var _content_registry: Dictionary = {
	"biomes":   {},
	"items":    {},
	"creatures":{},
	"quests":   {},
	"recipes":  {},
	"skills":   {},
	"factions": {},
}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(MOD_DIR)
	_discover_and_load_mods()


# ─── Discovery ────────────────────────────────────────────────────────────────
func _discover_and_load_mods() -> void:
	var dir := DirAccess.open(MOD_DIR)
	if dir == null:
		print("[ModLoader] No mods directory found")
		return

	var manifests: Array[ModManifest] = []

	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			var manifest_path := MOD_DIR + entry + "/" + MANIFEST_FILE
			if FileAccess.file_exists(manifest_path):
				var manifest := _parse_manifest(MOD_DIR + entry + "/", entry)
				if manifest:
					manifests.append(manifest)
				else:
					mod_failed.emit(entry, "Invalid manifest.json")
		entry = dir.get_next()
	dir.list_dir_end()

	# Resolve load order respecting dependencies
	_load_order = _resolve_load_order(manifests)

	# Load each mod in order
	for mod_id: String in _load_order:
		var manifest := manifests.filter(func(m): return m.id == mod_id)
		if not manifest.is_empty():
			_load_mod(manifest[0])

	print("[ModLoader] Loaded %d mods: %s" % [_loaded_mods.size(), str(_load_order)])
	all_mods_loaded.emit(_loaded_mods.size())


func _parse_manifest(mod_path: String, folder_name: String) -> ModManifest:
	var path   := mod_path + MANIFEST_FILE
	var text   := FileAccess.open(path, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if not parsed is Dictionary:
		return null
	return ModManifest.from_dict(parsed, mod_path, folder_name)


func _resolve_load_order(manifests: Array[ModManifest]) -> Array[String]:
	# Topological sort by dependencies
	var resolved  : Array[String]  = []
	var visited   : Dictionary     = {}
	var in_stack  : Dictionary     = {}
	var id_to_man : Dictionary     = {}

	for m: ModManifest in manifests:
		id_to_man[m.id] = m

	func visit(mod_id: String) -> bool:
		if in_stack.get(mod_id, false):
			push_error("[ModLoader] Circular dependency: %s" % mod_id)
			return false
		if visited.get(mod_id, false):
			return true
		in_stack[mod_id] = true
		var man := id_to_man.get(mod_id) as ModManifest
		if man:
			for dep: String in man.dependencies:
				if not id_to_man.has(dep):
					push_warning("[ModLoader] Missing dependency '%s' for mod '%s'" % [dep, mod_id])
					continue
				if not visit.call(dep):
					return false
		in_stack[mod_id] = false
		visited[mod_id]  = true
		resolved.append(mod_id)
		return true

	for m: ModManifest in manifests:
		visit.call(m.id)

	return resolved


# ─── Mod Loading ──────────────────────────────────────────────────────────────
func _load_mod(manifest: ModManifest) -> void:
	print("[ModLoader] Loading: %s v%s by %s" % [manifest.name, manifest.version, manifest.author])

	var success := true

	# Load data files
	for data_type in ["biomes", "items", "creatures", "quests", "recipes", "skills", "factions"]:
		var file_path := manifest.path + data_type + ".json"
		if FileAccess.file_exists(file_path):
			if not _load_json_content(manifest.id, data_type, file_path):
				push_warning("[ModLoader] Failed to load %s/%s.json" % [manifest.id, data_type])

	# Load GDScript hooks
	var hooks_path := manifest.path + "hooks.gd"
	if FileAccess.file_exists(hooks_path):
		_load_hooks(manifest.id, hooks_path)

	# Load custom scenes
	for scene_entry: Dictionary in manifest.scenes:
		var scene_path := manifest.path + str(scene_entry.get("file", ""))
		if FileAccess.file_exists(scene_path):
			_register_scene(str(scene_entry.get("type", "")),
				str(scene_entry.get("id", "")), scene_path)

	if success:
		_loaded_mods[manifest.id] = manifest
		mod_loaded.emit(manifest.id)
		print("[ModLoader] ✓ Loaded: %s" % manifest.name)
	else:
		mod_failed.emit(manifest.id, "Load errors encountered")


func _load_json_content(mod_id: String, content_type: String, file_path: String) -> bool:
	var text   := FileAccess.open(file_path, FileAccess.READ).get_as_text()
	var parsed := JSON.parse_string(text)
	if not parsed is Dictionary:
		return false

	var registry := _content_registry[content_type] as Dictionary

	for entry_id: String in parsed.keys():
		if entry_id.begins_with("_"):
			continue   # Skip comment/metadata keys
		var full_id := "%s:%s" % [mod_id, entry_id]
		registry[full_id] = parsed[entry_id]
		# Also register without prefix if override
		if parsed[entry_id].get("override_base", false):
			registry[entry_id] = parsed[entry_id]

	_inject_content(content_type, registry)
	return true


func _inject_content(content_type: String, new_data: Dictionary) -> void:
	# Merge into the live game systems
	match content_type:
		"items":
			InventorySystem._registry_loaded = false
			for item_id: String in new_data.keys():
				InventorySystem._item_registry[item_id] = \
					InventorySystem.ItemDefinition.from_dict(item_id, new_data[item_id])
		"biomes":
			var br := get_node_or_null("/root/BiomeRegistry")
			if br:
				for biome_id: String in new_data.keys():
					br.call("register_biome_raw", biome_id, new_data[biome_id])
		"skills":
			# Skills are reloaded by ProgressionSystem on next init
			pass
		"recipes":
			var cs := get_node_or_null("/root/CraftingSystem")
			if cs:
				for recipe_id: String in new_data.keys():
					var def := CraftingSystem.RecipeData.from_dict(recipe_id, new_data[recipe_id])
					cs._recipes[recipe_id] = def


func _load_hooks(mod_id: String, hooks_path: String) -> void:
	var script := load(hooks_path) as GDScript
	if script == null:
		push_warning("[ModLoader] Failed to load hooks: %s" % hooks_path)
		return
	var instance := script.new()
	instance.set_meta("mod_id", mod_id)

	# Check for hook methods and register them
	var hook_names := [
		"on_player_joined", "on_player_left", "on_creature_spawned",
		"on_item_picked_up", "on_quest_completed", "on_level_up",
		"on_biome_entered", "on_dungeon_entered", "on_boss_killed",
		"on_chunk_generated", "on_npc_talked", "on_craft_completed",
	]
	for hook in hook_names:
		if instance.has_method(hook):
			if not _hooks.has(hook):
				_hooks[hook] = []
			_hooks[hook].append(Callable(instance, hook))
			print("[ModLoader] Registered hook: %s.%s" % [mod_id, hook])


func _register_scene(scene_type: String, scene_id: String, scene_path: String) -> void:
	# Register custom scenes for buildings, creatures, abilities, etc.
	var full_id := scene_type + "/" + scene_id
	ResourceLoader.load_threaded_request(scene_path)
	print("[ModLoader] Registered scene: %s → %s" % [full_id, scene_path])


# ─── Hook Firing ──────────────────────────────────────────────────────────────
## Call this from game systems to fire mod hooks.
func fire_hook(event_name: String, args: Array = []) -> void:
	var callbacks := _hooks.get(event_name, []) as Array
	for cb: Callable in callbacks:
		if cb.is_valid():
			cb.callv(args)


# ─── API for Mods ─────────────────────────────────────────────────────────────
## Mods can call these from their hooks.gd

## Register a new event hook from a mod script.
func register_hook(event_name: String, callable: Callable) -> void:
	if not _hooks.has(event_name):
		_hooks[event_name] = []
	_hooks[event_name].append(callable)


## Get a reference to a core game system by name.
func get_system(system_name: String) -> Node:
	return get_node_or_null("/root/%s" % system_name)


## Register a custom item definition at runtime.
func register_item(item_id: String, item_data: Dictionary) -> void:
	InventorySystem._item_registry[item_id] = \
		InventorySystem.ItemDefinition.from_dict(item_id, item_data)
	print("[ModLoader API] Registered item: %s" % item_id)


## Register a custom crafting recipe at runtime.
func register_recipe(recipe_id: String, recipe_data: Dictionary) -> void:
	var cs := get_system("CraftingSystem") as CraftingSystem
	if cs:
		cs._recipes[recipe_id] = CraftingSystem.RecipeData.from_dict(recipe_id, recipe_data)


## Register a custom creature at runtime.
func register_creature(creature_id: String, creature_data: Dictionary) -> void:
	var cr := get_system("CreatureRegistry")
	if cr:
		cr.call("register_raw", creature_id, creature_data)


## Spawn an entity (convenience wrapper for mods).
func spawn_entity(entity_type: String, position: Vector3) -> Node3D:
	var em := get_system("EntityManager")
	if em:
		return em.call("spawn_creature", entity_type, position)
	return null


## Get the local player node.
func get_local_player() -> Node3D:
	for p: Node3D in get_tree().get_nodes_in_group("players"):
		if p.is_multiplayer_authority():
			return p
	return null


## Give an item to the local player.
func give_player_item(item_id: String, amount: int = 1) -> bool:
	var player := get_local_player()
	if player == null:
		return false
	var inv := player.get_node_or_null("InventorySystem") as InventorySystem
	return inv != null and inv.add_item(item_id, amount)


## Get list of all loaded mods.
func get_loaded_mods() -> Array[ModManifest]:
	return _loaded_mods.values() as Array[ModManifest]


func is_mod_loaded(mod_id: String) -> bool:
	return _loaded_mods.has(mod_id)


# ─── Data Classes ─────────────────────────────────────────────────────────────
class ModManifest extends RefCounted:
	var id           : String
	var name         : String
	var version      : String
	var author       : String
	var description  : String
	var path         : String
	var dependencies : Array[String] = []
	var scenes       : Array = []
	var tags         : Array = []

	static func from_dict(d: Dictionary, mod_path: String, folder: String) -> ModManifest:
		var m          := ModManifest.new()
		m.id            = str(d.get("id",          folder))
		m.name          = str(d.get("name",        folder))
		m.version       = str(d.get("version",     "1.0.0"))
		m.author        = str(d.get("author",      "Unknown"))
		m.description   = str(d.get("description", ""))
		m.path          = mod_path
		m.dependencies  = d.get("dependencies", [])
		m.scenes        = d.get("scenes",       [])
		m.tags          = d.get("tags",         [])
		return m
