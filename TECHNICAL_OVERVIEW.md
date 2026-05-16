# Roblox Modular Library — Technical Overview
**FashionistaPetGame Project**
Last updated: May 2026

---

## What This Is

A fully modular, dependency-injected Roblox game library written in Luau (`--!strict`).
Every module is a standalone building block. Drop in what you need, leave out what you don't.
The capstone demo (`examples/AdoptMeDemo.server.lua`) wires 33 of them together into
a working Adopt Me-style game — no procedural terrain required, since the map is
hand-built in Roblox Studio.

The procedural terrain pipeline (11 modules) lives in `src/` intact and can be
plugged into any game that needs generated worlds.

---

## Architecture Patterns

### Dependency Injection (DI)
Every module receives its dependencies through constructor arguments. Nothing
`require()`s another module directly at module scope. This means:
- Any module can be swapped for a mock/stub in tests
- The dependency graph is explicit and readable at the top of each script
- Circular dependencies are structurally impossible

```lua
-- Example: PetSystem needs EventBus, Inventory, XPSystem, TimerSystem
local pets = PetSystem.new(bus, inv, xp, timer)
```

### EventBus (Pub/Sub)
All cross-module communication goes through a shared `EventBus` instance.
Modules never hold direct references to each other — they only know about the bus.

```lua
-- Producer (PetSystem)
self._eventBus:Emit("EggHatched", { petName = "Dragon", rarity = "legendary", instanceId = id })

-- Consumer (NotificationSystem, UI, QuestSystem — all independent)
bus:Subscribe("EggHatched", function(data) ... end)
```

**Key events in the Adopt Me demo:**

| Event | Emitted by | Consumed by |
|---|---|---|
| `EggHatched` | PetSystem | UI, NotificationSystem |
| `PetFed` | PetSystem | QuestSystem, XPSystem, NotificationSystem |
| `PetPlayed` | PetSystem | QuestSystem |
| `PetAgedUp` | PetSystem | Debug log |
| `NeonCreated` | PetSystem | NotificationSystem |
| `TradeRequested` | TradeSystem | NotificationSystem |
| `TradeCompleted` | TradeSystem | NotificationSystem, QuestSystem |
| `QuestCompleted` | QuestSystem | CurrencySystem (reward grant), NotificationSystem |
| `CurrencyBalanceChanged` | CurrencySystem | UI (Bucks bar) |
| `WeatherChanged` | WeatherSystem | AudioSystem, UI |
| `LeaderboardUpdated` | LeaderboardSystem | Debug log |
| `AutoSaveTriggered` | Game loop | Debug log |
| `LODUpdate` | Game loop | LODSystem |
| `PlayerJoined` | Game script | PetSystem, HomeSystem, VehicleSystem, QuestSystem, SaveSystem |

### Event Naming Convention

All events follow a `PascalCase` noun-verb pattern grouped by domain. The convention
is `<Subject><Action>` — never generic names like `"update"` or `"changed"`.

| Domain prefix | Examples |
|---|---|
| **Pet** | `EggHatched`, `PetFed`, `PetPlayed`, `PetAgedUp`, `NeonCreated`, `PetOwnershipTransferred` |
| **Trade** | `TradeRequested`, `TradeAccepted`, `TradeConfirmed`, `TradeCompleted`, `TradeCancelled` |
| **Currency** | `CurrencyAdded`, `CurrencySubtracted`, `CurrencyBalanceChanged`, `TransactionLogged` |
| **Quest** | `QuestAccepted`, `QuestProgressUpdated`, `QuestCompleted`, `QuestFailed` |
| **XP** | `XPAdded`, `LevelUp`, `XPBarUpdated` |
| **Inventory** | `ItemAdded`, `ItemRemoved`, `ItemEquipped`, `InventoryFull` |
| **Weather** | `WeatherChanged`, `WeatherTransitioning` |
| **Home** | `FurniturePlaced`, `FurnitureRemoved`, `HomeUpgraded` |
| **System** | `WorldSaved`, `ChunkSaved`, `AutoSaveTriggered`, `PlayerJoined` |

**Rules:**
- New events must use `PascalCase` and fit an existing domain prefix or introduce a new one
- Payload fields use `camelCase` (`instanceId`, `oldStage`, `newStage`)
- Never reuse an existing event name for a different payload shape — bump the name instead
- Subscribe handles returned by `bus:Subscribe()` should be stored and disconnected in `Destroy()`

---

### `--!strict` Type Safety
All modules are written in strict Luau. Every public API has exported `type` declarations
so callers get autocomplete and type errors at edit time rather than runtime.

---

## Module Catalog

### Core (4 modules) — `src/Core/`

| Module | Purpose |
|---|---|
| `EventBus` | Pub/sub backbone. `Subscribe(event, fn)`, `Emit(event, payload)`, `Once(event, fn)`. Thread-safe, returns unsubscribe handles. |
| `Config` | Key-value config store with typed getters. Shared defaults (XP formula, intervals, starting currency). |
| `Types` | Shared type definitions used across modules. |
| `StateMachine` | Generic finite-state machine. Transition table, guard callbacks, entry/exit hooks. Used by TradeSystem, CombatSystem. |

---

### Game Mechanics (17 modules) — `src/`

| Module | Purpose |
|---|---|
| `XPSystem` | XP accumulation and level-up. Configurable XP curve via `xpFormula`. Emits `LevelUp`. |
| `Inventory` | Slot-based inventory (50 slots like Adopt Me backpack). `AddItem`, `RemoveItem`, `DefineItem`, `GetItems`. Stack limits. Emits `ItemAdded`, `ItemRemoved`, `ItemUsed`. |
| `CurrencySystem` | Multi-currency support (Bucks + Robux). `Add`, `Subtract`, `CanAfford`, `GetBalance`, `Transfer`. Emits `CurrencyBalanceChanged`. |
| `QuestSystem` | Register/accept/advance/complete quests with multiple objectives. `RegisterQuest`, `AcceptQuest`, `AdvanceObjective`, `TurnInQuest`. Emits `QuestCompleted`. |
| `DialogueSystem` | NPC dialogue trees. Nodes with choices, conditions (afford check), and action callbacks. Used for all shop NPCs. |
| `CraftingSystem` | Recipe-based crafting. Register recipes, consume inputs from Inventory, produce outputs. |
| `EquipmentSystem` | Equip/unequip items with slot management. Applies stat modifiers. |
| `LootSystem` | Loot table rolls with rarity tiers. `RegisterRarity`, `RegisterLootTable`, `Roll`. `GetRarityColor` returns a `Color3`. |
| `CombatSystem` | Turn-based / real-time combat framework. Hit detection, damage calculation, death events. |
| `StatusEffectSystem` | Buffs and debuffs with duration, stacking, and tick callbacks. **Self-ticking** via internal `RunService.Heartbeat` — do NOT call `_update` externally. `Apply`, `Remove`, `HasEffect`, `GetEffectStacks`, `Destroy`. |
| `Skills` | Cooldown-managed ability system. Cast, channel, interrupt. |
| `UIFramework` | Theming and reusable UI component factory. `CreateBar`, `ThemeBar`. Client-side only. |
| `DataStoreSafe` | Roblox DataStore wrapper with retry logic, error handling, and budget awareness. |
| `LeaderboardSystem` | Sorted score boards backed by DataStoreSafe. `RegisterBoard`, `SubmitScore`, `GetTop`. Emits `LeaderboardUpdated`. |
| `TimerSystem` | `StartTimer(interval, callback, loop)` — managed timers that survive cleanup. `Destroy` disconnects all. |
| `NotificationSystem` | Toast notification queue. `Show(type, title, message, duration)`, `DismissAll`. |
| `Physics` | Knockback, projectile arcs, BodyVelocity helpers. |

---

### Adopt Me Domain Systems (4 modules) — `src/`

#### `PetSystem`
The core gameplay loop. Depends on: `EventBus`, `Inventory`, `XPSystem`, `TimerSystem`.

**Pet lifecycle:** egg → hatch → newborn → junior → pre-teen → teen → post-teen → full-grown → (neon crafting)

**Key types:**
```lua
type PetRarity = "common" | "uncommon" | "rare" | "ultra-rare" | "legendary"
type PetStage  = "egg" | "newborn" | "junior" | "pre-teen" | "teen" | "post-teen" | "full-grown"

type OwnedPet = {
    instanceId, defId, name,
    rarity: PetRarity,   -- fixed to the pet definition, never changes
    stage: PetStage,
    xp, mood, moodValue, hunger, energy, fun,
    accessories, isNeon, isFly, isRide,
    lastFed, lastPlayed, learnedTricks,
}
```

**Key rule:** A pet's rarity is **fixed by its definition**. `HatchEgg` rolls a rarity tier,
then picks randomly from pets *matching that tier*. You can never get a "Rare Dog" because
Dog is defined as "common" — it can only appear when `chosenRarity == "common"`.

**Egg rarity weights (tuned to match Adopt Me feel):**

| Egg | Common | Uncommon | Rare | Ultra-Rare | Legendary |
|---|---|---|---|---|---|
| Starter Egg | 100% | — | — | — | — |
| Cracked Egg | 45% | 33% | 14.5% | 6% | 1.5% |
| Pet Egg | 20% | 35% | 27% | 15% | 3% |
| Royal Egg | — | 25% | 37% | 30% | 8% |

**Public API:** `RegisterPet`, `RegisterEgg`, `HatchEgg`, `GetPet`, `GetAllPets`,
`SetEquippedPet`, `GetEquippedPet`, `FeedPet`, `PlayWithPet`, `TeachTrick`, `DoTrick`,
`UpdateMood`, `AgeUpPet`, `MakeNeon`, `Serialize`, `Deserialize`.

**Events emitted:** `EggHatched` (includes `rarity` field), `PetFed`, `PetPlayed`,
`TrickTaught`, `TrickDone`, `PetAgedUp` (`oldStage`/`newStage`, not `stage`), `NeonCreated`.

---

#### `TradeSystem`
Two-phase anti-scam trading. Depends on: `EventBus`, `Inventory`, `CurrencySystem`, `TimerSystem`.

Phase 1: Request → Accept. Phase 2: Both players add items/Bucks → Both confirm → Execute.
If either player disconnects or timer expires, trade auto-cancels. `Destroy()` cleans up
all pending timeouts.

**Events:** `TradeRequested`, `TradeAccepted`, `TradeCompleted`, `TradeCancelled`.

---

#### `HomeSystem`
Player housing with furniture placement. Depends on: `EventBus`, `Inventory`, `CurrencySystem`.

Home types: Apartment (free), Starter House, Family Home, Mansion, Estate.
Furniture placement checks collision and room bounds. Room painting applies `Color3` to walls/floor.

**Events:** `HomePurchased`, `FurniturePlaced`, `FurnitureRemoved`, `RoomPainted`.

---

#### `VehicleSystem`
Drivable vehicles with physics. Depends on: `EventBus`, `Inventory`.

Register vehicle definitions, give vehicles to players, spawn/despawn in world,
paint with any `Color3`. Uses `BodyVelocity` for movement.

**Events:** `VehicleSpawned`, `VehicleDespawned`, `VehiclePainted`.

---

### Terrain Pipeline (11 modules — available in `src/`, not used in AdoptMeDemo)

These form a complete 7-stage procedural world generation pipeline. Plug them in
for any game that needs generated worlds.

| Module | Stage | Purpose |
|---|---|---|
| `NoiseLib` | — | Seeded multi-octave Perlin/fractal noise. `Get2D(x, z)` returns -1..1. |
| `TerrainGenerator` | 1 | Heightmap generation + Roblox voxel writing. `GenerateChunk(cx, cz)` → `ChunkData`. `ApplyToTerrain(chunk)` writes one `WriteVoxels` call per chunk. Valid materials: `Grass`, `Ground`, `Rock` (not `Dirt` — doesn't exist). |
| `ErosionSimulator` | 2 | Hydraulic + thermal erosion via droplet simulation. Config: `{ droplets, erosionRate, depositionRate, evaporationRate, gravity }`. Pass explicit config — do NOT pass a game Config object or it falls back to 50,000 droplets. |
| `BiomeSystem` | 3 | Temperature + moisture sampling → biome classification. `GenerateBiomeMap(chunk)`. |
| `WaterSystem` | 4 | River and lake carving from heightmaps. |
| `CaveSystem` | 5 | Underground tunnel generation via 3D noise thresholding. |
| `ObjectPlacer` | 6 | Biome-density-aware tree/rock/building scattering. |
| `AtmosphereSystem` | 7 | Per-biome `Lighting`/`Atmosphere` property tweening. Also used standalone for day/night cycles in hand-built maps. |
| `ChunkManager` | — | Chunk lifecycle: load/unload/stream around a player position. `StreamAround(worldX, worldZ)`. Circular view distance. `_clearTerrainVoxels` mirrors `ApplyToTerrain` exactly (same resolution, same origin math). |
| `WorldBuilder` | — | Orchestrates the full pipeline across an NxN chunk grid. Emits `WorldBuildStarted`, `BuildProgress`, `WorldBuildCompleted`. **Wrap in `task.spawn()`** — on large grids it will exceed Studio's 10-second script timeout. |
| `EnvironmentBuilder` | — | Scatters styled low-poly objects using terrain data + `LowPolyGenerator` + `ColorPaletteSystem`. |

**Voxel writing rules (critical):**
- `resolution` in `WriteVoxels` must be a **number** (e.g. `4`), never a `Vector3`
- Materials/occupancy arrays must be `[numVoxX][numVoxY][numVoxZ]` — sized exactly to match `region / resolution`
- `Enum.Material.Dirt` does **not** exist. Use `Enum.Material.Ground` for brown earth
- `ExpandToGrid(resolution)` is required before `WriteVoxels`

---

### Environment & Art Style (3 active modules) — `src/`

| Module | Purpose |
|---|---|
| `ColorPaletteSystem` | Register named palettes of `Color3` values. Used for vehicle paint, furniture swatches, UI accent colours. |
| `StylePresets` | Art-style configurations (FlatShaded, Cartoon, Realistic). `ApplyPreset("FlatShaded")`. |
| `LODSystem` | Mesh detail reduction for distant objects. Listens for `LODUpdate` events emitted from the game loop every 2s. |
| `LowPolyGenerator` | *(available in src/)* Converts meshes to flat-shaded low-poly. Not needed with hand-built geometry. |

---

### Extensions (4 modules) — `src/`

| Module | Purpose |
|---|---|
| `WeatherSystem` | Rain/snow/storm/fog state machine with particle emitter control. `EnableRandomWeather(interval)`, `Update(dt)`, `DisableRandomWeather`. Emits `WeatherChanged`. |
| `AudioSystem` | Per-biome ambient soundscapes with day/night crossfades. `RegisterBiomeSoundscape`, `PlayBiomeAmbience`, `SetTimeOfDay`, `Update(dt)`. **Requires manual `Update(dt)` call** in the game loop (unlike StatusEffectSystem which is self-ticking). |
| `SaveSystem` | World-aware save/load wrapping DataStoreSafe. `AutoSave(interval)`, `LoadWorld()`, `FlushQueue()`. |
| `PathfindingSystem` | A* navmesh pathfinding. Config: `{ slopeLimit, resolution }`. Used for pet following and NPC navigation. |

**Extra modules in src/ (not wired in AdoptMeDemo):**
- `ProfileStoreAdapter` — wraps ProfileStore for player data management
- `TradeCoordinator` — server-side trade session coordinator
- `TradeRemoteHandler` — RemoteEvent bridge for client↔server trade UI
- `PetAnimator` — animation state machine for pet models

---

## Demo & Example Scripts

### `examples/AdoptMeDemo.server.lua` ⭐ Main demo
Wires 33 modules into a complete Adopt Me-style game. Hand-built Studio map.
Sections: Imports → DI Wiring → Palette → Pets → Economy → Homes → Vehicles →
Quests → Weather/Audio → Save → Leaderboard → UI (client-guarded) → Event log → Game loop → Cleanup.

**Module count by group:**
- Core: 4
- Game Mechanics: 17
- Environment/Art: 3 + AtmosphereSystem
- Extensions: 4
- Adopt Me Domain: 4
- **Total: 33**

### `AdoptMeStudioTest.server.lua`
Automated test script that runs in Studio and exercises the full pet lifecycle:
register → hatch 3 eggs → feed → play → teach tricks → trade smoke test → neon craft.
Prints pass/fail for each step. Target: **DEMO COMPLETE ✓**

### `TradeSmoke.server.lua`
40-case smoke test for TradeSystem. Tests request → accept → add items → confirm →
execute, plus cancellation, timeout, and edge cases. Target: **40/40**.

### `ExampleWorld.server.lua`
Minimal example of the procedural terrain pipeline: NoiseLib → TerrainGenerator →
BiomeSystem → ChunkManager streaming. Good reference for wiring the terrain stack.

### `examples/ExampleLowPolyScene.lua`
Demonstrates ColorPaletteSystem + LowPolyGenerator + StylePresets for environment art.

### `PetGame.server.lua`
Alternative pet game wiring (lighter than AdoptMeDemo).

---

## Game Loop Pattern

```lua
local RunService = game:GetService("RunService")
local moodTimer, weatherTimer, saveTimer, leaderboardTimer, lodTimer = 0, 0, 0, 0, 0

local heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
    moodTimer += dt
    if moodTimer >= 60 then
        moodTimer = 0
        pets:UpdateMood(60)
    end

    weatherTimer += dt
    if weatherTimer >= 300 then
        weatherTimer = 0
        weather:Update(300)      -- WeatherSystem needs manual update
    end

    saveTimer += dt
    if saveTimer >= 120 then
        saveTimer = 0
        save:FlushQueue()
    end

    leaderboardTimer += dt
    if leaderboardTimer >= 60 then
        leaderboardTimer = 0
        leaderboard:SubmitScore(...)
    end

    lodTimer += dt
    if lodTimer >= 2 then
        lodTimer = 0
        bus:Emit("LODUpdate", { timestamp = tick() })
    end

    audio:Update(dt)  -- AudioSystem: manual update needed for crossfades
    -- StatusEffectSystem: NO manual update — self-ticks via internal Heartbeat
end)
```

---

## Luau Strict Mode Gotchas

Issues encountered and solved during development — save future sessions debugging time.

### 1. Tuple types not supported
```lua
-- ❌ Breaks under --!strict
function Foo:Bar(): { { TypeA, TypeB } }

-- ✅ Use union
function Foo:Bar(): { { TypeA | TypeB } }
```

### 2. `Enum.Material.Dirt` does not exist
```lua
Enum.Material.Dirt   -- ❌ runtime error
Enum.Material.Ground -- ✅ brown earth
```

### 3. `WriteVoxels` resolution must be a number
```lua
terrain:WriteVoxels(region, Vector3.new(4,4,4), ...)  -- ❌ wrong type
terrain:WriteVoxels(region, 4, ...)                    -- ✅
```

### 4. `Players.LocalPlayer` is nil on the server
```lua
-- ❌ Infinite yield on server scripts
Players:WaitForChild("LocalPlayer")

-- ✅ Guard all UI code
if game:GetService("RunService"):IsClient() then
    local player = Players.LocalPlayer
    ...
end
```

### 5. Studio 10-second script timeout
Each `.server.lua` gets 10 seconds of CPU on the main thread. Heavy setup (50 modules ~5s)
leaves little room for world generation. Fix:
```lua
task.spawn(function()
    worldBuilder:BuildWorld(config)  -- runs in its own thread with fresh budget
end)
```

### 6. ErosionSimulator config independence
`ErosionSimulator.new(bus, config)` where `config` is a game Config object will fall back
to all defaults including 50,000 droplets, ignoring `terrain.erosionIterations`. Always
pass an explicit ErosionConfig table:
```lua
ErosionSimulator.new(bus, {
    droplets        = 500,
    erosionRate     = 0.1,
    depositionRate  = 0.05,
    evaporationRate = 0.01,
    gravity         = 9.81,
})
```

### 7. StatusEffectSystem is self-ticking — do NOT call `_update`
`StatusEffectSystem.new()` connects its own `RunService.Heartbeat` internally.
Calling `statusFx:_update(dt)` from the game loop will error — the method doesn't exist.

### 8. ChunkManager `_clearTerrainVoxels` must mirror `ApplyToTerrain`
The origin, resolution, and array dimensions must be identical between the two functions
or chunks will clear to the wrong region. Both use:
```lua
local corner = Vector3.new(chunk.cx * hmSize, 0, chunk.cz * hmSize)
local extent  = Vector3.new(numVoxX * resolution, numVoxY * resolution, numVoxZ * resolution)
local region  = Region3.new(corner, corner + extent):ExpandToGrid(resolution)
terrain:WriteVoxels(region, resolution, materials, occupancies)
```

### 9. PetAgedUp event fields are `oldStage`/`newStage`, not `stage`
```lua
-- ❌ data.stage is nil
bus:Subscribe("PetAgedUp", function(data: { stage: string }) ... end)

-- ✅
bus:Subscribe("PetAgedUp", function(data: { oldStage: string, newStage: string }) ... end)
```

### 10. `OwnedPet` must include `rarity`
The `rarity` field must be present on `OwnedPet` (not just on the event payload) and
copied in `_deepCopyPet`. Without it, `pet.rarity` returns nil everywhere.

---

## File Structure

```
roblox-modular-lib/
│
├── src/                          # Library modules (54 files)
│   ├── Core/
│   │   ├── EventBus.lua
│   │   ├── Config.lua
│   │   ├── Types.lua
│   │   ├── StateMachine.lua
│   │   └── __init__.lua
│   │
│   ├── -- Game Mechanics --
│   ├── XPSystem.lua
│   ├── Inventory.lua
│   ├── CurrencySystem.lua
│   ├── QuestSystem.lua
│   ├── DialogueSystem.lua
│   ├── CraftingSystem.lua
│   ├── EquipmentSystem.lua
│   ├── LootSystem.lua
│   ├── CombatSystem.lua
│   ├── StatusEffectSystem.lua
│   ├── Skills.lua
│   ├── UIFramework.lua
│   ├── DataStoreSafe.lua
│   ├── LeaderboardSystem.lua
│   ├── TimerSystem.lua
│   ├── NotificationSystem.lua
│   ├── Physics.lua
│   │
│   ├── -- Adopt Me Domain --
│   ├── PetSystem.lua             ← rarity on OwnedPet, egg weights tuned
│   ├── HomeSystem.lua
│   ├── TradeSystem.lua
│   ├── VehicleSystem.lua
│   ├── PetAnimator.lua
│   ├── TradeCoordinator.lua
│   ├── TradeRemoteHandler.lua
│   ├── ProfileStoreAdapter.lua
│   │
│   ├── -- Terrain Pipeline --
│   ├── NoiseLib.lua
│   ├── TerrainGenerator.lua      ← ApplyToTerrain: single WriteVoxels per chunk
│   ├── ErosionSimulator.lua
│   ├── BiomeSystem.lua
│   ├── WaterSystem.lua
│   ├── CaveSystem.lua
│   ├── ObjectPlacer.lua
│   ├── ChunkManager.lua          ← _clearTerrainVoxels mirrors ApplyToTerrain
│   ├── WorldBuilder.lua
│   │
│   ├── -- Environment & Art --
│   ├── AtmosphereSystem.lua
│   ├── ColorPaletteSystem.lua
│   ├── LowPolyGenerator.lua
│   ├── EnvironmentBuilder.lua
│   ├── StylePresets.lua
│   ├── LODSystem.lua
│   │
│   ├── -- Extensions --
│   ├── WeatherSystem.lua         ← GetWeatherForBiome returns { { WeatherType | number } }
│   ├── AudioSystem.lua
│   ├── SaveSystem.lua
│   ├── PathfindingSystem.lua
│   └── init.lua
│
├── examples/
│   ├── AdoptMeDemo.server.lua    ← 33-module hand-built-map demo (v2.0.0)
│   ├── ExampleWorld.server.lua   ← terrain pipeline reference
│   └── ExampleLowPolyScene.lua   ← art style reference
│
├── tests/                        ← 40 test files, one per module
│   └── test_*.lua
│
├── AdoptMeStudioTest.server.lua  ← in-Studio automated pet lifecycle test
├── TradeSmoke.server.lua         ← 40-case trade smoke test
├── PetGame.server.lua
├── ExampleGame.server.lua
├── RunTests_Bootstrap.lua
└── TECHNICAL_OVERVIEW.md         ← this file
```

---

## Testing

Each module has a corresponding `tests/test_<Module>.lua`. Run via `RunTests_Bootstrap.lua`.

**Studio verification targets:**
| Script | Target |
|---|---|
| `TradeSmoke.server.lua` | **40/40 passed** |
| `AdoptMeStudioTest.server.lua` | **DEMO COMPLETE ✓** |
| `ExampleWorld.server.lua` | Streaming loads + unloads cleanly |
| `examples/AdoptMeDemo.server.lua` | **INITIALIZED SUCCESSFULLY** + no repeating errors |

---

## Next Steps

### Map
- Build the world in Roblox Studio (baseplate → terrain sculpt → zones)
- Suggested zones: Nursery (starter area), Pet Shop, Trading Plaza, Neighbourhood
  (player homes), Park (play area), General Store
- For zone-based audio: emit `bus:Emit("BiomeEntered", { biome = "town" })` from
  zone trigger parts → AudioSystem swaps soundscape automatically

### Rojo Sync
- The project uses Rojo to sync `.lua` files into Roblox Studio
- `src/` maps to `ServerScriptService` (or a ModuleScript hierarchy)
- `examples/` maps to `ServerScriptService`

### Production TODOs
- Move Section 12 (UI) of AdoptMeDemo into a **LocalScript** — it is currently
  guarded by `RunService:IsClient()` but belongs in its own file in production
- Wire `Players.PlayerAdded` / `Players.PlayerRemoving` to emit
  `PlayerJoined` / `PlayerLeaving` on the bus
- Replace placeholder `rbxassetid://pet_*` with real uploaded asset IDs
- Hook `PetSystem:Serialize` / `Deserialize` into `SaveSystem` for pet persistence
  across sessions
- Add `TradeRemoteHandler` for client↔server trade UI RemoteEvents
