--!strict
-- ChunkManager.lua
-- Chunk lifecycle: load/unload/streaming around a player position.

local EventBus = require(script.Parent.Core.EventBus)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

export type ChunkData = {
	cx: number,
	cz: number,
	heightmap: { { number } },
	surfaceY: { { number } },
	biomeMap: { { string } },
}

export type ObjectPlacer = {
	PlaceInChunk: (self: ObjectPlacer, chunk: ChunkData, densityMultiplier: number?) -> { Placement },
	ClearChunk: (self: ObjectPlacer, cx: number, cz: number) -> (),
	GetPlacementCount: (self: ObjectPlacer) -> number,
	SetDensityMultiplier: (self: ObjectPlacer, multiplier: number) -> (),
}

export type Placement = {
	objectId: string,
	cframe: CFrame,
	scale: number,
}

export type TerrainGenerator = {
	GenerateChunk: (self: TerrainGenerator, cx: number, cz: number) -> ChunkData,
	ApplyToTerrain: (self: TerrainGenerator, chunk: ChunkData) -> (),
	GetHeightAt: (self: TerrainGenerator, worldX: number, worldZ: number) -> number,
	SetTerrainConfig: (self: TerrainGenerator, config: any) -> (),
}

export type BiomeSystem = {
	GenerateBiomeMap: (self: BiomeSystem, chunk: ChunkData) -> ChunkData,
	GetTempAt: (self: BiomeSystem, x: number, z: number) -> number,
	GetMoistureAt: (self: BiomeSystem, x: number, z: number) -> number,
}

export type ChunkManager = {
	LoadChunk: (self: ChunkManager, cx: number, cz: number) -> ChunkData,
	UnloadChunk: (self: ChunkManager, cx: number, cz: number) -> (),
	IsChunkLoaded: (self: ChunkManager, cx: number, cz: number) -> boolean,
	GetLoadedChunks: (self: ChunkManager) -> { { cx: number, cz: number } },
	SetViewDistance: (self: ChunkManager, chunks: number) -> (),
	StreamAround: (self: ChunkManager, worldX: number, worldZ: number) -> ({ ChunkData }, { ChunkData }),

	-- private
	_eventBus: any,
	_terrainGen: TerrainGenerator,
	_objectPlacer: ObjectPlacer,
	_biomeSys: BiomeSystem?,
	_loadedChunks: { [number]: { [number]: ChunkData } },
	_viewDistance: number,
	_lastStreamedCenter: { cx: number, cz: number }?,
}

-- ---------------------------------------------------------------------------
-- ChunkManager
-- ---------------------------------------------------------------------------

local ChunkManager = {}
ChunkManager.__index = ChunkManager

function ChunkManager.new(
	eventBus: any,
	terrainGen: TerrainGenerator,
	objectPlacer: ObjectPlacer,
	biomeSys: BiomeSystem?
): ChunkManager
	local self = setmetatable({}, ChunkManager)

	self._eventBus = eventBus
	self._terrainGen = terrainGen
	self._objectPlacer = objectPlacer
	self._biomeSys = biomeSys
	self._loadedChunks = {} :: { [number]: { [number]: ChunkData } }
	self._viewDistance = 4 -- default 4 chunks in each direction
	self._lastStreamedCenter = nil

	return self
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ChunkManager:LoadChunk(cx: number, cz: number): ChunkData
	-- Return cached chunk if already loaded
	if self:IsChunkLoaded(cx, cz) then
		return self._loadedChunks[cx][cz]
	end

	-- Step 1: Generate terrain (heightmap + surface)
	local chunk = self._terrainGen:GenerateChunk(cx, cz)

	-- Step 2: Apply biome map
	if self._biomeSys then
		chunk = self._biomeSys:GenerateBiomeMap(chunk)
	else
		-- Fallback: fill with grassland if no biome system
		local size = #chunk.heightmap
		chunk.biomeMap = table.create(size)
		for ix = 1, size do
			chunk.biomeMap[ix] = table.create(size)
			for iz = 1, size do
				chunk.biomeMap[ix][iz] = "grassland"
			end
		end
	end

	-- Step 3: Write terrain voxels
	self._terrainGen:ApplyToTerrain(chunk)

	-- Step 4: Place objects
	local placements = self._objectPlacer:PlaceInChunk(chunk)

	-- Cache the chunk
	if not self._loadedChunks[cx] then
		self._loadedChunks[cx] = {}
	end
	self._loadedChunks[cx][cz] = chunk

	self._eventBus:Emit("ChunkLoaded", {
		cx = cx,
		cz = cz,
		chunk = chunk,
		placements = placements,
	})

	return chunk
end

function ChunkManager:UnloadChunk(cx: number, cz: number)
	if not self:IsChunkLoaded(cx, cz) then
		return
	end

	local chunk = self._loadedChunks[cx][cz]

	-- Remove terrain voxels (fill with air)
	self:_clearTerrainVoxels(chunk)

	-- Destroy placed objects
	self._objectPlacer:ClearChunk(cx, cz)

	-- Remove from cache
	self._loadedChunks[cx][cz] = nil
	if next(self._loadedChunks[cx]) == nil then
		self._loadedChunks[cx] = nil
	end

	self._eventBus:Emit("ChunkUnloaded", {
		cx = cx,
		cz = cz,
		chunk = chunk,
	})
end

function ChunkManager:IsChunkLoaded(cx: number, cz: number): boolean
	return self._loadedChunks[cx] ~= nil and self._loadedChunks[cx][cz] ~= nil
end

function ChunkManager:GetLoadedChunks(): { { cx: number, cz: number } }
	local chunks = {}
	for cx, row in pairs(self._loadedChunks) do
		for cz, _ in pairs(row) do
			table.insert(chunks, { cx = cx, cz = cz })
		end
	end
	return chunks
end

function ChunkManager:SetViewDistance(chunks: number)
	self._viewDistance = math.clamp(math.floor(chunks), 1, 32)
end

function ChunkManager:StreamAround(worldX: number, worldZ: number): ({ ChunkData }, { ChunkData })
	local chunkSize = 64 -- studs per chunk (default)
	local cx = math.floor(worldX / chunkSize)
	local cz = math.floor(worldZ / chunkSize)
	local viewDist = self._viewDistance

	local newlyLoaded = {} :: { ChunkData }
	local newlyUnloaded = {} :: { ChunkData }

	-- Determine desired chunks within view distance
	local desiredChunks = {} :: { [string]: boolean }
	for dx = -viewDist, viewDist do
		for dz = -viewDist, viewDist do
			-- Circular view distance for more natural loading
			if math.sqrt(dx * dx + dz * dz) <= viewDist + 0.5 then
				local targetCx = cx + dx
				local targetCz = cz + dz
				desiredChunks[targetCx .. "," .. targetCz] = true

				if not self:IsChunkLoaded(targetCx, targetCz) then
					local loadedChunk = self:LoadChunk(targetCx, targetCz)
					table.insert(newlyLoaded, loadedChunk)
				end
			end
		end
	end

	-- Unload chunks outside view distance
	local chunksToUnload = {} :: { { cx: number, cz: number } }
	for loadedCx, row in pairs(self._loadedChunks) do
		for loadedCz, chunkData in pairs(row) do
			local key = loadedCx .. "," .. loadedCz
			if not desiredChunks[key] then
				table.insert(chunksToUnload, { cx = loadedCx, cz = loadedCz })
				table.insert(newlyUnloaded, chunkData)
			end
		end
	end

	for _, coord in ipairs(chunksToUnload) do
		self:UnloadChunk(coord.cx, coord.cz)
	end

	self._lastStreamedCenter = { cx = cx, cz = cz }

	self._eventBus:Emit("ChunksStreamed", {
		centerCx = cx,
		centerCz = cz,
		viewDistance = viewDist,
		newlyLoaded = newlyLoaded,
		newlyUnloaded = newlyUnloaded,
	})

	return newlyLoaded, newlyUnloaded
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Fill a chunk's terrain voxels with air (removing terrain)
function ChunkManager:_clearTerrainVoxels(chunk: ChunkData)
	local terrain = workspace:FindFirstChild("Terrain")
	if not terrain then return end

	-- Mirror ApplyToTerrain: 1 heightmap cell = 1 stud, 1 voxel = 4 studs.
	local resolution = 4
	local hmSize     = #chunk.heightmap         -- 64 cells = 64 studs per side
	local numVoxX    = hmSize // resolution      -- 16 voxels
	local numVoxZ    = numVoxX
	local numVoxY    = 256 // resolution         -- 64 voxels tall (conservative max)

	-- Build a full-chunk all-air table matching ApplyToTerrain's dimensions.
	local materials: { { { Enum.Material } } } = {}
	local occupancies: { { { number } } } = {}
	for vx = 1, numVoxX do
		materials[vx]  = {}
		occupancies[vx] = {}
		for vy = 1, numVoxY do
			materials[vx][vy]  = {}
			occupancies[vx][vy] = {}
			for vz = 1, numVoxZ do
				materials[vx][vy][vz]  = Enum.Material.Air
				occupancies[vx][vy][vz] = 0
			end
		end
	end

	-- Write once for the whole chunk (same origin math as ApplyToTerrain).
	local corner = Vector3.new(chunk.cx * hmSize, 0, chunk.cz * hmSize)
	local extent  = Vector3.new(numVoxX * resolution, numVoxY * resolution, numVoxZ * resolution)
	local region  = Region3.new(corner, corner + extent):ExpandToGrid(resolution)
	terrain:WriteVoxels(region, resolution, materials, occupancies)
end

return ChunkManager
