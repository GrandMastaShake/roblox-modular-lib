--!strict
-- ExampleWorld.lua
-- Comprehensive integration demo showing the full terrain generation system
-- wired together via Dependency Injection (DI).  This is the "composition root"
-- for the terrain / world-building feature set.
--
-- WHAT THIS FILE DEMONSTRATES:
--   1. How to instantiate every terrain module with the shared EventBus.
--   2. How to configure a complete world (seed, size, feature flags).
--   3. How to call WorldBuilder:BuildWorld() and react to progress events.
--   4. How to use ChunkManager for streaming as a "player" moves around.
--   5. How the entire pipeline connects: terrain -> erosion -> biome ->
--      caves -> water -> objects -> atmosphere.
--
-- ARCHITECTURE NOTES:
--   - No terrain module imports another module directly.  All cross-module
--     communication flows through the shared EventBus.
--   - WorldBuilder is the orchestrator; it calls each module in pipeline order.
--   - Optional modules (WaterSystem, CaveSystem, etc.) can be omitted and the
--     corresponding pipeline stages are silently skipped.

-- =============================================================================
-- REQUIRE PATHS
-- =============================================================================

-- Core services (shared infrastructure used by ALL modules)
local EventBus = require(script.Parent.src.Core.EventBus)
local Config   = require(script.Parent.src.Core.Config)
local Types    = require(script.Parent.src.Core.Types) -- type aliases only

-- Terrain modules (all depend on Core via DI; never on each other directly)
local NoiseLib          = require(script.Parent.src.NoiseLib)
local TerrainGenerator  = require(script.Parent.src.TerrainGenerator)
local BiomeSystem       = require(script.Parent.src.BiomeSystem)
local ObjectPlacer      = require(script.Parent.src.ObjectPlacer)
local WaterSystem       = require(script.Parent.src.WaterSystem)
local CaveSystem        = require(script.Parent.src.CaveSystem)
local AtmosphereSystem  = require(script.Parent.src.AtmosphereSystem)
local ErosionSimulator  = require(script.Parent.src.ErosionSimulator)
local ChunkManager      = require(script.Parent.src.ChunkManager)
local WorldBuilder      = require(script.Parent.src.WorldBuilder)

-- =============================================================================
-- SHARED SERVICE SETUP (The "wiring harness")
-- =============================================================================

-- EventBus: the central nervous system. Every module gets the SAME bus so they
-- can communicate by event name without direct references.
local bus = EventBus.new()

-- Config: global tuning values.  Terrain modules read keys they care about via
-- :Get().  This keeps magic numbers out of module internals.
local config = Config.new({
    -- World generation seed: same seed -> identical world (reproducible).
    seed = 12345,

    -- World size in chunks (square grid centered at origin).
    -- size=2 for Studio demo (4 chunks = fast); use 8+ for production.
    size = 2,

    -- Terrain generation parameters
    terrain = {
        chunkSize        = 64,    -- studs per chunk side
        maxHeight        = 128,   -- maximum terrain height in studs
        seaLevel         = 32,    -- water plane Y coordinate
        erosion          = true,  -- enable erosion pass
        erosionIterations = 500,   -- reduced for Studio CPU limit (use 50000 in production)
        noise = {
            seed        = 12345,
            octaves     = 4,
            persistence = 0.5,
            lacunarity  = 2.0,
            scale       = 100,
        },
    },

    -- Feature toggles: set to true/false to enable/disable pipeline stages.
    water           = true,
    caves           = true,
    erosion         = true,
    objects         = true,
    atmosphere      = true,
    chunkStreaming  = true,
    viewDistance    = 3,  -- chunks to keep loaded around the player
})

-- =============================================================================
-- MODULE INSTANTIATION (Dependency Injection)
-- =============================================================================
-- Each module receives only the shared services it needs.  This satisfies the
-- "zero hard coupling" rule: you can swap any module or mock the bus in tests.

-- NoiseLib: the foundation of procedural generation.  Shared seed ensures all
-- noise-based systems (terrain, biome temp/moisture, caves) stay coherent.
local noiseLib = NoiseLib.new({
    seed        = config:Get("seed", 12345),
    octaves     = 4,
    persistence = 0.5,
    lacunarity  = 2.0,
    scale       = 100,
})

-- TerrainGenerator: converts noise heightmaps into Roblox Terrain voxels.
local terrainGen = TerrainGenerator.new(bus, config:Get("terrain"))

-- BiomeSystem: maps temperature + moisture to biome definitions.
local biomeSys = BiomeSystem.new(bus, config:Get("seed", 12345))

-- ObjectPlacer: scatters trees, rocks, foliage based on biome rules.
local objectPlacer = ObjectPlacer.new(bus)

-- WaterSystem: river networks and lake creation.
local waterSys = WaterSystem.new(bus, config:Get("seed", 12345))

-- CaveSystem: 3D noise cave networks underground.
local caveSys = CaveSystem.new(bus, config:Get("seed", 12345))

-- AtmosphereSystem: per-biome lighting, fog, sky, and soundscape.
local atmosphereSys = AtmosphereSystem.new(bus)

-- ErosionSimulator: thermal + hydraulic erosion on the heightmap.
local erosionSim = ErosionSimulator.new(bus, {
    droplets        = 500,    -- reduced for Studio CPU limit (use 50000 in production)
    erosionRate     = 0.1,
    depositionRate  = 0.05,
    evaporationRate = 0.01,
    gravity         = 9.81,
})

-- ChunkManager: chunk lifecycle (load / unload / stream around player).
local chunkMgr = ChunkManager.new(bus, terrainGen, objectPlacer)

-- =============================================================================
-- WORLDBUILDER ORCHESTRATOR
-- =============================================================================
-- WorldBuilder is the conductor.  It receives ALL the terrain modules via DI
-- and calls them in the correct pipeline order.  Optional modules after
-- objectPlacer can be nil and the corresponding stages are skipped.

local worldBuilder = WorldBuilder.new(
    bus,            -- eventBus      (required)
    terrainGen,     -- terrainGen    (required)
    biomeSys,       -- biomeSys      (required)
    objectPlacer,   -- objectPlacer  (required)
    waterSys,       -- waterSys?     (optional)
    caveSys,        -- caveSys?      (optional)
    erosionSim,     -- erosionSim?   (optional)
    atmosphereSys,  -- atmosphereSys?(optional)
    chunkMgr        -- chunkMgr?     (optional)
)

-- =============================================================================
-- CROSS-MODULE EVENT WIRING (Where the magic happens)
-- =============================================================================
-- Because modules emit events and never call each other directly, we wire
-- reactions HERE in the composition root.  This is the only file that knows
-- about ALL modules, making the system easy to refactor.

-- ---------------------------------------------------------------------------
-- WorldBuilder progress events — great for loading screens
-- ---------------------------------------------------------------------------

bus:Subscribe("WorldBuildStarted", function(data)
    print(string.format(
        "[WorldBuilder] World generation STARTED | seed=%d size=%dx%d chunks=%d",
        data.seed, data.size, data.size, data.totalChunks
    ))
    print(string.format(
        "[WorldBuilder] Features enabled: water=%s caves=%s erosion=%s objects=%s atmosphere=%s",
        tostring(data.features.water),
        tostring(data.features.caves),
        tostring(data.features.erosion),
        tostring(data.features.objects),
        tostring(data.features.atmosphere)
    ))
end)

bus:Subscribe("BuildProgress", function(data: {
    current: number,
    total: number,
    chunkCx: number,
    chunkCz: number,
    stage: string,
})
    -- Only print every 5th chunk to avoid spam
    if data.current % 5 == 0 or data.current == 1 then
        print(string.format(
            "[WorldBuilder] Progress %d/%d (%.0f%%) | chunk (%d,%d) | stage=%s",
            data.current,
            data.total,
            (data.current / data.total) * 100,
            data.chunkCx,
            data.chunkCz,
            data.stage
        ))
    end
end)

bus:Subscribe("ChunkBuilt", function(data)
    -- Uncomment for verbose per-chunk logging:
    -- print(string.format(
    --     "[WorldBuilder] Chunk (%d,%d) built | progress=%.1f%%",
    --     data.cx, data.cz, data.progress * 100
    -- ))
end)

bus:Subscribe("WorldBuildCompleted", function(data)
    print(string.format(
        "[WorldBuilder] World generation COMPLETED | seed=%d chunks=%d time=%.2fs",
        data.seed, data.chunksGenerated, data.generationTime
    ))
    print(string.format(
        "[WorldBuilder] Biomes found: %s",
        table.concat(data.biomes, ", ")
    ))
end)

-- ---------------------------------------------------------------------------
-- TerrainGenerator events
-- ---------------------------------------------------------------------------
bus:Subscribe("ChunkGenerated", function(data)
    print(string.format("[Terrain] Chunk generated: (%d,%d)", data.cx, data.cz))
end)

bus:Subscribe("TerrainApplied", function(data)
    -- Terrain voxels have been written to workspace.Terrain
    -- print(string.format("[Terrain] Terrain applied to chunk (%d,%d)", data.cx, data.cz))
end)

-- ---------------------------------------------------------------------------
-- BiomeSystem events
-- ---------------------------------------------------------------------------
bus:Subscribe("BiomeRegistered", function(data)
    print(string.format("[Biome] Registered biome: %s", data.biomeId))
end)

bus:Subscribe("BiomeAssigned", function(data)
    -- Called per-chunk-column; too noisy to print every call.
    -- Use for biome-border visual effects or minimap updates.
end)

-- ---------------------------------------------------------------------------
-- ObjectPlacer events
-- ---------------------------------------------------------------------------
bus:Subscribe("ObjectPlaced", function(data)
    -- data: { objectId, cframe, scale, chunkCx, chunkCz }
    -- print(string.format("[Objects] Placed %s at %s", data.objectId, tostring(data.cframe)))
end)

bus:Subscribe("PlacementCompleted", function(data)
    print(string.format(
        "[Objects] Placement completed for chunk (%d,%d) | %d objects placed",
        data.cx, data.cz, data.count
    ))
end)

-- ---------------------------------------------------------------------------
-- WaterSystem events
-- ---------------------------------------------------------------------------
bus:Subscribe("RiverGenerated", function(data)
    print(string.format("[Water] River generated: %d nodes", #data.river))
end)

bus:Subscribe("RiverCarved", function(data)
    print(string.format("[Water] River carved into terrain"))
end)

bus:Subscribe("LakeCreated", function(data)
    print(string.format(
        "[Water] Lake created at (%d,%d) with radius %d",
        data.cx, data.cz, data.radius
    ))
end)

-- ---------------------------------------------------------------------------
-- CaveSystem events
-- ---------------------------------------------------------------------------
bus:Subscribe("CavesCarved", function(data)
    print(string.format("[Caves] Caves carved for chunk (%d,%d)", data.cx, data.cz))
end)

bus:Subscribe("CaveEntranceFound", function(data)
    print(string.format(
        "[Caves] Cave entrance found at (%d, %d, %d)",
        data.x, data.y, data.z
    ))
end)

-- ---------------------------------------------------------------------------
-- ErosionSimulator events
-- ---------------------------------------------------------------------------
bus:Subscribe("ErosionCompleted", function(data)
    print(string.format("[Erosion] Hydraulic erosion completed | droplets=%d", data.droplets))
end)

bus:Subscribe("ThermalErosionCompleted", function(data)
    print(string.format("[Erosion] Thermal erosion completed"))
end)

-- ---------------------------------------------------------------------------
-- AtmosphereSystem events
-- ---------------------------------------------------------------------------
bus:Subscribe("AtmosphereApplied", function(data)
    -- Atmosphere has been applied to a chunk's region
    -- print(string.format("[Atmosphere] Applied to biome %s", data.biomeId))
end)

bus:Subscribe("AtmosphereTransitioned", function(data)
    print(string.format(
        "[Atmosphere] Transitioned %s -> %s in %.1fs",
        data.fromBiome, data.toBiome, data.duration
    ))
end)

-- ---------------------------------------------------------------------------
-- ChunkManager events
-- ---------------------------------------------------------------------------
bus:Subscribe("ChunkLoaded", function(data)
    print(string.format("[ChunkMgr] Chunk loaded: (%d,%d)", data.cx, data.cz))
end)

bus:Subscribe("ChunkUnloaded", function(data)
    print(string.format("[ChunkMgr] Chunk unloaded: (%d,%d)", data.cx, data.cz))
end)

bus:Subscribe("ChunksStreamed", function(data)
    print(string.format(
        "[ChunkMgr] Streamed: %d loaded, %d unloaded",
        data.loadedCount, data.unloadedCount
    ))
end)

-- =============================================================================
-- BIOME REGISTRATION (Default biome set)
-- =============================================================================
-- Register the standard biome palette.  Temperature and moisture ranges are
-- 0..1.  The BiomeSystem uses two noise fields (large-scale variation) to
-- determine temp/moisture at any world position, then selects the biome whose
-- ranges contain that point.

biomeSys:RegisterBiome({
    id = "tundra", name = "Tundra",
    tempRange = { min = 0.0, max = 0.2 },
    moistureRange = { min = 0.0, max = 1.0 },
    baseColor = Color3.fromRGB(220, 230, 240),
    terrainMaterial = Enum.Material.Snow,
    treeDensity = 0.0, rockDensity = 0.1, flowerDensity = 0.0,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "taiga", name = "Taiga",
    tempRange = { min = 0.1, max = 0.35 },
    moistureRange = { min = 0.4, max = 1.0 },
    baseColor = Color3.fromRGB(40, 80, 40),
    terrainMaterial = Enum.Material.Grass,
    treeDensity = 0.7, rockDensity = 0.1, flowerDensity = 0.1,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "temperate_forest", name = "Temperate Forest",
    tempRange = { min = 0.25, max = 0.55 },
    moistureRange = { min = 0.3, max = 0.9 },
    baseColor = Color3.fromRGB(50, 140, 50),
    terrainMaterial = Enum.Material.Grass,
    treeDensity = 0.8, rockDensity = 0.1, flowerDensity = 0.3,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "grassland", name = "Grassland",
    tempRange = { min = 0.3, max = 0.65 },
    moistureRange = { min = 0.1, max = 0.5 },
    baseColor = Color3.fromRGB(120, 180, 50),
    terrainMaterial = Enum.Material.Grass,
    treeDensity = 0.1, rockDensity = 0.05, flowerDensity = 0.5,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "desert", name = "Desert",
    tempRange = { min = 0.5, max = 1.0 },
    moistureRange = { min = 0.0, max = 0.25 },
    baseColor = Color3.fromRGB(230, 200, 120),
    terrainMaterial = Enum.Material.Sand,
    treeDensity = 0.0, rockDensity = 0.2, flowerDensity = 0.0,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "tropical_rainforest", name = "Tropical Rainforest",
    tempRange = { min = 0.6, max = 1.0 },
    moistureRange = { min = 0.6, max = 1.0 },
    baseColor = Color3.fromRGB(30, 100, 30),
    terrainMaterial = Enum.Material.Grass,
    treeDensity = 0.95, rockDensity = 0.05, flowerDensity = 0.4,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "savanna", name = "Savanna",
    tempRange = { min = 0.55, max = 0.85 },
    moistureRange = { min = 0.15, max = 0.5 },
    baseColor = Color3.fromRGB(160, 170, 60),
    terrainMaterial = Enum.Material.Grass,
    treeDensity = 0.3, rockDensity = 0.1, flowerDensity = 0.2,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "mountains", name = "Mountains",
    tempRange = { min = 0.0, max = 1.0 },
    moistureRange = { min = 0.0, max = 1.0 },
    baseColor = Color3.fromRGB(120, 120, 120),
    terrainMaterial = Enum.Material.Rock,
    treeDensity = 0.05, rockDensity = 0.8, flowerDensity = 0.0,
    groundCover = {},
})

biomeSys:RegisterBiome({
    id = "ocean", name = "Ocean",
    tempRange = { min = 0.0, max = 1.0 },
    moistureRange = { min = 0.0, max = 1.0 },
    baseColor = Color3.fromRGB(40, 80, 160),
    terrainMaterial = Enum.Material.Sand,
    treeDensity = 0.0, rockDensity = 0.0, flowerDensity = 0.0,
    groundCover = {},
})

-- =============================================================================
-- OBJECT REGISTRATION (Scattering definitions)
-- =============================================================================
-- Register the types of objects that can be placed on terrain.  Each object
-- has constraints (slope, altitude, biome whitelist) that the ObjectPlacer
-- validates during placement.

objectPlacer:RegisterObject({
    id = "oak_tree", name = "Oak Tree",
    category = "tree",
    modelId = "rbxassetid://12345678",
    scaleRange = { min = 0.8, max = 1.5 },
    slopeMax = 0.4,
    altitudeMin = 10, altitudeMax = 100,
    biomeWhitelist = { "temperate_forest", "grassland" },
    collision = true,
})

objectPlacer:RegisterObject({
    id = "pine_tree", name = "Pine Tree",
    category = "tree",
    modelId = "rbxassetid://12345679",
    scaleRange = { min = 1.0, max = 2.0 },
    slopeMax = 0.5,
    altitudeMin = 15, altitudeMax = 120,
    biomeWhitelist = { "taiga", "mountains" },
    collision = true,
})

objectPlacer:RegisterObject({
    id = "palm_tree", name = "Palm Tree",
    category = "tree",
    modelId = "rbxassetid://12345680",
    scaleRange = { min = 0.9, max = 1.4 },
    slopeMax = 0.3,
    altitudeMin = 5, altitudeMax = 60,
    biomeWhitelist = { "tropical_rainforest", "savanna" },
    collision = true,
})

objectPlacer:RegisterObject({
    id = "boulder", name = "Boulder",
    category = "rock",
    modelId = "rbxassetid://12345681",
    scaleRange = { min = 0.5, max = 2.5 },
    slopeMax = 0.8,
    altitudeMin = 0, altitudeMax = 128,
    biomeWhitelist = nil, -- all biomes
    collision = true,
})

objectPlacer:RegisterObject({
    id = "wildflowers", name = "Wildflowers",
    category = "flower",
    modelId = "rbxassetid://12345682",
    scaleRange = { min = 0.5, max = 1.0 },
    slopeMax = 0.3,
    altitudeMin = 10, altitudeMax = 80,
    biomeWhitelist = { "grassland", "temperate_forest" },
    collision = false,
})

objectPlacer:RegisterObject({
    id = "cactus", name = "Cactus",
    category = "bush",
    modelId = "rbxassetid://12345683",
    scaleRange = { min = 0.7, max = 1.3 },
    slopeMax = 0.3,
    altitudeMin = 5, altitudeMax = 50,
    biomeWhitelist = { "desert", "savanna" },
    collision = true,
})

-- =============================================================================
-- WORLD GENERATION
-- =============================================================================
-- Build the complete world with the configuration defined above.  WorldBuilder
-- emits progress events after each chunk, so you can wire a loading bar or
-- streaming UI to "BuildProgress" and "WorldBuildCompleted".

print("\n=================================================================")
print("  EXAMPLE WORLD: Starting world generation demo")
print("=================================================================\n")

local worldConfig = {
    seed = config:Get("seed", 12345),
    size = config:Get("size", 8),
    terrain = config:Get("terrain") :: any,
    water      = config:Get("water", true),
    caves      = config:Get("caves", true),
    erosion    = config:Get("erosion", true),
    objects    = config:Get("objects", true),
    atmosphere = config:Get("atmosphere", true),
    chunkStreaming = config:Get("chunkStreaming", true),
    viewDistance   = config:Get("viewDistance", 3),
}

local worldData = worldBuilder:BuildWorld(worldConfig)

-- =============================================================================
-- POST-GENERATION STATS
-- =============================================================================

print("\n=================================================================")
print("  WORLD GENERATION STATS")
print("=================================================================")
print(string.format("  Seed:              %d", worldData.seed))
print(string.format("  Size:              %d x %d chunks", worldData.size, worldData.size))
print(string.format("  Chunks generated:  %d", worldData.chunksGenerated))
print(string.format("  Generation time:   %.3f seconds", worldData.generationTime))
print(string.format("  Unique biomes:     %d (%s)", #worldData.biomes, table.concat(worldData.biomes, ", ")))
print(string.format("  Checkpoints:       %d", #worldData.checkpoints))
for _, cp in ipairs(worldData.checkpoints) do
    print(string.format("    - wave %d: %s", cp.wave, cp.status))
end
print("=================================================================\n")

-- =============================================================================
-- CHUNK STREAMING DEMO
-- =============================================================================
-- Demonstrate the ChunkManager's StreamAround function by simulating a player
-- moving around the world.  The ChunkManager loads chunks within viewDistance
-- of the player and unloads those that fall outside.

if config:Get("chunkStreaming", true) and chunkMgr then
    print("\n=================================================================")
    print("  CHUNK STREAMING DEMO")
    print("=================================================================\n")

    chunkMgr:SetViewDistance(config:Get("viewDistance", 3))

    -- Simulate a player starting at the center of the world and walking
    -- along a path.  In a real game, this would be driven by the player's
    -- HumanoidRootPart position every Heartbeat.
    local playerPositions = {
        { x = 0,   z = 0   },   -- spawn at center
        { x = 64,  z = 0   },   -- walk +X (one chunk)
        { x = 128, z = 64  },   -- walk +X+Z (two chunks)
        { x = 192, z = 128 },   -- walk further
        { x = 0,   z = 0   },   -- return to center
    }

    for i, pos in ipairs(playerPositions) do
        print(string.format("[Streaming] Player moves to (%d, %d)", pos.x, pos.z))

        local loaded, unloaded = chunkMgr:StreamAround(pos.x, pos.z)
        print(string.format(
            "[Streaming] -> %d chunks loaded, %d chunks unloaded",
            #loaded, #unloaded
        ))

        -- Brief delay between movements so output is readable
        if i < #playerPositions then
            task.wait(0.1)
        end
    end

    print("\n=================================================================")
    print(string.format(
        "  Final loaded chunks: %d",
        #(chunkMgr:GetLoadedChunks())
    ))
    print("=================================================================\n")
end

-- =============================================================================
-- SINGLE CHUNK BUILD DEMO
-- =============================================================================
-- BuildChunk can be used to generate a single chunk on demand, outside of the
-- initial world build.  This is useful for:
--   - Infinite-world terrain (procedural chunks as the player explores)
--   - Dynamic world modification (e.g. a meteor crater)
--   - Server-authoritative chunk regeneration

print("\n=================================================================")
print("  SINGLE CHUNK BUILD DEMO")
print("=================================================================\n")

-- Build a chunk far outside the original world bounds
local extraChunk = worldBuilder:BuildChunk(100, 100)
print(string.format(
    "[BuildChunk] Built chunk (%d,%d) | heightmap size: %dx%d",
    extraChunk.cx, extraChunk.cz,
    #extraChunk.heightmap,
    extraChunk.heightmap[1] and #(extraChunk.heightmap[1]) or 0
))

-- =============================================================================
-- MODULE STATUS DIAGNOSTICS
-- =============================================================================
-- Print which modules are injected and which are missing.  Useful for
-- verifying that the DI setup is complete.

print("\n=================================================================")
print("  MODULE STATUS")
print("=================================================================")
local status = worldBuilder:GetModuleStatus()
for name, present in pairs(status) do
    local icon = present and "[OK]" or "[MISSING]"
    print(string.format("  %s %s", icon, name))
end
print("=================================================================\n")

-- =============================================================================
-- CUSTOMIZATION GUIDE (commented)
-- =============================================================================
--[[

HOW TO CUSTOMIZE THIS DEMO:

1.  Change the world size:
    Set config.size = 16 for a 1024x1024-stud world (16x16 chunks).
    Larger worlds take more time and memory but give more exploration area.

2.  Disable features to speed up generation:
    Set config.water = false, config.caves = false, etc.
    The WorldBuilder will skip those pipeline stages automatically.

3.  Use a different seed:
    Change config.seed to any number.  Same seed = identical world.
    This is great for competitive multiplayer (fair worlds) or save files.

4.  Add custom biomes:
    Call biomeSys:RegisterBiome({ ... }) with your own temp/moisture ranges,
    colors, and terrain materials.  The BiomeSystem will pick them up
    automatically during GenerateBiomeMap.

5.  Add custom objects:
    Call objectPlacer:RegisterObject({ ... }) with new model IDs,
    scale ranges, and biome whitelists.  The ObjectPlacer uses Poisson disc
    sampling to distribute them naturally without overlapping.

6.  Adjust erosion parameters:
    Pass a different ErosionConfig to ErosionSimulator.new() to control
    droplet count, erosion rate, and deposition rate.  More droplets =
    more realistic but slower.

7.  Change view distance for streaming:
    Set config.viewDistance = 5 to keep more chunks loaded around the
    player (better visuals, more memory) or = 1 for minimal memory.

8.  Hook up a real player character:
    Replace the simulated playerPositions loop with:

    local player = game.Players.LocalPlayer
    local char = player.Character or player.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart")
    game:GetService("RunService").Heartbeat:Connect(function()
        local pos = hrp.Position
        chunkMgr:StreamAround(pos.X, pos.Z)
    end)

9.  Create a loading screen:
    Subscribe to "BuildProgress" and update a Gui progress bar:

    bus:Subscribe("BuildProgress", function(data)
        local bar = playerGui.LoadingScreen.ProgressBar
        bar.Size = UDim2.new(data.current / data.total, 0, 1, 0)
        bar.Parent.StatusLabel.Text = data.stage
    end)

    bus:Subscribe("WorldBuildCompleted", function()
        playerGui.LoadingScreen.Enabled = false
    end)

10. Save/load generated worlds:
    Serialize worldData.chunks (heightmaps, biome maps) to DataStore,
    then on load, skip generation and use TerrainGenerator:ApplyToTerrain()
    directly from the saved chunk data.

--]]

-- =============================================================================
-- PUBLIC API — Return the composition root so other scripts can access it
-- =============================================================================

export type ExampleWorld = {
    Bus: typeof(bus),
    Config: typeof(config),
    WorldBuilder: typeof(worldBuilder),
    WorldData: typeof(worldData),
    ChunkManager: ChunkManager?,
    TerrainGenerator: typeof(terrainGen),
    BiomeSystem: typeof(biomeSys),
    ObjectPlacer: typeof(objectPlacer),
    WaterSystem: WaterSystem?,
    CaveSystem: CaveSystem?,
    ErosionSimulator: ErosionSimulator?,
    AtmosphereSystem: AtmosphereSystem?,
    NoiseLib: typeof(noiseLib),
}

local worldAPI: ExampleWorld = {
    Bus               = bus,
    Config            = config,
    WorldBuilder      = worldBuilder,
    WorldData         = worldData,
    ChunkManager      = chunkMgr,
    TerrainGenerator  = terrainGen,
    BiomeSystem       = biomeSys,
    ObjectPlacer      = objectPlacer,
    WaterSystem       = waterSys,
    CaveSystem        = caveSys,
    ErosionSimulator  = erosionSim,
    AtmosphereSystem  = atmosphereSys,
    NoiseLib          = noiseLib,
}

return worldAPI
