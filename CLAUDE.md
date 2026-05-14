# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A `--!strict` Luau modular game-systems library for Roblox, version 1.3.0. It provides 49 standalone modules wired together via Dependency Injection and an EventBus pub/sub pattern. The capstone demo is an Adopt Me-style pet game (`examples/AdoptMeDemo.server.lua`) targeting a hand-built Studio map (not procedural terrain). See `TECHNICAL_OVERVIEW.md` for the full module catalogue, event table, egg odds, and known-gotcha list.

## Toolchain

Managed by [Aftman](https://github.com/LPGhatguy/aftman). Install all tools with:

```bash
aftman install          # installs rojo 7.4.0, wally 0.3.2, selene 0.26.1
```

| Tool | Purpose |
|---|---|
| `rojo` | Syncs this filesystem into Roblox Studio live |
| `wally` | Package manager (no external deps currently) |
| `selene` | Lua static analyser / linter |

## Rojo workflow

```bash
rojo serve default.project.json   # start live sync — open FashionistaPetGame.rbxlx in Studio
rojo build default.project.json --output FashionistaPetGame.rbxlx  # one-shot build
rojo sourcemap default.project.json --output sourcemap.json        # IDE type support
```

`default.project.json` maps:
- `src/` → `ServerScriptService.src` (the library itself)
- `tests/` → `ServerScriptService.Tests`
- Root `.server.lua` files and `examples/` → directly into `ServerScriptService`

## Linting

```bash
selene src/                        # lint the whole library
selene src/PetSystem.lua           # lint a single file
```

## Running tests

All tests run **inside Roblox Studio** — there is no standalone Lua test runner.

1. Open `FashionistaPetGame.rbxlx` in Studio with Rojo syncing (`rojo serve`)
2. Hit **Play** in Studio
3. Check the Output panel

| Script | What it tests | Pass condition |
|---|---|---|
| `RunTests_Bootstrap.lua` | All 23 unit test modules, then PetGame smoke test | No red errors; `Results: N passed, 0 failed` |
| `TradeSmoke.server.lua` | 40 TradeSystem edge cases | `40/40` |
| `AdoptMeStudioTest.server.lua` | Full pet lifecycle (hatch → feed → trick → neon) | `DEMO COMPLETE ✓` |

To run a single test module, `require` it directly in a temporary Script:
```lua
require(game.ServerScriptService.Tests.test_PetSystem)
```

## Architecture

### Core patterns

Every module is instantiated with explicit dependencies — nothing `require()`s a sibling at module scope:

```lua
local bus   = EventBus.new()
local pets  = PetSystem.new(bus, inv, xp, timer)   -- deps injected
local trade = TradeSystem.new(bus, inv, currency, timer)
```

Cross-module communication is exclusively through the shared `EventBus` (`Subscribe` / `Emit` / `Once`). Modules never hold direct references to each other. The bus instance is the single shared root.

### Two distinct stacks

**Gameplay stack** — used in `AdoptMeDemo` (33 modules, hand-built map):
Core → Mechanics → Domain (Pets/Trade/Home/Vehicle) → Extensions (Weather/Audio/Save/Pathfinding)

**Terrain pipeline** — available in `src/`, not wired in `AdoptMeDemo`, used in `ExampleWorld.server.lua`:
NoiseLib → TerrainGenerator → ErosionSimulator → BiomeSystem → WaterSystem → CaveSystem → ObjectPlacer → AtmosphereSystem → ChunkManager → WorldBuilder

When adding a feature, decide which stack it belongs to. The terrain pipeline modules are available for other games but should not be pulled into the Adopt Me demo.

### Central re-export

`src/init.lua` re-exports all 49 modules by category. External projects that install via Wally use this as their entry point (`require(Packages.modular_lib).PetSystem`). Direct `require(script.Parent.src.PetSystem)` is used inside the project itself.

### Demo scripts

- `examples/AdoptMeDemo.server.lua` — the canonical 33-module wiring. Sections 1-14 are clearly labelled; read them top to bottom to understand the full DI graph.
- `AdoptMeStudioTest.server.lua` — automated lifecycle test; run this after any change to PetSystem, TradeSystem, or CurrencySystem.
- `TradeSmoke.server.lua` — run after any TradeSystem or Inventory change.
- `ExampleWorld.server.lua` — reference for wiring the terrain pipeline.

### Map builder plugin

`%LOCALAPPDATA%\Roblox\Plugins\AdoptMeMapBuilder.lua` — a Studio Plugin (runs in edit mode, changes persist). Restart Studio after installing. **Plugins tab → 🏗 Build Map.** Builds all zones (Hub, Pet Shop, Nursery, Park, Trading Plaza, Neighbourhood, General Store), paths, outer terrain, and lighting in one click. Zone trigger parts are named `<Zone>_Trigger` and have a `ZoneName` attribute for `BiomeEntered` event wiring.

## Critical Luau / Roblox gotchas

These have all caused runtime errors in this codebase — check here before debugging:

- **`StatusEffectSystem` is self-ticking.** Its constructor connects a `RunService.Heartbeat` internally. Never call `statusFx:_update(dt)` from a game loop — the method does not exist.
- **`WriteVoxels` resolution must be a `number`, not a `Vector3`.** Use `4`, not `Vector3.new(4,4,4)`.
- **`Enum.Material.Dirt` does not exist.** Use `Enum.Material.Ground` for brown earth.
- **`Players.LocalPlayer` is `nil` on the server.** Guard all UI code with `RunService:IsClient()`.
- **`WorldBuilder:BuildWorld` in `task.spawn()`.** The 50-module DI setup consumes ~5 s of Studio's 10-second script budget; `task.spawn` gives the world build a fresh thread.
- **`ErosionSimulator` config is independent of game Config.** Always pass an explicit table: `ErosionSimulator.new(bus, { droplets = 500, erosionRate = 0.1, ... })`. Passing a game `Config` object silently falls back to 50,000 droplets.
- **`PetAgedUp` event payload uses `oldStage`/`newStage`, not `stage`.** Subscribers that read `data.stage` will get `nil`.
- **`OwnedPet` has a `rarity` field** — it must be populated in `HatchEgg` and copied in `_deepCopyPet`. Pet rarity is fixed by the `PetDef`; `HatchEgg` rolls a tier then filters candidates by `def.rarity == chosenRarity`.
- **Luau `--!strict` does not support tuple table types.** `{ { TypeA, TypeB } }` is a parse error; use `{ { TypeA | TypeB } }` (union).
- **`ChunkManager:_clearTerrainVoxels` must mirror `ApplyToTerrain` exactly** — same resolution, origin formula, and array dimensions — or terrain clears to the wrong region.
