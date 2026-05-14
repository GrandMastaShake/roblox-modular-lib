--!strict
-- tests/test_TerrainGenerator.lua
-- Tests for TerrainGenerator: chunk generation, boundary continuity, events.

local TerrainGenerator = require(script.Parent.Parent.src.TerrainGenerator)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. ": expected true")
	end
end

local function assertNear(a: number, b: number, tolerance: number, msg: string)
	if math.abs(a - b) > tolerance then
		error(msg .. ": expected near " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function createMockEventBus()
	return {
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
		Once = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			return function() end
		end,
		GetEvents = function(self: any, eventName: string): { any }
			return self._events[eventName] or {}
		end,
		Clear = function(self: any)
			self._events = {}
		end,
	}
end

local TESTS = {}

-- Test 1: GenerateChunk produces a heightmap with correct dimensions
function TESTS.testChunkDimensions()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 32,
		maxHeight = 128,
		seaLevel = 16,
		erosion = false,
	})

	local chunk = gen:GenerateChunk(0, 0)
	assertEq(chunk.cx, 0, "Chunk X coordinate")
	assertEq(chunk.cz, 0, "Chunk Z coordinate")
	assertEq(#chunk.heightmap, 32, "Heightmap width")
	assertEq(#chunk.heightmap[1], 32, "Heightmap depth")
	assertEq(#chunk.surfaceY, 32, "SurfaceY width")
	assertEq(#chunk.surfaceY[1], 32, "SurfaceY depth")
end

-- Test 2: Generated chunk emits ChunkGenerated event
function TESTS.testChunkEvent()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 16,
		maxHeight = 64,
		seaLevel = 8,
		erosion = false,
	})

	bus:Clear()
	local chunk = gen:GenerateChunk(1, 2)
	local events = bus:GetEvents("ChunkGenerated")
	assertTrue(#events >= 1, "Should emit ChunkGenerated event")
	assertEq(events[1].cx, 1, "Event cx")
	assertEq(events[1].cz, 2, "Event cz")
end

-- Test 3: Height values are within valid range [0, maxHeight]
function TESTS.testHeightRange()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 64,
		maxHeight = 256,
		seaLevel = 32,
		erosion = false,
	})

	local chunk = gen:GenerateChunk(0, 0)
	for x = 1, 64 do
		for z = 1, 64 do
			local h = chunk.heightmap[x][z]
			assertTrue(h >= 0, "Height should be >= 0, got " .. tostring(h))
			assertTrue(h <= 256, "Height should be <= 256, got " .. tostring(h))
		end
	end
end

-- Test 4: Chunk boundary continuity - adjacent chunks have matching edge heights
function TESTS.testBoundaryContinuity()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 32,
		maxHeight = 128,
		seaLevel = 16,
		erosion = false,
		noise = {
			seed = 42,
			octaves = 4,
			persistence = 0.5,
			lacunarity = 2.0,
			scale = 100,
		},
	})

	local chunk00 = gen:GenerateChunk(0, 0)
	local chunk10 = gen:GenerateChunk(1, 0)
	local chunk01 = gen:GenerateChunk(0, 1)

	local size = 32

	-- Check X boundary: chunk00 right edge vs chunk10 left edge
	-- chunk00 heightmap[size][z] should match chunk10 heightmap[1][z]
	for z = 1, size do
		local hRight = chunk00.heightmap[size][z]
		local hLeft = chunk10.heightmap[1][z]
		assertEq(hRight, hLeft, "X boundary mismatch at z=" .. tostring(z))
	end

	-- Check Z boundary: chunk00 bottom edge vs chunk01 top edge
	for x = 1, size do
		local hBottom = chunk00.heightmap[x][size]
		local hTop = chunk01.heightmap[x][1]
		assertEq(hBottom, hTop, "Z boundary mismatch at x=" .. tostring(x))
	end
end

-- Test 5: Different seeds produce different chunks
function TESTS.testDifferentSeeds()
	local bus1 = createMockEventBus()
	local bus2 = createMockEventBus()
	local gen1 = TerrainGenerator.new(bus1, {
		chunkSize = 32,
		maxHeight = 128,
		seaLevel = 16,
		erosion = false,
		noise = { seed = 1, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 },
	})
	local gen2 = TerrainGenerator.new(bus2, {
		chunkSize = 32,
		maxHeight = 128,
		seaLevel = 16,
		erosion = false,
		noise = { seed = 999, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 },
	})

	local chunk1 = gen1:GenerateChunk(0, 0)
	local chunk2 = gen2:GenerateChunk(0, 0)

	local diffCount = 0
	for x = 1, 32 do
		for z = 1, 32 do
			if chunk1.heightmap[x][z] ~= chunk2.heightmap[x][z] then
				diffCount += 1
			end
		end
	end

	assertTrue(diffCount > 100, "Different seeds should produce different chunks, got " .. tostring(diffCount) .. " differences")
end

-- Test 6: GetHeightAt returns consistent height
function TESTS.testGetHeightAt()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 32,
		maxHeight = 128,
		seaLevel = 16,
		erosion = false,
		noise = { seed = 55, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 },
	})

	local h1 = gen:GetHeightAt(10, 20)
	local h2 = gen:GetHeightAt(10, 20)
	assertEq(h1, h2, "GetHeightAt should be deterministic for same coordinates")
end

-- Test 7: SetTerrainConfig updates configuration
function TESTS.testSetConfig()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 16,
		maxHeight = 64,
		seaLevel = 8,
		erosion = false,
		noise = { seed = 1, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 },
	})

	local chunk1 = gen:GenerateChunk(0, 0)

	-- Change config with different seed
	gen:SetTerrainConfig({
		chunkSize = 16,
		maxHeight = 64,
		seaLevel = 8,
		erosion = false,
		noise = { seed = 2, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 },
	})

	local chunk2 = gen:GenerateChunk(0, 0)

	local diffCount = 0
	for x = 1, 16 do
		for z = 1, 16 do
			if chunk1.heightmap[x][z] ~= chunk2.heightmap[x][z] then
				diffCount += 1
			end
		end
	end

	assertTrue(diffCount > 10, "SetTerrainConfig with different seed should change output")
end

-- Test 8: HeightSampled event is emitted by GetHeightAt
function TESTS.testHeightSampledEvent()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 16,
		maxHeight = 64,
		seaLevel = 8,
		erosion = false,
	})

	bus:Clear()
	gen:GetHeightAt(100, 200)
	local events = bus:GetEvents("HeightSampled")
	assertTrue(#events >= 1, "Should emit HeightSampled event")
	assertEq(events[1].x, 100, "Event x coordinate")
	assertEq(events[1].z, 200, "Event z coordinate")
	assertTrue(events[1].height ~= nil, "Event should include height")
end

-- Test 9: biomeMap is initialized
function TESTS.testBiomeMapInitialized()
	local bus = createMockEventBus()
	local gen = TerrainGenerator.new(bus, {
		chunkSize = 16,
		maxHeight = 64,
		seaLevel = 8,
		erosion = false,
	})

	local chunk = gen:GenerateChunk(0, 0)
	assertEq(#chunk.biomeMap, 16, "Biome map width")
	assertEq(#chunk.biomeMap[1], 16, "Biome map depth")
	assertEq(chunk.biomeMap[5][5], "Unknown", "Default biome should be Unknown")
end

-- Run all tests
local passed = 0
local failed = 0
for name, testFn in pairs(TESTS) do
	local ok, err = pcall(testFn)
	if ok then
		print("  [PASS] " .. name)
		passed += 1
	else
		print("  [FAIL] " .. name .. ": " .. tostring(err))
		failed += 1
	end
end

print("")
print("TerrainGenerator Test Results: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed")
if failed > 0 then
	error("TerrainGenerator tests failed")
end
