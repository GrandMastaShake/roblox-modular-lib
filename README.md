# roblox-modular-lib

A `--!strict` Luau modular game-systems library for Roblox. **49 standalone modules** wired together via Dependency Injection and an EventBus pub/sub pattern — drop in only what your game needs.

> Capstone demo: an Adopt Me-style pet game (`examples/AdoptMeDemo.server.lua`) built on a hand-crafted Studio map.

---

## Features

- **49 modules** across Core, Mechanics, Domain (Pets/Trade/Home/Vehicle), Extensions, and a full procedural Terrain pipeline
- **Strict types throughout** — `--!strict` Luau with exported types for every public API
- **Dependency Injection** — no module-scope `require()` of siblings; every system receives its deps at construction
- **EventBus pub/sub** — cross-module communication via `Subscribe` / `Emit` / `Once`; modules never hold direct references to each other
- **Two reusable stacks** — Gameplay stack (33 modules for the Adopt Me demo) and a standalone Terrain pipeline (11 modules for procedural worlds)
- **Studio map plugin** — one-click procedural generation of the full 7-zone Adopt Me map in edit mode
- **23 unit-test modules** + 40 TradeSystem edge cases + a full pet lifecycle smoke test

---

## Toolchain

Managed by [Aftman](https://github.com/LPGhatguy/aftman):

```bash
aftman install   # installs rojo 7.4.0, wally 0.3.2, selene 0.26.1
```

| Tool | Version | Purpose |
|---|---|---|
| Rojo | 7.4.0 | Syncs filesystem into Roblox Studio live |
| Wally | 0.3.2 | Package manager |
| Selene | 0.26.1 | Lua static analyser / linter |

---

## Getting Started

### 1. Clone & install tools

```bash
git clone https://github.com/GrandMastaShake/roblox-modular-lib.git
cd roblox-modular-lib
aftman install
```

### 2. Open in Studio

```bash
rojo serve default.project.json
# Then open FashionistaPetGame.rbxlx in Roblox Studio
```

### 3. Build the map (first time)

Install the Studio plugin by copying it to your plugins folder:

```
%LOCALAPPDATA%\Roblox\Plugins\AdoptMeMapBuilder.lua
```

Restart Studio → **Plugins tab → 🏗 Build Map**. Generates all 7 zones, paths, terrain, and lighting in one click.

### 4. Run the demo

Hit **Play** in Studio and check the Output panel. You should see all 33 systems initialize with no errors and the demo cycling through pet lifecycle events.

---

## Architecture

### Core patterns

Every module is instantiated with explicit dependencies — nothing `require()`s a sibling at module scope:

```lua
local bus   = EventBus.new()
local inv   = Inventory.new(bus)
local xp    = XPSystem.new(bus, cfg)
local pets  = PetSystem.new(bus, inv, xp, timer)
local trade = TradeSystem.new(bus, inv, currency, timer)
```

Cross-module communication is exclusively through the shared EventBus. The bus instance is the single shared root.

### Two distinct stacks

**Gameplay stack** (used in `AdoptMeDemo`, 33 modules):
```
Core → Mechanics → Domain (Pets/Trade/Home/Vehicle) → Extensions (Weather/Audio/Save/Pathfinding)
```

**Terrain pipeline** (available in `src/`, used in `ExampleWorld.server.lua`, not wired in AdoptMeDemo):
```
NoiseLib → TerrainGenerator → ErosionSimulator → BiomeSystem → WaterSystem
→ CaveSystem → ObjectPlacer → AtmosphereSystem → ChunkManager → WorldBuilder
```

When adding a feature, decide which stack it belongs to. Terrain pipeline modules are reusable for other games but should not be pulled into the Adopt Me demo.

### Central re-export

`src/init.lua` re-exports all 49 modules by category. External projects installed via Wally use this as their entry point:

```lua
local lib = require(Packages.modular_lib)
local bus = lib.Core.EventBus.new()
local pets = lib.PetSystem.new(bus, inv, xp, timer)
```

---

## Module Catalogue

### Core (4)
| Module | Description |
|---|---|
| `Core.EventBus` | Central pub/sub — `Subscribe`, `Emit`, `Once` |
| `Core.Types` | Shared Luau type definitions |
| `Core.Config` | Configuration manager |
| `Core.StateMachine` | Hierarchical state machine |

### Mechanics (15)
| Module | Description |
|---|---|
| `XPSystem` | Experience & leveling |
| `Skills` | Skill trees & progression |
| `Inventory` | Item management |
| `CurrencySystem` | In-game currencies |
| `CombatSystem` | Combat engine |
| `StatusEffectSystem` | Buffs/debuffs (self-ticking via Heartbeat) |
| `LootSystem` | Loot tables & drops |
| `EquipmentSystem` | Gear & slots |
| `QuestSystem` | Quest management |
| `DialogueSystem` | NPC dialogue trees |
| `LeaderboardSystem` | Score tracking |
| `NotificationSystem` | Player notifications |
| `UIFramework` | UI toolkit |
| `TimerSystem` | Timed events |
| `CraftingSystem` | Recipe-based crafting |

### Domain (9)
| Module | Description |
|---|---|
| `PetSystem` | Full pet lifecycle — hatch, feed, train, age up, fuse neon |
| `TradeSystem` | Peer-to-peer trading with validation |
| `TradeCoordinator` | Multi-party trade orchestration |
| `TradeRemoteHandler` | RemoteEvent wiring for trade UI |
| `HomeSystem` | Player housing & furniture |
| `VehicleSystem` | Rideable vehicles |
| `PetAnimator` | Pet movement & emote animations |
| `ColorPaletteSystem` | Shared colour theming |
| `StylePresets` | Preset visual configurations |

### Extensions (5)
| Module | Description |
|---|---|
| `SaveSystem` | Persistent DataStore saves |
| `DataStoreSafe` | Retry-safe DataStore wrapper |
| `ProfileStoreAdapter` | ProfileStore integration |
| `PathfindingSystem` | NavMesh & A* pathfinding |
| `AudioSystem` | Ambient soundscapes |

### Visual (3)
| Module | Description |
|---|---|
| `LODSystem` | Level-of-detail management |
| `LowPolyGenerator` | Procedural low-poly meshes |
| `EnvironmentBuilder` | Scene dressing & prop placement |

### Terrain pipeline (11)
| Module | Description |
|---|---|
| `NoiseLib` | Perlin/Simplex noise primitives |
| `TerrainGenerator` | Heightmap & voxel generation |
| `ErosionSimulator` | Hydraulic erosion (droplet-based) |
| `BiomeSystem` | Biome blending & transitions |
| `WaterSystem` | Rivers, lakes, and ocean |
| `CaveSystem` | Underground cave networks |
| `ObjectPlacer` | Scatter trees, rocks, props |
| `AtmosphereSystem` | Lighting, fog, day/night cycle |
| `ChunkManager` | Streaming chunk management |
| `WorldBuilder` | Top-level world orchestration |
| `WeatherSystem` | Rain, snow, storms |

---

## Pet System

The pet system implements the full Adopt Me lifecycle:

| Stage | Unlock |
|---|---|
| Newborn | Hatch from egg |
| Junior | 10 XP |
| Pre-Teen | 30 XP |
| Teen | 60 XP |
| Post-Teen | 100 XP |
| Full Grown | 150 XP |
| Neon | Fuse 4 Full Grown pets |

### Egg rarity weights

| Egg | Common | Uncommon | Rare | Ultra-Rare | Legendary |
|---|---|---|---|---|---|
| Starter | 100% | — | — | — | — |
| Cracked | 45% | 33% | 14.5% | 6% | 1.5% |
| Pet | 20% | 35% | 27% | 15% | 3% |
| Royal | — | 25% | 37% | 30% | 8% |

Pets of the same species always share the same rarity — rarity is a property of the `PetDef`, not the roll. `HatchEgg` rolls a tier then hard-filters `def.rarity == chosenRarity`.

---

## Running Tests

All tests run **inside Roblox Studio** — there is no standalone Lua runner.

1. Open `FashionistaPetGame.rbxlx` in Studio with Rojo syncing
2. Hit **Play**
3. Check the Output panel

| Script | What it tests | Pass condition |
|---|---|---|
| `RunTests_Bootstrap.lua` | All 23 unit test modules + PetGame smoke test | `Results: N passed, 0 failed` |
| `TradeSmoke.server.lua` | 40 TradeSystem edge cases | `40/40` |
| `AdoptMeStudioTest.server.lua` | Full pet lifecycle (hatch → feed → trick → neon) | `DEMO COMPLETE ✓` |

To run a single test module directly:

```lua
require(game.ServerScriptService.Tests.test_PetSystem)
```

Lint with Selene:

```bash
selene src/          # whole library
selene src/PetSystem.lua   # single file
```

---

## Installing via Wally

Add to your project's `wally.toml`:

```toml
[dependencies]
modular-lib = "roblox-modular-lib@1.3.0"
```

```bash
wally install
```

Then in your code:

```lua
local lib = require(Packages.modular_lib)
local bus = lib.Core.EventBus.new()
local pets = lib.PetSystem.new(bus, inv, xp, timer)
```

---

## License

MIT
