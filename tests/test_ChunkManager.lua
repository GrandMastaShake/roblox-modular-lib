--!strict
-- tests/test_ChunkManager.lua
-- Tests for ChunkManager: LoadChunk, UnloadChunk, StreamAround, cache, view distance.

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
-- Mock TerrainGenerator
-- ---------------------------------------------------------------------------

local MockTerrainGenerator = {}
MockTerrainGenerator.__index = MockTerrainGenerator

function MockTerrainGenerator.new()
	local self = setmetatable({}, MockTerrainGenerator)
	self._chunks = {} :: { [string]: any }
	self._applyCount = 0
	return self
end

function MockTerrainGenerator:GenerateChunk(cx: number, cz: number): any
	local key = cx .. "," .. cz
	if self._chunks[key] then
		return self._chunks[key]
	end

	-- Generate a 16x16 heightmap
	local heightmap = {}
	local surfaceY = {}
	local biomeMap = {}
	for ix = 1, 16 do
		heightmap[ix] = {}
		surfaceY[ix] = {}
		biomeMap[ix] = {}
		for iz = 1, 16 do
			-- Deterministic pseudo-height based on position
			local h = 50 + math.sin(cx * 0.5 + ix * 0.1) * 20 + math.cos(cz * 0.5 + iz * 0.1) * 20
			heightmap[ix][iz] = math.clamp(h, 0, 200)
			surfaceY[ix][iz] = heightmap[ix][iz]
			biomeMap[ix][iz] = "grassland"
		end
	end

	local chunk = {
		cx = cx, cz = cz,
		heightmap = heightmap,
		surfaceY = surfaceY,
		biomeMap = biomeMap,
	}
	self._chunks[key] = chunk
	return chunk
end

function MockTerrainGenerator:ApplyToTerrain(chunk: any)
	self._applyCount += 1
end

function MockTerrainGenerator:GetHeightAt(worldX: number, worldZ: number): number
	return 50
end

function MockTerrainGenerator:SetTerrainConfig(config: any) end

-- ---------------------------------------------------------------------------
-- Mock BiomeSystem
-- ---------------------------------------------------------------------------

local MockBiomeSystem = {}
MockBiomeSystem.__index = MockBiomeSystem

function MockBiomeSystem.new()
	local self = setmetatable({}, MockBiomeSystem)
	self._biomeMapCount = 0
	return self
end

function MockBiomeSystem:GenerateBiomeMap(chunk: any): any
	self._biomeMapCount += 1
	-- Assign a deterministic biome based on position
	local size = #chunk.heightmap
	for ix = 1, size do
		for iz = 1, size do
			if chunk.surfaceY[ix][iz] > 100 then
				chunk.biomeMap[ix][iz] = "mountains"
			elseif chunk.surfaceY[ix][iz] < 30 then
				chunk.biomeMap[ix][iz] = "ocean"
			else
				chunk.biomeMap[ix][iz] = "grassland"
			end
		end
	end
	return chunk
end

function MockBiomeSystem:GetTempAt(x: number, z: number): number
	return 0.5
end

function MockBiomeSystem:GetMoistureAt(x: number, z: number): number
	return 0.5
end

-- ---------------------------------------------------------------------------
-- Mock ObjectPlacer
-- ---------------------------------------------------------------------------

local MockObjectPlacer = {}
MockObjectPlacer.__index = MockObjectPlacer

function MockObjectPlacer.new()
	local self = setmetatable({}, MockObjectPlacer)
	self._placedChunks = {} :: { [string]: { any } }
	self._clearedChunks = {} :: { [string]: boolean }
	self._placementCount = 0
	self._densityMultiplier = 1.0
	return self
end

function MockObjectPlacer:PlaceInChunk(chunk: any, densityMultiplier: number?): { any }
	local key = chunk.cx .. "," .. chunk.cz
	local placements = {}
	-- Create some mock placements
	for i = 1, 5 do
		table.insert(placements, {
			objectId = "MockObj" .. tostring(i),
			cframe = CFrame.new(chunk.cx * 64 + i * 4, 50, chunk.cz * 64 + i * 4),
			scale = 1.0,
		})
	end
	self._placedChunks[key] = placements
	self._placementCount += #placements
	return placements
end

function MockObjectPlacer:ClearChunk(cx: number, cz: number)
	local key = cx .. "," .. cz
	local existing = self._placedChunks[key]
	if existing then
		self._placementCount -= #existing
		self._placedChunks[key] = nil
	end
	self._clearedChunks[key] = true
end

function MockObjectPlacer:GetPlacementCount(): number
	return self._placementCount
end

function MockObjectPlacer:SetDensityMultiplier(multiplier: number)
	self._densityMultiplier = multiplier
end

-- ---------------------------------------------------------------------------
-- ChunkManager module table (self-contained for test)
-- ---------------------------------------------------------------------------

local ChunkManagerModule = {}
ChunkManagerModule.__index = ChunkManagerModule

function ChunkManagerModule.new(eventBus: any, terrainGen: any, objectPlacer: any, biomeSys: any?)
	local self = setmetatable({}, ChunkManagerModule)
	self._eventBus = eventBus
	self._terrainGen = terrainGen
	self._objectPlacer = objectPlacer
	self._biomeSys = biomeSys
	self._loadedChunks = {} :: { [number]: { [number]: any } }
	self._viewDistance = 4
	self._lastStreamedCenter = nil
	return self
end

function ChunkManagerModule:LoadChunk(cx: number, cz: number): any
	if self:IsChunkLoaded(cx, cz) then
		return self._loadedChunks[cx][cz]
	end

	local chunk = self._terrainGen:GenerateChunk(cx, cz)

	if self._biomeSys then
		chunk = self._biomeSys:GenerateBiomeMap(chunk)
	else
		local size = #chunk.heightmap
		chunk.biomeMap = table.create(size)
		for ix = 1, size do
			chunk.biomeMap[ix] = table.create(size)
			for iz = 1, size do
				chunk.biomeMap[ix][iz] = "grassland"
			end
		end
	end

	self._terrainGen:ApplyToTerrain(chunk)
	local _placements = self._objectPlacer:PlaceInChunk(chunk)

	if not self._loadedChunks[cx] then
		self._loadedChunks[cx] = {}
	end
	self._loadedChunks[cx][cz] = chunk

	self._eventBus:Emit("ChunkLoaded", { cx = cx, cz = cz, chunk = chunk })
	return chunk
end

function ChunkManagerModule:UnloadChunk(cx: number, cz: number)
	if not self:IsChunkLoaded(cx, cz) then
		return
	end

	local chunk = self._loadedChunks[cx][cz]
	self._objectPlacer:ClearChunk(cx, cz)
	self._loadedChunks[cx][cz] = nil
	if next(self._loadedChunks[cx]) == nil then
		self._loadedChunks[cx] = nil
	end

	self._eventBus:Emit("ChunkUnloaded", { cx = cx, cz = cz, chunk = chunk })
end

function ChunkManagerModule:IsChunkLoaded(cx: number, cz: number): boolean
	return self._loadedChunks[cx] ~= nil and self._loadedChunks[cx][cz] ~= nil
end

function ChunkManagerModule:GetLoadedChunks(): { { cx: number, cz: number } }
	local chunks = {}
	for cx, row in pairs(self._loadedChunks) do
		for cz, _ in pairs(row) do
			table.insert(chunks, { cx = cx, cz = cz })
		end
	end
	return chunks
end

function ChunkManagerModule:SetViewDistance(chunks: number)
	self._viewDistance = math.clamp(math.floor(chunks), 1, 32)
end

function ChunkManagerModule:StreamAround(worldX: number, worldZ: number): ({ any }, { any })
	local chunkSize = 64
	local cx = math.floor(worldX / chunkSize)
	local cz = math.floor(worldZ / chunkSize)
	local viewDist = self._viewDistance

	local newlyLoaded = {} :: { any }
	local newlyUnloaded = {} :: { any }

	local desiredChunks = {} :: { [string]: boolean }
	for dx = -viewDist, viewDist do
		for dz = -viewDist, viewDist do
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
	self._eventBus:Emit("ChunksStreamed", { centerCx = cx, centerCz = cz, viewDistance = viewDist, newlyLoaded = newlyLoaded, newlyUnloaded = newlyUnloaded })

	return newlyLoaded, newlyUnloaded
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

local function testLoadChunkReturnsChunkData()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local biome = MockBiomeSystem.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer, biome)

	local chunk = cm:LoadChunk(0, 0)
	assertNotNil(chunk, "LoadChunk should return ChunkData")
	assertNotNil(chunk.heightmap, "ChunkData should have heightmap")
	assertNotNil(chunk.surfaceY, "ChunkData should have surfaceY")
	assertNotNil(chunk.biomeMap, "ChunkData should have biomeMap")
	assertEq(chunk.cx, 0, "ChunkData cx")
	assertEq(chunk.cz, 0, "ChunkData cz")
end

local function testLoadChunkCaches()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local biome = MockBiomeSystem.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer, biome)

	local c1 = cm:LoadChunk(1, 1)
	local c2 = cm:LoadChunk(1, 1)
	assertEq(c1, c2, "Loading same chunk twice should return cached instance")
end

local function testLoadChunkEmitsEvent()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:LoadChunk(0, 0)
	local events = bus:getEvents("ChunkLoaded")
	assertEq(#events, 1, "Should emit ChunkLoaded event")
end

local function testIsChunkLoaded()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	assertTrue(not cm:IsChunkLoaded(0, 0), "Chunk (0,0) should not be loaded initially")
	cm:LoadChunk(0, 0)
	assertTrue(cm:IsChunkLoaded(0, 0), "Chunk (0,0) should be loaded after LoadChunk")
end

local function testGetLoadedChunks()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:LoadChunk(0, 0)
	cm:LoadChunk(1, 0)
	cm:LoadChunk(0, 1)

	local loaded = cm:GetLoadedChunks()
	assertEq(#loaded, 3, "Should have 3 loaded chunks")
end

local function testUnloadChunkRemovesFromCache()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:LoadChunk(0, 0)
	assertTrue(cm:IsChunkLoaded(0, 0), "Chunk should be loaded")

	cm:UnloadChunk(0, 0)
	assertTrue(not cm:IsChunkLoaded(0, 0), "Chunk should be unloaded")
end

local function testUnloadChunkEmitsEvent()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:LoadChunk(0, 0)
	cm:UnloadChunk(0, 0)

	local events = bus:getEvents("ChunkUnloaded")
	assertEq(#events, 1, "Should emit ChunkUnloaded event")
end

local function testUnloadChunkCallsObjectPlacer()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:LoadChunk(0, 0)
	assertTrue(placer._placedChunks["0,0"] ~= nil, "Objects should be placed")

	cm:UnloadChunk(0, 0)
	assertTrue(placer._clearedChunks["0,0"], "ClearChunk should be called")
end

local function testSetViewDistance()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:SetViewDistance(2)
	-- At (0,0) with view distance 2, should load a roughly 5x5 diamond of chunks
	local loaded, unloaded = cm:StreamAround(0, 0)
	assertTrue(#loaded > 0, "Should load some chunks")

	-- With view distance 2, max chunks = circle of radius 2.5 = ~19-21 chunks
	local allLoaded = cm:GetLoadedChunks()
	assertTrue(#allLoaded <= 32, "View distance 2 should not load more than ~32 chunks")
end

local function testStreamAroundLoadsChunksInView()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:SetViewDistance(1)
	local loaded, _ = cm:StreamAround(100, 100)
	assertTrue(#loaded > 0, "StreamAround should load chunks near (100, 100)")

	-- Chunk (100, 100) / 64 = (1, 1), so center is around (1,1)
	-- View distance 1 should load chunks within 1 chunk
	local allLoaded = cm:GetLoadedChunks()
	assertTrue(#allLoaded >= 1, "Should have at least 1 loaded chunk")
end

local function testStreamAroundUnloadsFarChunks()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:SetViewDistance(3)
	-- Start at origin
	cm:StreamAround(0, 0)
	local loaded1 = #cm:GetLoadedChunks()
	assertTrue(loaded1 > 0, "Should load chunks at origin")

	-- Move far away
	local _, unloaded = cm:StreamAround(1000, 1000)
	assertTrue(#unloaded > 0, "Moving far away should unload previous chunks")
end

local function testStreamAroundEmitsChunksStreamed()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:SetViewDistance(1)
	cm:StreamAround(0, 0)

	local events = bus:getEvents("ChunksStreamed")
	assertTrue(#events > 0, "Should emit ChunksStreamed event")
end

local function testStreamAroundReturnsNewlyLoadedAndUnloaded()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	cm:SetViewDistance(2)

	-- First stream
	local loaded1, unloaded1 = cm:StreamAround(0, 0)
	assertTrue(#loaded1 > 0, "First stream should load chunks")
	assertEq(#unloaded1, 0, "First stream should have nothing to unload")

	-- Second stream at same position: nothing new to load
	local loaded2, unloaded2 = cm:StreamAround(0, 0)
	assertEq(#loaded2, 0, "Re-streaming same position should load nothing new")
	assertEq(#unloaded2, 0, "Re-streaming same position should unload nothing")
end

local function testMemoryBounded()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	-- Stream around many different positions
	cm:SetViewDistance(2)
	for i = 1, 20 do
		cm:StreamAround(i * 128, 0)
	end

	-- Loaded chunks should be bounded by view distance
	local loaded = cm:GetLoadedChunks()
	-- Max: circle of radius 2.5 ≈ ~21 chunks at any position
	assertTrue(#loaded <= 32, "Loaded chunks should stay bounded (<= 32 for vd=2)")
end

local function testMultipleChunksIndependent()
	local bus = MockEventBus.new()
	local terrain = MockTerrainGenerator.new()
	local placer = MockObjectPlacer.new()
	local cm = ChunkManagerModule.new(bus, terrain, placer)

	local c1 = cm:LoadChunk(0, 0)
	local c2 = cm:LoadChunk(1, 0)
	local c3 = cm:LoadChunk(0, 1)

	assertTrue(cm:IsChunkLoaded(0, 0), "(0,0) should be loaded")
	assertTrue(cm:IsChunkLoaded(1, 0), "(1,0) should be loaded")
	assertTrue(cm:IsChunkLoaded(0, 1), "(0,1) should be loaded")
	assertTrue(not cm:IsChunkLoaded(5, 5), "(5,5) should not be loaded")

	-- Each chunk should have independent data
	assertTrue(c1 ~= c2, "Chunks should be independent instances")
	assertTrue(c1 ~= c3, "Chunks should be independent instances")
end

-- Runner
local tests = {
	{ name = "testLoadChunkReturnsChunkData", fn = testLoadChunkReturnsChunkData },
	{ name = "testLoadChunkCaches", fn = testLoadChunkCaches },
	{ name = "testLoadChunkEmitsEvent", fn = testLoadChunkEmitsEvent },
	{ name = "testIsChunkLoaded", fn = testIsChunkLoaded },
	{ name = "testGetLoadedChunks", fn = testGetLoadedChunks },
	{ name = "testUnloadChunkRemovesFromCache", fn = testUnloadChunkRemovesFromCache },
	{ name = "testUnloadChunkEmitsEvent", fn = testUnloadChunkEmitsEvent },
	{ name = "testUnloadChunkCallsObjectPlacer", fn = testUnloadChunkCallsObjectPlacer },
	{ name = "testSetViewDistance", fn = testSetViewDistance },
	{ name = "testStreamAroundLoadsChunksInView", fn = testStreamAroundLoadsChunksInView },
	{ name = "testStreamAroundUnloadsFarChunks", fn = testStreamAroundUnloadsFarChunks },
	{ name = "testStreamAroundEmitsChunksStreamed", fn = testStreamAroundEmitsChunksStreamed },
	{ name = "testStreamAroundReturnsNewlyLoadedAndUnloaded", fn = testStreamAroundReturnsNewlyLoadedAndUnloaded },
	{ name = "testMemoryBounded", fn = testMemoryBounded },
	{ name = "testMultipleChunksIndependent", fn = testMultipleChunksIndependent },
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
