--!strict
-- TerrainGenerator.lua
-- Chunk-based terrain heightmap generation and Roblox Terrain voxel writing.

local NoiseLib = require(script.Parent.NoiseLib)

export type NoiseConfig = NoiseLib.NoiseConfig
export type ChunkData = {
	cx: number,
	cz: number,
	heightmap: { { number } },
	surfaceY: { { number } },
	biomeMap: { { string } },
}

export type TerrainConfig = {
	chunkSize: number,
	maxHeight: number,
	seaLevel: number,
	noise: NoiseConfig?,
	erosion: boolean,
	erosionIterations: number,
}

export type TerrainGenerator = {
	GenerateChunk: (self: TerrainGenerator, cx: number, cz: number) -> ChunkData,
	ApplyToTerrain: (self: TerrainGenerator, chunk: ChunkData) -> (),
	GetHeightAt: (self: TerrainGenerator, worldX: number, worldZ: number) -> number,
	SetTerrainConfig: (self: TerrainGenerator, config: TerrainConfig) -> (),
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
	Once: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
}

local DEFAULT_TERRAIN_CONFIG: TerrainConfig = {
	chunkSize = 64,
	maxHeight = 256,
	seaLevel = 32,
	noise = nil,
	erosion = true,
	erosionIterations = 50000,
}

local TerrainGenerator = {}
TerrainGenerator.__index = TerrainGenerator

function TerrainGenerator.new(eventBus: EventBus, config: TerrainConfig?): TerrainGenerator
	local self = setmetatable({}, TerrainGenerator)
	self._eventBus = eventBus
	self._config = self:_mergeConfig(config or {})
	self._noise = NoiseLib.new(self._config.noise)
	return self
end

function TerrainGenerator:_mergeConfig(overrides: TerrainConfig): TerrainConfig
	local base = table.clone(DEFAULT_TERRAIN_CONFIG)
	if overrides.chunkSize ~= nil then base.chunkSize = overrides.chunkSize end
	if overrides.maxHeight ~= nil then base.maxHeight = overrides.maxHeight end
	if overrides.seaLevel ~= nil then base.seaLevel = overrides.seaLevel end
	if overrides.noise ~= nil then base.noise = overrides.noise end
	if overrides.erosion ~= nil then base.erosion = overrides.erosion end
	if overrides.erosionIterations ~= nil then base.erosionIterations = overrides.erosionIterations end
	return base
end

-- World coordinates from chunk coordinates + local offset
function TerrainGenerator:_chunkToWorldX(cx: number, localX: number): number
	return cx * self._config.chunkSize + localX
end

function TerrainGenerator:_chunkToWorldZ(cz: number, localZ: number): number
	return cz * self._config.chunkSize + localZ
end

-- Sample noise for a world position and map to terrain height
function TerrainGenerator:_sampleHeight(worldX: number, worldZ: number): number
	local n = self._noise:Get2D(worldX, worldZ)
	-- Map -1..1 to 0..maxHeight, then sharpen with power for more valleys
	local t = (n + 1) / 2
	-- Power curve to create more interesting terrain (sharpen peaks)
	t = math.pow(t, 1.2)
	return math.clamp(math.floor(t * self._config.maxHeight), 0, self._config.maxHeight)
end

function TerrainGenerator:GenerateChunk(cx: number, cz: number): ChunkData
	local size = self._config.chunkSize
	local heightmap: { { number } } = {}
	local surfaceY: { { number } } = {}
	for x = 1, size do
		heightmap[x] = {}
		surfaceY[x] = {}
		for z = 1, size do
			local worldX = self:_chunkToWorldX(cx, x - 1)
			local worldZ = self:_chunkToWorldZ(cz, z - 1)
			local h = self:_sampleHeight(worldX, worldZ)
			heightmap[x][z] = h
			surfaceY[x][z] = h
		end
	end

	local chunk: ChunkData = {
		cx = cx,
		cz = cz,
		heightmap = heightmap,
		surfaceY = surfaceY,
		biomeMap = {},
	}

	-- Initialize empty biome map
	for x = 1, size do
		chunk.biomeMap[x] = {}
		for z = 1, size do
			chunk.biomeMap[x][z] = "Unknown"
		end
	end

	self._eventBus:Emit("ChunkGenerated", chunk)
	return chunk
end

function TerrainGenerator:ApplyToTerrain(chunk: ChunkData)
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if not terrain then
		warn("[TerrainGenerator] No Terrain object found in workspace")
		return
	end

	-- Each heightmap cell = 1 stud; each voxel = resolution studs.
	-- Build material/occupancy tables for the whole chunk, then write once.
	local resolution = 4
	local hmSize = #chunk.heightmap                        -- e.g. 64 cells
	local numVoxX = hmSize // resolution                   -- e.g. 16 voxels
	local numVoxZ = numVoxX
	local numVoxY = math.max(1, self._config.maxHeight // resolution)  -- e.g. 32

	local materials: { { { Enum.Material } } } = {}
	local occupancies: { { { number } } } = {}
	for vx = 1, numVoxX do
		materials[vx] = {}
		occupancies[vx] = {}
		for vy = 1, numVoxY do
			materials[vx][vy] = {}
			occupancies[vx][vy] = {}
			for vz = 1, numVoxZ do
				-- Sample heightmap at the voxel's top-left corner (1-indexed).
				local hx = (vx - 1) * resolution + 1
				local hz = (vz - 1) * resolution + 1
				local surfaceHeight = chunk.heightmap[hx][hz]
				-- worldY is the stud position of this voxel's base.
				local worldY = (vy - 1) * resolution

				local mat: Enum.Material
				local occ: number
				if worldY + resolution > surfaceHeight + resolution then
					-- Voxel base is above surface: Air
					mat = Enum.Material.Air
					occ = 0
				elseif worldY + resolution > surfaceHeight then
					-- Voxel straddles or meets the surface: Grass cap
					mat = Enum.Material.Grass
					occ = 1
				elseif worldY >= surfaceHeight - resolution * 3 then
					-- Within 3 voxels (12 studs) below surface: Ground (brown earth)
					mat = Enum.Material.Ground
					occ = 1
				else
					mat = Enum.Material.Rock
					occ = 1
				end

				materials[vx][vy][vz] = mat
				occupancies[vx][vy][vz] = occ
			end
		end
	end

	-- Write the entire chunk in one WriteVoxels call.
	local chunkOriginX = chunk.cx * hmSize
	local chunkOriginZ = chunk.cz * hmSize
	local corner = Vector3.new(chunkOriginX, 0, chunkOriginZ)
	local extent  = Vector3.new(numVoxX * resolution, numVoxY * resolution, numVoxZ * resolution)
	local region  = Region3.new(corner, corner + extent):ExpandToGrid(resolution)
	terrain:WriteVoxels(region, resolution, materials, occupancies)

	self._eventBus:Emit("TerrainApplied", { cx = chunk.cx, cz = chunk.cz })
end

function TerrainGenerator:GetHeightAt(worldX: number, worldZ: number): number
	local height = self:_sampleHeight(worldX, worldZ)
	self._eventBus:Emit("HeightSampled", { x = worldX, z = worldZ, height = height })
	return height
end

function TerrainGenerator:SetTerrainConfig(config: TerrainConfig)
	self._config = self:_mergeConfig(config)
	self._noise = NoiseLib.new(self._config.noise)
end

return TerrainGenerator
