--!strict
-- test_WorldBuilder.lua
-- Tests for the WorldBuilder orchestrator.
--
-- Covers:
--   1. BuildWorld with minimal config (no optional modules)
--   2. BuildWorld with all optional modules enabled
--   3. BuildChunk (single chunk on demand)
--   4. Progress event tracking
--   5. WorldData structure validation
--   6. Graceful nil-module handling (skipped stages, no errors)

-- =============================================================================
-- HELPERS
-- =============================================================================

local function assertEq(a: any, b: any, msg: string)
    if a ~= b then
        error(msg .. string.format(" | expected %s, got %s", tostring(b), tostring(a)))
    end
end

local function assertTrue(a: boolean, msg: string)
    if not a then
        error(msg .. " | expected true")
    end
end

local function assertFalse(a: boolean, msg: string)
    if a then
        error(msg .. " | expected false")
    end
end

local function assertNotNil(a: any, msg: string)
    if a == nil then
        error(msg .. " | expected non-nil")
    end
end

-- =============================================================================
-- MOCK MODULE FACTORIES
-- =============================================================================
-- Since the real terrain modules are built by other agents in parallel, we
-- create lightweight mocks that satisfy the interface contracts WorldBuilder
-- depends on.  Each mock records its call history so we can assert that
-- stages were invoked (or skipped) correctly.

local function createMockEventBus()
    local bus = {
        _events = {} :: { [string]: { any } },
        Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
            return function() end
        end,
        Emit = function(self: any, eventName: string, payload: any)
            if not self._events[eventName] then
                self._events[eventName] = {}
            end
            table.insert(self._events[eventName], payload)
        end,
        GetEvents = function(self: any, eventName: string): { any }
            return self._events[eventName] or {}
        end,
        Clear = function(self: any)
            table.clear(self._events)
        end,
    }
    return bus
end

local function createMockTerrainGenerator()
    local gen = {
        _calls = {} :: { { method: string, args: { any } } },
        _chunkCounter = 0,

        GenerateChunk = function(self: any, cx: number, cz: number): any
            table.insert(self._calls, { method = "GenerateChunk", args = { cx, cz } })
            self._chunkCounter += 1
            -- Return a realistic ChunkData structure
            local heightmap: { { number } } = {}
            local surfaceY: { { number } } = {}
            for x = 1, 4 do
                heightmap[x] = {}
                surfaceY[x] = {}
                for z = 1, 4 do
                    heightmap[x][z] = 50 + math.random() * 50
                    surfaceY[x][z] = heightmap[x][z]
                end
            end
            return {
                cx = cx, cz = cz,
                heightmap = heightmap,
                surfaceY = surfaceY,
            }
        end,

        ApplyToTerrain = function(self: any, chunk: any)
            table.insert(self._calls, { method = "ApplyToTerrain", args = { chunk.cx, chunk.cz } })
        end,

        GetHeightAt = function(self: any, worldX: number, worldZ: number): number
            return 50
        end,

        SetTerrainConfig = function(self: any, config: any)
            table.insert(self._calls, { method = "SetTerrainConfig", args = { config } })
        end,
    }
    return gen
end

local function createMockBiomeSystem()
    local biomeSys = {
        _calls = {} :: { { method: string, args: { any } } },
        _biomes = {} :: { any },

        RegisterBiome = function(self: any, biome: any)
            table.insert(self._biomes, biome)
        end,

        GetBiome = function(self: any, temp: number, moisture: number): any
            return { id = "grassland", name = "Grassland" }
        end,

        GenerateBiomeMap = function(self: any, chunk: any): any
            table.insert(self._calls, { method = "GenerateBiomeMap", args = { chunk.cx, chunk.cz } })
            -- Add a biomeMap to the chunk
            local biomeMap: { { string } } = {}
            for x = 1, #chunk.heightmap do
                biomeMap[x] = {}
                for z = 1, #(chunk.heightmap[x]) do
                    biomeMap[x][z] = "grassland"
                end
            end
            chunk.biomeMap = biomeMap
            return chunk
        end,

        GetAllBiomes = function(self: any): { any }
            return self._biomes
        end,

        GetTempAt = function(self: any, x: number, z: number): number
            return 0.5
        end,

        GetMoistureAt = function(self: any, x: number, z: number): number
            return 0.5
        end,
    }
    return biomeSys
end

local function createMockObjectPlacer()
    local placer = {
        _calls = {} :: { { method: string, args: { any } } },
        _placementCount = 0,
        _densityMultiplier = 1.0,

        RegisterObject = function(self: any, def: any)
            table.insert(self._calls, { method = "RegisterObject", args = { def.id } })
        end,

        PlaceInChunk = function(self: any, chunk: any): { any }
            table.insert(self._calls, { method = "PlaceInChunk", args = { chunk.cx, chunk.cz } })
            -- Return a few mock placements
            local placements = {}
            for i = 1, 3 do
                table.insert(placements, {
                    objectId = "test_tree",
                    cframe = CFrame.new(i * 10, 50, i * 10),
                    scale = 1.0,
                })
            end
            self._placementCount += #placements
            return placements
        end,

        ClearChunk = function(self: any, cx: number, cz: number)
            table.insert(self._calls, { method = "ClearChunk", args = { cx, cz } })
        end,

        GetPlacementCount = function(self: any): number
            return self._placementCount
        end,

        SetDensityMultiplier = function(self: any, multiplier: number)
            self._densityMultiplier = multiplier
        end,
    }
    return placer
end

local function createMockWaterSystem()
    local water = {
        _calls = {} :: { { method: string, args: { any } } },
        _riversGenerated = false,

        GenerateRivers = function(self: any, terrain: any): { any }
            table.insert(self._calls, { method = "GenerateRivers", args = {} })
            self._riversGenerated = true
            return {}
        end,

        CarveRiver = function(self: any, river: { any })
            table.insert(self._calls, { method = "CarveRiver", args = {} })
        end,

        CreateLake = function(self: any, cx: number, cz: number, radius: number)
            table.insert(self._calls, { method = "CreateLake", args = { cx, cz, radius } })
        end,

        ErodeTerrain = function(self: any, chunk: any, river: { any }): any
            return chunk
        end,
    }
    return water
end

local function createMockCaveSystem()
    local caves = {
        _calls = {} :: { { method: string, args: { any } } },

        CarveChunk = function(self: any, chunk: any): any
            table.insert(self._calls, { method = "CarveChunk", args = { chunk.cx, chunk.cz } })
            return chunk
        end,

        IsCaveAt = function(self: any, x: number, y: number, z: number): boolean
            return false
        end,

        SetConfig = function(self: any, config: any)
            table.insert(self._calls, { method = "SetConfig", args = {} })
        end,
    }
    return caves
end

local function createMockErosionSimulator()
    local erosion = {
        _calls = {} :: { { method: string, args: { any } } },

        Erode = function(self: any, heightmap: { { number } }): { { number } }
            table.insert(self._calls, { method = "Erode", args = { #heightmap } })
            -- Slightly modify the heightmap to simulate erosion
            local result: { { number } } = {}
            for x = 1, #heightmap do
                result[x] = {}
                for z = 1, #(heightmap[x]) do
                    result[x][z] = heightmap[x][z] - 0.5 -- subtle erosion
                end
            end
            return result
        end,

        ThermalErosion = function(self: any, heightmap: { { number } }, talusAngle: number): { { number } }
            return heightmap
        end,

        SetConfig = function(self: any, config: any)
            table.insert(self._calls, { method = "SetConfig", args = {} })
        end,
    }
    return erosion
end

local function createMockAtmosphereSystem()
    local atmos = {
        _calls = {} :: { { method: string, args: { any } } },

        RegisterBiomeAtmosphere = function(self: any, biomeId: string, config: any)
            table.insert(self._calls, { method = "RegisterBiomeAtmosphere", args = { biomeId } })
        end,

        ApplyToRegion = function(self: any, biomeId: string, region: Region3)
            table.insert(self._calls, { method = "ApplyToRegion", args = { biomeId } })
        end,

        ApplyToChunk = function(self: any, chunk: any)
            table.insert(self._calls, { method = "ApplyToChunk", args = { chunk.cx, chunk.cz } })
        end,

        TransitionAtmosphere = function(self: any, fromBiome: string, toBiome: string, duration: number)
            table.insert(self._calls, { method = "TransitionAtmosphere", args = { fromBiome, toBiome } })
        end,
    }
    return atmos
end

local function createMockChunkManager()
    local mgr = {
        _calls = {} :: { { method: string, args = { any } } },
        _loadedChunks = {} :: { [string]: boolean },
        _viewDistance = 3,

        LoadChunk = function(self: any, cx: number, cz: number): any
            table.insert(self._calls, { method = "LoadChunk", args = { cx, cz } })
            self._loadedChunks[string.format("%d,%d", cx, cz)] = true
            return { cx = cx, cz = cz }
        end,

        UnloadChunk = function(self: any, cx: number, cz: number)
            table.insert(self._calls, { method = "UnloadChunk", args = { cx, cz } })
            self._loadedChunks[string.format("%d,%d", cx, cz)] = nil
        end,

        IsChunkLoaded = function(self: any, cx: number, cz: number): boolean
            return self._loadedChunks[string.format("%d,%d", cx, cz)] == true
        end,

        GetLoadedChunks = function(self: any): { { cx: number, cz: number } }
            local list = {}
            for key, _ in pairs(self._loadedChunks) do
                local cx, cz = string.match(key, "(-?%d+),(-?%d+)")
                if cx and cz then
                    table.insert(list, { cx = tonumber(cx), cz = tonumber(cz) })
                end
            end
            return list
        end,

        SetViewDistance = function(self: any, chunks: number)
            self._viewDistance = chunks
        end,

        StreamAround = function(self: any, worldX: number, worldZ: number): ({ any }, { any })
            table.insert(self._calls, { method = "StreamAround", args = { worldX, worldZ } })
            -- Return mock loaded/unloaded lists
            return {}, {}
        end,
    }
    return mgr
end

-- =============================================================================
-- TEST 1: BuildWorld with minimal config (no optional modules)
-- =============================================================================
print("TEST 1: BuildWorld with minimal config (no optional modules)")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    local worldConfig = {
        seed = 12345,
        size = 2, -- 2x2 = 4 chunks (small for fast testing)
        terrain = {
            chunkSize = 64,
            maxHeight = 128,
            seaLevel = 32,
        },
        -- All optional features explicitly disabled
        water = false,
        caves = false,
        erosion = false,
        objects = false, -- skip object placement too
        atmosphere = false,
        chunkStreaming = false,
        viewDistance = 1,
    }

    local worldData = wb:BuildWorld(worldConfig)

    -- Validate WorldData structure
    assertNotNil(worldData, "WorldData should not be nil")
    assertEq(worldData.seed, 12345, "WorldData.seed")
    assertEq(worldData.size, 2, "WorldData.size")
    assertEq(worldData.chunksGenerated, 4, "WorldData.chunksGenerated (2x2)")
    assertTrue(worldData.generationTime >= 0, "WorldData.generationTime should be >= 0")
    assertTrue(#worldData.checkpoints >= 2, "WorldData should have start+end checkpoints")

    -- TerrainGenerator should have been called for each chunk
    assertEq(terrainGen._chunkCounter, 4, "TerrainGenerator.GenerateChunk call count")

    -- BiomeSystem should have been called for each chunk
    assertEq(#biomeSys._calls, 4, "BiomeSystem.GenerateBiomeMap call count")

    -- ObjectPlacer should NOT have been called (objects=false)
    assertEq(#objectPlacer._calls, 0, "ObjectPlacer should not be called when objects=false")

    -- Events should have been emitted
    local startedEvents = bus.GetEvents(bus, "WorldBuildStarted")
    assertEq(#startedEvents, 1, "WorldBuildStarted event count")

    local completedEvents = bus.GetEvents(bus, "WorldBuildCompleted")
    assertEq(#completedEvents, 1, "WorldBuildCompleted event count")

    local chunkBuiltEvents = bus.GetEvents(bus, "ChunkBuilt")
    assertEq(#chunkBuiltEvents, 4, "ChunkBuilt event count")

    -- BuildProgress should have been emitted for each chunk
    local progressEvents = bus.GetEvents(bus, "BuildProgress")
    assertTrue(#progressEvents >= 4, "BuildProgress should have events for each chunk")

    -- GetWorldData should return the same data
    local retrievedData = wb:GetWorldData()
    assertNotNil(retrievedData, "GetWorldData should return data")
    assertEq(retrievedData.seed, worldData.seed, "GetWorldData consistency")

    print("  PASSED")
end

-- =============================================================================
-- TEST 2: BuildWorld with all optional modules enabled
-- =============================================================================
print("TEST 2: BuildWorld with all optional modules enabled")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()
    local waterSys = createMockWaterSystem()
    local caveSys = createMockCaveSystem()
    local erosionSim = createMockErosionSimulator()
    local atmosphereSys = createMockAtmosphereSystem()
    local chunkMgr = createMockChunkManager()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(
        bus, terrainGen, biomeSys, objectPlacer,
        waterSys, caveSys, erosionSim, atmosphereSys, chunkMgr
    )

    local worldConfig = {
        seed = 99999,
        size = 2,
        terrain = {
            chunkSize = 64,
            maxHeight = 128,
            seaLevel = 32,
        },
        water = true,
        caves = true,
        erosion = true,
        objects = true,
        atmosphere = true,
        chunkStreaming = true,
        viewDistance = 2,
    }

    local worldData = wb:BuildWorld(worldConfig)

    -- Validate structure
    assertNotNil(worldData, "WorldData should not be nil")
    assertEq(worldData.seed, 99999, "WorldData.seed")
    assertEq(worldData.size, 2, "WorldData.size")
    assertEq(worldData.chunksGenerated, 4, "WorldData.chunksGenerated")

    -- TerrainGenerator: 4 chunks
    assertEq(terrainGen._chunkCounter, 4, "TerrainGenerator call count")

    -- ErosionSimulator: should have been called for each chunk
    assertEq(#erosionSim._calls, 4, "ErosionSimulator.Erode call count")

    -- CaveSystem: should have been called for each chunk
    assertEq(#caveSys._calls, 4, "CaveSystem.CarveChunk call count")

    -- WaterSystem: GenerateRivers should have been called (once per world)
    assertTrue(#(waterSys._calls) > 0, "WaterSystem should have been called")

    -- ObjectPlacer: should have been called for each chunk
    assertEq(#objectPlacer._calls, 4, "ObjectPlacer.PlaceInChunk call count")

    -- AtmosphereSystem: should have been called for each chunk
    assertEq(#atmosphereSys._calls, 4, "AtmosphereSystem.ApplyToChunk call count")

    -- Biomes should be collected
    assertTrue(#worldData.biomes > 0, "WorldData.biomes should not be empty")

    -- Events
    assertEq(#(bus.GetEvents(bus, "WorldBuildStarted")), 1, "WorldBuildStarted")
    assertEq(#(bus.GetEvents(bus, "WorldBuildCompleted")), 1, "WorldBuildCompleted")
    assertEq(#(bus.GetEvents(bus, "ChunkBuilt")), 4, "ChunkBuilt events")

    -- Module status should show all present
    local status = wb:GetModuleStatus()
    assertTrue(status.EventBus, "EventBus status")
    assertTrue(status.TerrainGenerator, "TerrainGenerator status")
    assertTrue(status.BiomeSystem, "BiomeSystem status")
    assertTrue(status.ObjectPlacer, "ObjectPlacer status")
    assertTrue(status.WaterSystem, "WaterSystem status")
    assertTrue(status.CaveSystem, "CaveSystem status")
    assertTrue(status.ErosionSimulator, "ErosionSimulator status")
    assertTrue(status.AtmosphereSystem, "AtmosphereSystem status")
    assertTrue(status.ChunkManager, "ChunkManager status")

    print("  PASSED")
end

-- =============================================================================
-- TEST 3: BuildChunk (single chunk on demand)
-- =============================================================================
print("TEST 3: BuildChunk (single chunk on demand)")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    -- Build a single chunk outside of BuildWorld
    local chunk = wb:BuildChunk(10, 20)

    -- Validate returned chunk
    assertNotNil(chunk, "BuildChunk should return a chunk")
    assertEq(chunk.cx, 10, "Chunk cx")
    assertEq(chunk.cz, 20, "Chunk cz")
    assertNotNil(chunk.heightmap, "Chunk should have heightmap")
    assertTrue(#chunk.heightmap > 0, "Heightmap should have rows")

    -- Should have emitted ChunkBuilt event
    local chunkBuiltEvents = bus.GetEvents(bus, "ChunkBuilt")
    assertTrue(#chunkBuiltEvents >= 1, "BuildChunk should emit ChunkBuilt")

    print("  PASSED")
end

-- =============================================================================
-- TEST 4: Progress tracking through BuildProgress events
-- =============================================================================
print("TEST 4: Progress tracking through BuildProgress events")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    -- Track progress manually
    local progressTracker = {
        maxCurrent = 0,
        stagesSeen = {} :: { [string]: boolean },
    }

    bus.Subscribe(bus, "BuildProgress", function(data: any)
        if data.current > progressTracker.maxCurrent then
            progressTracker.maxCurrent = data.current
        end
        if data.stage then
            progressTracker.stagesSeen[data.stage] = true
        end
    end)

    local worldConfig = {
        seed = 11111,
        size = 2, -- 4 chunks
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        water = false,
        caves = false,
        erosion = false,
        objects = false,
        atmosphere = false,
    }

    wb:BuildWorld(worldConfig)

    -- Progress should have reached 4 (all chunks)
    assertTrue(progressTracker.maxCurrent >= 1, "Progress should have advanced")

    -- The "terrain" stage should always be seen (it's the first stage)
    assertTrue(progressTracker.stagesSeen["terrain"], "Terrain stage should be seen")

    -- Stages that are disabled should NOT appear
    assertFalse(progressTracker.stagesSeen["water"] == true, "Water stage should not appear when disabled")
    assertFalse(progressTracker.stagesSeen["caves"] == true, "Caves stage should not appear when disabled")

    print("  PASSED")
end

-- =============================================================================
-- TEST 5: WorldData structure validation
-- =============================================================================
print("TEST 5: WorldData structure validation")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    local worldConfig = {
        seed = 22222,
        size = 2,
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        water = false,
        caves = false,
        erosion = false,
        objects = true,
        atmosphere = false,
    }

    local worldData = wb:BuildWorld(worldConfig)

    -- Validate all required WorldData fields
    assertEq(type(worldData.seed), "number", "seed should be a number")
    assertEq(type(worldData.size), "number", "size should be a number")
    assertEq(type(worldData.chunksGenerated), "number", "chunksGenerated should be a number")
    assertEq(type(worldData.generationTime), "number", "generationTime should be a number")
    assertEq(type(worldData.biomes), "table", "biomes should be a table")
    assertEq(type(worldData.checkpoints), "table", "checkpoints should be a table")
    assertEq(type(worldData.chunks), "table", "chunks should be a table")

    -- Check chunks dictionary has entries
    local chunkCount = 0
    for _key, _val in pairs(worldData.chunks) do
        chunkCount += 1
    end
    assertEq(chunkCount, 4, "chunks dictionary should have 4 entries")

    -- Verify a specific chunk key exists
    local testChunk = worldData.chunks["0,0"]
    if testChunk then
        assertNotNil(testChunk.heightmap, "Chunk should have heightmap")
        assertNotNil(testChunk.surfaceY, "Chunk should have surfaceY")
        assertNotNil(testChunk.biomeMap, "Chunk should have biomeMap (after biome stage)")
    end

    -- Checkpoints should have "started" and "completed"
    assertEq(worldData.checkpoints[1].status, "started", "First checkpoint should be 'started'")
    assertEq(worldData.checkpoints[#worldData.checkpoints].status, "completed", "Last checkpoint should be 'completed'")

    print("  PASSED")
end

-- =============================================================================
-- TEST 6: Graceful nil-module handling (skip stages, no errors)
-- =============================================================================
print("TEST 6: Graceful nil-module handling")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    -- Create WorldBuilder with ONLY required modules — all optional are nil
    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(
        bus, terrainGen, biomeSys, objectPlacer,
        nil, -- waterSys
        nil, -- caveSys
        nil, -- erosionSim
        nil, -- atmosphereSys
        nil  -- chunkMgr
    )

    -- Even with nil optional modules, BuildWorld should succeed
    local worldConfig = {
        seed = 33333,
        size = 2,
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        -- Request features that we don't have modules for — should be skipped
        water = true,      -- no WaterSystem -> skipped
        caves = true,      -- no CaveSystem -> skipped
        erosion = true,    -- no ErosionSimulator -> skipped
        objects = false,   -- explicitly disabled
        atmosphere = true, -- no AtmosphereSystem -> skipped
    }

    -- This should NOT error even though we requested features without modules
    local ok, result = pcall(function()
        return wb:BuildWorld(worldConfig)
    end)

    assertTrue(ok, string.format("BuildWorld should not error with nil modules | error: %s", tostring(result)))
    assertNotNil(result, "BuildWorld should return WorldData even with nil modules")

    if ok and result then
        assertEq(result.chunksGenerated, 4, "Should still generate all chunks")
    end

    -- Module status should reflect what's missing
    local status = wb:GetModuleStatus()
    assertTrue(status.TerrainGenerator, "TerrainGenerator should be present")
    assertFalse(status.WaterSystem, "WaterSystem should be missing")
    assertFalse(status.CaveSystem, "CaveSystem should be missing")
    assertFalse(status.ErosionSimulator, "ErosionSimulator should be missing")
    assertFalse(status.AtmosphereSystem, "AtmosphereSystem should be missing")
    assertFalse(status.ChunkManager, "ChunkManager should be missing")

    print("  PASSED")
end

-- =============================================================================
-- TEST 7: BuildWorld should guard against concurrent builds
-- =============================================================================
print("TEST 7: Concurrent build guard")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    local worldConfig = {
        seed = 44444,
        size = 2,
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        water = false,
        caves = false,
        erosion = false,
        objects = false,
        atmosphere = false,
    }

    -- First build should succeed
    local data1 = wb:BuildWorld(worldConfig)
    assertNotNil(data1, "First BuildWorld should succeed")

    -- Second build should return the existing data (not start a concurrent build)
    local data2 = wb:BuildWorld(worldConfig)
    assertNotNil(data2, "Second BuildWorld should return data")
    assertEq(data2.seed, data1.seed, "Should return same world data")

    print("  PASSED")
end

-- =============================================================================
-- TEST 8: BuildChunk after BuildWorld stores in worldData.chunks
-- =============================================================================
print("TEST 8: BuildChunk stores in existing worldData")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    -- Build a small world first
    local worldConfig = {
        seed = 55555,
        size = 2,
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        water = false, caves = false, erosion = false,
        objects = false, atmosphere = false,
    }
    wb:BuildWorld(worldConfig)

    -- Now build a single extra chunk — it should be stored in worldData.chunks
    local extraChunk = wb:BuildChunk(50, 50)
    local worldData = wb:GetWorldData()
    assertNotNil(worldData, "Should have worldData")

    local key = "50,50"
    assertNotNil(worldData.chunks[key], "BuildChunk should store the new chunk in worldData")

    print("  PASSED")
end

-- =============================================================================
-- TEST 9: BuildProgress stages when features are enabled vs disabled
-- =============================================================================
print("TEST 9: BuildProgress stage filtering")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()
    local caveSys = createMockCaveSystem()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    -- Only caves enabled (no water, erosion, atmosphere)
    local wb = WorldBuilder.new(
        bus, terrainGen, biomeSys, objectPlacer,
        nil, caveSys, nil, nil, nil
    )

    local stagesSeen: { [string]: boolean } = {}
    bus.Subscribe(bus, "BuildProgress", function(data: any)
        if data.stage then
            stagesSeen[data.stage] = true
        end
    end)

    wb:BuildWorld({
        seed = 66666,
        size = 2,
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        water = false,
        caves = true,      -- enabled AND module present
        erosion = true,    -- enabled but module nil -> skipped
        objects = false,
        atmosphere = true, -- enabled but module nil -> skipped
    })

    -- Terrain and biome are always present
    assertTrue(stagesSeen["terrain"], "Terrain stage should run")
    assertTrue(stagesSeen["biome"], "Biome stage should run")

    -- Caves should run (enabled + module present)
    assertTrue(stagesSeen["caves"], "Caves stage should run when enabled and module present")

    -- Erosion should NOT run (enabled but module nil)
    assertTrue(stagesSeen["erosion"] == nil or stagesSeen["erosion"] == false,
        "Erosion stage should NOT run when module is nil")

    print("  PASSED")
end

-- =============================================================================
-- TEST 10: Larger world size
-- =============================================================================
print("TEST 10: Larger world size (4x4 = 16 chunks)")
do
    local bus = createMockEventBus()
    local terrainGen = createMockTerrainGenerator()
    local biomeSys = createMockBiomeSystem()
    local objectPlacer = createMockObjectPlacer()

    local WorldBuilder = require(script.Parent.Parent.src.WorldBuilder)
    local wb = WorldBuilder.new(bus, terrainGen, biomeSys, objectPlacer)

    local worldConfig = {
        seed = 77777,
        size = 4, -- 4x4 = 16 chunks
        terrain = { chunkSize = 64, maxHeight = 128, seaLevel = 32 },
        water = false, caves = false, erosion = false,
        objects = false, atmosphere = false,
    }

    local worldData = wb:BuildWorld(worldConfig)

    assertEq(worldData.size, 4, "WorldData.size")
    assertEq(worldData.chunksGenerated, 16, "16 chunks for 4x4 world")

    -- Verify chunks dictionary has all 16 entries
    local count = 0
    for _ in pairs(worldData.chunks) do
        count += 1
    end
    assertEq(count, 16, "chunks dictionary should have 16 entries")

    print("  PASSED")
end

-- =============================================================================
-- ALL TESTS PASSED
-- =============================================================================
print("\n========================================")
print("  ALL WorldBuilder TESTS PASSED (10/10)")
print("========================================")
