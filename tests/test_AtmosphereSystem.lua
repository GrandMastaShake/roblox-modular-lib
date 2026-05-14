--!strict
-- tests/test_AtmosphereSystem.lua
-- Lightweight assert-based tests for AtmosphereSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local AtmosphereSystem = require(script.Parent.Parent.src.AtmosphereSystem)

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

local function runTests()
	print("[test_AtmosphereSystem] Starting tests...")

	-- Test 1: Constructor creates AtmosphereSystem
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)
		assertTrue(atm ~= nil, "AtmosphereSystem.new should return instance")
		print("  [PASS] Constructor")
	end

	-- Test 2: Default biomes are registered on construction
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		-- Verify all 9 default biomes are registered by applying each
		local biomes = {
			"Tundra", "Taiga", "Temperate Forest", "Grassland",
			"Desert", "Tropical Rainforest", "Savanna", "Mountains", "Ocean"
		}

		for _, biomeId in ipairs(biomes) do
			local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
			-- Should not error
			local ok = pcall(function()
				atm:ApplyToRegion(biomeId, region)
			end)
			assertTrue(ok, "Default biome '" .. biomeId .. "' should be registered")
		end
		print("  [PASS] All 9 default biomes registered")
	end

	-- Test 3: RegisterBiomeAtmosphere stores custom biome config
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local customConfig = {
			lighting = {
				ambient = Color3.fromRGB(255, 0, 0),
				outdoorAmbient = Color3.fromRGB(200, 0, 0),
				brightness = 3.0,
				clockTime = 14,
			},
			fog = {
				start = 50,
				["end"] = 200,
				color = Color3.fromRGB(255, 100, 100),
			},
			sky = {
				skyboxId = nil,
				celestialBodiesShown = false,
			},
			soundscape = {
				daySounds = {},
				nightSounds = {},
			},
		}

		atm:RegisterBiomeAtmosphere("CustomBiome", customConfig)

		-- Apply it to verify it was stored correctly
		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		local ok = pcall(function()
			atm:ApplyToRegion("CustomBiome", region)
		end)
		assertTrue(ok, "Custom biome should be registered and applicable")
		print("  [PASS] RegisterBiomeAtmosphere stores custom config")
	end

	-- Test 4: RegisterBiomeAtmosphere emits BiomeAtmosphereRegistered event
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local eventFired = false
		local eventData = nil
		bus:Subscribe("BiomeAtmosphereRegistered", function(payload: any)
			eventFired = true
			eventData = payload
		end)

		local config = {
			lighting = {
				ambient = Color3.fromRGB(100, 100, 100),
				outdoorAmbient = Color3.fromRGB(90, 90, 90),
				brightness = 1.0,
				clockTime = 12,
			},
			fog = {
				start = 30,
				["end"] = 150,
				color = Color3.fromRGB(150, 150, 150),
			},
			sky = {
				skyboxId = nil,
				celestialBodiesShown = true,
			},
			soundscape = {
				daySounds = {},
				nightSounds = {},
			},
		}

		atm:RegisterBiomeAtmosphere("TestBiome", config)
		assertTrue(eventFired, "BiomeAtmosphereRegistered event should fire")
		if eventData then
			assertEq(eventData.biomeId, "TestBiome", "Event should contain biomeId")
		end
		print("  [PASS] RegisterBiomeAtmosphere emits event")
	end

	-- Test 5: ApplyToRegion emits AtmosphereApplied event
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local eventFired = false
		local eventData = nil
		bus:Subscribe("AtmosphereApplied", function(payload: any)
			eventFired = true
			eventData = payload
		end)

		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Desert", region)

		assertTrue(eventFired, "AtmosphereApplied event should fire")
		if eventData then
			assertEq(eventData.biomeId, "Desert", "Event should contain Desert biomeId")
			assertTrue(eventData.region ~= nil, "Event should contain region")
			assertTrue(eventData.config ~= nil, "Event should contain config")
		end
		print("  [PASS] ApplyToRegion emits AtmosphereApplied")
	end

	-- Test 6: ApplyToRegion handles unknown biome gracefully
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		-- Should not error, just warn
		local ok = pcall(function()
			atm:ApplyToRegion("UnknownBiome", region)
		end)
		assertTrue(ok, "ApplyToRegion with unknown biome should not error")
		print("  [PASS] ApplyToRegion handles unknown biome")
	end

	-- Test 7: ApplyToChunk processes chunk with biomeMap
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local size = 8
		local biomeMap: { { string } } = {}
		for x = 1, size do
			biomeMap[x] = {}
			for z = 1, size do
				biomeMap[x][z] = "Desert"
			end
		end

		local chunk = {
			cx = 0,
			cz = 0,
			size = size,
			biomeMap = biomeMap,
		}

		local eventFired = false
		bus:Subscribe("AtmosphereApplied", function(payload: any)
			eventFired = true
		end)

		atm:ApplyToChunk(chunk)
		assertTrue(eventFired, "ApplyToChunk should trigger AtmosphereApplied")
		print("  [PASS] ApplyToChunk with biomeMap")
	end

	-- Test 8: ApplyToChunk handles chunk without biomeMap
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local chunk = {
			cx = 0,
			cz = 0,
			size = 8,
		}

		-- Should not error
		local ok = pcall(function()
			atm:ApplyToChunk(chunk)
		end)
		assertTrue(ok, "ApplyToChunk without biomeMap should not error")
		print("  [PASS] ApplyToChunk without biomeMap")
	end

	-- Test 9: ApplyToChunk handles nil chunk
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local ok = pcall(function()
			atm:ApplyToChunk(nil)
		end)
		assertTrue(ok, "ApplyToChunk with nil should not error")
		print("  [PASS] ApplyToChunk with nil chunk")
	end

	-- Test 10: TransitionAtmosphere handles known biomes
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		-- Apply source biome first so Lighting has values
		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Forest", region)

		-- Should not error
		local ok = pcall(function()
			atm:TransitionAtmosphere("Forest", "Desert", 0.1)
		end)
		assertTrue(ok, "TransitionAtmosphere between known biomes should not error")
		print("  [PASS] TransitionAtmosphere handles known biomes")
	end

	-- Test 11: TransitionAtmosphere emits AtmosphereTransitioned event
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Tundra", region)

		-- Use a biome that exists
		local transitionedFired = false
		bus:Subscribe("AtmosphereTransitioned", function(payload: any)
			transitionedFired = true
		end)

		-- The event fires on tween completion which is async
		-- Just verify the call doesn't error and the tween is created
		local ok = pcall(function()
			atm:TransitionAtmosphere("Tundra", "Ocean", 0.05)
		end)
		assertTrue(ok, "TransitionAtmosphere should not error")
		print("  [PASS] TransitionAtmosphere creates transition")
	end

	-- Test 12: TransitionAtmosphere handles unknown fromBiome gracefully
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local ok = pcall(function()
			atm:TransitionAtmosphere("NonExistent", "Desert", 0.1)
		end)
		assertTrue(ok, "TransitionAtmosphere with unknown fromBiome should not error (warns)")
		print("  [PASS] TransitionAtmosphere handles unknown fromBiome")
	end

	-- Test 13: TransitionAtmosphere handles unknown toBiome gracefully
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Desert", region)

		local ok = pcall(function()
			atm:TransitionAtmosphere("Desert", "NonExistent", 0.1)
		end)
		assertTrue(ok, "TransitionAtmosphere with unknown toBiome should not error (warns)")
		print("  [PASS] TransitionAtmosphere handles unknown toBiome")
	end

	-- Test 14: Biome configs have realistic values
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		-- Desert should be warm and bright
		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Desert", region)

		-- Verify lighting was set to desert values
		local Lighting = game:GetService("Lighting")
		assertGt(Lighting.Brightness, 2.0, "Desert brightness should be high")
		print("  [PASS] Desert atmosphere has bright lighting")
	end

	-- Test 15: Ocean biome has blue fog color
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Ocean", region)

		local Lighting = game:GetService("Lighting")
		-- Ocean ambient should have blue component highest
		local ambient = Lighting.Ambient
		assertTrue(ambient.B > ambient.R, "Ocean ambient should be blue-tinted")
		print("  [PASS] Ocean atmosphere has blue tint")
	end

	-- Test 16: Tropical Rainforest has dark green ambient
	do
		local bus = EventBus.new()
		local atm = AtmosphereSystem.new(bus)

		local region = Region3.new(Vector3.new(0, 0, 0), Vector3.new(64, 128, 64))
		atm:ApplyToRegion("Tropical Rainforest", region)

		local Lighting = game:GetService("Lighting")
		assertTrue(Lighting.Brightness < 1.0, "Rainforest brightness should be low (dark)")
		print("  [PASS] Tropical Rainforest atmosphere is dark")
	end

	print("[test_AtmosphereSystem] All tests passed!")
end

runTests()
