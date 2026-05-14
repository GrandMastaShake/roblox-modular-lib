# Installing via Wally

`roblox-modular-lib` is published to the [Wally registry](https://github.com/UpliftGames/wally-index) and can be installed in any Rojo-managed Roblox project.

---

## 1. Add the dependency

In your project's `wally.toml`:

```toml
[dependencies]
modular-lib = "roblox-modular-lib@1.0.0"
```

## 2. Install

```bash
wally install
```

This downloads the package into `Packages/modular-lib`.

## 3. Generate a sourcemap (optional, for IDE support)

```bash
rojo sourcemap default.project.json --output sourcemap.json
```

## 4. Use in your code

```lua
local lib = require(Packages.modular_lib)

-- Core systems
local bus = lib.Core.EventBus.new()
local cfg = lib.Core.Config.new({ debug = true })

-- Terrain generation
local terrain = lib.TerrainGenerator.new(bus)
terrain:GenerateWorld(256)

-- Game mechanics
local inventory = lib.Inventory.new(bus)
local combat = lib.CombatSystem.new(bus)

-- Extension systems
local pathfinding = lib.PathfindingSystem.new(bus)
local weather = lib.WeatherSystem.new(bus)
weather:SetWeather("rain", 0.5, 120)
```

---

## Module Reference (36 modules)

### Core (4)
| Module | Description |
|--------|-------------|
| `Core.EventBus` | Central pub/sub event system |
| `Core.Types` | Shared Luau type definitions |
| `Core.Config` | Configuration manager |
| `Core.StateMachine` | Hierarchical state machine |

### Game Mechanics (15)
| Module | Description |
|--------|-------------|
| `XPSystem` | Experience & leveling |
| `Skills` | Skill trees & progression |
| `Inventory` | Item management |
| `CurrencySystem` | In-game currencies |
| `CombatSystem` | Combat engine |
| `StatusEffectSystem` | Buffs/debuffs |
| `LootSystem` | Loot tables & drops |
| `EquipmentSystem` | Gear & slots |
| `QuestSystem` | Quest management |
| `DialogueSystem` | NPC dialogue |
| `LeaderboardSystem` | Score tracking |
| `NotificationSystem` | Player notifications |
| `UIFramework` | UI toolkit |
| `TimerSystem` | Timed events |
| `CraftingSystem` | Recipe-based crafting |

### Terrain (10)
| Module | Description |
|--------|-------------|
| `NoiseLib` | Perlin/Simplex noise |
| `TerrainGenerator` | Heightmap generation |
| `WorldBuilder` | World orchestration |
| `BiomeSystem` | Biome management |
| `AtmosphereSystem` | Lighting & fog |
| `WaterSystem` | Water bodies |
| `ChunkManager` | Chunk streaming |
| `ObjectPlacer` | Object placement |
| `ErosionSimulator` | Hydraulic erosion |
| `CaveSystem` | Cave generation |

### Data & Physics (3)
| Module | Description |
|--------|-------------|
| `DataStoreSafe` | Safe DataStore wrapper |
| `Physics` | Physics utilities |

### Extensions (4)
| Module | Description |
|--------|-------------|
| `SaveSystem` | Persistent world saves |
| `PathfindingSystem` | NavMesh & A* pathfinding |
| `WeatherSystem` | Rain, snow, storms |
| `AudioSystem` | Ambient soundscapes |

---

## Development Toolchain

This package uses [Aftman](https://github.com/LPGhatguy/aftman) for tool management:

```bash
aftman install   # Installs rojo, wally, selene
```

| Tool | Version | Purpose |
|------|---------|---------|
| Rojo | 7.4.0 | Roblox <> filesystem sync |
| Wally | 0.3.2 | Package manager |
| Selene | 0.26.1 | Lua linting |

---

## License

MIT
