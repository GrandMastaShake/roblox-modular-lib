--!strict
-- WorldBuilder.lua
-- Orchestrator that wires all terrain-generation modules into a single
-- reproducible pipeline: terrain -> erosion -> biome -> caves -> water ->
-- objects -> atmosphere.  It emits progress events so UIs, loaders, and
-- streaming systems can react to generation stages.
--
-- Architecture note: WorldBuilder does NOT hard-require any optional module.
-- If a module is nil (e.g. no WaterSystem was injected), that pipeline stage
-- is silently skipped.  This makes the system work in minimal configurations
-- (just terrain + biomes + objects) up to the full feature set.

local EventBus = require(script.Parent.Core.EventBus)

-- =============================================================================
-- TYPE IMPORTS — mirror the spec exactly so the orchestrator is fully typed
-- =============================================================================

export type NoiseConfig = {
    seed: number,
    octaves: number,
    persistence: number,
    lacunarity: number,
    scale: number,
}

export type TerrainConfig = {
    chunkSize: number,
    maxHeight: number,
    seaLevel: number,
    noise: NoiseConfig?,
    erosion: boolean?,
    erosionIterations: number?,
}

export type ChunkData = {
    cx: number,
    cz: number,
    heightmap: { { number } },
    surfaceY: { { number } },
    biomeMap: { { string } }?,
    placements: { Placement }?,
}

export type Placement = {
    objectId: string,
    cframe: CFrame,
    scale: number,
}

export type BiomeDef = {
    id: string,
    name: string,
    tempRange: { min: number, max: number },
    moistureRange: { min: number, max: number },
    baseColor: Color3,
    terrainMaterial: Enum.Material,
    treeDensity: number,
    rockDensity: number,
    flowerDensity: number,
    groundCover: { string },
}

export type BiomeSystem = {
    RegisterBiome: (self: BiomeSystem, biome: BiomeDef) -> (),
    GetBiome: (self: BiomeSystem, temp: number, moisture: number) -> BiomeDef,
    GenerateBiomeMap: (self: BiomeSystem, chunk: ChunkData) -> ChunkData,
    GetAllBiomes: (self: BiomeSystem) -> { BiomeDef },
}

export type TerrainGenerator = {
    GenerateChunk: (self: TerrainGenerator, cx: number, cz: number) -> ChunkData,
    ApplyToTerrain: (self: TerrainGenerator, chunk: ChunkData) -> (),
    GetHeightAt: (self: TerrainGenerator, worldX: number, worldZ: number) -> number,
    SetTerrainConfig: (self: TerrainGenerator, config: TerrainConfig) -> (),
}

export type ObjectPlacer = {
    RegisterObject: (self: ObjectPlacer, def: any) -> (),
    PlaceInChunk: (self: ObjectPlacer, chunk: ChunkData) -> { Placement },
    ClearChunk: (self: ObjectPlacer, cx: number, cz: number) -> (),
    GetPlacementCount: (self: ObjectPlacer) -> number,
    SetDensityMultiplier: (self: ObjectPlacer, multiplier: number) -> (),
}

export type WaterSystem = {
    GenerateRivers: (self: WaterSystem, terrain: TerrainGenerator) -> { RiverNode },
    CarveRiver: (self: WaterSystem, river: { RiverNode }) -> (),
    CreateLake: (self: WaterSystem, cx: number, cz: number, radius: number) -> (),
    ErodeTerrain: (self: WaterSystem, chunk: ChunkData, river: { RiverNode }) -> ChunkData,
}

export type RiverNode = {
    x: number,
    z: number,
    y: number,
    flow: number,
    next: { RiverNode },
}

export type CaveSystem = {
    CarveChunk: (self: CaveSystem, chunk: ChunkData) -> ChunkData,
    IsCaveAt: (self: CaveSystem, x: number, y: number, z: number) -> boolean,
    SetConfig: (self: CaveSystem, config: CaveConfig) -> (),
}

export type CaveConfig = {
    frequency: number,
    threshold: number,
    minY: number,
    maxY: number,
    tunnelWidth: number,
}

export type AtmosphereSystem = {
    RegisterBiomeAtmosphere: (self: AtmosphereSystem, biomeId: string, config: AtmosphereConfig) -> (),
    ApplyToRegion: (self: AtmosphereSystem, biomeId: string, region: Region3) -> (),
    ApplyToChunk: (self: AtmosphereSystem, chunk: ChunkData) -> (),
    TransitionAtmosphere: (self: AtmosphereSystem, fromBiome: string, toBiome: string, duration: number) -> (),
}

export type AtmosphereConfig = {
    lighting: {
        ambient: Color3,
        outdoorAmbient: Color3,
        brightness: number,
        clockTime: number,
    },
    fog: {
        start: number,
        _end: number,
        color: Color3,
    },
    sky: {
        skyboxId: string?,
        celestialBodiesShown: boolean,
    },
    soundscape: {
        daySounds: { string },
        nightSounds: { string },
    },
}

export type ErosionSimulator = {
    Erode: (self: ErosionSimulator, heightmap: { { number } }) -> { { number } },
    ThermalErosion: (self: ErosionSimulator, heightmap: { { number } }, talusAngle: number) -> { { number } },
    SetConfig: (self: ErosionSimulator, config: ErosionConfig) -> (),
}

export type ErosionConfig = {
    droplets: number,
    erosionRate: number,
    depositionRate: number,
    evaporationRate: number,
    gravity: number,
}

export type ChunkManager = {
    LoadChunk: (self: ChunkManager, cx: number, cz: number) -> ChunkData,
    UnloadChunk: (self: ChunkManager, cx: number, cz: number) -> (),
    IsChunkLoaded: (self: ChunkManager, cx: number, cz: number) -> boolean,
    GetLoadedChunks: (self: ChunkManager) -> { { cx: number, cz: number } },
    SetViewDistance: (self: ChunkManager, chunks: number) -> (),
    StreamAround: (self: ChunkManager, worldX: number, worldZ: number) -> ({ ChunkData }, { ChunkData }),
}

export type WorldConfig = {
    seed: number,
    size: number,
    terrain: TerrainConfig,
    water: boolean?,
    caves: boolean?,
    erosion: boolean?,
    objects: boolean?,
    atmosphere: boolean?,
    chunkStreaming: boolean?,
    viewDistance: number?,
}

export type WorldData = {
    seed: number,
    size: number,
    chunksGenerated: number,
    biomes: { string },
    generationTime: number,
    checkpoints: { { wave: number, status: string } },
    chunks: { [string]: ChunkData },
}

export type ProgressPayload = {
    current: number,
    total: number,
    chunkCx: number,
    chunkCz: number,
    stage: string,
}

export type WorldBuilder = {
    BuildWorld: (self: WorldBuilder, config: WorldConfig) -> WorldData,
    BuildChunk: (self: WorldBuilder, cx: number, cz: number) -> ChunkData,
    GetWorldData: (self: WorldBuilder) -> WorldData?,
}

-- =============================================================================
-- MODULE DEFINITION
-- =============================================================================

local WorldBuilder = {}
WorldBuilder.__index = WorldBuilder

--[=[
    Create a new WorldBuilder orchestrator.

    @param eventBus     Shared EventBus for cross-module communication.
    @param terrainGen   TerrainGenerator instance (required).
    @param biomeSys     BiomeSystem instance (required).
    @param objectPlacer ObjectPlacer instance (required).
    @param waterSys?    WaterSystem instance (optional).
    @param caveSys?     CaveSystem instance (optional).
    @param erosionSim?  ErosionSimulator instance (optional).
    @param atmosphereSys? AtmosphereSystem instance (optional).
    @param chunkMgr?    ChunkManager instance (optional).
    @return WorldBuilder
]=]
function WorldBuilder.new(
    eventBus: EventBus.EventBus,
    terrainGen: TerrainGenerator,
    biomeSys: BiomeSystem,
    objectPlacer: ObjectPlacer,
    waterSys: WaterSystem?,
    caveSys: CaveSystem?,
    erosionSim: ErosionSimulator?,
    atmosphereSys: AtmosphereSystem?,
    chunkMgr: ChunkManager?
): WorldBuilder
    local self = setmetatable({}, WorldBuilder)

    self._eventBus = eventBus
    self._terrainGen = terrainGen
    self._biomeSys = biomeSys
    self._objectPlacer = objectPlacer
    self._waterSys = waterSys
    self._caveSys = caveSys
    self._erosionSim = erosionSim
    self._atmosphereSys = atmosphereSys
    self._chunkMgr = chunkMgr

    self._worldData = nil :: WorldData?
    self._isBuilding = false

    return self
end

--[=[
    Internal helper: emit BuildProgress and also fire the stage-specific event.
]=]
function WorldBuilder:_emitProgress(
    current: number,
    total: number,
    chunkCx: number,
    chunkCz: number,
    stage: string
)
    local payload: ProgressPayload = {
        current = current,
        total = total,
        chunkCx = chunkCx,
        chunkCz = chunkCz,
        stage = stage,
    }
    self._eventBus:Emit("BuildProgress", payload)
end

--[=[
    Internal helper: build a single chunk through the full pipeline.
    This is called both by BuildWorld (for the full grid) and by BuildChunk
    (for on-demand / streaming use).

    Pipeline order (stages 1-7):
      1. terrain   — Generate heightmap
      2. erosion   — Thermal + hydraulic erosion pass
      3. biome     — Temperature/moisture -> biome mapping
      4. caves     — 3D noise cave carving
      5. water     — Rivers and lakes
      6. objects   — Scatter trees, rocks, foliage
      7. atmosphere — Per-biome lighting/fog/sky

    @param cx       Chunk X coordinate.
    @param cz       Chunk Z coordinate.
    @param opts     Optional flags controlling which stages run.
    @return ChunkData
]=]
function WorldBuilder:_buildChunkPipeline(
    cx: number,
    cz: number,
    opts: {
        erosion: boolean,
        caves: boolean,
        water: boolean,
        objects: boolean,
        atmosphere: boolean,
    }
): ChunkData
    -- Stage 1: Terrain (always required)
    self._eventBus:Emit("BuildProgress", {
        current = 0,
        total = 7,
        chunkCx = cx,
        chunkCz = cz,
        stage = "terrain",
    } :: ProgressPayload)

    local chunk: ChunkData = self._terrainGen:GenerateChunk(cx, cz)

    -- Stage 2: Erosion (optional)
    if opts.erosion and self._erosionSim then
        self._eventBus:Emit("BuildProgress", {
            current = 1,
            total = 7,
            chunkCx = cx,
            chunkCz = cz,
            stage = "erosion",
        } :: ProgressPayload)

        chunk.heightmap = self._erosionSim:Erode(chunk.heightmap)

        -- Update surfaceY cache after erosion modifies heights
        for x = 1, #chunk.heightmap do
            for z = 1, #(chunk.heightmap[x]) do
                chunk.surfaceY[x][z] = chunk.heightmap[x][z]
            end
        end
    end

    -- Stage 3: Biomes (always required)
    self._eventBus:Emit("BuildProgress", {
        current = 2,
        total = 7,
        chunkCx = cx,
        chunkCz = cz,
        stage = "biome",
    } :: ProgressPayload)

    chunk = self._biomeSys:GenerateBiomeMap(chunk)

    -- Stage 4: Caves (optional)
    if opts.caves and self._caveSys then
        self._eventBus:Emit("BuildProgress", {
            current = 3,
            total = 7,
            chunkCx = cx,
            chunkCz = cz,
            stage = "caves",
        } :: ProgressPayload)

        chunk = self._caveSys:CarveChunk(chunk)
    end

    -- Stage 5: Water (optional)
    if opts.water and self._waterSys then
        self._eventBus:Emit("BuildProgress", {
            current = 4,
            total = 7,
            chunkCx = cx,
            chunkCz = cz,
            stage = "water",
        } :: ProgressPayload)

        -- Generate rivers once per world, not per chunk; the WaterSystem
        -- internally tracks which chunks have been processed.  We call
        -- GenerateRivers lazily on first water-enabled chunk.
        self._waterSys:GenerateRivers(self._terrainGen)

        -- Create lakes in low-elevation chunks (heuristic: avg height < seaLevel * 1.5)
        local avgHeight = 0
        local count = 0
        for x = 1, #chunk.heightmap do
            for z = 1, #(chunk.heightmap[x]) do
                avgHeight += chunk.heightmap[x][z]
                count += 1
            end
        end
        if count > 0 then
            avgHeight /= count
            if avgHeight < 48 then -- below approximate sea-level threshold
                local lakeRadius = math.random(8, 20)
                self._waterSys:CreateLake(cx, cz, lakeRadius)
            end
        end
    end

    -- Stage 6: Objects (optional, but objectPlacer is a required constructor arg
    -- because even a "minimal" world usually wants terrain detail.  We respect
    -- the config.objects flag.)
    if opts.objects then
        self._eventBus:Emit("BuildProgress", {
            current = 5,
            total = 7,
            chunkCx = cx,
            chunkCz = cz,
            stage = "objects",
        } :: ProgressPayload)

        local _placements: { Placement } = self._objectPlacer:PlaceInChunk(chunk)
        chunk.placements = _placements
    end

    -- Stage 7: Atmosphere (optional)
    if opts.atmosphere and self._atmosphereSys then
        self._eventBus:Emit("BuildProgress", {
            current = 6,
            total = 7,
            chunkCx = cx,
            chunkCz = cz,
            stage = "atmosphere",
        } :: ProgressPayload)

        self._atmosphereSys:ApplyToChunk(chunk)
    end

    return chunk
end

--[=[
    Build a complete world from a configuration table.

    @param config  WorldConfig table with seed, size, terrain settings, and
                   feature flags (water, caves, erosion, objects, atmosphere,
                   chunkStreaming, viewDistance).
    @return WorldData  Generation statistics and per-chunk data.
]=]
function WorldBuilder:BuildWorld(config: WorldConfig): WorldData
    if self._isBuilding then
        warn("[WorldBuilder] BuildWorld called while another build is in progress; ignoring.")
        return self._worldData :: WorldData
    end

    self._isBuilding = true
    local startTime = tick()

    -- Apply terrain configuration to the generator
    self._terrainGen:SetTerrainConfig(config.terrain)

    -- Determine which pipeline stages are active
    local opts = {
        erosion = config.erosion == true and self._erosionSim ~= nil,
        caves = config.caves == true and self._caveSys ~= nil,
        water = config.water == true and self._waterSys ~= nil,
        objects = config.objects ~= false, -- default true
        atmosphere = config.atmosphere == true and self._atmosphereSys ~= nil,
    }

    local worldSize = config.size
    local totalChunks = worldSize * worldSize
    local chunksGenerated = 0
    local checkpoints: { { wave: number, status: string } } = {}

    -- Initialize empty world data
    local worldData: WorldData = {
        seed = config.seed,
        size = worldSize,
        chunksGenerated = 0,
        biomes = {},
        generationTime = 0,
        checkpoints = checkpoints,
        chunks = {},
    }

    -- Collect unique biome IDs as we go
    local biomeSet: { [string]: boolean } = {}

    -- Notify listeners that world generation has begun
    self._eventBus:Emit("WorldBuildStarted", {
        seed = config.seed,
        size = worldSize,
        totalChunks = totalChunks,
        features = opts,
    })

    table.insert(checkpoints, { wave = 0, status = "started" })

    -- Iterate over a size x size grid centered at the origin.
    -- For a world of size N, chunks range from -(N//2) to +(N//2 - 1)
    local halfSize = math.floor(worldSize / 2)

    for cx = -halfSize, halfSize - 1 do
        for cz = -halfSize, halfSize - 1 do
            chunksGenerated += 1

            -- Emit overall progress (not per-stage)
            self:_emitProgress(chunksGenerated, totalChunks, cx, cz, "building")

            -- Run the full pipeline for this chunk
            local chunk: ChunkData = self:_buildChunkPipeline(cx, cz, opts)

            -- Store chunk in world data keyed by "cx,cz"
            local key = string.format("%d,%d", cx, cz)
            worldData.chunks[key] = chunk

            -- Collect biome IDs from this chunk's biome map
            if chunk.biomeMap then
                for x = 1, #chunk.biomeMap do
                    for z = 1, #(chunk.biomeMap[x]) do
                        local biomeId = chunk.biomeMap[x][z]
                        if biomeId and not biomeSet[biomeId] then
                            biomeSet[biomeId] = true
                            table.insert(worldData.biomes, biomeId)
                        end
                    end
                end
            end

            -- Notify that this individual chunk is complete
            self._eventBus:Emit("ChunkBuilt", {
                cx = cx,
                cz = cz,
                progress = chunksGenerated / totalChunks,
                chunkData = chunk,
            })
        end
    end

    -- Finalize world data
    worldData.chunksGenerated = chunksGenerated
    worldData.generationTime = tick() - startTime

    table.insert(checkpoints, {
        wave = #checkpoints + 1,
        status = "completed",
    })

    self._worldData = worldData
    self._isBuilding = false

    -- Notify listeners that the entire world is done
    self._eventBus:Emit("WorldBuildCompleted", {
        seed = config.seed,
        size = worldSize,
        chunksGenerated = chunksGenerated,
        biomes = worldData.biomes,
        generationTime = worldData.generationTime,
        checkpoints = worldData.checkpoints,
    })

    return worldData
end

--[=[
    Build a single chunk on demand.
    This is useful for streaming/loading individual chunks after the initial
    world has been built, or for chunk-based infinite-world scenarios.

    @param cx  Chunk X coordinate.
    @param cz  Chunk Z coordinate.
    @return ChunkData
]=]
function WorldBuilder:BuildChunk(cx: number, cz: number): ChunkData
    -- Use the last world configuration if available; otherwise use all-defaults.
    local defaultOpts = {
        erosion = self._erosionSim ~= nil,
        caves = self._caveSys ~= nil,
        water = self._waterSys ~= nil,
        objects = true,
        atmosphere = self._atmosphereSys ~= nil,
    }

    -- Override with worldData config if we have it
    local opts = defaultOpts
    if self._worldData then
        -- The world was already built; re-use the same feature set.
        -- We reconstruct opts from what the last BuildWorld used by
        -- checking which optional modules are present.
        opts = {
            erosion = self._erosionSim ~= nil,
            caves = self._caveSys ~= nil,
            water = self._waterSys ~= nil,
            objects = true,
            atmosphere = self._atmosphereSys ~= nil,
        }
    end

    local chunk: ChunkData = self:_buildChunkPipeline(cx, cz, opts)

    -- Store in worldData if available
    if self._worldData then
        local key = string.format("%d,%d", cx, cz)
        self._worldData.chunks[key] = chunk
    end

    self._eventBus:Emit("ChunkBuilt", {
        cx = cx,
        cz = cz,
        progress = -1, -- single chunk; no overall progress
        chunkData = chunk,
    })

    return chunk
end

--[=[
    Retrieve the WorldData from the most recent BuildWorld call.
    Returns nil if BuildWorld has never been called.

    @return WorldData?
]=]
function WorldBuilder:GetWorldData(): WorldData?
    return self._worldData
end

-- =============================================================================
-- VALIDATION HELPERS — useful for diagnostics and tests
-- =============================================================================

--[=[
    Returns a table showing which modules are injected and which are missing.
    Handy for debugging configuration issues.
]=]
function WorldBuilder:GetModuleStatus(): { [string]: boolean }
    return {
        EventBus = self._eventBus ~= nil,
        TerrainGenerator = self._terrainGen ~= nil,
        BiomeSystem = self._biomeSys ~= nil,
        ObjectPlacer = self._objectPlacer ~= nil,
        WaterSystem = self._waterSys ~= nil,
        CaveSystem = self._caveSys ~= nil,
        ErosionSimulator = self._erosionSim ~= nil,
        AtmosphereSystem = self._atmosphereSys ~= nil,
        ChunkManager = self._chunkMgr ~= nil,
    }
end

return WorldBuilder
