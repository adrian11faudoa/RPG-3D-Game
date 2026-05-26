# Veilborn — Open-World Fantasy RPG

> A massively procedural, multiplayer-ready open-world fantasy RPG built with Godot 4.
> Inspired by Veloren, Cube World, Breath of the Wild, and classic MMORPGs.

![Veilborn Banner](docs/banner.png)

## Overview

Veilborn is a fully open-source, modular, procedurally generated fantasy RPG designed for:
- **Massive procedural worlds** — infinite biomes, dungeons, ruins, cities
- **Seamless multiplayer** — co-op exploration, guilds, trading, shared quests
- **Deep RPG progression** — classless skill trees, loot rarity, faction reputation
- **Living world simulation** — weather, NPC schedules, ecosystem AI, faction wars
- **Long-term expandability** — data-driven modding, scripting, open architecture

---

## Architecture

Veilborn uses a **hybrid ECS/scene-based architecture** in Godot 4:

```
Engine Layer:       Godot 4.3+ (GDScript + GDExtension for perf-critical systems)
World Generation:   Custom FastNoise2 + domain warping + biome tables
Networking:         Godot High-Level Multiplayer API + custom ENet transport
ECS-style logic:    Composition via Godot nodes + Resource-based component data
AI:                 BehaviorTree nodes + NavigationServer3D
Rendering:          Forward+ renderer, custom stylized shaders, LOD system
Persistence:        SQLite (server) + binary chunk files, JSON mod data
```

---

## Repository Structure

```
veilborn/
├── core/
│   ├── ecs/                # Entity-Component system helpers
│   ├── terrain/            # Chunk generation, LOD, streaming
│   ├── networking/         # Server/client sync, RPCs, state
│   └── physics/            # Custom character physics
│
├── systems/
│   ├── combat/             # Hit detection, combos, abilities
│   ├── crafting/           # Recipes, workstations, gathering
│   ├── quests/             # Quest data, tracking, rewards
│   ├── economy/            # Merchant prices, supply/demand
│   ├── weather/            # Weather simulation, transitions
│   └── factions/           # Reputation, war, territory
│
├── world/
│   ├── biomes/             # Biome definitions (JSON + scripts)
│   ├── dungeons/           # Procedural dungeon generator
│   ├── cities/             # City layout, building placement
│   └── creatures/          # Creature AI, spawn tables
│
├── player/
│   ├── controller/         # Movement, climbing, swimming
│   ├── inventory/          # Items, equipment slots
│   ├── skills/             # Skill trees, XP, leveling
│   └── stats/              # HP, stamina, attributes
│
├── ui/
│   ├── hud/                # Health bars, compass, quickslots
│   ├── menus/              # Inventory, crafting, map, quests
│   └── minimap/            # Minimap renderer
│
├── server/
│   ├── dedicated/          # Headless server entry point
│   ├── auth/               # Player auth, session tokens
│   └── sync/               # World state sync, chunk authority
│
├── client/
│   ├── rendering/          # Camera, post-FX, LOD control
│   ├── audio/              # Biome ambience, music, SFX
│   └── shaders/            # Stylized terrain, water, foliage
│
├── assets/
│   ├── definitions/        # items.json, creatures.json, biomes.json
│   └── mods/               # Mod loader, example mod
│
└── tools/
    ├── debug/              # Chunk visualizer, AI debugger
    ├── editor/             # In-game world editor
    └── profiler/           # Performance monitor
```

---

## Quick Start

### Prerequisites
- Godot 4.3+
- Rust (for GDExtension terrain module, optional)
- Python 3.10+ (for world editor tools)

### Running the Game
```bash
git clone https://github.com/your-org/veilborn
cd veilborn
# Open project.godot in Godot 4
# Or run headless server:
godot --headless --script server/dedicated/server_main.gd
```

### Running a Dedicated Server
```bash
godot --headless --script server/dedicated/server_main.gd \
  --port 7777 \
  --max-players 64 \
  --world-seed 42069 \
  --region "Ironmarch Reaches"
```

---

## Core Systems Documentation

| System | Description | Status |
|--------|-------------|--------|
| [Terrain Generation](docs/terrain.md) | Chunk-based procedural world | ✅ Core |
| [Player Controller](docs/player.md) | Movement, climbing, stamina | ✅ Core |
| [Combat System](docs/combat.md) | Melee, magic, archery, combos | ✅ Core |
| [Multiplayer](docs/networking.md) | Dedicated server, sync, RPCs | ✅ Core |
| [AI System](docs/ai.md) | BehaviorTree, pathfinding, groups | ✅ Core |
| [RPG Progression](docs/rpg.md) | XP, skills, loot, quests | ✅ Core |
| [Crafting](docs/crafting.md) | Gathering, recipes, workstations | ✅ Core |
| [World Simulation](docs/simulation.md) | Weather, factions, economy | 🔧 Beta |
| [Modding API](docs/modding.md) | Lua scripting, JSON definitions | 🔧 Beta |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We welcome:
- New biome definitions (JSON)
- Creature AI behaviors
- UI improvements
- Performance optimizations
- New crafting recipes
- Bug reports / playtesting

## License

MIT License — see [LICENSE](LICENSE)
