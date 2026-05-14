--!strict
-- tests/test_WeatherSystem.lua
-- Test stubs for WeatherSystem: transitions, duration, biome probabilities, random weather.

local WeatherSystem = require(script.Parent.Parent.src.WeatherSystem)

-- Minimal mock EventBus.
local MockEventBus = {}
MockEventBus.__index = MockEventBus

function MockEventBus.new(): MockEventBus
	local self = setmetatable({}, MockEventBus)
	self.events = {} :: { [string]: { any } }
	return self
end

function MockEventBus:Subscribe(eventName: string, callback: (any) -> ()): () -> ()
	if not self.events[eventName] then
		self.events[eventName] = {}
	end
	-- Store callbacks for introspection in tests.
	if not self._callbacks then
		self._callbacks = {} :: { [string]: { (any) -> () } }
	end
	if not self._callbacks[eventName] then
		self._callbacks[eventName] = {}
	end
	table.insert(self._callbacks[eventName], callback)
	return function() end
end

function MockEventBus:Emit(eventName: string, payload: any)
	if not self.events[eventName] then
		self.events[eventName] = {}
	end
	table.insert(self.events[eventName], payload)
	-- Also fire any subscribed callbacks.
	if self._callbacks and self._callbacks[eventName] then
		for _, cb in ipairs(self._callbacks[eventName]) do
			cb(payload)
		end
	end
end

function MockEventBus:Once(eventName: string, callback: (any) -> ()): () -> ()
	return self:Subscribe(eventName, callback)
end

-- Test result accumulator.
local TestResults = {
	passed = 0,
	failed = 0,
	errors = {} :: { string },
}

local function assertEq(got: any, expected: any, msg: string)
	if got ~= expected then
		table.insert(TestResults.errors, msg .. " | expected: " .. tostring(expected) .. " got: " .. tostring(got))
		TestResults.failed += 1
	else
		TestResults.passed += 1
	end
end

local function assertNear(got: number, expected: number, tolerance: number, msg: string)
	if math.abs(got - expected) > tolerance then
		table.insert(TestResults.errors, msg .. " | expected near: " .. tostring(expected) .. " got: " .. tostring(got))
		TestResults.failed += 1
	else
		TestResults.passed += 1
	end
end

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		table.insert(TestResults.errors, msg .. " | condition was false")
		TestResults.failed += 1
	else
		TestResults.passed += 1
	end
end

local function runTest(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		table.insert(TestResults.errors, "TEST ERROR [" .. name .. "]: " .. tostring(err))
		TestResults.failed += 1
	end
end

--------------------------------------------------------------------------------
-- TESTS
--------------------------------------------------------------------------------

-- 1. SetWeather transitions ---------------------------------------------------

runTest("SetWeather transitions weather type", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	assertEq(ws:GetCurrentWeather().type, "clear", "initial type should be clear")

	ws:SetWeather("rain", 0.5, 30)
	local state = ws:GetCurrentWeather()
	assertEq(state.type, "rain", "type should be rain after SetWeather")
	assertEq(state.intensity, 0, "intensity should start at 0 before Update")
	assertNear(state.duration, 30, 0.001, "duration should be 30")

	-- Check WeatherChanged event was emitted.
	assertTrue(bus.events["WeatherChanged"] ~= nil, "WeatherChanged event should be emitted")
	assertEq(bus.events["WeatherChanged"][1].to, "rain", "event should show transition to rain")
end)

runTest("SetWeather intensity tweens toward target", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("rain", 1.0)
	-- After multiple Update calls, intensity should approach 1.
	for _ = 1, 10 do
		ws:Update(0.2) -- 2 seconds total
	end
	local state = ws:GetCurrentWeather()
	assertNear(state.intensity, 1.0, 0.01, "intensity should reach 1.0 after ~2s of updates")
end)

runTest("SetWeather to storm emits StormStarted", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("storm", 0.8, 60)
	assertTrue(bus.events["StormStarted"] ~= nil, "StormStarted should be emitted")
	assertEq(bus.events["StormStarted"][1].intensity, 0.8, "StormStarted should carry intensity")
end)

runTest("SetWeather from storm to clear emits StormEnded", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("storm", 0.8, 60)
	ws:SetWeather("clear", 0)
	assertTrue(bus.events["StormEnded"] ~= nil, "StormEnded should be emitted when leaving storm")
	assertEq(bus.events["StormEnded"][1].newType, "clear", "StormEnded should show new type")
end)

-- 2. Update reduces duration and auto-clears ----------------------------------

runTest("Update reduces duration over time", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("rain", 0.5, 10)
	ws:Update(2)
	local state = ws:GetCurrentWeather()
	assertNear(state.duration, 8, 0.001, "duration should decrease by dt")
end)

runTest("Update auto-clears weather when duration expires", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("rain", 0.5, 5)
	-- Step past the duration.
	ws:Update(6)
	local state = ws:GetCurrentWeather()
	assertEq(state.type, "clear", "weather should auto-clear after duration expires")
	assertEq(state.intensity, 0, "intensity should be 0 after auto-clear")
end)

runTest("Update emits WeatherUpdated", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("snow", 0.7, 20)
	ws:Update(0.1)
	assertTrue(bus.events["WeatherUpdated"] ~= nil, "WeatherUpdated should be emitted")
end)

-- 3. Lightning during storms --------------------------------------------------

runTest("Lightning flash fires LightningStruck event", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("storm", 1.0, 60)
	-- After setting storm, Update should trigger lightning eventually.
	-- Force lightning by stepping past the 2-8s interval.
	local lightningFired = false
	local origEmit = bus.Emit
	bus.Emit = function(selfBus, eventName, payload)
		if eventName == "LightningStruck" then
			lightningFired = true
		end
		origEmit(selfBus, eventName, payload)
	end

	-- Step enough time to trigger at least one lightning (interval is 2-8s).
	for i = 1, 100 do
		ws:Update(0.1) -- 10 seconds total, enough for lightning
		if lightningFired then
			break
		end
	end

	assertTrue(lightningFired, "LightningStruck should fire during storm")
end)

-- 4. Biome weather probabilities sum to 1 -------------------------------------

runTest("Desert biome probabilities sum to 1", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local probs = ws:GetWeatherForBiome("Desert")
	local sum = 0
	for _, v in pairs(probs) do
		sum += v
	end
	assertNear(sum, 1.0, 0.001, "Desert probabilities should sum to 1")
end)

runTest("Rainforest biome probabilities sum to 1", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local probs = ws:GetWeatherForBiome("Rainforest")
	local sum = 0
	for _, v in pairs(probs) do
		sum += v
	end
	assertNear(sum, 1.0, 0.001, "Rainforest probabilities should sum to 1")
end)

runTest("Tundra biome probabilities sum to 1", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local probs = ws:GetWeatherForBiome("Tundra")
	local sum = 0
	for _, v in pairs(probs) do
		sum += v
	end
	assertNear(sum, 1.0, 0.001, "Tundra probabilities should sum to 1")
end)

runTest("Temperate Forest biome probabilities sum to 1", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local probs = ws:GetWeatherForBiome("Temperate Forest")
	local sum = 0
	for _, v in pairs(probs) do
		sum += v
	end
	assertNear(sum, 1.0, 0.001, "Temperate Forest probabilities should sum to 1")
end)

runTest("Default biome probabilities sum to 1", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local probs = ws:GetWeatherForBiome("UnknownBiome")
	local sum = 0
	for _, v in pairs(probs) do
		sum += v
	end
	assertNear(sum, 1.0, 0.001, "Default biome probabilities should sum to 1")
end)

-- 5. Random weather respects biome weights ------------------------------------

runTest("EnableRandomWeather sets up timer", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:EnableRandomWeather(5)
	assertTrue(ws._randomWeatherActive, "random weather should be active")
	assertEq(ws._randomWeatherInterval, 5, "interval should be 5")
	assertNear(ws._randomWeatherTimer, 5, 0.001, "timer should start at interval")
end)

runTest("DisableRandomWeather stops timer", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:EnableRandomWeather(5)
	ws:DisableRandomWeather()
	assertTrue(not ws._randomWeatherActive, "random weather should be inactive")
end)

runTest("Random weather triggers after interval", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetCurrentBiome("Desert")
	ws:EnableRandomWeather(10)

	-- Collect weather types chosen over many cycles.
	local typeCounts: { [string]: number } = {}
	for _ = 1, 200 do
		-- Reset and step the timer to trigger a roll.
		ws._randomWeatherTimer = 0.1
		ws:Update(0.2)
		local wtype = ws:GetCurrentWeather().type
		typeCounts[wtype] = (typeCounts[wtype] or 0) + 1
	end

	-- In Desert, "clear" should dominate (~70%).
	assertTrue((typeCounts["clear"] or 0) > 50, "Desert should heavily favor clear weather")
	-- Rainforest biome test.
	local bus2 = MockEventBus.new()
	local ws2 = WeatherSystem.new(bus2 :: any)
	ws2:SetCurrentBiome("Rainforest")
	ws2:EnableRandomWeather(10)

	local rfCounts: { [string]: number } = {}
	for _ = 1, 200 do
		ws2._randomWeatherTimer = 0.1
		ws2:Update(0.2)
		local wtype = ws2:GetCurrentWeather().type
		rfCounts[wtype] = (rfCounts[wtype] or 0) + 1
	end

	-- In Rainforest, rain should be most common (~40%).
	assertTrue((rfCounts["rain"] or 0) > 30, "Rainforest should favor rain")
end)

-- 6. SetParticleSystem override -----------------------------------------------

runTest("SetParticleSystem overrides default config", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local customConfig = {
		particleCount = 999,
		velocity = Vector3.new(0, -100, 0),
		acceleration = Vector3.new(0, -20, 0),
		color = Color3.fromRGB(255, 0, 0),
		size = 0.5,
		lifetime = 2,
		spread = 50,
		transparency = 0.1,
	}
	ws:SetParticleSystem("rain", customConfig)

	-- The particle config should be updated internally.
	assertTrue(ws._particleConfigs ~= nil, "particle configs should exist")
	assertEq(ws._particleConfigs.rain.particleCount, 999, "custom particle count should be set")
end)

-- 7. Particle emission rates --------------------------------------------------

runTest("Rain emission rate scales with intensity", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("rain", 1.0)
	ws:Update(10) -- fully tweened
	local state = ws:GetCurrentWeather()
	-- Base rate for rain is 800, intensity 1.0 -> 800 particles.
	assertTrue(ws._activeParticles > 0, "rain should produce particles at intensity 1.0")
	assertEq(ws._activeParticles, 800, "rain emission should be 800 at full intensity")
end)

runTest("Storm emission rate scales with intensity", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("storm", 1.0)
	ws:Update(10)
	assertEq(ws._activeParticles, 1500, "storm emission should be 1500 at full intensity")
end)

runTest("Snow emission rate scales with intensity", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("snow", 1.0)
	ws:Update(10)
	assertEq(ws._activeParticles, 300, "snow emission should be 300 at full intensity")
end)

runTest("Clear has zero emission", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("clear", 0)
	ws:Update(1)
	assertEq(ws._activeParticles, 0, "clear should have 0 particles")
end)

-- 8. Wind direction and speed -------------------------------------------------

runTest("Initial wind state is valid", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	local state = ws:GetCurrentWeather()
	assertEq(state.windSpeed, 0, "initial wind speed should be 0")
	assertEq(state.windDirection.X, 1, "initial wind direction should be (1,0,0)")
end)

-- 9. Multiple weather transitions ---------------------------------------------

runTest("Multiple transitions emit correct events", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("clear", 0)
	ws:SetWeather("rain", 0.5)
	ws:SetWeather("storm", 0.9)
	ws:SetWeather("snow", 0.4)

	local weatherChanges = bus.events["WeatherChanged"] or {}
	assertEq(#weatherChanges, 4, "should have 4 WeatherChanged events")

	-- Check the sequence.
	assertEq(weatherChanges[1].to, "clear", "1st: clear")
	assertEq(weatherChanges[2].to, "rain", "2nd: rain")
	assertEq(weatherChanges[3].to, "storm", "3rd: storm")
	assertEq(weatherChanges[4].to, "snow", "4th: snow")
end)

-- 10. Cleanup / Destroy -------------------------------------------------------

runTest("Destroy cleans up state", function()
	local bus = MockEventBus.new()
	local ws = WeatherSystem.new(bus :: any)

	ws:SetWeather("storm", 1.0, 100)
	ws:Destroy()
	assertTrue(not ws._lightningActive, "lightning should be inactive after destroy")
	assertTrue(not ws._randomWeatherActive, "random weather should be inactive after destroy")
end)

--------------------------------------------------------------------------------
-- REPORT
--------------------------------------------------------------------------------

print(string.rep("=", 60))
print("WeatherSystem Test Results")
print(string.rep("=", 60))
print("Passed: " .. TestResults.passed)
print("Failed: " .. TestResults.failed)
if #TestResults.errors > 0 then
	print("\nErrors:")
	for _, err in ipairs(TestResults.errors) do
		print("  - " .. err)
	end
else
	print("\nAll tests passed!")
end
print(string.rep("=", 60))

-- Return results for test harness integration.
return TestResults
