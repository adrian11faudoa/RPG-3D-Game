## assets/mods/example_mod/hooks.gd
## Frostlands Expansion — GDScript hooks
## Demonstrates the Veilborn mod hook system.
##
## The ModLoader instantiates this script and calls matching methods
## when game events fire. Access the API via the "mod" autoload.

extends Node

var _mod_loader : ModLoader

func _ready() -> void:
	_mod_loader = get_node_or_null("/root/ModLoader")
	print("[FrostlandsExpansion] Hooks initialized")

	# Register additional hooks at runtime (optional — can also rely on method names)
	_mod_loader.register_hook("on_boss_killed", _on_any_boss_killed)


# ─── Hook: Player Joins ───────────────────────────────────────────────────────
## Called when a player connects (singleplayer: called on game start).
func on_player_joined(player: Node3D) -> void:
	print("[FrostlandsExpansion] Player joined: %s" % player.get_meta("username", "?"))
	# Give new players a starter frostite shard
	_mod_loader.give_player_item("frostlands_expansion:frostite_shard_small", 3)


# ─── Hook: Biome Entered ──────────────────────────────────────────────────────
func on_biome_entered(player: Node3D, biome_id: String) -> void:
	if biome_id != "frostlands_expansion:deep_glacier":
		return
	# Show a unique notification when entering our custom biome
	if player.has_method("show_notification"):
		player.show_notification(
			"❄️ Deep Glacier",
			"The air crystallizes around you. Ancient frost energies stir.",
			Color(0.5, 0.8, 1.0)
		)
	# Spawn a special creature event with 20% chance
	if randf() < 0.20:
		var pos := player.global_position + Vector3(randi_range(-20, 20), 0, randi_range(-20, 20))
		_mod_loader.spawn_entity("frostlands_expansion:frost_stalker", pos)


# ─── Hook: Quest Completed ────────────────────────────────────────────────────
func on_quest_completed(player: Node3D, quest_id: String) -> void:
	# Unlock our special quest after the main tundra quest line
	if quest_id == "tundra_elder_quest_3":
		var qs := player.get_node_or_null("QuestSystem") as QuestSystem
		if qs and qs.can_accept("frostlands_expansion:ancient_wyrm_hunt"):
			qs.accept_quest("frostlands_expansion:ancient_wyrm_hunt")
			print("[FrostlandsExpansion] Unlocked Ancient Frost Wyrm hunt!")


# ─── Hook: Level Up ───────────────────────────────────────────────────────────
func on_level_up(player: Node3D, new_level: int) -> void:
	# At level 15, give the player a frost affinity passive
	if new_level == 15:
		var prog := player.get_node_or_null("ProgressionSystem") as ProgressionSystem
		if prog:
			# Register our custom skill if not already present
			_ensure_frost_skill_registered()
			# Unlock it for free as a reward
			prog._skill_points += 1
			prog.unlock_skill("frostlands_expansion:frost_affinity")
			if player.has_method("show_notification"):
				player.show_notification(
					"❄️ Frost Affinity Unlocked!",
					"Your time in the cold has awakened an inner frost.",
					Color(0.4, 0.7, 1.0)
				)


# ─── Hook: Creature Spawned ───────────────────────────────────────────────────
func on_creature_spawned(creature: Node3D, creature_id: String) -> void:
	if creature_id == "frostlands_expansion:ancient_frost_wyrm":
		# Make the boss announcement
		for player: Node3D in creature.get_tree().get_nodes_in_group("players"):
			if player.global_position.distance_to(creature.global_position) < 200.0:
				if player.has_method("show_notification"):
					player.show_notification(
						"🐉 Ancient Frost Wyrm",
						"A terrible roar echoes from the glacier. A legendary beast awakens!",
						Color(0.2, 0.5, 1.0)
					)
		# Set special music
		var audio := creature.get_node_or_null("/root/AudioManager")
		if audio:
			audio.call("play_combat_music", "frost_wyrm_battle")


# ─── Hook: Boss Killed (registered at runtime) ───────────────────────────────
func _on_any_boss_killed(attacker: Node3D, target: Node3D) -> void:
	var creature_id := target.get_meta("creature_id", "") as String
	if creature_id != "frostlands_expansion:ancient_frost_wyrm":
		return

	# Extra special loot for Frost Wyrm kill
	_mod_loader.give_player_item("frostlands_expansion:wyrm_heart", 1)
	_mod_loader.give_player_item("frostlands_expansion:frost_dragon_scale", 3)

	if attacker.has_method("show_notification"):
		attacker.show_notification(
			"🏆 Wyrm Slayer!",
			"You have slain the Ancient Frost Wyrm. A new title has been earned.",
			Color.GOLD
		)
	print("[FrostlandsExpansion] Ancient Frost Wyrm slain by %s!" % attacker.get_meta("username", "?"))


# ─── Hook: Chunk Generated ───────────────────────────────────────────────────
func on_chunk_generated(chunk: ChunkData) -> void:
	# In the deep glacier biome, add ice crystal formations
	var origin := chunk.world_origin()
	var wx     := float(origin.x + ChunkManager.CHUNK_SIZE / 2)
	var wz     := float(origin.z + ChunkManager.CHUNK_SIZE / 2)

	# Only apply to our custom biome regions (approximate check)
	# In production: check biome registry properly
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(chunk.chunk_pos)
	if rng.randf() < 0.05:
		# Randomly place an ice crystal cluster on the surface
		for _i in rng.randi_range(2, 6):
			var lx  := rng.randi_range(2, ChunkManager.CHUNK_SIZE - 3)
			var lz  := rng.randi_range(2, ChunkManager.CHUNK_SIZE - 3)
			var sy  := chunk.get_surface_y(lx, lz)
			if sy < 0:
				continue
			for h in rng.randi_range(2, 5):
				chunk.try_set_voxel(Vector3i(lx, sy + 1 + h, lz), VoxelTypes.ICE)


# ─── Utility ──────────────────────────────────────────────────────────────────
func _ensure_frost_skill_registered() -> void:
	if not InventorySystem._item_registry.has("frostlands_expansion:frost_affinity"):
		_mod_loader.register_item("frostlands_expansion:frost_affinity", {
			"name": "Frost Affinity",
			"description": "Passive: Ice and cold attacks deal 15% more damage.",
			"category": "skill_passive",
		})
