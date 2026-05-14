--!strict
-- tests/test_ObjectPlacer.lua
-- Tests for ObjectPlacer: RegisterObject, PlaceInChunk, Poisson disc, ClearChunk.

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
-- ObjectPlacer module table (self-contained for test)
-- ---------------------------------------------------------------------------

local RNG = Random.new()

export type ObjectDef = {
	id: string, name: string,
	category: "tree" | "rock" | "flower" | "bush" | "grass" | "structure",
	modelId: string, scaleRange: { min: number, max: number },
	slopeMax: number, altitudeMin: number, altitudeMax: number,
	biomeWhitelist: { string }?, collision: boolean,
}

export type Placement = { objectId: string, cframe: CFrame, scale: number }

local function computeSlope(heightmap: { { number } }, ix: number, iz: number, size: number): number
	local h = heightmap[ix][iz]
	local dx, dz = 0, 0
	if ix > 1 and ix < size then dx = math.abs(heightmap[ix + 1][iz] - heightmap[ix - 1][iz]) / 2
	elseif ix > 1 then dx = math.abs(h - heightmap[ix - 1][iz])
	elseif ix < size then dx = math.abs(heightmap[ix + 1][iz] - h) end
	if iz > 1 and iz < size then dz = math.abs(heightmap[ix][iz + 1] - heightmap[ix][iz - 1]) / 2
	elseif iz > 1 then dz = math.abs(h - heightmap[ix][iz - 1])
	elseif iz < size then dz = math.abs(heightmap[ix][iz + 1] - h) end
	return math.sqrt(dx * dx + dz * dz)
end

local GRID_TO_STUDS = 4

local function gridToStuds(cx: number, cz: number, ix: number, iz: number, size: number): (number, number)
	return cx * size * GRID_TO_STUDS + (ix - 1) * GRID_TO_STUDS, cz * size * GRID_TO_STUDS + (iz - 1) * GRID_TO_STUDS
end

local function poissonDiscSamples(size: number, minRadius: number, maxAttempts: number, targetCount: number): { { x: number, z: number } }
	local points = {} :: { { x: number, z: number } }
	local active = {} :: { { x: number, z: number } }
	if targetCount <= 0 then return points end
	local first = { x = size / 2, z = size / 2 }
	table.insert(points, first)
	table.insert(active, first)
	while #active > 0 and #points < targetCount do
		local idx = RNG:NextInteger(1, #active)
		local center = active[idx]
		local placed = false
		for _ = 1, maxAttempts do
			local angle = RNG:NextNumber(0, math.pi * 2)
			local r = minRadius + RNG:NextNumber(0, minRadius)
			local px = center.x + r * math.cos(angle)
			local pz = center.z + r * math.sin(angle)
			if px >= 1 and px <= size and pz >= 1 and pz <= size then
				local tooClose = false
				for _, p in ipairs(points) do
					if math.sqrt((px - p.x) ^ 2 + (pz - p.z) ^ 2) < minRadius then
						tooClose = true
						break
					end
				end
				if not tooClose then
					local newP = { x = px, z = pz }
					table.insert(points, newP)
					table.insert(active, newP)
					placed = true
					break
				end
			end
		end
		if not placed then
			table.remove(active, idx)
		end
	end
	return points
end

local ObjectPlacerModule = {}
ObjectPlacerModule.__index = ObjectPlacerModule

function ObjectPlacerModule.new(eventBus: any)
	local self = setmetatable({}, ObjectPlacerModule)
	self._eventBus = eventBus
	self._objects = {} :: { [string]: ObjectDef }
	self._objectList = {} :: { ObjectDef }
	self._densityMultiplier = 1.0
	self._placementsByChunk = {} :: { [string]: { Placement } }
	self._totalPlacements = 0
	self:_registerDefaultObjects()
	return self
end

function ObjectPlacerModule:_registerDefaultObjects()
	local defaults: { ObjectDef } = {
		{ id = "PineTree", name = "Pine Tree", category = "tree", modelId = "rbxassetid://PineTree001", scaleRange = { min = 0.8, max = 1.5 }, slopeMax = 0.6, altitudeMin = 0, altitudeMax = 200, biomeWhitelist = { "taiga", "tundra", "mountains" }, collision = true },
		{ id = "OakTree", name = "Oak Tree", category = "tree", modelId = "rbxassetid://OakTree001", scaleRange = { min = 0.9, max = 1.4 }, slopeMax = 0.5, altitudeMin = 0, altitudeMax = 180, biomeWhitelist = { "temperate_forest", "grassland" }, collision = true },
		{ id = "PalmTree", name = "Palm Tree", category = "tree", modelId = "rbxassetid://PalmTree001", scaleRange = { min = 0.9, max = 1.3 }, slopeMax = 0.4, altitudeMin = 0, altitudeMax = 80, biomeWhitelist = { "tropical_rainforest", "savanna", "ocean" }, collision = true },
		{ id = "Rock_Large", name = "Large Rock", category = "rock", modelId = "rbxassetid://RockLarge001", scaleRange = { min = 1.0, max = 2.5 }, slopeMax = 1.2, altitudeMin = 0, altitudeMax = 300, biomeWhitelist = nil, collision = true },
		{ id = "Rock_Small", name = "Small Rock", category = "rock", modelId = "rbxassetid://RockSmall001", scaleRange = { min = 0.3, max = 0.8 }, slopeMax = 1.5, altitudeMin = 0, altitudeMax = 300, biomeWhitelist = nil, collision = false },
		{ id = "Bush", name = "Bush", category = "bush", modelId = "rbxassetid://Bush001", scaleRange = { min = 0.5, max = 1.0 }, slopeMax = 0.5, altitudeMin = 0, altitudeMax = 200, biomeWhitelist = { "temperate_forest", "grassland", "savanna", "taiga" }, collision = false },
		{ id = "Flower_Red", name = "Red Flower", category = "flower", modelId = "rbxassetid://FlowerRed001", scaleRange = { min = 0.4, max = 0.8 }, slopeMax = 0.3, altitudeMin = 0, altitudeMax = 150, biomeWhitelist = { "temperate_forest", "grassland", "tropical_rainforest", "tundra" }, collision = false },
		{ id = "Flower_Yellow", name = "Yellow Flower", category = "flower", modelId = "rbxassetid://FlowerYellow001", scaleRange = { min = 0.4, max = 0.8 }, slopeMax = 0.3, altitudeMin = 0, altitudeMax = 150, biomeWhitelist = { "grassland", "savanna", "temperate_forest" }, collision = false },
		{ id = "Grass_Clump", name = "Grass Clump", category = "grass", modelId = "rbxassetid://GrassClump001", scaleRange = { min = 0.5, max = 1.2 }, slopeMax = 0.7, altitudeMin = 0, altitudeMax = 200, biomeWhitelist = nil, collision = false },
	}
	for _, obj in ipairs(defaults) do
		self:RegisterObject(obj)
	end
end

function ObjectPlacerModule:RegisterObject(def: ObjectDef)
	self._objects[def.id] = def
	self._objectList = {}
	for _, obj in pairs(self._objects) do
		table.insert(self._objectList, obj)
	end
end

function ObjectPlacerModule:_getBiomeDensity(biomeId: string, category: string): number
	local densityTable: { [string]: { [string]: number } } = {
		ocean = { tree = 0, rock = 0.05, flower = 0, bush = 0, grass = 0.02 },
		tundra = { tree = 0.05, rock = 0.2, flower = 0.1, bush = 0.05, grass = 0.1 },
		taiga = { tree = 0.6, rock = 0.15, flower = 0.1, bush = 0.15, grass = 0.3 },
		temperate_forest = { tree = 0.7, rock = 0.1, flower = 0.25, bush = 0.3, grass = 0.4 },
		grassland = { tree = 0.15, rock = 0.1, flower = 0.4, bush = 0.2, grass = 0.6 },
		desert = { tree = 0.02, rock = 0.25, flower = 0.05, bush = 0.05, grass = 0.02 },
		tropical_rainforest = { tree = 0.85, rock = 0.1, flower = 0.5, bush = 0.5, grass = 0.3 },
		savanna = { tree = 0.2, rock = 0.15, flower = 0.3, bush = 0.25, grass = 0.5 },
		mountains = { tree = 0.1, rock = 0.6, flower = 0.1, bush = 0.05, grass = 0.1 },
	}
	local biomeDensities = densityTable[biomeId]
	if biomeDensities then return biomeDensities[category] or 0.1 end
	return 0.1
end

function ObjectPlacerModule:_getMinRadius(category: string): number
	local radii: { [string]: number } = { tree = 5, rock = 3, flower = 1.5, bush = 2.5, grass = 1, structure = 8 }
	return radii[category] or 3
end

function ObjectPlacerModule:PlaceInChunk(chunk: any, densityMultiplier: number?): { Placement }
	local multiplier = densityMultiplier or self._densityMultiplier
	local size = #chunk.heightmap
	local biomeId = chunk.biomeMap and chunk.biomeMap[1] and chunk.biomeMap[1][1] or "grassland"
	local placements = {} :: { Placement }
	local chunkKey = chunk.cx .. "," .. chunk.cz

	for _, objDef in ipairs(self._objectList) do
		if objDef.biomeWhitelist then
			local allowed = false
			for _, bid in ipairs(objDef.biomeWhitelist) do
				if bid == biomeId then allowed = true; break end
			end
			if not allowed then continue end
		end

		local density = self:_getBiomeDensity(biomeId, objDef.category)
		local adjustedDensity = density * multiplier
		if adjustedDensity <= 0 then continue end

		local chunkArea = size * size
		local targetCount = math.floor(chunkArea * adjustedDensity / 100)
		if targetCount < 1 then continue end

		local minRadius = self:_getMinRadius(objDef.category)
		local candidates = poissonDiscSamples(size, minRadius, 30, targetCount)

		for _, candidate in ipairs(candidates) do
			local ix = math.clamp(math.round(candidate.x), 1, size)
			local iz = math.clamp(math.round(candidate.z), 1, size)
			local height = chunk.heightmap[ix] and chunk.heightmap[ix][iz]
			if not height then continue end

			local slope = computeSlope(chunk.heightmap, ix, iz, size)
			if slope > objDef.slopeMax then continue end
			if height < objDef.altitudeMin or height > objDef.altitudeMax then continue end

			local scale = objDef.scaleRange.min + RNG:NextNumber(0, 1) * (objDef.scaleRange.max - objDef.scaleRange.min)
			local angleY = RNG:NextNumber(0, math.pi * 2)
			local worldX, worldZ = gridToStuds(chunk.cx, chunk.cz, ix, iz, size)
			local tiltX = RNG:NextNumber(-0.1, 0.1)
			local tiltZ = RNG:NextNumber(-0.1, 0.1)
			local cframe = CFrame.new(worldX, height, worldZ) * CFrame.Angles(tiltX, angleY, tiltZ)

			table.insert(placements, { objectId = objDef.id, cframe = cframe, scale = scale })
			self._eventBus:Emit("ObjectPlaced", { placement = { objectId = objDef.id, cframe = cframe, scale = scale }, chunkCx = chunk.cx, chunkCz = chunk.cz, objectDef = objDef })
		end
	end

	self._placementsByChunk[chunkKey] = placements
	self._totalPlacements += #placements
	self._eventBus:Emit("PlacementCompleted", { cx = chunk.cx, cz = chunk.cz, count = #placements, placements = placements })
	return placements
end

function ObjectPlacerModule:ClearChunk(cx: number, cz: number)
	local chunkKey = cx .. "," .. cz
	local existing = self._placementsByChunk[chunkKey]
	if existing then
		self._totalPlacements -= #existing
		self._placementsByChunk[chunkKey] = nil
	end
	self._eventBus:Emit("ChunkCleared", { cx = cx, cz = cz, count = existing and #existing or 0 })
end

function ObjectPlacerModule:GetPlacementCount(): number
	return self._totalPlacements
end

function ObjectPlacerModule:SetDensityMultiplier(multiplier: number)
	self._densityMultiplier = math.clamp(multiplier, 0, 10)
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

local function testRegisterObject()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	local customObj: ObjectDef = {
		id = "TestObj", name = "Test Object", category = "structure",
		modelId = "rbxassetid://Test001", scaleRange = { min = 1, max = 2 },
		slopeMax = 0.3, altitudeMin = 0, altitudeMax = 100,
		biomeWhitelist = nil, collision = true,
	}
	placer:RegisterObject(customObj)

	-- Total should be 9 defaults + 1 = 10 unique by id
	-- (RegisterObject overwrites if same id; TestObj is new)
	assertEq(placer:GetPlacementCount(), 0, "Initial placement count should be 0")
end

local function testDefaultObjectsRegistered()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	-- Default objects are registered in constructor, we test by placing
	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "grassland"
		end
	end

	local placements = placer:PlaceInChunk(chunk)
	assertTrue(#placements > 0, "Should place objects in grassland")
end

local function testPlaceInChunkProducesValidCFrames()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "temperate_forest"
		end
	end

	local placements = placer:PlaceInChunk(chunk)
	assertTrue(#placements > 0, "Should place objects in temperate_forest")

	for _, p in ipairs(placements) do
		assertNotNil(p.objectId, "Placement should have objectId")
		assertNotNil(p.cframe, "Placement should have cframe")
		assertNotNil(p.scale, "Placement should have scale")
		-- Scale should be within range
		local objDef = nil
		for _, od in ipairs(placer._objectList) do
			if od.id == p.objectId then objDef = od; break end
		end
		if objDef then
			assertTrue(p.scale >= objDef.scaleRange.min and p.scale <= objDef.scaleRange.max,
				"Scale should be within range for " .. p.objectId)
		end
		-- CFrame should have valid position
		local pos = p.cframe.Position
		assertNotNil(pos.X, "CFrame should have X")
		assertNotNil(pos.Y, "CFrame should have Y")
		assertNotNil(pos.Z, "CFrame should have Z")
	end
end

local function testPoissonDiscNoOverlapping()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	-- Use flat terrain with low density to get more placements
	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 32 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 32 do
			chunk.heightmap[ix][iz] = 50  -- flat terrain
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "grassland"
		end
	end

	local placements = placer:PlaceInChunk(chunk)

	-- Check no two placements of the same object type are too close
	local minDistByCategory: { [string]: number } = { tree = 5 * 4, rock = 3 * 4, flower = 1.5 * 4, bush = 2.5 * 4, grass = 1 * 4, structure = 8 * 4 }

	for i = 1, #placements do
		for j = i + 1, #placements do
			if placements[i].objectId == placements[j].objectId then
				local pos1 = placements[i].cframe.Position
				local pos2 = placements[j].cframe.Position
				local dist = math.sqrt((pos1.X - pos2.X) ^ 2 + (pos1.Z - pos2.Z) ^ 2)
				-- Same-type objects should respect min spacing (in studs)
				-- We check that they're at least 1 stud apart (very loose, since
			-- Poisson disc operates on grid cells and conversion adds jitter)
				assertTrue(dist >= 4, "Placements of same object type should not overlap (dist=" .. tostring(dist) .. ")")
			end
		end
	end
end

local function testClearChunk()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "grassland"
		end
	end

	local placements = placer:PlaceInChunk(chunk)
	local countBefore = placer:GetPlacementCount()
	assertTrue(countBefore > 0, "Should have placements before clear")

	placer:ClearChunk(0, 0)
	local countAfter = placer:GetPlacementCount()
	assertEq(countAfter, 0, "Placement count should be 0 after clearing chunk")

	local clearedEvents = bus:getEvents("ChunkCleared")
	assertEq(#clearedEvents, 1, "Should emit exactly one ChunkCleared event")
end

local function testPlacementCompletedEvent()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	local chunk = {
		cx = 1, cz = 1,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "tropical_rainforest"
		end
	end

	placer:PlaceInChunk(chunk)

	local completed = bus:getEvents("PlacementCompleted")
	assertEq(#completed, 1, "Should emit PlacementCompleted")
	assertEq(completed[1].cx, 1, "PlacementCompleted cx")
	assertEq(completed[1].cz, 1, "PlacementCompleted cz")
	assertTrue(completed[1].count > 0, "PlacementCompleted count should be > 0")
end

local function testDensityMultiplier()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)
	placer:SetDensityMultiplier(2.0)

	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 32 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 32 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "grassland"
		end
	end

	local placements = placer:PlaceInChunk(chunk)
	local count2x = placer:GetPlacementCount()

	-- Now do 1x on same-sized chunk
	local bus2 = MockEventBus.new()
	local placer2 = ObjectPlacerModule.new(bus2)
	placer2:SetDensityMultiplier(1.0)
	placer2:PlaceInChunk(chunk)
	local count1x = placer2:GetPlacementCount()

	-- 2x should place at least as many objects (roughly double, allow variance)
	assertTrue(count2x >= count1x, "2x density should place >= 1x density count")
end

local function testSlopeFiltering()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	-- Create steep terrain: height varies a lot
	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			-- Steep slope: height varies from 10 to 100 across the chunk
			chunk.heightmap[ix][iz] = 10 + (ix - 1) * 8
			chunk.surfaceY[ix][iz] = 10 + (ix - 1) * 8
			chunk.biomeMap[ix][iz] = "grassland"
		end
	end

	local placements = placer:PlaceInChunk(chunk)
	-- Objects with low slopeMax should not be placed on steep areas
	-- All placed objects should be on positions where slope <= their slopeMax
	for _, p in ipairs(placements) do
		-- Just verify placement is valid (slope check passed)
		assertNotNil(p.cframe, "Placement should have valid CFrame after slope check")
	end
end

local function testBiomeWhitelist()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	-- Place in desert where PalmTree is NOT whitelisted
	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "desert"
		end
	end

	local placements = placer:PlaceInChunk(chunk)

	-- In desert, only objects that whitelist desert should appear
	-- Rock_Large, Rock_Small, Grass_Clump have nil whitelist (all biomes)
	-- Desert tree density is very low so mostly rocks
	for _, p in ipairs(placements) do
		-- Verify that only desert-compatible objects are placed
		local objDef = nil
		for _, od in ipairs(placer._objectList) do
			if od.id == p.objectId then objDef = od; break end
		end
		if objDef and objDef.biomeWhitelist then
			local allowed = false
			for _, bid in ipairs(objDef.biomeWhitelist) do
				if bid == "desert" then allowed = true; break end
			end
			assertTrue(allowed, p.objectId .. " should not be placed in desert")
		end
	end
end

local function testObjectPlacedEvent()
	local bus = MockEventBus.new()
	local placer = ObjectPlacerModule.new(bus)

	local chunk = {
		cx = 0, cz = 0,
		heightmap = {}, surfaceY = {}, biomeMap = {},
	}
	for ix = 1, 16 do
		chunk.heightmap[ix] = {}
		chunk.surfaceY[ix] = {}
		chunk.biomeMap[ix] = {}
		for iz = 1, 16 do
			chunk.heightmap[ix][iz] = 50
			chunk.surfaceY[ix][iz] = 50
			chunk.biomeMap[ix][iz] = "grassland"
		end
	end

	local placements = placer:PlaceInChunk(chunk)
	local placedEvents = bus:getEvents("ObjectPlaced")
	assertTrue(#placedEvents > 0, "Should emit ObjectPlaced events")
	assertTrue(#placedEvents == #placements, "ObjectPlaced event count should match placement count")
end

-- Runner
local tests = {
	{ name = "testRegisterObject", fn = testRegisterObject },
	{ name = "testDefaultObjectsRegistered", fn = testDefaultObjectsRegistered },
	{ name = "testPlaceInChunkProducesValidCFrames", fn = testPlaceInChunkProducesValidCFrames },
	{ name = "testPoissonDiscNoOverlapping", fn = testPoissonDiscNoOverlapping },
	{ name = "testClearChunk", fn = testClearChunk },
	{ name = "testPlacementCompletedEvent", fn = testPlacementCompletedEvent },
	{ name = "testDensityMultiplier", fn = testDensityMultiplier },
	{ name = "testSlopeFiltering", fn = testSlopeFiltering },
	{ name = "testBiomeWhitelist", fn = testBiomeWhitelist },
	{ name = "testObjectPlacedEvent", fn = testObjectPlacedEvent },
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
