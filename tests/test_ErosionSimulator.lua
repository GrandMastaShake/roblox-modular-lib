--!strict
-- tests/test_ErosionSimulator.lua
-- Tests for ErosionSimulator: hydraulic erosion, thermal erosion, config.

local ErosionSimulator = require(script.Parent.Parent.src.ErosionSimulator)

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

-- Create a synthetic heightmap with a prominent peak for testing erosion
local function createPeakedHeightmap(size: number): { { number } }
	local hm: { { number } } = {}
	local center = size / 2
	for x = 1, size do
		hm[x] = {}
		for z = 1, size do
			-- Cone shape: highest at center
			local dx = x - center
			local dz = z - center
			local dist = math.sqrt(dx * dx + dz * dz)
			local height = math.max(10, 100 - dist * 3)
			hm[x][z] = height
		end
	end
	return hm
end

-- Create a heightmap with steep slopes
local function createSteepHeightmap(size: number): { { number } }
	local hm: { { number } } = {}
	for x = 1, size do
		hm[x] = {}
		for z = 1, size do
			-- Steep ridge in the middle
			local h = if x < size / 2 then 80 else 10
			-- Add some noise-like variation
			h += math.sin(x * 0.5) * 5 + math.cos(z * 0.5) * 5
			hm[x][z] = math.max(0, h)
		end
	end
	return hm
end

-- Find max height in a heightmap
local function getMaxHeight(hm: { { number } }): number
	local maxH = -math.huge
	for x = 1, #hm do
		for z = 1, #hm[x] do
			maxH = math.max(maxH, hm[x][z])
		end
	end
	return maxH
end

-- Calculate maximum slope in a heightmap
local function getMaxSlope(hm: { { number } }): number
	local maxSlope = 0
	local size = #hm
	for x = 2, size - 1 do
		for z = 2, size - 1 do
			for _, n in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
				local nx = x + n[1]
				local nz = z + n[2]
				local slope = math.abs(hm[x][z] - hm[nx][nz])
				maxSlope = math.max(maxSlope, slope)
			end
		end
	end
	return maxSlope
end

local TESTS = {}

-- Test 1: Erode reduces max peak heights
function TESTS.testHydraulicErosionReducesPeaks()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 2000,
		erosionRate = 0.1,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	local hm = createPeakedHeightmap(32)
	local maxBefore = getMaxHeight(hm)

	local eroded = eroder:Erode(hm)
	local maxAfter = getMaxHeight(eroded)

	assertTrue(maxAfter < maxBefore, "Hydraulic erosion should reduce max peak: " .. tostring(maxBefore) .. " -> " .. tostring(maxAfter))
	-- Verify heightmap dimensions unchanged
	assertEq(#eroded, 32, "Eroded heightmap width")
	assertEq(#eroded[1], 32, "Eroded heightmap depth")
end

-- Test 2: Erode emits ErosionCompleted event
function TESTS.testErosionEvent()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 500,
		erosionRate = 0.05,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	bus:Clear()
	local hm = createPeakedHeightmap(16)
	eroder:Erode(hm)
	local events = bus:GetEvents("ErosionCompleted")
	assertTrue(#events >= 1, "Should emit ErosionCompleted event")
end

-- Test 3: Thermal erosion reduces max slopes
function TESTS.testThermalErosionReducesSlopes()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 500,
		erosionRate = 0.05,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	local hm = createSteepHeightmap(32)
	local slopeBefore = getMaxSlope(hm)

	local eroded = eroder:ThermalErosion(hm, 5.0)
	local slopeAfter = getMaxSlope(eroded)

	assertTrue(
		slopeAfter < slopeBefore,
		"Thermal erosion should reduce max slope: " .. tostring(slopeBefore) .. " -> " .. tostring(slopeAfter)
	)
end

-- Test 4: Thermal erosion emits ThermalErosionCompleted event
function TESTS.testThermalErosionEvent()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 500,
		erosionRate = 0.05,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	bus:Clear()
	local hm = createSteepHeightmap(16)
	eroder:ThermalErosion(hm, 3.0)
	local events = bus:GetEvents("ThermalErosionCompleted")
	assertTrue(#events >= 1, "Should emit ThermalErosionCompleted event")
end

-- Test 5: SetConfig updates erosion parameters
function TESTS.testSetConfig()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 500,
		erosionRate = 0.5,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	-- Apply with aggressive erosion
	local hm1 = createPeakedHeightmap(20)
	local maxBefore1 = getMaxHeight(hm1)
	local eroded1 = eroder:Erode(hm1)
	local maxAfter1 = getMaxHeight(eroded1)

	-- Reduce erosion rate
	eroder:SetConfig({
		droplets = 500,
		erosionRate = 0.001,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	local hm2 = createPeakedHeightmap(20)
	local maxBefore2 = getMaxHeight(hm2)
	local eroded2 = eroder:Erode(hm2)
	local maxAfter2 = getMaxHeight(eroded2)

	-- Low erosion rate should remove less material
	local reduction1 = maxBefore1 - maxAfter1
	local reduction2 = maxBefore2 - maxAfter2
	assertTrue(
		reduction2 < reduction1,
		"Lower erosion rate should reduce less: high=" .. tostring(reduction1) .. " vs low=" .. tostring(reduction2)
	)
end

-- Test 6: Erosion preserves heightmap dimensions
function TESTS.testErosionPreservesDimensions()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 1000,
		erosionRate = 0.1,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	local sizes = { 8, 16, 32 }
	for _, size in ipairs(sizes) do
		local hm = createPeakedHeightmap(size)
		local eroded = eroder:Erode(hm)
		assertEq(#eroded, size, "Hydraulic erosion should preserve width for size " .. tostring(size))
		assertEq(#eroded[1], size, "Hydraulic erosion should preserve depth for size " .. tostring(size))

		local thermal = eroder:ThermalErosion(hm, 5.0)
		assertEq(#thermal, size, "Thermal erosion should preserve width for size " .. tostring(size))
		assertEq(#thermal[1], size, "Thermal erosion should preserve depth for size " .. tostring(size))
	end
end

-- Test 7: All heights remain non-negative after erosion
function TESTS.testErosionNonNegative()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 5000,
		erosionRate = 0.2,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	local hm = createPeakedHeightmap(32)
	local eroded = eroder:Erode(hm)

	for x = 1, #eroded do
		for z = 1, #eroded[x] do
			assertTrue(eroded[x][z] >= 0, "Eroded height should be non-negative at (" .. tostring(x) .. ", " .. tostring(z) .. ")")
		end
	end
end

-- Test 8: Thermal erosion with talusAngle = 0 still runs
function TESTS.testThermalErosionZeroTalus()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus)

	local hm = createSteepHeightmap(16)
	local eroded = eroder:ThermalErosion(hm, 0)
	assertTrue(#eroded == 16, "Zero talus thermal erosion should still work")
end

-- Test 9: Empty heightmap returns safely
function TESTS.testEmptyHeightmap()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus)

	local empty: { { number } } = {}
	local result = eroder:Erode(empty)
	assertEq(#result, 0, "Empty heightmap should return empty")

	local result2 = eroder:ThermalErosion(empty, 5.0)
	assertEq(#result2, 0, "Empty heightmap thermal erosion should return empty")
end

-- Test 10: Both erosion types work on same heightmap sequentially
function TESTS.testCombinedErosion()
	local bus = createMockEventBus()
	local eroder = ErosionSimulator.new(bus, {
		droplets = 2000,
		erosionRate = 0.1,
		depositionRate = 0.01,
		evaporationRate = 0.05,
		gravity = 4.0,
	})

	local hm = createPeakedHeightmap(32)
	local maxBefore = getMaxHeight(hm)
	local slopeBefore = getMaxSlope(hm)

	-- First hydraulic, then thermal
	local eroded = eroder:Erode(hm)
	eroded = eroder:ThermalErosion(eroded, 5.0)

	local maxAfter = getMaxHeight(eroded)
	local slopeAfter = getMaxSlope(eroded)

	assertTrue(maxAfter <= maxBefore, "Combined erosion should not increase max height")
	assertTrue(slopeAfter <= slopeBefore, "Combined erosion should not increase max slope")
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
print("ErosionSimulator Test Results: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed")
if failed > 0 then
	error("ErosionSimulator tests failed")
end
