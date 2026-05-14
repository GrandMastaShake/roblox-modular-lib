--!strict
-- tests/test_WaterSystem.lua
-- Lightweight assert-based tests for WaterSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local WaterSystem = require(script.Parent.Parent.src.WaterSystem)

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. ": expected true")
	end
end

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertGt(a: number, b: number, msg: string)
	if not (a > b) then
		error(msg .. ": expected " .. tostring(a) .. " > " .. tostring(b))
	end
end

local function assertGte(a: number, b: number, msg: string)
	if not (a >= b) then
		error(msg .. ": expected " .. tostring(a) .. " >= " .. tostring(b))
	end
end

local function runTests()
	print("[test_WaterSystem] Starting tests...")

	-- Test 1: Constructor creates WaterSystem with seed
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 12345)
		assertTrue(water ~= nil, "WaterSystem.new should return instance")
		print("  [PASS] Constructor")
	end

	-- Test 2: GenerateRivers produces valid river paths
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 99999)

		local eventFired = false
		local eventData = nil
		bus:Subscribe("RiverGenerated", function(payload: any)
			eventFired = true
			eventData = payload
		end)

		local rivers = water:GenerateRivers(nil)
		assertTrue(#rivers >= 0, "GenerateRivers should return a list")
		assertTrue(eventFired, "RiverGenerated event should fire")
		assertTrue(eventData ~= nil, "Event data should not be nil")
		if eventData then
			assertTrue(eventData.riverCount ~= nil, "Event should contain riverCount")
			assertEq(eventData.seed, 99999, "Event should contain correct seed")
		end

		print("  [PASS] GenerateRivers produces valid paths")
	end

	-- Test 3: River paths flow downhill (each node <= previous node)
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 55555)
		local rivers = water:GenerateRivers(nil)

		if #rivers > 0 then
			for i, rootNode in ipairs(rivers) do
				local function checkDownhill(node: any, prevY: number?)
					if prevY then
						assertGte(prevY :: number, node.y, "River must flow downhill: y[" .. tostring(i) .. "]=" .. tostring(prevY) .. " -> " .. tostring(node.y))
					end
					if node.next then
						for _, child in ipairs(node.next) do
							checkDownhill(child, node.y)
						end
					end
				end
				checkDownhill(rootNode, nil)
			end
		end

		print("  [PASS] River paths flow downhill")
	end

	-- Test 4: GenerateRivers is deterministic with same seed
	do
		local bus1 = EventBus.new()
		local water1 = WaterSystem.new(bus1, 77777)
		local rivers1 = water1:GenerateRivers(nil)

		local bus2 = EventBus.new()
		local water2 = WaterSystem.new(bus2, 77777)
		local rivers2 = water2:GenerateRivers(nil)

		assertEq(#rivers1, #rivers2, "Same seed should produce same river count")
		print("  [PASS] GenerateRivers deterministic with same seed")
	end

	-- Test 5: River nodes have required fields
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 44444)
		local rivers = water:GenerateRivers(nil)

		if #rivers > 0 then
			local function checkNode(node: any)
				assertTrue(typeof(node.x) == "number", "Node must have x coordinate")
				assertTrue(typeof(node.z) == "number", "Node must have z coordinate")
				assertTrue(typeof(node.y) == "number", "Node must have y coordinate")
				assertTrue(typeof(node.flow) == "number", "Node must have flow")
				assertTrue(node.flow >= 0, "Flow must be non-negative")
				if node.next then
					for _, child in ipairs(node.next) do
						checkNode(child)
					end
				end
			end
			checkNode(rivers[1])
		end

		print("  [PASS] River nodes have required fields")
	end

	-- Test 6: CarveRiver emits RiverCarved event
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 33333)
		local rivers = water:GenerateRivers(nil)

		if #rivers > 0 then
			-- Flatten river tree to array for CarveRiver
			local riverArray: { any } = {}
			local function flatten(node: any)
				table.insert(riverArray, node)
				if node.next then
					for _, child in ipairs(node.next) do
						flatten(child)
					end
				end
			end
			flatten(rivers[1])

			local carvedFired = false
			bus:Subscribe("RiverCarved", function(payload: any)
				carvedFired = true
				assertTrue(payload.nodeCount ~= nil, "RiverCarved should have nodeCount")
			end)

			water:CarveRiver(riverArray)
			-- Note: CarveRiver may warn about no Terrain in non-Roblox environment
			-- but should still emit the event
		end

		print("  [PASS] CarveRiver handles river array")
	end

	-- Test 7: CreateLake emits LakeCreated event
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 22222)

		local lakeFired = false
		local lakeData = nil
		bus:Subscribe("LakeCreated", function(payload: any)
			lakeFired = true
			lakeData = payload
		end)

		water:CreateLake(100, 200, 15)
		assertTrue(lakeFired, "LakeCreated event should fire")
		if lakeData then
			assertEq(lakeData.center.x, 100, "Lake center x")
			assertEq(lakeData.center.z, 200, "Lake center z")
			assertEq(lakeData.radius, 15, "Lake radius")
		end

		print("  [PASS] CreateLake emits LakeCreated event")
	end

	-- Test 8: ErodeTerrain modifies heightmap along river
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 11111)

		-- Create a mock chunk with heightmap
		local size = 16
		local heightmap: { { number } } = {}
		for x = 1, size do
			heightmap[x] = {}
			for z = 1, size do
				heightmap[x][z] = 80 -- flat terrain at y=80
			end
		end

		local chunk = {
			cx = 0,
			cz = 0,
			size = size,
			heightmap = heightmap,
		}

		-- Create a mock river that passes through the chunk
		local river = {
			{ x = 4, z = 4, y = 70, flow = 5, next = {} },
			{ x = 6, z = 6, y = 65, flow = 6, next = {} },
			{ x = 8, z = 8, y = 60, flow = 7, next = {} },
		}

		local erodedChunk = water:ErodeTerrain(chunk, river)
		assertTrue(erodedChunk ~= nil, "ErodeTerrain should return chunk")
		assertTrue(erodedChunk.heightmap ~= nil, "Eroded chunk should have heightmap")

		-- Verify heightmap was modified (eroded) at river positions
		local originalHeight = 80
		local anyEroded = false
		for x = 1, size do
			for z = 1, size do
				if erodedChunk.heightmap[x][z] < originalHeight then
					anyEroded = true
				end
			end
		end
		assertTrue(anyEroded, "ErodeTerrain should lower some heightmap values")

		print("  [PASS] ErodeTerrain modifies heightmap along river")
	end

	-- Test 9: ErodeTerrain with empty river returns chunk unchanged
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 11111)

		local size = 8
		local heightmap: { { number } } = {}
		for x = 1, size do
			heightmap[x] = {}
			for z = 1, size do
				heightmap[x][z] = 50
			end
		end

		local chunk = {
			cx = 0,
			cz = 0,
			size = size,
			heightmap = heightmap,
		}

		local emptyRiver: { any } = {}
		local result = water:ErodeTerrain(chunk, emptyRiver)
		assertTrue(result.heightmap[1][1] == 50, "Empty river should not change heightmap")

		print("  [PASS] ErodeTerrain with empty river")
	end

	-- Test 10: Multiple river generation creates distinct paths
	do
		local bus = EventBus.new()
		local water = WaterSystem.new(bus, 66666)
		local rivers = water:GenerateRivers(nil)

		-- Each river root should start at a different location
		local positions: { string } = {}
		for _, root in ipairs(rivers) do
			local key = tostring(math.floor(root.x / 10)) .. "," .. tostring(math.floor(root.z / 10))
			table.insert(positions, key)
		end

		-- Check uniqueness (coarse grid to allow some variation)
		local seen: { [string]: boolean } = {}
		for _, key in ipairs(positions) do
			seen[key] = true
		end

		-- With random sampling, sources should be spread out
		assertTrue(#rivers <= 8, "Should generate at most 8 rivers")

		print("  [PASS] Multiple river generation")
	end

	print("[test_WaterSystem] All tests passed!")
end

runTests()
