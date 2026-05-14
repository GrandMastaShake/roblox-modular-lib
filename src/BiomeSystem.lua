--!strict
-- BiomeSystem.lua
-- Temperature + moisture noise → biome mapping with 9 default biomes.

local EventBus = require(script.Parent.Core.EventBus)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

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
	altitudeOverride: boolean?, -- true for mountains (altitude-based)
}

export type ChunkData = {
	cx: number,
	cz: number,
	heightmap: { { number } },
	surfaceY: { { number } },
	biomeMap: { { string } },
}

export type BiomeSystem = {
	RegisterBiome: (self: BiomeSystem, biome: BiomeDef) -> (),
	GetBiome: (self: BiomeSystem, temp: number, moisture: number) -> BiomeDef,
	GetTempAt: (self: BiomeSystem, x: number, z: number) -> number,
	GetMoistureAt: (self: BiomeSystem, x: number, z: number) -> number,
	GenerateBiomeMap: (self: BiomeSystem, chunk: ChunkData) -> ChunkData,
	GetAllBiomes: (self: BiomeSystem) -> { BiomeDef },

	-- private
	_eventBus: any,
	_seed: number,
	_biomes: { [string]: BiomeDef },
	_biomeList: { BiomeDef },
	_noise: any,
}

-- ---------------------------------------------------------------------------
-- Simple deterministic 2D noise (Perlin-like) used for temperature / moisture
-- ---------------------------------------------------------------------------

local SimpleNoise = {}
SimpleNoise.__index = SimpleNoise

function SimpleNoise.new(seed: number)
	local self = setmetatable({}, SimpleNoise)
	self._seed = seed
	return self
end

local function fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function hash2D(seed: number, x: number, y: number): number
	-- deterministic hash for noise gradient selection
	local n = math.sin(x * 127.1 + y * 311.7 + seed * 74.3) * 43758.5453
	return n - math.floor(n)
end

local function grad2D(hash: number, x: number, y: number): number
	local h = hash % 4
	if h == 0 then
		return x + y
	elseif h == 1 then
		return -x + y
	elseif h == 2 then
		return x - y
	else
		return -x - y
	end
end

function SimpleNoise:Get2D(x: number, y: number): number
	local seed = self._seed

	local xi = math.floor(x)
	local yi = math.floor(y)
	local xf = x - xi
	local yf = y - yi

	local u = fade(xf)
	local v = fade(yf)

	-- grid point hashes
	local n00 = hash2D(seed, xi, yi)
	local n10 = hash2D(seed, xi + 1, yi)
	local n01 = hash2D(seed, xi, yi + 1)
	local n11 = hash2D(seed, xi + 1, yi + 1)

	-- gradients
	local g00 = grad2D(n00, xf, yf)
	local g10 = grad2D(n10, xf - 1, yf)
	local g01 = grad2D(n01, xf, yf - 1)
	local g11 = grad2D(n11, xf - 1, yf - 1)

	-- interpolation
	local x0 = lerp(g00, g10, u)
	local x1 = lerp(g01, g11, u)
	local val = lerp(x0, x1, v)

	-- normalize roughly -1..1
	return math.clamp(val, -1, 1)
end

function SimpleNoise:Get2DRange(x: number, y: number, minVal: number, maxVal: number): number
	local raw = self:Get2D(x, y)
	local t = (raw + 1) / 2 -- map -1..1 → 0..1
	return minVal + t * (maxVal - minVal)
end

-- ---------------------------------------------------------------------------
-- BiomeSystem
-- ---------------------------------------------------------------------------

local BiomeSystem = {}
BiomeSystem.__index = BiomeSystem

-- fBm noise helper
local function fBm(noise: any, x: number, z: number, octaves: number, persistence: number, lacunarity: number): number
	local amplitude = 1
	local frequency = 1
	local maxVal = 0
	local total = 0

	for _ = 1, octaves do
		total += amplitude * noise:Get2D(x * frequency, z * frequency)
		maxVal += amplitude
		amplitude *= persistence
		frequency *= lacunarity
	end

	return total / maxVal
end

function BiomeSystem.new(eventBus: any, seed: number?): BiomeSystem
	local self = setmetatable({}, BiomeSystem)

	self._eventBus = eventBus
	self._seed = seed or 42
	self._biomes = {} :: { [string]: BiomeDef }
	self._biomeList = {} :: { BiomeDef }

	-- Noise generators for temperature and moisture
	self._noise = SimpleNoise.new(self._seed)

	-- Register 9 default biomes
	self:_registerDefaultBiomes()

	return self
end

function BiomeSystem:_registerDefaultBiomes()
	-- 1. Ocean
	self:RegisterBiome({
		id = "ocean",
		name = "Ocean",
		tempRange = { min = 0, max = 0.4 },
		moistureRange = { min = 0.6, max = 1.0 },
		baseColor = Color3.fromRGB(30, 90, 150),
		terrainMaterial = Enum.Material.Sand,
		treeDensity = 0,
		rockDensity = 0.05,
		flowerDensity = 0,
		groundCover = {},
	} :: BiomeDef)

	-- 2. Tundra
	self:RegisterBiome({
		id = "tundra",
		name = "Tundra",
		tempRange = { min = 0, max = 0.2 },
		moistureRange = { min = 0, max = 0.4 },
		baseColor = Color3.fromRGB(200, 210, 220),
		terrainMaterial = Enum.Material.Snow,
		treeDensity = 0.05,
		rockDensity = 0.2,
		flowerDensity = 0.1,
		groundCover = {},
	} :: BiomeDef)

	-- 3. Taiga
	self:RegisterBiome({
		id = "taiga",
		name = "Taiga",
		tempRange = { min = 0.1, max = 0.3 },
		moistureRange = { min = 0.3, max = 0.7 },
		baseColor = Color3.fromRGB(40, 80, 50),
		terrainMaterial = Enum.Material.Grass,
		treeDensity = 0.6,
		rockDensity = 0.15,
		flowerDensity = 0.1,
		groundCover = {},
	} :: BiomeDef)

	-- 4. Temperate Forest
	self:RegisterBiome({
		id = "temperate_forest",
		name = "Temperate Forest",
		tempRange = { min = 0.3, max = 0.6 },
		moistureRange = { min = 0.4, max = 0.8 },
		baseColor = Color3.fromRGB(50, 130, 50),
		terrainMaterial = Enum.Material.Grass,
		treeDensity = 0.7,
		rockDensity = 0.1,
		flowerDensity = 0.25,
		groundCover = {},
	} :: BiomeDef)

	-- 5. Grassland
	self:RegisterBiome({
		id = "grassland",
		name = "Grassland",
		tempRange = { min = 0.4, max = 0.7 },
		moistureRange = { min = 0.2, max = 0.5 },
		baseColor = Color3.fromRGB(140, 180, 50),
		terrainMaterial = Enum.Material.Grass,
		treeDensity = 0.15,
		rockDensity = 0.1,
		flowerDensity = 0.4,
		groundCover = {},
	} :: BiomeDef)

	-- 6. Desert
	self:RegisterBiome({
		id = "desert",
		name = "Desert",
		tempRange = { min = 0.6, max = 1.0 },
		moistureRange = { min = 0, max = 0.3 },
		baseColor = Color3.fromRGB(230, 200, 140),
		terrainMaterial = Enum.Material.Sand,
		treeDensity = 0.02,
		rockDensity = 0.25,
		flowerDensity = 0.05,
		groundCover = {},
	} :: BiomeDef)

	-- 7. Tropical Rainforest
	self:RegisterBiome({
		id = "tropical_rainforest",
		name = "Tropical Rainforest",
		tempRange = { min = 0.7, max = 1.0 },
		moistureRange = { min = 0.7, max = 1.0 },
		baseColor = Color3.fromRGB(30, 110, 40),
		terrainMaterial = Enum.Material.Grass,
		treeDensity = 0.85,
		rockDensity = 0.1,
		flowerDensity = 0.5,
		groundCover = {},
	} :: BiomeDef)

	-- 8. Savanna
	self:RegisterBiome({
		id = "savanna",
		name = "Savanna",
		tempRange = { min = 0.6, max = 0.9 },
		moistureRange = { min = 0.2, max = 0.5 },
		baseColor = Color3.fromRGB(180, 170, 60),
		terrainMaterial = Enum.Material.Grass,
		treeDensity = 0.2,
		rockDensity = 0.15,
		flowerDensity = 0.3,
		groundCover = {},
	} :: BiomeDef)

	-- 9. Mountains
	self:RegisterBiome({
		id = "mountains",
		name = "Mountains",
		tempRange = { min = 0, max = 1.0 },
		moistureRange = { min = 0, max = 0.5 },
		baseColor = Color3.fromRGB(120, 120, 130),
		terrainMaterial = Enum.Material.Rock,
		treeDensity = 0.1,
		rockDensity = 0.6,
		flowerDensity = 0.1,
		groundCover = {},
		altitudeOverride = true,
	} :: BiomeDef)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function BiomeSystem:RegisterBiome(biome: BiomeDef)
	if self._biomes[biome.id] then
		warn("[BiomeSystem] Overwriting existing biome: " .. biome.id)
	end
	self._biomes[biome.id] = biome
	-- Update ordered list
	self._biomeList = {}
	for _, b in pairs(self._biomes) do
		table.insert(self._biomeList, b)
	end
	self._eventBus:Emit("BiomeRegistered", biome)
end

function BiomeSystem:GetBiome(temp: number, moisture: number): BiomeDef
	temp = math.clamp(temp, 0, 1)
	moisture = math.clamp(moisture, 0, 1)

	-- Find biome where temp/moisture fall within range
	for _, biome in ipairs(self._biomeList) do
		local tr = biome.tempRange
		local mr = biome.moistureRange
		if temp >= tr.min and temp <= tr.max and moisture >= mr.min and moisture <= mr.max then
			return biome
		end
	end

	-- Fallback: find closest biome by Euclidean distance in temp-moisture space
	local closest: BiomeDef? = nil
	local closestDist = math.huge

	for _, biome in ipairs(self._biomeList) do
		local tr = biome.tempRange
		local mr = biome.moistureRange
		-- Use center of range as anchor point
		local tCenter = (tr.min + tr.max) / 2
		local mCenter = (mr.min + mr.max) / 2
		local dist = math.sqrt((temp - tCenter) ^ 2 + (moisture - mCenter) ^ 2)
		if dist < closestDist then
			closestDist = dist
			closest = biome
		end
	end

	return closest :: BiomeDef
end

function BiomeSystem:GetTempAt(x: number, z: number): number
	-- Temperature noise: large-scale variation
	local raw = fBm(self._noise, x / 2000, z / 2000, 4, 0.5, 2.0)
	-- Map -1..1 → 0..1
	return math.clamp((raw + 1) / 2, 0, 1)
end

function BiomeSystem:GetMoistureAt(x: number, z: number): number
	-- Moisture noise: offset for independence from temperature
	local raw = fBm(self._noise, x / 1500 + 1000, z / 1500, 4, 0.5, 2.0)
	return math.clamp((raw + 1) / 2, 0, 1)
end

function BiomeSystem:GenerateBiomeMap(chunk: ChunkData): ChunkData
	local size = #chunk.heightmap
	chunk.biomeMap = table.create(size)

	for ix = 1, size do
		chunk.biomeMap[ix] = table.create(size)
		for iz = 1, size do
			local worldX = chunk.cx * size + ix
			local worldZ = chunk.cz * size + iz

			local temp = self:GetTempAt(worldX, worldZ)
			local moisture = self:GetMoistureAt(worldX, worldZ)

			-- Mountains override: high altitude areas become mountains
			local height = chunk.heightmap[ix] and chunk.heightmap[ix][iz] or 0
			local surfaceY = chunk.surfaceY and chunk.surfaceY[ix] and chunk.surfaceY[ix][iz] or height

			local biome: BiomeDef
			if surfaceY > 180 then -- altitude threshold for mountains
				biome = self._biomes["mountains"] :: BiomeDef
			else
				biome = self:GetBiome(temp, moisture)
			end

			chunk.biomeMap[ix][iz] = biome.id
			self._eventBus:Emit("BiomeAssigned", {
				cx = chunk.cx,
				cz = chunk.cz,
				x = ix,
				z = iz,
				biomeId = biome.id,
				temp = temp,
				moisture = moisture,
			})
		end
	end

	return chunk
end

function BiomeSystem:GetAllBiomes(): { BiomeDef }
	local result = table.clone(self._biomeList)
	return result
end

return BiomeSystem
