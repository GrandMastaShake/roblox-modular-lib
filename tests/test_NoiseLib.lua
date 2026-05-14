--!strict
-- tests/test_NoiseLib.lua
-- Tests for NoiseLib: determinism, range checks, seed behavior, octave effects.

local NoiseLib = require(script.Parent.Parent.src.NoiseLib)

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
	}
end

local TESTS = {}

-- Test 1: Determinism - same seed + coordinates = same output
function TESTS.testDeterminism()
	local noise1 = NoiseLib.new({ seed = 42, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 })
	local noise2 = NoiseLib.new({ seed = 42, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 })

	for i = 1, 100 do
		local x = i * 3.7
		local z = i * 7.3
		local v1 = noise1:Get2D(x, z)
		local v2 = noise2:Get2D(x, z)
		assertEq(v1, v2, "Determinism failed at sample " .. tostring(i) .. ": " .. tostring(v1) .. " ~= " .. tostring(v2))
	end
end

-- Test 2: Range - Get2D returns values in [-1, 1]
function TESTS.testRange()
	local noise = NoiseLib.new({ seed = 1337, octaves = 6, persistence = 0.5, lacunarity = 2.0, scale = 100 })

	local minVal = math.huge
	local maxVal = -math.huge
	for i = 1, 500 do
		local x = i * 1.3 + 0.5
		local z = i * 2.7 + 0.3
		local v = noise:Get2D(x, z)
		minVal = math.min(minVal, v)
		maxVal = math.max(maxVal, v)
		assertTrue(v >= -1.0 and v <= 1.0, "Get2D value " .. tostring(v) .. " out of range [-1, 1] at (" .. tostring(x) .. ", " .. tostring(z) .. ")")
	end
end

-- Test 3: Range - Get2DRange maps to arbitrary min..max
function TESTS.testGet2DRange()
	local noise = NoiseLib.new({ seed = 99, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 50 })

	for i = 1, 200 do
		local x = i * 0.7
		local z = i * 1.1
		local v = noise:Get2DRange(x, z, 10, 50)
		assertTrue(v >= 10 and v <= 50, "Get2DRange value " .. tostring(v) .. " out of range [10, 50]")
	end

	-- Verify midpoint maps approximately correctly
	local mid = noise:Get2DRange(0, 0, 0, 100)
	assertTrue(mid >= 0 and mid <= 100, "Get2DRange midpoint out of [0, 100]")
end

-- Test 4: Different seeds produce different outputs
function TESTS.testDifferentSeeds()
	local noise1 = NoiseLib.new({ seed = 1, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 })
	local noise2 = NoiseLib.new({ seed = 2, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 })

	local diffCount = 0
	for i = 1, 100 do
		local x = i * 5.1
		local z = i * 3.9
		local v1 = noise1:Get2D(x, z)
		local v2 = noise2:Get2D(x, z)
		if v1 ~= v2 then
			diffCount += 1
		end
	end

	assertTrue(diffCount >= 95, "Expected different seeds to produce different outputs, but only " .. tostring(diffCount) .. "/100 differed")
end

-- Test 5: SetSeed changes output
function TESTS.testSetSeed()
	local noise = NoiseLib.new({ seed = 10, octaves = 4, persistence = 0.5, lacunarity = 2.0, scale = 100 })
	local v1 = noise:Get2D(50, 50)
	noise:SetSeed(20)
	local v2 = noise:Get2D(50, 50)
	assertTrue(v1 ~= v2, "SetSeed should change output: got " .. tostring(v1) .. " and " .. tostring(v2))
end

-- Test 6: Octave behavior - more octaves = more detail/variation
function TESTS.testOctaveBehavior()
	local seed = 777
	local noiseLow = NoiseLib.new({ seed = seed, octaves = 1, persistence = 0.5, lacunarity = 2.0, scale = 100 })
	local noiseHigh = NoiseLib.new({ seed = seed, octaves = 8, persistence = 0.5, lacunarity = 2.0, scale = 100 })

	-- Measure local variance (detail) by checking differences between nearby samples
	local function measureVariance(noise)
		local totalDiff = 0
		for i = 1, 100 do
			local x = i * 10
			local z = i * 10
			local v1 = noise:Get2D(x, z)
			local v2 = noise:Get2D(x + 0.5, z + 0.5)
			totalDiff += math.abs(v1 - v2)
		end
		return totalDiff / 100
	end

	local varLow = measureVariance(noiseLow)
	local varHigh = measureVariance(noiseHigh)

	-- Higher octaves should produce more local variation
	assertTrue(varHigh > varLow, "Higher octaves should produce more local variation: " .. tostring(varHigh) .. " vs " .. tostring(varLow))
end

-- Test 7: GetConfig returns correct values
function TESTS.testGetConfig()
	local config = { seed = 123, octaves = 3, persistence = 0.3, lacunarity = 1.5, scale = 200 }
	local noise = NoiseLib.new(config)
	local cfg = noise:GetConfig()
	assertEq(cfg.seed, 123, "Config seed mismatch")
	assertEq(cfg.octaves, 3, "Config octaves mismatch")
	assertNear(cfg.persistence, 0.3, 0.0001, "Config persistence mismatch")
	assertNear(cfg.lacunarity, 1.5, 0.0001, "Config lacunarity mismatch")
	assertEq(cfg.scale, 200, "Config scale mismatch")
end

-- Test 8: Default config
function TESTS.testDefaults()
	local noise = NoiseLib.new(nil)
	local cfg = noise:GetConfig()
	assertEq(cfg.octaves, 6, "Default octaves should be 6")
	assertNear(cfg.persistence, 0.5, 0.0001, "Default persistence should be 0.5")
	assertNear(cfg.lacunarity, 2.0, 0.0001, "Default lacunarity should be 2.0")
	assertEq(cfg.scale, 100, "Default scale should be 100")
end

-- Test 9: 3D noise determinism and range
function TESTS.test3D()
	local noise = NoiseLib.new({ seed = 555, octaves = 3, persistence = 0.5, lacunarity = 2.0, scale = 50 })

	for i = 1, 100 do
		local x = i * 1.1
		local y = i * 2.2
		local z = i * 3.3
		local v = noise:Get3D(x, y, z)
		assertTrue(v >= -1 and v <= 1, "Get3D value out of range [-1, 1]: " .. tostring(v))
	end
end

-- Test 10: Zero seed works
function TESTS.testZeroSeed()
	local noise = NoiseLib.new({ seed = 0, octaves = 2, persistence = 0.5, lacunarity = 2.0, scale = 100 })
	local v1 = noise:Get2D(0, 0)
	local v2 = noise:Get2D(10, 10)
	assertTrue(v1 >= -1 and v1 <= 1, "Zero seed Get2D should be in range")
	assertTrue(v2 >= -1 and v2 <= 1, "Zero seed Get2D should be in range")
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
print("NoiseLib Test Results: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed")
if failed > 0 then
	error("NoiseLib tests failed")
end
