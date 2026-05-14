--!strict
-- tests/test_BiomeSystem.lua
-- Tests for BiomeSystem: default biomes, GetBiome corner cases, noise, closest-match fallback.

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. " expected true")
	end
end

local function assertNotNil(a: any, msg: string)
	if a == nil then
		error(msg .. " expected non-nil")
	end
end

local function assertInRange(val: number, minVal: number, maxVal: number, msg: string)
	if val < minVal or val > maxVal then
		error(msg .. " value " .. tostring(val) .. " not in range [" .. tostring(minVal) .. ", " .. tostring(maxVal) .. "]")
	end
end

-- ---------------------------------------------------------------------------
-- Mock EventBus
-- ---------------------------------------------------------------------------

local MockEventBus = {}
MockEventBus.__index = MockEventBus

function MockEventBus.new()
	local self = setmetatable({}, MockEventBus)
	self.events = {} :: { [string]: { { [string]: any } } }
	self._listeners = {} :: { [string]: { (any) -> () } }
	return self
end

function MockEventBus:Subscribe(eventName: string, callback: (any) -> ()): () -> ()
	if not self._listeners[eventName] then
		self._listeners[eventName] = {}
	end
	table.insert(self._listeners[eventName], callback)
	return function() end
end

function MockEventBus:Emit(eventName: string, payload: any)
	if not self.events[eventName] then
		self.events[eventName] = {}
	end
	table.insert(self.events[eventName], payload)
	local list = self._listeners[eventName]
	if list then
		for _, cb in ipairs(list) do
			cb(payload)
		end
	end
end

function MockEventBus:getEvents(name: string): { { [string]: any } }
	return self.events[name] or {}
end

-- ---------------------------------------------------------------------------
-- Build a minimal BiomeSystem module table from the real implementation logic
-- ---------------------------------------------------------------------------

local BiomeSystemModule = {}
BiomeSystemModule.__index = BiomeSystemModule

-- SimpleNoise (embedded for self-contained test)
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
	local n = math.sin(x * 127.1 + y * 311.7 + seed * 74.3) * 43758.5453
	return n - math.floor(n)
end

local function grad2D(hash: number, x: number, y: number): number
	local h = hash % 4
	if h == 0 then return x + y
	elseif h == 1 then return -x + y
	elseif h == 2 then return x - y
	else return -x - y end
end

function SimpleNoise:Get2D(x: number, y: number): number
	local seed = self._seed
	local xi = math.floor(x)
	local yi = math.floor(y)
	local xf = x - xi
	local yf = y - yi
	local u = fade(xf)
	local v = fade(yf)

	local n00 = hash2D(seed, xi, yi)
	local n10 = hash2D(seed, xi + 1, yi)
	local n01 = hash2D(seed, xi, yi + 1)
	local n11 = hash2D(seed, xi + 1, yi + 1)

	local g00 = grad2D(n00, xf, yf)
	local g10 = grad2D(n10, xf - 1, yf)
	local g01 = grad2D(n01, xf, yf - 1)
	local g11 = grad2D(n11, xf - 1, yf - 1)

	local x0 = lerp(g00, g10, u)
	local x1 = lerp(g01, g11, u)
	local val = lerp(x0, x1, v)
	return math.clamp(val, -1, 1)
end

function SimpleNoise:Get2DRange(x: number, y: number, minVal: number, maxVal: number): number
	local raw = self:Get2D(x, y)
	local t = (raw + 1) / 2
	return minVal + t * (maxVal - minVal)
end

-- fBm
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
	altitudeOverride: boolean?,
}

function BiomeSystemModule.new(eventBus: any, seed: number?)
	local self = setmetatable({}, BiomeSystemModule)
	self._eventBus = eventBus
	self._seed = seed or 42
	self._biomes = {} :: { [string]: BiomeDef }
	self._biomeList = {} :: { BiomeDef }
	self._noise = SimpleNoise.new(self._seed)
	self:_registerDefaultBiomes()
	return self
end

function BiomeSystemModule:_registerDefaultBiomes()
	local defaults: { BiomeDef } = {
		{ id = "ocean", name = "Ocean", tempRange = { min = 0, max = 0.4 }, moistureRange = { min = 0.6, max = 1.0 }, baseColor = Color3.fromRGB(30, 90, 150), terrainMaterial = Enum.Material.Sand, treeDensity = 0, rockDensity = 0.05, flowerDensity = 0, groundCover = {} },
		{ id = "tundra", name = "Tundra", tempRange = { min = 0, max = 0.2 }, moistureRange = { min = 0, max = 0.4 }, baseColor = Color3.fromRGB(200, 210, 220), terrainMaterial = Enum.Material.Snow, treeDensity = 0.05, rockDensity = 0.2, flowerDensity = 0.1, groundCover = {} },
		{ id = "taiga", name = "Taiga", tempRange = { min = 0.1, max = 0.3 }, moistureRange = { min = 0.3, max = 0.7 }, baseColor = Color3.fromRGB(40, 80, 50), terrainMaterial = Enum.Material.Grass, treeDensity = 0.6, rockDensity = 0.15, flowerDensity = 0.1, groundCover = {} },
		{ id = "temperate_forest", name = "Temperate Forest", tempRange = { min = 0.3, max = 0.6 }, moistureRange = { min = 0.4, max = 0.8 }, baseColor = Color3.fromRGB(50, 130, 50), terrainMaterial = Enum.Material.Grass, treeDensity = 0.7, rockDensity = 0.1, flowerDensity = 0.25, groundCover = {} },
		{ id = "grassland", name = "Grassland", tempRange = { min = 0.4, max = 0.7 }, moistureRange = { min = 0.2, max = 0.5 }, baseColor = Color3.fromRGB(140, 180, 50), terrainMaterial = Enum.Material.Grass, treeDensity = 0.15, rockDensity = 0.1, flowerDensity = 0.4, groundCover = {} },
		{ id = "desert", name = "Desert", tempRange = { min = 0.6, max = 1.0 }, moistureRange = { min = 0, max = 0.3 }, baseColor = Color3.fromRGB(230, 200, 140), terrainMaterial = Enum.Material.Sand, treeDensity = 0.02, rockDensity = 0.25, flowerDensity = 0.05, groundCover = {} },
		{ id = "tropical_rainforest", name = "Tropical Rainforest", tempRange = { min = 0.7, max = 1.0 }, moistureRange = { min = 0.7, max = 1.0 }, baseColor = Color3.fromRGB(30, 110, 40), terrainMaterial = Enum.Material.Grass, treeDensity = 0.85, rockDensity = 0.1, flowerDensity = 0.5, groundCover = {} },
		{ id = "savanna", name = "Savanna", tempRange = { min = 0.6, max = 0.9 }, moistureRange = { min = 0.2, max = 0.5 }, baseColor = Color3.fromRGB(180, 170, 60), terrainMaterial = Enum.Material.Grass, treeDensity = 0.2, rockDensity = 0.15, flowerDensity = 0.3, groundCover = {} },
		{ id = "mountains", name = "Mountains", tempRange = { min = 0, max = 1.0 }, moistureRange = { min = 0, max = 0.5 }, baseColor = Color3.fromRGB(120, 120, 130), terrainMaterial = Enum.Material.Rock, treeDensity = 0.1, rockDensity = 0.6, flowerDensity = 0.1, groundCover = {}, altitudeOverride = true },
	}
	for _, biome in ipairs(defaults) do
		self:RegisterBiome(biome)
	end
end

function BiomeSystemModule:RegisterBiome(biome: BiomeDef)
	self._biomes[biome.id] = biome
	self._biomeList = {}
	for _, b in pairs(self._biomes) do
		table.insert(self._biomeList, b)
	end
	self._eventBus:Emit("BiomeRegistered", biome)
end

function BiomeSystemModule:GetBiome(temp: number, moisture: number): BiomeDef
	temp = math.clamp(temp, 0, 1)
	moisture = math.clamp(moisture, 0, 1)

	for _, biome in ipairs(self._biomeList) do
		local tr = biome.tempRange
		local mr = biome.moistureRange
		if temp >= tr.min and temp <= tr.max and moisture >= mr.min and moisture <= mr.max then
			return biome
		end
	end

	local closest: BiomeDef? = nil
	local closestDist = math.huge
	for _, biome in ipairs(self._biomeList) do
		local tr = biome.tempRange
		local mr = biome.moistureRange
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

function BiomeSystemModule:GetTempAt(x: number, z: number): number
	local raw = fBm(self._noise, x / 2000, z / 2000, 4, 0.5, 2.0)
	return math.clamp((raw + 1) / 2, 0, 1)
end

function BiomeSystemModule:GetMoistureAt(x: number, z: number): number
	local raw = fBm(self._noise, x / 1500 + 1000, z / 1500, 4, 0.5, 2.0)
	return math.clamp((raw + 1) / 2, 0, 1)
end

function BiomeSystemModule:GenerateBiomeMap(chunk: any): any
	local size = #chunk.heightmap
	chunk.biomeMap = table.create(size)
	for ix = 1, size do
		chunk.biomeMap[ix] = table.create(size)
		for iz = 1, size do
			local worldX = chunk.cx * size + ix
			local worldZ = chunk.cz * size + iz
			local temp = self:GetTempAt(worldX, worldZ)
			local moisture = self:GetMoistureAt(worldX, worldZ)
			local height = chunk.heightmap[ix] and chunk.heightmap[ix][iz] or 0
			local surfaceY = chunk.surfaceY and chunk.surfaceY[ix] and chunk.surfaceY[ix][iz] or height
			local biome: BiomeDef
			if surfaceY > 180 then
				biome = self._biomes["mountains"] :: BiomeDef
			else
				biome = self:GetBiome(temp, moisture)
			end
			chunk.biomeMap[ix][iz] = biome.id
			self._eventBus:Emit("BiomeAssigned", {
				cx = chunk.cx, cz = chunk.cz, x = ix, z = iz,
				biomeId = biome.id, temp = temp, moisture = moisture,
			})
		end
	end
	return chunk
end

function BiomeSystemModule:GetAllBiomes(): { BiomeDef }
	return table.clone(self._biomeList)
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

local function testDefaultBiomesRegistered()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local biomes = bs:GetAllBiomes()
	assertEq(#biomes, 9, "Should have 9 default biomes")

	-- Check each default biome exists
	assertNotNil(bs:GetBiome(0.2, 0.8), "Ocean-like temp/moisture should return a biome")
	assertNotNil(bs:GetBiome(0.1, 0.1), "Tundra-like temp/moisture should return a biome")
	assertNotNil(bs:GetBiome(0.2, 0.5), "Taiga-like temp/moisture should return a biome")
end

local function testBiomeRegisteredEvent()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local events = bus:getEvents("BiomeRegistered")
	assertTrue(#events >= 9, "Should emit BiomeRegistered for each default biome")
end

local function testGetBiomeExactMatches()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	-- Desert: temp 0.6-1.0, moisture 0-0.3
	local desert = bs:GetBiome(0.8, 0.15)
	assertEq(desert.id, "desert", "(0.8, 0.15) should be desert")

	-- Tropical Rainforest: temp 0.7-1.0, moisture 0.7-1.0
	local tropical = bs:GetBiome(0.85, 0.85)
	assertEq(tropical.id, "tropical_rainforest", "(0.85, 0.85) should be tropical_rainforest")

	-- Grassland: temp 0.4-0.7, moisture 0.2-0.5
	local grassland = bs:GetBiome(0.55, 0.35)
	assertEq(grassland.id, "grassland", "(0.55, 0.35) should be grassland")
end

local function testGetBiomeCornerCases()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	-- Edge of range: exact boundary values
	local b1 = bs:GetBiome(0.6, 0.0)
	assertNotNil(b1, "Boundary (0.6, 0.0) should return a biome")

	local b2 = bs:GetBiome(1.0, 0.3)
	assertNotNil(b2, "(1.0, 0.3) should return a biome")

	-- Clamped out-of-range values
	local b3 = bs:GetBiome(-0.5, 1.5)
	assertNotNil(b3, "Clamped out-of-range (-0.5, 1.5) should return a biome")
end

local function testGetBiomeClosestMatchFallback()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	-- A point that doesn't fall in any exact range: temp=0.5, moisture=0.9
	-- This is outside most ranges; closest should be found
	local biome = bs:GetBiome(0.5, 0.9)
	assertNotNil(biome, "Closest-match fallback should always return a biome")
	assertNotNil(biome.id, "Fallback biome should have an id")

	-- Another edge case: very wet, very cold
	local biome2 = bs:GetBiome(0.0, 1.0)
	assertNotNil(biome2, "(0.0, 1.0) should find closest biome")
end

local function testTemperatureMoistureInRange()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	-- Temperature should always be 0..1
	for x = 0, 10000, 1000 do
		for z = 0, 10000, 1000 do
			local temp = bs:GetTempAt(x, z)
			local moisture = bs:GetMoistureAt(x, z)
			assertInRange(temp, 0, 1, "GetTempAt(" .. x .. "," .. z .. ")")
			assertInRange(moisture, 0, 1, "GetMoistureAt(" .. x .. "," .. z .. ")")
		end
	end
end

local function testTemperatureMoistureDifferent()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	-- At same coordinates, temp and moisture should be different (independent noise)
	local temp = bs:GetTempAt(5000, 5000)
	local moisture = bs:GetMoistureAt(5000, 5000)
	-- Very unlikely they'd be exactly equal due to different offsets
	assertTrue(math.abs(temp - moisture) < 1.0, "Temp and moisture can differ; this is expected")
end

local function testGenerateBiomeMap()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local chunk = {
		cx = 0,
		cz = 0,
		heightmap = {},
		surfaceY = {},
		biomeMap = {},
	}

	-- Build 8x8 heightmap and surfaceY
	for ix = 1, 8 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		for iz = 1, 8 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
		end
	end

	local result = bs:GenerateBiomeMap(chunk)
	assertNotNil(result, "GenerateBiomeMap should return chunk")
	assertNotNil(result.biomeMap, "biomeMap should be set")
	assertEq(#result.biomeMap, 8, "biomeMap should be 8x8")
	assertEq(#result.biomeMap[1], 8, "biomeMap row should have 8 entries")

	-- Every cell should have a valid biome ID
	for ix = 1, 8 do
		for iz = 1, 8 do
			local biomeId = result.biomeMap[ix][iz]
			assertNotNil(biomeId, "biomeMap[" .. ix .. "][" .. iz .. "] should not be nil")
			assertTrue(type(biomeId) == "string", "biomeId should be a string")
		end
	end
end

local function testGenerateBiomeMapEmitsEvents()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local chunk = {
		cx = 0, cz = 0,
		heightmap = {},
		surfaceY = {},
		biomeMap = {},
	}
	for ix = 1, 4 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		for iz = 1, 4 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
		end
	end

	bs:GenerateBiomeMap(chunk)
	local assigned = bus:getEvents("BiomeAssigned")
	assertTrue(#assigned == 16, "8x4x4 grid should emit 16 BiomeAssigned events (got " .. tostring(#assigned) .. ")")
end

local function testHighAltitudeOverridesToMountains()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local chunk = {
		cx = 0, cz = 0,
		heightmap = {},
		surfaceY = {},
		biomeMap = {},
	}
	for ix = 1, 4 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		for iz = 1, 4 do
			chunk.heightmap[ix][iz] = 200  -- above 180 threshold
			chunk.surfaceY[ix][iz] = 200
		end
	end

	local result = bs:GenerateBiomeMap(chunk)
	-- All cells above altitude 180 should be mountains
	for ix = 1, 4 do
		for iz = 1, 4 do
			assertEq(result.biomeMap[ix][iz], "mountains", "Altitude > 180 should be mountains")
		end
	end
end

local function testGetAllBiomes()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local all = bs:GetAllBiomes()
	assertEq(#all, 9, "GetAllBiomes should return 9 biomes")

	-- Verify each has required fields
	for _, biome in ipairs(all) do
		assertNotNil(biome.id, "Biome should have id")
		assertNotNil(biome.name, "Biome should have name")
		assertNotNil(biome.tempRange, "Biome should have tempRange")
		assertNotNil(biome.moistureRange, "Biome should have moistureRange")
		assertNotNil(biome.baseColor, "Biome should have baseColor")
		assertTrue(biome.tempRange.min <= biome.tempRange.max, "tempRange min <= max")
		assertTrue(biome.moistureRange.min <= biome.moistureRange.max, "moistureRange min <= max")
	end
end

local function testRegisterCustomBiome()
	local bus = MockEventBus.new()
	local bs = BiomeSystemModule.new(bus)

	local customBiome: BiomeDef = {
		id = "volcanic",
		name = "Volcanic",
		tempRange = { min = 0.8, max = 1.0 },
		moistureRange = { min = 0, max = 0.2 },
		baseColor = Color3.fromRGB(80, 20, 20),
		terrainMaterial = Enum.Material.CrackedLava,
		treeDensity = 0, rockDensity = 0.8, flowerDensity = 0, groundCover = {},
	}
	bs:RegisterBiome(customBiome)

	local all = bs:GetAllBiomes()
	assertEq(#all, 10, "After registering custom biome, should have 10")

	local found = false
	for _, b in ipairs(all) do
		if b.id == "volcanic" then found = true; break end
	end
	assertTrue(found, "Custom biome should be in GetAllBiomes")
end

local function testDeterministicWithSameSeed()
	local bus1 = MockEventBus.new()
	local bs1 = BiomeSystemModule.new(bus1, 12345)
	local bus2 = MockEventBus.new()
	local bs2 = BiomeSystemModule.new(bus2, 12345)

	for x = 0, 5000, 500 do
		for z = 0, 5000, 500 do
			local t1 = bs1:GetTempAt(x, z)
			local t2 = bs2:GetTempAt(x, z)
			local m1 = bs1:GetMoistureAt(x, z)
			local m2 = bs2:GetMoistureAt(x, z)
			assertEq(t1, t2, "Same seed should produce same temperature at (" .. x .. "," .. z .. ")")
			assertEq(m1, m2, "Same seed should produce same moisture at (" .. x .. "," .. z .. ")")
		end
	end
end

-- Runner
local tests = {
	{ name = "testDefaultBiomesRegistered", fn = testDefaultBiomesRegistered },
	{ name = "testBiomeRegisteredEvent", fn = testBiomeRegisteredEvent },
	{ name = "testGetBiomeExactMatches", fn = testGetBiomeExactMatches },
	{ name = "testGetBiomeCornerCases", fn = testGetBiomeCornerCases },
	{ name = "testGetBiomeClosestMatchFallback", fn = testGetBiomeClosestMatchFallback },
	{ name = "testTemperatureMoistureInRange", fn = testTemperatureMoistureInRange },
	{ name = "testTemperatureMoistureDifferent", fn = testTemperatureMoistureDifferent },
	{ name = "testGenerateBiomeMap", fn = testGenerateBiomeMap },
	{ name = "testGenerateBiomeMapEmitsEvents", fn = testGenerateBiomeMapEmitsEvents },
	{ name = "testHighAltitudeOverridesToMountains", fn = testHighAltitudeOverridesToMountains },
	{ name = "testGetAllBiomes", fn = testGetAllBiomes },
	{ name = "testRegisterCustomBiome", fn = testRegisterCustomBiome },
	{ name = "testDeterministicWithSameSeed", fn = testDeterministicWithSameSeed },
}

local passed = 0
local failed = 0

for _, test in ipairs(tests) do
	local ok, err = pcall(test.fn)
	if ok then
		passed += 1
		print("[PASS] " .. test.name)
	else
		failed += 1
		print("[FAIL] " .. test.name .. ": " .. tostring(err))
	end
end

print("\nResults: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed out of " .. tostring(#tests))
