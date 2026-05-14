--!strict
-- tests/test_SaveSystem.lua
-- Tests for SaveSystem: serialization roundtrip, queue/flush, autosave, metadata.
--
-- Standalone-compatible: loads modules via loadfile for non-Roblox environments.

-- =============================================================================
-- MODULE LOADER SETUP (non-Roblox compatible)
-- =============================================================================

local TESTS_DIR = debug.info(1, "s"):match("^(.*)/") or "."
local SRC_DIR = TESTS_DIR .. "/../src"
local CORE_DIR = SRC_DIR .. "/Core"

-- Minimal mock of Roblox globals for standalone execution
if not game then
	-- luau-lint: ignore global game
	game = {
		GetService = function(_self: any, name: string): any
			if name == "HttpService" then
				return {
					JSONEncode = function(_self: any, data: any): string
						return "__JSON_PLACEHOLDER__"
					end,
					JSONDecode = function(_self: any, str: string): any
						return {}
					end,
				}
			end
			return {}
		end,
	} :: any
end

if not script then
	-- luau-lint: ignore global script
	script = {
		Parent = {
			Core = {},
		},
	} :: any
end

if not task then
	-- luau-lint: ignore global task
	task = {
		wait = function(seconds: number?)
			-- No-op in test environment
		end,
		spawn = function(fn: () -> ())
			-- Run synchronously in test environment
			local ok, err = pcall(fn)
			if not ok then
				print("[task.spawn error] " .. tostring(err))
			end
			return nil
		end,
		delay = function(seconds: number, fn: () -> ())
			return task.spawn(fn)
		end,
	} :: any
end

if not CFrame then
	-- luau-lint: ignore global CFrame
	CFrame = {
		new = function(x: number, y: number, z: number): any
			return {
				X = x, Y = y, Z = z,
				GetComponents = function(self: any): ...number
					return self.X, self.Y, self.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1
				end,
			}
		end,
	} :: any
end

if not typeof then
	-- luau-lint: ignore global typeof
	typeof = function(v: any): string
		return type(v)
	end
end

if not warn then
	-- luau-lint: ignore global warn
	warn = function(...)
		print("[WARN]", ...)
	end
end

-- Module cache
local _moduleCache: { [string]: any } = {}

-- Custom require that loads from filesystem
local function requireModule(modulePath: string): any
	if _moduleCache[modulePath] then
		return _moduleCache[modulePath]
	end

	local filePath = ""
	if modulePath == "script.Parent.Core.Types" or modulePath:match("^Core%.Types$") then
		filePath = CORE_DIR .. "/Types.lua"
	elseif modulePath == "script.Parent.Core.EventBus" or modulePath:match("^Core%.EventBus$") then
		filePath = CORE_DIR .. "/EventBus.lua"
	elseif modulePath == "script.Parent.Core.Config" or modulePath:match("^Core%.Config$") then
		filePath = CORE_DIR .. "/Config.lua"
	elseif modulePath == "script.Parent.SaveSystem" or modulePath == script.Parent.Name .. ".SaveSystem" then
		filePath = SRC_DIR .. "/SaveSystem.lua"
	elseif modulePath == "script.Parent.Parent.src.SaveSystem" then
		filePath = SRC_DIR .. "/SaveSystem.lua"
	elseif modulePath == "script.Parent.Parent.src.Core.EventBus" then
		filePath = CORE_DIR .. "/EventBus.lua"
	elseif modulePath == "script.Parent.Parent.src.Core.Config" then
		filePath = CORE_DIR .. "/Config.lua"
	elseif modulePath == "script.Parent.Parent.src.DataStoreSafe" then
		filePath = SRC_DIR .. "/DataStoreSafe.lua"
	else
		-- Try direct path
		filePath = SRC_DIR .. "/" .. modulePath:gsub("%.", "/") .. ".lua"
		local f = io.open(filePath, "r")
		if not f then
			filePath = CORE_DIR .. "/" .. modulePath:gsub("%.", "/") .. ".lua"
			f = io.open(filePath, "r")
		end
		if f then f:close() end
	end

	local chunk, err = loadfile(filePath)
	if not chunk then
		error("Failed to load module '" .. modulePath .. "' from '" .. filePath .. "': " .. tostring(err))
	end

	-- Set up script global for the loaded module
	local oldScript = script
	script = {
		Name = filePath:match("([^/]+)%.lua$") or "module",
		Parent = {
			Name = "src",
			Core = {},
			Parent = {
				Name = "roblox-modular-lib",
				src = {
					Core = {},
				},
			},
		},
	} :: any

	local result = chunk()
	script = oldScript

	_moduleCache[modulePath] = result
	return result
end

-- Replace global require for this test
local _origRequire = require
local function patchedRequire(moduleRef: any): any
	if typeof(moduleRef) == "string" then
		return requireModule(moduleRef)
	end
	return _origRequire(moduleRef)
end

-- luau-lint: ignore global require
require = patchedRequire :: any

-- =============================================================================
-- TEST HELPERS
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

local function assertNotNil(a: any, msg: string)
	if a == nil then
		error(msg .. " | expected non-nil")
	end
end

local function assertNil(a: any, msg: string)
	if a ~= nil then
		error(msg .. " | expected nil, got " .. tostring(a))
	end
end

-- =============================================================================
-- MOCK EventBus
-- =============================================================================

local function createMockEventBus()
	local bus = {
		_events = {} :: { [string]: { any } },
		_listeners = {} :: { [string]: { (any) -> () } },

		Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			if not self._listeners[eventName] then
				self._listeners[eventName] = {}
			end
			table.insert(self._listeners[eventName], callback)
			return function() end
		end,

		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
			local list = self._listeners[eventName]
			if list then
				for _, cb in ipairs(list) do
					cb(payload)
				end
			end
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

-- =============================================================================
-- MOCK DataStoreSafe
-- =============================================================================

local function createMockDataStoreSafe(name: string?)
	local store = {
		_name = name or "MockDataStore",
		_data = {} :: { [string]: any },
		_cache = {} :: { [string]: any },
		_saveCount = 0,
		_loadCount = 0,

		Save = function(self: any, key: string, data: any): boolean
			self._data[key] = data
			self._cache[key] = data
			self._saveCount += 1
			return true
		end,

		Load = function(self: any, key: string): any
			self._loadCount += 1
			if self._cache[key] ~= nil then
				return self._cache[key]
			end
			return self._data[key]
		end,

		GetCache = function(self: any, key: string): any
			return self._cache[key]
		end,

		ClearCache = function(self: any, key: string)
			self._cache[key] = nil
		end,

		GetSaveCount = function(self: any): number
			return self._saveCount
		end,

		GetLoadCount = function(self: any): number
			return self._loadCount
		end,

		GetStoredKeys = function(self: any): { string }
			local keys = {}
			for k, _ in pairs(self._data) do
				table.insert(keys, k)
			end
			return keys
		end,

		GetData = function(self: any, key: string): any
			return self._data[key]
		end,

		Reset = function(self: any)
			self._data = {}
			self._cache = {}
			self._saveCount = 0
			self._loadCount = 0
		end,
	}
	return store
end

-- =============================================================================
-- TEST DATA FACTORIES
-- =============================================================================

local function createSampleHeightmap(size: number): { { number } }
	local hm: { { number } } = {}
	for x = 1, size do
		hm[x] = {}
		for z = 1, size do
			hm[x][z] = 50 + math.sin(x * 0.3) * 20 + math.cos(z * 0.3) * 15
		end
	end
	return hm
end

local function createSampleBiomeMap(size: number): { { string } }
	local bm: { { string } } = {}
	for x = 1, size do
		bm[x] = {}
		for z = 1, size do
			if (x + z) % 3 == 0 then
				bm[x][z] = "forest"
			elseif (x + z) % 3 == 1 then
				bm[x][z] = "grassland"
			else
				bm[x][z] = "desert"
			end
		end
	end
	return bm
end

local function createSamplePlacements(count: number): { any }
	local placements = {}
	for i = 1, count do
		table.insert(placements, {
			objectId = "tree_" .. tostring(i),
			cframe = CFrame.new(i * 10, 50, i * 10),
			scale = 1.0 + (i % 3) * 0.5,
		})
	end
	return placements
end

local function createWorldData(seed: number, size: number): any
	local chunks: { [string]: any } = {}
	for cx = 0, size - 1 do
		for cz = 0, size - 1 do
			local key = cx .. "," .. cz
			chunks[key] = {
				cx = cx,
				cz = cz,
				heightmap = createSampleHeightmap(16),
				biomeMap = createSampleBiomeMap(16),
				objectPlacements = createSamplePlacements(3),
				isModified = true,
			}
		end
	end
	return {
		seed = seed,
		size = size,
		chunks = chunks,
		placements = createSamplePlacements(2),
	}
end

-- =============================================================================
-- LOAD MODULES
-- =============================================================================

local EventBus = requireModule("Core.EventBus")
local Config = requireModule("Core.Config")
local SaveSystem = requireModule("SaveSystem")

-- =============================================================================
-- TEST 1: Serialization roundtrip (SaveWorld + LoadWorld)
-- =============================================================================

local function testSaveWorldLoadWorldRoundtrip()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 12345 })

	local ss = SaveSystem.new(bus, ds, config)

	local worldData = createWorldData(12345, 2)

	-- Save the world
	local saveOk = ss:SaveWorld(worldData)
	assertTrue(saveOk, "SaveWorld should return true")

	-- Check that events were emitted
	local savedEvents = bus.GetEvents(bus, "WorldSaved")
	assertTrue(#savedEvents >= 1, "Should emit WorldSaved event")
	assertEq(savedEvents[1].seed, 12345, "WorldSaved event should contain seed")

	-- Load the world back
	local loaded = ss:LoadWorld()
	assertNotNil(loaded, "LoadWorld should return WorldSaveData")
	assertEq(loaded.seed, 12345, "Loaded seed should match")
	assertEq(loaded.size, 2, "Loaded size should match")

	-- Check that modified chunks were saved
	local chunkCount = 0
	for _ in pairs(loaded.modifiedChunks) do
		chunkCount += 1
	end
	assertEq(chunkCount, 4, "Should have 4 modified chunks (2x2)")

	-- Verify a specific chunk's data integrity
	local chunk = loaded.modifiedChunks["0,0"]
	assertNotNil(chunk, "Chunk 0,0 should exist")
	assertEq(chunk.cx, 0, "Chunk cx")
	assertEq(chunk.cz, 0, "Chunk cz")
	assertTrue(#chunk.heightmap > 0, "Chunk should have heightmap")
	assertTrue(#chunk.biomeMap > 0, "Chunk should have biomeMap")

	-- Check events
	local loadedEvents = bus.GetEvents(bus, "WorldLoaded")
	assertTrue(#loadedEvents >= 1, "Should emit WorldLoaded event")
end

-- =============================================================================
-- TEST 2: Chunk save/load roundtrip
-- =============================================================================

local function testChunkSaveLoadRoundtrip()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 99999 })

	local ss = SaveSystem.new(bus, ds, config)

	local chunkData = {
		cx = 5,
		cz = -3,
		heightmap = createSampleHeightmap(8),
		biomeMap = createSampleBiomeMap(8),
		objectPlacements = createSamplePlacements(2),
		isModified = true,
	}

	-- Save chunk
	local saveOk = ss:SaveChunk(chunkData)
	assertTrue(saveOk, "SaveChunk should return true")

	-- Check event
	local savedEvents = bus.GetEvents(bus, "ChunkSaved")
	assertEq(#savedEvents, 1, "Should emit ChunkSaved event")
	assertEq(savedEvents[1].cx, 5, "ChunkSaved cx")
	assertEq(savedEvents[1].cz, -3, "ChunkSaved cz")

	-- Load chunk back
	local loaded = ss:LoadChunk(5, -3)
	assertNotNil(loaded, "LoadChunk should return ChunkSaveData")
	assertEq(loaded.cx, 5, "Loaded chunk cx")
	assertEq(loaded.cz, -3, "Loaded chunk cz")
	assertTrue(#loaded.heightmap == 8, "Loaded heightmap size")
	assertTrue(#loaded.biomeMap == 8, "Loaded biomeMap size")
	assertTrue(#loaded.objectPlacements == 2, "Loaded placements count")

	-- Check ChunkLoaded event
	local loadedEvents = bus.GetEvents(bus, "ChunkLoaded")
	assertEq(#loadedEvents, 1, "Should emit ChunkLoaded event")

	-- Load non-existent chunk
	local notFound = ss:LoadChunk(100, 100)
	assertNil(notFound, "LoadChunk for non-existent chunk should return nil")
end

-- =============================================================================
-- TEST 3: Queue and Flush
-- =============================================================================

local function testQueueAndFlush()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 77777 })

	local ss = SaveSystem.new(bus, ds, config)

	-- Pre-save some chunks so FlushQueue can find them
	for cx = 0, 2 do
		for cz = 0, 2 do
			local chunkData = {
				cx = cx,
				cz = cz,
				heightmap = createSampleHeightmap(4),
				biomeMap = createSampleBiomeMap(4),
				objectPlacements = {},
				isModified = true,
			}
			ss:SaveChunk(chunkData)
		end
	end

	-- Clear events from pre-save
	bus.Clear(bus)
	ds.Reset(ds)

	-- Queue several chunks
	ss:QueueChunkSave(0, 0)
	ss:QueueChunkSave(1, 1)
	ss:QueueChunkSave(2, 2)

	-- Flush the queue
	local flushOk = ss:FlushQueue()
	assertTrue(flushOk, "FlushQueue should return true")

	-- All three chunks should have been saved
	assertTrue(ds.GetSaveCount(ds) >= 3, "FlushQueue should save queued chunks")

	-- Verify chunk keys exist
	local keys = ds.GetStoredKeys(ds)
	local foundChunks = 0
	for _, key in ipairs(keys) do
		if string.match(key, "_Chunk_") then
			foundChunks += 1
		end
	end
	assertTrue(foundChunks >= 3, "Should have chunk keys after flush")
end

-- =============================================================================
-- TEST 4: Empty queue flush
-- =============================================================================

local function testFlushEmptyQueue()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 55555 })

	local ss = SaveSystem.new(bus, ds, config)

	-- Flush with nothing queued
	local flushOk = ss:FlushQueue()
	assertTrue(flushOk, "FlushQueue with empty queue should return true")
	assertEq(ds.GetSaveCount(ds), 0, "No saves should occur on empty queue flush")
end

-- =============================================================================
-- TEST 5: Auto-save scheduling
-- =============================================================================

local function testAutoSaveScheduling()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 44444 })

	local ss = SaveSystem.new(bus, ds, config)

	-- Pre-save a chunk so FlushQueue has something to do
	local chunkData = {
		cx = 0,
		cz = 0,
		heightmap = createSampleHeightmap(4),
		biomeMap = createSampleBiomeMap(4),
		objectPlacements = {},
		isModified = true,
	}
	ss:SaveChunk(chunkData)

	-- Queue a chunk
	ss:QueueChunkSave(0, 0)

	-- Start auto-save with a short interval for testing
	ss:AutoSave(0.05) -- 50ms for fast test

	-- Wait for at least one auto-save cycle
	task.wait(0.15)

	-- Check that AutoSaveTriggered event was emitted
	local autoSaveEvents = bus.GetEvents(bus, "AutoSaveTriggered")
	assertTrue(#autoSaveEvents >= 1, "AutoSave should trigger at least once")

	-- Stop auto-save
	ss:StopAutoSave()

	-- Wait to ensure no more events fire
	task.wait(0.15)

	-- Count events -- should not have increased significantly
	local eventCountAfterStop = #bus.GetEvents(bus, "AutoSaveTriggered")

	-- Wait again
	task.wait(0.15)
	local eventCountAfterWait = #bus.GetEvents(bus, "AutoSaveTriggered")

	-- After stopping, event count should not grow
	assertTrue(
		eventCountAfterWait <= eventCountAfterStop + 1,
		"AutoSave should stop emitting after StopAutoSave"
	)
end

-- =============================================================================
-- TEST 6: Save and retrieve metadata
-- =============================================================================

local function testGetSaveMetadata()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 33333 })

	local ss = SaveSystem.new(bus, ds, config)

	-- Before save, metadata should show defaults
	local metaBefore = ss:GetSaveMetadata()
	assertEq(metaBefore.created, 0, "Default created should be 0")
	assertEq(metaBefore.lastSaved, 0, "Default lastSaved should be 0")
	assertEq(metaBefore.version, "none", "Default version should be 'none'")

	-- Save a world
	local worldData = createWorldData(33333, 1)
	ss:SaveWorld(worldData)

	-- After save, metadata should have real values
	local metaAfter = ss:GetSaveMetadata()
	assertTrue(metaAfter.created > 0, "created should be > 0 after save")
	assertTrue(metaAfter.lastSaved > 0, "lastSaved should be > 0 after save")
	assertEq(metaAfter.version, "1.0.0", "version should be '1.0.0'")
end

-- =============================================================================
-- TEST 7: Heightmap serialization accuracy
-- =============================================================================

local function testHeightmapSerializationAccuracy()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 22222 })

	local ss = SaveSystem.new(bus, ds, config)

	-- Create a specific heightmap with known values
	local heightmap: { { number } } = {}
	for x = 1, 4 do
		heightmap[x] = {}
		for z = 1, 4 do
			heightmap[x][z] = x * 10.0 + z * 1.5
		end
	end

	local chunkData = {
		cx = 7,
		cz = 8,
		heightmap = heightmap,
		biomeMap = { { "grassland", "forest" }, { "desert", "ocean" } },
		objectPlacements = {},
		isModified = true,
	}

	ss:SaveChunk(chunkData)
	local loaded = ss:LoadChunk(7, 8)

	assertNotNil(loaded, "Should load chunk")
	-- Values are serialized with 3 decimal places, allow small epsilon
	for x = 1, 4 do
		for z = 1, 4 do
			local expected = x * 10.0 + z * 1.5
			local actual = loaded.heightmap[x][z]
			local diff = math.abs(actual - expected)
			assertTrue(diff < 0.001, string.format(
				"Heightmap[%d][%d] expected %.3f, got %.3f (diff=%.6f)",
				x, z, expected, actual, diff
			))
		end
	end
end

-- =============================================================================
-- TEST 8: BiomeMap serialization accuracy
-- =============================================================================

local function testBiomeMapSerializationAccuracy()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 11111 })

	local ss = SaveSystem.new(bus, ds, config)

	local biomeMap: { { string } } = {
		{ "grassland", "forest", "desert" },
		{ "ocean", "mountains", "tundra" },
		{ "swamp", "rainforest", "savanna" },
	}

	local chunkData = {
		cx = 3,
		cz = 4,
		heightmap = { { 10, 20 }, { 30, 40 } },
		biomeMap = biomeMap,
		objectPlacements = {},
		isModified = true,
	}

	ss:SaveChunk(chunkData)
	local loaded = ss:LoadChunk(3, 4)

	assertNotNil(loaded, "Should load chunk")
	assertEq(loaded.biomeMap[1][1], "grassland", "biomeMap[1][1]")
	assertEq(loaded.biomeMap[1][2], "forest", "biomeMap[1][2]")
	assertEq(loaded.biomeMap[1][3], "desert", "biomeMap[1][3]")
	assertEq(loaded.biomeMap[2][1], "ocean", "biomeMap[2][1]")
	assertEq(loaded.biomeMap[2][2], "mountains", "biomeMap[2][2]")
	assertEq(loaded.biomeMap[2][3], "tundra", "biomeMap[2][3]")
	assertEq(loaded.biomeMap[3][1], "swamp", "biomeMap[3][1]")
	assertEq(loaded.biomeMap[3][2], "rainforest", "biomeMap[3][2]")
	assertEq(loaded.biomeMap[3][3], "savanna", "biomeMap[3][3]")
end

-- =============================================================================
-- TEST 9: LoadWorld with no save returns nil
-- =============================================================================

local function testLoadWorldNoSave()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 88888 })

	local ss = SaveSystem.new(bus, ds, config)

	-- No save exists yet
	local loaded = ss:LoadWorld()
	assertNil(loaded, "LoadWorld with no save should return nil")
end

-- =============================================================================
-- TEST 10: Chunk placement serialization
-- =============================================================================

local function testPlacementSerialization()
	local bus = createMockEventBus()
	local ds = createMockDataStoreSafe()
	local config = Config.new({ seed = 66666 })

	local ss = SaveSystem.new(bus, ds, config)

	local placements = {
		{
			objectId = "oak_tree",
			cframe = CFrame.new(100, 50, 200),
			scale = 1.5,
		},
		{
			objectId = "boulder",
			cframe = CFrame.new(150, 45, 250),
			scale = 2.0,
		},
	}

	local chunkData = {
		cx = 1,
		cz = 2,
		heightmap = { { 50, 60 }, { 70, 80 } },
		biomeMap = { { "grassland", "grassland" }, { "forest", "forest" } },
		objectPlacements = placements,
		isModified = true,
	}

	ss:SaveChunk(chunkData)
	local loaded = ss:LoadChunk(1, 2)

	assertNotNil(loaded, "Should load chunk with placements")
	assertEq(#loaded.objectPlacements, 2, "Should have 2 placements")
	assertEq(loaded.objectPlacements[1].objectId, "oak_tree", "Placement 1 objectId")
	assertEq(loaded.objectPlacements[2].objectId, "boulder", "Placement 2 objectId")
end

-- =============================================================================
-- TEST RUNNER
-- =============================================================================

local tests = {
	{ name = "testSaveWorldLoadWorldRoundtrip", fn = testSaveWorldLoadWorldRoundtrip },
	{ name = "testChunkSaveLoadRoundtrip", fn = testChunkSaveLoadRoundtrip },
	{ name = "testQueueAndFlush", fn = testQueueAndFlush },
	{ name = "testFlushEmptyQueue", fn = testFlushEmptyQueue },
	{ name = "testAutoSaveScheduling", fn = testAutoSaveScheduling },
	{ name = "testGetSaveMetadata", fn = testGetSaveMetadata },
	{ name = "testHeightmapSerializationAccuracy", fn = testHeightmapSerializationAccuracy },
	{ name = "testBiomeMapSerializationAccuracy", fn = testBiomeMapSerializationAccuracy },
	{ name = "testLoadWorldNoSave", fn = testLoadWorldNoSave },
	{ name = "testPlacementSerialization", fn = testPlacementSerialization },
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

print("")
print("========================================")
print(string.format("  SaveSystem: %d passed, %d failed out of %d", passed, failed, #tests))
print("========================================")
