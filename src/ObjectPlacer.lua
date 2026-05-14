--!strict
-- ObjectPlacer.lua
-- Scatter trees, rocks, foliage on terrain using Poisson disc sampling.

local EventBus = require(script.Parent.Core.EventBus)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

export type ObjectDef = {
	id: string,
	name: string,
	category: "tree" | "rock" | "flower" | "bush" | "grass" | "structure",
	modelId: string,
	scaleRange: { min: number, max: number },
	slopeMax: number,
	altitudeMin: number,
	altitudeMax: number,
	biomeWhitelist: { string }?,
	collision: boolean,
}

export type Placement = {
	objectId: string,
	cframe: CFrame,
	scale: number,
}

export type ChunkData = {
	cx: number,
	cz: number,
	heightmap: { { number } },
	surfaceY: { { number } },
	biomeMap: { { string } },
}

export type ObjectPlacer = {
	RegisterObject: (self: ObjectPlacer, def: ObjectDef) -> (),
	PlaceInChunk: (self: ObjectPlacer, chunk: ChunkData, densityMultiplier: number?) -> { Placement },
	ClearChunk: (self: ObjectPlacer, cx: number, cz: number) -> (),
	GetPlacementCount: (self: ObjectPlacer) -> number,
	SetDensityMultiplier: (self: ObjectPlacer, multiplier: number) -> (),

	-- private
	_eventBus: any,
	_objects: { [string]: ObjectDef },
	_objectList: { ObjectDef },
	_densityMultiplier: number,
	_placementsByChunk: { [string]: { Placement } },
	_totalPlacements: number,
}

-- ---------------------------------------------------------------------------
-- Poisson disc sampling helpers
-- ---------------------------------------------------------------------------

local RNG = Random.new()

-- Seeded random for deterministic placement (optional reproducibility)
local function seededRandom(seed: number): number
	return math.abs(math.sin(seed * 127.1 + 311.7) * 43758.5453) % 1
end

-- Compute slope from heightmap finite differences at position (ix, iz)
local function computeSlope(heightmap: { { number } }, ix: number, iz: number, size: number): number
	local h = heightmap[ix][iz]
	local dx = 0
	local dz = 0

	if ix > 1 and ix < size then
		dx = math.abs(heightmap[ix + 1][iz] - heightmap[ix - 1][iz]) / 2
	elseif ix > 1 then
		dx = math.abs(h - heightmap[ix - 1][iz])
	elseif ix < size then
		dx = math.abs(heightmap[ix + 1][iz] - h)
	end

	if iz > 1 and iz < size then
		dz = math.abs(heightmap[ix][iz + 1] - heightmap[ix][iz - 1]) / 2
	elseif iz > 1 then
		dz = math.abs(h - heightmap[ix][iz - 1])
	elseif iz < size then
		dz = math.abs(heightmap[ix][iz + 1] - h)
	end

	-- Slope as tan of angle: 0 = flat, 1 ≈ 45°, inf = vertical
	local slope = math.sqrt(dx * dx + dz * dz)
	return slope
end

-- Convert chunk-local grid index to world offset in studs
-- (assumes 4 studs per grid cell, matching TerrainGenerator)
local GRID_TO_STUDS = 4

local function gridToStuds(cx: number, cz: number, ix: number, iz: number, size: number): (number, number)
	local worldX = cx * size * GRID_TO_STUDS + (ix - 1) * GRID_TO_STUDS
	local worldZ = cz * size * GRID_TO_STUDS + (iz - 1) * GRID_TO_STUDS
	return worldX, worldZ
end

-- Poisson disc sampling: generate candidate positions with minimum radius
local function poissonDiscSamples(
	size: number,
	minRadius: number,
	maxAttempts: number,
	targetCount: number
): { { x: number, z: number } }
	local points = {} :: { { x: number, z: number } }
	local active = {} :: { { x: number, z: number } }

	-- First point: center of chunk
	local first = { x = size / 2, z = size / 2 }
	table.insert(points, first)
	table.insert(active, first)

	while #active > 0 and #points < targetCount do
		-- Pick random active point
		local idx = RNG:NextInteger(1, #active)
		local center = active[idx]
		local placed = false

		for _ = 1, maxAttempts do
			-- Random angle and radius between minRadius and 2*minRadius
			local angle = RNG:NextNumber(0, math.pi * 2)
			local r = minRadius + RNG:NextNumber(0, minRadius)
			local px = center.x + r * math.cos(angle)
			local pz = center.z + r * math.sin(angle)

			-- Bounds check
			if px >= 1 and px <= size and pz >= 1 and pz <= size then
				-- Check against all existing points
				local tooClose = false
				for _, p in ipairs(points) do
					local d = math.sqrt((px - p.x) ^ 2 + (pz - p.z) ^ 2)
					if d < minRadius then
						tooClose = true
						break
					end
				end

				if not tooClose then
					local newPoint = { x = px, z = pz }
					table.insert(points, newPoint)
					table.insert(active, newPoint)
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

-- ---------------------------------------------------------------------------
-- ObjectPlacer
-- ---------------------------------------------------------------------------

local ObjectPlacer = {}
ObjectPlacer.__index = ObjectPlacer

function ObjectPlacer.new(eventBus: any): ObjectPlacer
	local self = setmetatable({}, ObjectPlacer)

	self._eventBus = eventBus
	self._objects = {} :: { [string]: ObjectDef }
	self._objectList = {} :: { ObjectDef }
	self._densityMultiplier = 1.0
	self._placementsByChunk = {} :: { [string]: { Placement } }
	self._totalPlacements = 0

	self:_registerDefaultObjects()

	return self
end

function ObjectPlacer:_registerDefaultObjects()
	-- PineTree: cold biomes
	self:RegisterObject({
		id = "PineTree",
		name = "Pine Tree",
		category = "tree",
		modelId = "rbxassetid://PineTree001",
		scaleRange = { min = 0.8, max = 1.5 },
		slopeMax = 0.6,
		altitudeMin = 0,
		altitudeMax = 200,
		biomeWhitelist = { "taiga", "tundra", "mountains" },
		collision = true,
	} :: ObjectDef)

	-- OakTree: temperate
	self:RegisterObject({
		id = "OakTree",
		name = "Oak Tree",
		category = "tree",
		modelId = "rbxassetid://OakTree001",
		scaleRange = { min = 0.9, max = 1.4 },
		slopeMax = 0.5,
		altitudeMin = 0,
		altitudeMax = 180,
		biomeWhitelist = { "temperate_forest", "grassland" },
		collision = true,
	} :: ObjectDef)

	-- PalmTree: tropical
	self:RegisterObject({
		id = "PalmTree",
		name = "Palm Tree",
		category = "tree",
		modelId = "rbxassetid://PalmTree001",
		scaleRange = { min = 0.9, max = 1.3 },
		slopeMax = 0.4,
		altitudeMin = 0,
		altitudeMax = 80,
		biomeWhitelist = { "tropical_rainforest", "savanna", "ocean" },
		collision = true,
	} :: ObjectDef)

	-- Rock_Large: universal
	self:RegisterObject({
		id = "Rock_Large",
		name = "Large Rock",
		category = "rock",
		modelId = "rbxassetid://RockLarge001",
		scaleRange = { min = 1.0, max = 2.5 },
		slopeMax = 1.2, -- rocks can be on steeper slopes
		altitudeMin = 0,
		altitudeMax = 300,
		biomeWhitelist = nil, -- all biomes
		collision = true,
	} :: ObjectDef)

	-- Rock_Small: universal
	self:RegisterObject({
		id = "Rock_Small",
		name = "Small Rock",
		category = "rock",
		modelId = "rbxassetid://RockSmall001",
		scaleRange = { min = 0.3, max = 0.8 },
		slopeMax = 1.5,
		altitudeMin = 0,
		altitudeMax = 300,
		biomeWhitelist = nil,
		collision = false,
	} :: ObjectDef)

	-- Bush
	self:RegisterObject({
		id = "Bush",
		name = "Bush",
		category = "bush",
		modelId = "rbxassetid://Bush001",
		scaleRange = { min = 0.5, max = 1.0 },
		slopeMax = 0.5,
		altitudeMin = 0,
		altitudeMax = 200,
		biomeWhitelist = { "temperate_forest", "grassland", "savanna", "taiga" },
		collision = false,
	} :: ObjectDef)

	-- Flower_Red
	self:RegisterObject({
		id = "Flower_Red",
		name = "Red Flower",
		category = "flower",
		modelId = "rbxassetid://FlowerRed001",
		scaleRange = { min = 0.4, max = 0.8 },
		slopeMax = 0.3,
		altitudeMin = 0,
		altitudeMax = 150,
		biomeWhitelist = { "temperate_forest", "grassland", "tropical_rainforest", "tundra" },
		collision = false,
	} :: ObjectDef)

	-- Flower_Yellow
	self:RegisterObject({
		id = "Flower_Yellow",
		name = "Yellow Flower",
		category = "flower",
		modelId = "rbxassetid://FlowerYellow001",
		scaleRange = { min = 0.4, max = 0.8 },
		slopeMax = 0.3,
		altitudeMin = 0,
		altitudeMax = 150,
		biomeWhitelist = { "grassland", "savanna", "temperate_forest" },
		collision = false,
	} :: ObjectDef)

	-- Grass_Clump
	self:RegisterObject({
		id = "Grass_Clump",
		name = "Grass Clump",
		category = "grass",
		modelId = "rbxassetid://GrassClump001",
		scaleRange = { min = 0.5, max = 1.2 },
		slopeMax = 0.7,
		altitudeMin = 0,
		altitudeMax = 200,
		biomeWhitelist = nil,
		collision = false,
	} :: ObjectDef)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ObjectPlacer:RegisterObject(def: ObjectDef)
	if self._objects[def.id] then
		warn("[ObjectPlacer] Overwriting existing object: " .. def.id)
	end
	self._objects[def.id] = def
	-- Update ordered list
	self._objectList = {}
	for _, obj in pairs(self._objects) do
		table.insert(self._objectList, obj)
	end
end

function ObjectPlacer:PlaceInChunk(chunk: ChunkData, densityMultiplier: number?): { Placement }
	local multiplier = densityMultiplier or self._densityMultiplier
	local size = #chunk.heightmap
	local biomeId = chunk.biomeMap and chunk.biomeMap[1] and chunk.biomeMap[1][1] or "grassland"
	local placements = {} :: { Placement }
	local chunkKey = chunk.cx .. "," .. chunk.cz

	for _, objDef in ipairs(self._objectList) do
		-- Check biome whitelist
		if objDef.biomeWhitelist then
			local allowed = false
			for _, bid in ipairs(objDef.biomeWhitelist) do
				if bid == biomeId then
					allowed = true
					break
				end
			end
			if not allowed then
				continue
			end
		end

		-- Compute how many of this object to place based on biome density
		local density = self:_getBiomeDensity(biomeId, objDef.category)
		local adjustedDensity = density * multiplier
		if adjustedDensity <= 0 then
			continue
		end

		-- Target count based on chunk area and density
		local chunkArea = size * size
		local targetCount = math.floor(chunkArea * adjustedDensity / 100)
		if targetCount < 1 then
			continue
		end

		-- Poisson disc sampling for this object type
		local minRadius = self:_getMinRadius(objDef.category)
		local candidates = poissonDiscSamples(size, minRadius, 30, targetCount)

		for _, candidate in ipairs(candidates) do
			local ix = math.clamp(math.round(candidate.x), 1, size)
			local iz = math.clamp(math.round(candidate.z), 1, size)

			local height = chunk.heightmap[ix] and chunk.heightmap[ix][iz]
			if not height then
				continue
			end

			-- Slope check
			local slope = computeSlope(chunk.heightmap, ix, iz, size)
			if slope > objDef.slopeMax then
				continue
			end

			-- Altitude check
			if height < objDef.altitudeMin or height > objDef.altitudeMax then
				continue
			end

			-- Scale randomization
			local scale = objDef.scaleRange.min
				+ RNG:NextNumber(0, 1) * (objDef.scaleRange.max - objDef.scaleRange.min)

			-- Orientation: random Y-rotation
			local angleY = RNG:NextNumber(0, math.pi * 2)
			local worldX, worldZ = gridToStuds(chunk.cx, chunk.cz, ix, iz, size)

			-- Slight tilt to match terrain (optional)
			local tiltX = RNG:NextNumber(-0.1, 0.1)
			local tiltZ = RNG:NextNumber(-0.1, 0.1)

			local cframe = CFrame.new(worldX, height, worldZ)
				* CFrame.Angles(tiltX, angleY, tiltZ)

			local placement: Placement = {
				objectId = objDef.id,
				cframe = cframe,
				scale = scale,
			}

			table.insert(placements, placement)
			self._eventBus:Emit("ObjectPlaced", {
				placement = placement,
				chunkCx = chunk.cx,
				chunkCz = chunk.cz,
				objectDef = objDef,
			})
		end
	end

	-- Store placements for this chunk
	self._placementsByChunk[chunkKey] = placements
	self._totalPlacements += #placements

	self._eventBus:Emit("PlacementCompleted", {
		cx = chunk.cx,
		cz = chunk.cz,
		count = #placements,
		placements = placements,
	})

	return placements
end

function ObjectPlacer:ClearChunk(cx: number, cz: number)
	local chunkKey = cx .. "," .. cz
	local existing = self._placementsByChunk[chunkKey]
	if existing then
		self._totalPlacements -= #existing
		self._placementsByChunk[chunkKey] = nil
	end

	self._eventBus:Emit("ChunkCleared", {
		cx = cx,
		cz = cz,
		count = existing and #existing or 0,
	})
end

function ObjectPlacer:GetPlacementCount(): number
	return self._totalPlacements
end

function ObjectPlacer:SetDensityMultiplier(multiplier: number)
	self._densityMultiplier = math.clamp(multiplier, 0, 10)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function ObjectPlacer:_getBiomeDensity(biomeId: string, category: string): number
	-- Biome density lookup for object categories
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
	if biomeDensities then
		return biomeDensities[category] or 0.1
	end
	return 0.1
end

function ObjectPlacer:_getMinRadius(category: string): number
	-- Minimum spacing in grid cells between objects of same category
	local radii: { [string]: number } = {
		tree = 5,
		rock = 3,
		flower = 1.5,
		bush = 2.5,
		grass = 1,
		structure = 8,
	}
	return radii[category] or 3
end

return ObjectPlacer
