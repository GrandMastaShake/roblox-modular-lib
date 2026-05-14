--!strict
-- ErosionSimulator.lua
-- Hydraulic and thermal erosion simulation on heightmap data.

export type ErosionConfig = {
	droplets: number,
	erosionRate: number,
	depositionRate: number,
	evaporationRate: number,
	gravity: number,
}

export type Heightmap = { { number } }

export type ErosionSimulator = {
	Erode: (self: ErosionSimulator, heightmap: Heightmap) -> Heightmap,
	ThermalErosion: (self: ErosionSimulator, heightmap: Heightmap, talusAngle: number) -> Heightmap,
	SetConfig: (self: ErosionSimulator, config: ErosionConfig) -> (),
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
	Once: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
}

local DEFAULT_CONFIG: ErosionConfig = {
	droplets = 50000,
	erosionRate = 0.05,
	depositionRate = 0.01,
	evaporationRate = 0.05,
	gravity = 4.0,
}

local ErosionSimulator = {}
ErosionSimulator.__index = ErosionSimulator

function ErosionSimulator.new(eventBus: EventBus, config: ErosionConfig?): ErosionSimulator
	local self = setmetatable({}, ErosionSimulator)
	self._eventBus = eventBus
	self._config = self:_mergeConfig(config or {})
	return self
end

function ErosionSimulator:_mergeConfig(overrides: ErosionConfig): ErosionConfig
	local base = table.clone(DEFAULT_CONFIG)
	if overrides.droplets ~= nil then base.droplets = overrides.droplets end
	if overrides.erosionRate ~= nil then base.erosionRate = overrides.erosionRate end
	if overrides.depositionRate ~= nil then base.depositionRate = overrides.depositionRate end
	if overrides.evaporationRate ~= nil then base.evaporationRate = overrides.evaporationRate end
	if overrides.gravity ~= nil then base.gravity = overrides.gravity end
	return base
end

function ErosionSimulator:SetConfig(config: ErosionConfig)
	self._config = self:_mergeConfig(config)
end

-- Get height at position, with bilinear interpolation for sub-grid positions
function ErosionSimulator:_getInterpolatedHeight(
	hm: Heightmap,
	x: number,
	z: number,
	width: number,
	depth: number
): number
	local ix = math.clamp(math.floor(x), 1, width)
	local iz = math.clamp(math.floor(z), 1, depth)
	local fx = x - ix
	local fz = z - iz

	local x1 = math.min(ix + 1, width)
	local z1 = math.min(iz + 1, depth)

	local h00 = hm[ix][iz]
	local h10 = hm[x1][iz]
	local h01 = hm[ix][z1]
	local h11 = hm[x1][z1]

	return h00 * (1 - fx) * (1 - fz)
		+ h10 * fx * (1 - fz)
		+ h01 * (1 - fx) * fz
		+ h11 * fx * fz
end

-- Simple hash for pseudo-random numbers (deterministic)
local function _hash(x: number, y: number, seed: number): number
	local h = bit32.band(math.floor(x * 127.1 + y * 311.7 + seed * 17), 0x7FFFFFFF)
	return (h % 10000) / 10000
end

-- 4-neighbor offsets: right, left, down, up
local NEIGHBORS = {
	{ 1, 0 },
	{ -1, 0 },
	{ 0, 1 },
	{ 0, -1 },
}

-- 8-neighbor offsets (for thermal erosion, includes diagonals)
local NEIGHBORS_8 = {
	{ 1, 0 },
	{ -1, 0 },
	{ 0, 1 },
	{ 0, -1 },
	{ 1, 1 },
	{ -1, 1 },
	{ 1, -1 },
	{ -1, -1 },
}

--------------------------------------------------------------------------------
-- Hydraulic Erosion
--------------------------------------------------------------------------------

function ErosionSimulator:Erode(heightmap: Heightmap): Heightmap
	local cfg = self._config
	local droplets = cfg.droplets
	local erosionRate = cfg.erosionRate
	local depositionRate = cfg.depositionRate
	local evaporationRate = cfg.evaporationRate
	local gravity = cfg.gravity

	local width = #heightmap
	if width == 0 then
		return heightmap
	end
	local depth = #heightmap[1]

	-- Deep copy the heightmap to avoid mutating input
	local hm: Heightmap = {}
	for x = 1, width do
		hm[x] = table.clone(heightmap[x])
	end

	-- Seed for deterministic droplet placement
	local dropletSeed = 42

	for i = 1, droplets do
		-- Random starting position (deterministic based on droplet index)
		local px = 2 + (_hash(i * 1.618, 0, dropletSeed) * (width - 3))
		local pz = 2 + (_hash(0, i * 2.414, dropletSeed) * (depth - 3))

		-- Droplet state
		local dirX = 0
		local dirZ = 0
		local speed = 1.0
		local water = 1.0
		local sediment = 0.0

		-- Maximum path length per droplet
		local maxPathLength = 30

		for _ = 1, maxPathLength do
			local ix = math.clamp(math.floor(px + 0.5), 1, width)
			local iz = math.clamp(math.floor(pz + 0.5), 1, depth)
			local currentHeight = hm[ix][iz]

			-- Find lowest neighbor using bilinear gradient
			local gradX = 0.0
			local gradZ = 0.0

			if ix > 1 and ix < width then
				gradX = (hm[ix + 1][iz] - hm[ix - 1][iz]) / 2
			end
			if iz > 1 and iz < depth then
				gradZ = (hm[ix][iz + 1] - hm[ix][iz - 1]) / 2
			end

			-- Update direction with inertia
			local inertia = 0.5
			dirX = (dirX * inertia) - (gradX * (1 - inertia))
			dirZ = (dirZ * inertia) - (gradZ * (1 - inertia))

			-- Normalize direction
			local dirLen = math.sqrt(dirX * dirX + dirZ * dirZ)
			if dirLen > 0 then
				dirX /= dirLen
				dirZ /= dirLen
			end

			-- New position
			local newPx = px + dirX
			local newPz = pz + dirZ
			local newIx = math.clamp(math.floor(newPx + 0.5), 1, width)
			local newIz = math.clamp(math.floor(newPz + 0.5), 1, depth)

			-- Height difference (positive = downhill)
			local newHeight = hm[newIx][newIz]
			local heightDiff = currentHeight - newHeight

			-- If trapped in a flat area or pit, try random neighbors
			if heightDiff <= 0 then
				-- Check all 4 neighbors
				local bestDir = nil
				local bestDiff = 0
				for _, n in ipairs(NEIGHBORS) do
					local nx = math.clamp(ix + n[1], 1, width)
					local nz = math.clamp(iz + n[2], 1, depth)
					local diff = hm[ix][iz] - hm[nx][nz]
					if diff > bestDiff then
						bestDiff = diff
						bestDir = n
					end
				end

				if bestDir then
					newIx = math.clamp(ix + bestDir[1], 1, width)
					newIz = math.clamp(iz + bestDir[2], 1, depth)
					heightDiff = bestDiff
					newPx = px + bestDir[1]
					newPz = pz + bestDir[2]
				else
					-- In a local minimum - deposit remaining sediment
					if sediment > 0 then
						local depositAmount = sediment * 0.5
						hm[ix][iz] += depositAmount
						sediment -= depositAmount
					end
					break
				end
			end

			-- Capacity = proportional to speed * water * |slope|
			local slope = math.max(heightDiff, 0.01)
			local capacity = slope * speed * water * 2.0

			if sediment > capacity then
				-- Moving slow/full: deposit
				local depositAmount = (sediment - capacity) * depositionRate
				depositAmount = math.max(depositAmount, 0)
				hm[ix][iz] += depositAmount
				sediment -= depositAmount
			else
				-- Moving fast: erode
				local erodeAmount = math.min(
					(capacity - sediment) * erosionRate,
					heightDiff * 0.5  -- Don't erode more than half the height difference
				)
				erodeAmount = math.max(erodeAmount, 0)
				-- Distribute erosion to 3x3 neighborhood for smoother results
				local erodePerCell = erodeAmount / 9
				for dx = -1, 1 do
					for dz = -1, 1 do
						local ex = math.clamp(ix + dx, 1, width)
						local ez = math.clamp(iz + dz, 1, depth)
						hm[ex][ez] = math.max(0, hm[ex][ez] - erodePerCell)
					end
				end
				sediment += erodeAmount
			end

			-- Update position
			px = newPx
			pz = newPz

			-- Update speed using gravity
			speed = math.sqrt(speed * speed + heightDiff * gravity)
			speed = math.clamp(speed, 0.5, 5.0)

			-- Evaporation
			water *= (1 - evaporationRate)
			if water < 0.01 then
				-- Droplet evaporated - deposit remaining sediment
				local finalIx = math.clamp(math.floor(px + 0.5), 1, width)
				local finalIz = math.clamp(math.floor(pz + 0.5), 1, depth)
				hm[finalIx][finalIz] += sediment * 0.5
				break
			end
		end
	end

	self._eventBus:Emit("ErosionCompleted", { droplets = droplets, width = width, depth = depth })
	return hm
end

--------------------------------------------------------------------------------
-- Thermal Erosion
--------------------------------------------------------------------------------

function ErosionSimulator:ThermalErosion(heightmap: Heightmap, talusAngle: number): Heightmap
	local cfg = self._config
	local width = #heightmap
	if width == 0 then
		return heightmap
	end
	local depth = #heightmap[1]

	-- Deep copy
	local hm: Heightmap = {}
	for x = 1, width do
		hm[x] = table.clone(heightmap[x])
	end

	-- Number of iterations for thermal erosion
	local iterations = 10

	for _ = 1, iterations do
		for x = 2, width - 1 do
			for z = 2, depth - 1 do
				local h = hm[x][z]

				-- Find the neighbor with the maximum height difference
				local maxDiff = 0
				local maxNeighbor = nil

				for _, n in ipairs(NEIGHBORS_8) do
					local nx = x + n[1]
					local nz = z + n[2]
					if nx >= 1 and nx <= width and nz >= 1 and nz <= depth then
						local diff = h - hm[nx][nz]
						-- Diagonal neighbors have longer distance, so adjust threshold
						local dist = if n[1] ~= 0 and n[2] ~= 0 then math.sqrt(2) else 1
						local adjustedTalus = talusAngle * dist

						if diff > adjustedTalus and diff > maxDiff then
							maxDiff = diff
							maxNeighbor = n
						end
					end
				end

				-- If any neighbor exceeds the talus angle, transfer material
				if maxNeighbor then
					local nx = x + maxNeighbor[1]
					local nz = z + maxNeighbor[2]
					-- Transfer amount based on how much exceeds threshold
					local transferAmount = (maxDiff - talusAngle) * 0.25
					transferAmount = math.clamp(transferAmount, 0, maxDiff * 0.5)

					hm[x][z] -= transferAmount
					hm[nx][nz] += transferAmount
				end
			end
		end
	end

	self._eventBus:Emit("ThermalErosionCompleted", { talusAngle = talusAngle, width = width, depth = depth })
	return hm
end

return ErosionSimulator
