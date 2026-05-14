--!strict
-- WaterSystem.lua
-- River networks, lakes, and hydraulic erosion for procedural terrain.

local EventBus = require(script.Parent.Core.EventBus)

local WaterSystem = {}
WaterSystem.__index = WaterSystem

export type RiverNode = {
	x: number,
	z: number,
	y: number,
	flow: number,
	next: { RiverNode },
}

export type WaterSystem = {
	GenerateRivers: (self: WaterSystem, terrain: any) -> { RiverNode },
	CarveRiver: (self: WaterSystem, river: { RiverNode }) -> (),
	CreateLake: (self: WaterSystem, cx: number, cz: number, radius: number) -> (),
	ErodeTerrain: (self: WaterSystem, chunk: any, river: { RiverNode }) -> any,

	_eventBus: EventBus.EventBus,
	_seed: number,
	_rng: Random,
	_seaLevel: number,
	_maxRiverSteps: number,
	_numRiverSources: number,
}

-- Simple 2D noise for terrain height sampling when no generator provided
local function pseudoNoise2D(x: number, z: number, seed: number): number
 local n = math.sin(x * 12.9898 + z * 78.233 + seed * 43758.5453) * 43758.5453123
 return n - math.floor(n)
end

-- Smooth interpolated noise
local function smoothNoise2D(x: number, z: number, seed: number): number
 local ix, iz = math.floor(x), math.floor(z)
 local fx, fz = x - ix, z - iz

 -- Bilinear interpolation of 4 corners
 local n00 = pseudoNoise2D(ix, iz, seed)
 local n10 = pseudoNoise2D(ix + 1, iz, seed)
 local n01 = pseudoNoise2D(ix, iz + 1, seed)
 local n11 = pseudoNoise2D(ix + 1, iz + 1, seed)

 -- Smoothstep interpolation
 local sx = fx * fx * (3 - 2 * fx)
 local sz = fz * fz * (3 - 2 * fz)

 local nx0 = n00 + (n10 - n00) * sx
 local nx1 = n01 + (n11 - n01) * sx
 return nx0 + (nx1 - nx0) * sz
end

-- Fractal Brownian Motion for terrain-like height
local function fbm2D(x: number, z: number, seed: number, octaves: number): number
 local value = 0
 local amplitude = 1
 local frequency = 1
 local maxValue = 0

 for _ = 1, octaves do
  value += smoothNoise2D(x * frequency, z * frequency, seed) * amplitude
  maxValue += amplitude
  amplitude *= 0.5
  frequency *= 2
 end

 return value / maxValue
end

function WaterSystem.new(eventBus: EventBus.EventBus, seed: number?): WaterSystem
 local self = setmetatable({}, WaterSystem) :: WaterSystem
 self._eventBus = eventBus
 self._seed = seed or math.random(1, 100000)
 self._rng = Random.new(self._seed)
 self._seaLevel = 32
 self._maxRiverSteps = 200
 self._numRiverSources = 8
 return self
end

-- Sample height at world position. Uses terrain generator if available, else noise.
function WaterSystem:_sampleHeight(terrain: any, worldX: number, worldZ: number): number
 if terrain and terrain.GetHeightAt then
  local ok, h = pcall(function()
   return terrain:GetHeightAt(worldX, worldZ)
  end)
  if ok and typeof(h) == "number" then
   return h
  end
 end

 -- Fallback: procedural terrain from noise
 local h = fbm2D(worldX * 0.005, worldZ * 0.005, self._seed, 4)
 return math.floor(h * 128 + self._seaLevel)
end

-- Find the lowest neighbor in the 8-connected grid
function WaterSystem:_findLowestNeighbor(
 terrain: any,
 x: number,
 z: number,
 currentY: number
): (number, number, number)
 local bestX, bestZ, bestY = x, z, currentY
 local step = 4 -- sample every 4 studs

 for dx = -1, 1 do
  for dz = -1, 1 do
   if dx == 0 and dz == 0 then
    continue
   end
   local nx = x + dx * step
   local nz = z + dz * step
   local ny = self:_sampleHeight(terrain, nx, nz)

   if ny < bestY then
    bestX, bestZ, bestY = nx, nz, ny
   end
  end
 end

 return bestX, bestZ, bestY
end

--[[
 GenerateRivers(terrainGenerator)
 1. Sample random high points across the world
 2. From each high point, follow the terrain gradient downhill
 3. At each step: move to the lowest neighbor, accumulate flow volume
 4. Stop when reaching sea level or flat terrain
 5. Return list of river paths (each path is a list of RiverNode)
--]]
function WaterSystem:GenerateRivers(terrain: any): { RiverNode }
 local rivers: { RiverNode } = {}
 local worldSize = 512

 for _ = 1, self._numRiverSources do
  -- 1. Sample a random high point
  local startX = self._rng:NextInteger(-worldSize // 2, worldSize // 2)
  local startZ = self._rng:NextInteger(-worldSize // 2, worldSize // 2)
  local startY = self:_sampleHeight(terrain, startX, startZ)

  -- Ensure we start from a reasonably high point
  local attempts = 0
  while startY < self._seaLevel + 20 and attempts < 20 do
   startX = self._rng:NextInteger(-worldSize // 2, worldSize // 2)
   startZ = self._rng:NextInteger(-worldSize // 2, worldSize // 2)
   startY = self:_sampleHeight(terrain, startX, startZ)
   attempts += 1
  end

  if startY < self._seaLevel + 10 then
   continue -- couldn't find a high point
  end

  -- 2. Follow gradient downhill
  local path: { RiverNode } = {}
  local cx, cz, cy = startX, startZ, startY
  local flow = 1.0

  for step = 1, self._maxRiverSteps do
   -- Create river node
   local node: RiverNode = {
    x = cx,
    z = cz,
    y = cy,
    flow = flow,
    next = {},
   }

   if #path > 0 then
    table.insert(path[#path].next, node)
   end
   table.insert(path, node)

   -- 3. Find lowest neighbor
   local nx, nz, ny = self:_findLowestNeighbor(terrain, cx, cz, cy)

   -- 4. Stop conditions: reached sea level, flat terrain, or no downhill
   if ny <= self._seaLevel then
    break
   end
   if ny >= cy then
    break -- flat or uphill (local minimum)
   end
   if math.abs(cx - nx) < 0.001 and math.abs(cz - nz) < 0.001 then
    break -- no movement
   end

   -- Accumulate flow as tributaries join (simplified: grows with path)
   flow += 0.5

   cx, cz, cy = nx, nz, ny
  end

  if #path >= 3 then
   table.insert(rivers, path[1])
   self._eventBus:Emit("RiverGenerated", {
    source = { x = startX, z = startZ, y = startY },
    pathLength = #path,
    endPoint = { x = cx, z = cz, y = cy },
   })
  end
 end

 self._eventBus:Emit("RiverGenerated", {
  riverCount = #rivers,
  seed = self._seed,
 })

 return rivers
end

--[[
 CarveRiver(river): for each node in the river, carve a channel into the terrain.
 Channel width increases with flow volume.
--]]
function WaterSystem:CarveRiver(river: { RiverNode }): ()
 if #river == 0 then
  return
 end

 local terrain = workspace:FindFirstChildOfClass("Terrain")
 if not terrain then
  warn("[WaterSystem] No Terrain object found in workspace")
  return
 end

 for i, node in ipairs(river) do
  -- Channel width increases with flow
  local width = math.clamp(2 + node.flow * 0.5, 2, 12)
  local depth = math.clamp(1 + node.flow * 0.3, 1, 6)

  -- Carve a channel using FillBlock with Air
  local carveCFrame = CFrame.new(node.x, node.y - depth * 0.5, node.z)
  local carveSize = Vector3.new(width, depth, width)

  pcall(function()
   terrain:FillBlock(carveCFrame, carveSize, Enum.Material.Air)
  end)

  -- Link next nodes
  if node.next then
   for _, nextNode in ipairs(node.next) do
    -- Carve a connecting channel between this node and the next
    local midX = (node.x + nextNode.x) / 2
    local midZ = (node.z + nextNode.z) / 2
    local midY = (node.y + nextNode.y) / 2
    local dist = math.sqrt((nextNode.x - node.x) ^ 2 + (nextNode.z - node.z) ^ 2)
    local connWidth = math.clamp(width * 0.8, 2, 10)

    local connCFrame = CFrame.new(midX, midY - depth * 0.3, midZ)
    local connSize = Vector3.new(math.max(dist, connWidth), depth * 0.6, connWidth)

    pcall(function()
     terrain:FillBlock(connCFrame, connSize, Enum.Material.Air)
    end)
   end
  end
 end

 self._eventBus:Emit("RiverCarved", {
  nodeCount = #river,
  startPoint = { x = river[1].x, y = river[1].y, z = river[1].z },
 })
end

--[[
 CreateLake(cx, cz, radius): circular depression filled with water.
--]]
function WaterSystem:CreateLake(cx: number, cz: number, radius: number): ()
 local terrain = workspace:FindFirstChildOfClass("Terrain")
 if not terrain then
  warn("[WaterSystem] No Terrain object found in workspace")
  return
 end

 -- Create a depression
 local depth = math.clamp(radius * 0.3, 3, 15)
 local lakeCFrame = CFrame.new(cx, self._seaLevel - depth * 0.5, cz)
 local lakeSize = Vector3.new(radius * 2, depth, radius * 2)

 -- Carve the depression
 pcall(function()
  terrain:FillBlock(lakeCFrame, lakeSize, Enum.Material.Air)
 end)

 -- Fill with water material up to sea level
 local waterCFrame = CFrame.new(cx, self._seaLevel - 1, cz)
 local waterSize = Vector3.new(radius * 2 - 2, 2, radius * 2 - 2)

 pcall(function()
  terrain:FillBlock(waterCFrame, waterSize, Enum.Material.Water)
 end)

 self._eventBus:Emit("LakeCreated", {
  center = { x = cx, z = cz },
  radius = radius,
  seaLevel = self._seaLevel,
 })
end

--[[
 ErodeTerrain(chunk, river): apply hydraulic erosion along river path,
 deepening the channel in the heightmap.
--]]
function WaterSystem:ErodeTerrain(chunk: any, river: { RiverNode }): any
 if not chunk or not chunk.heightmap then
  warn("[WaterSystem] ErodeTerrain: invalid chunk")
  return chunk
 end

 local heightmap: { { number } } = chunk.heightmap
 local size = #heightmap

 for _, node in ipairs(river) do
  -- Convert world coords to chunk-local coords
  local chunkOriginX = chunk.cx * (chunk.size or 64)
  local chunkOriginZ = chunk.cz * (chunk.size or 64)
  local lx = math.floor(node.x - chunkOriginX + size / 2)
  local lz = math.floor(node.z - chunkOriginZ + size / 2)

  if lx >= 1 and lx <= size and lz >= 1 and lz <= size then
   -- Erode: deepen channel proportional to flow
   local erosionAmount = math.clamp(node.flow * 0.8, 0.5, 5)
   local newHeight = heightmap[lx][lz] - erosionAmount
   heightmap[lx][lz] = math.max(newHeight, self._seaLevel - 10)

   -- Erode neighbors (wider channel at higher flow)
   local erodeRadius = math.clamp(math.floor(node.flow * 0.4), 1, 3)
   for dx = -erodeRadius, erodeRadius do
    for dz = -erodeRadius, erodeRadius do
     local dist = math.sqrt(dx * dx + dz * dz)
     if dist <= erodeRadius then
      local nlx, nlz = lx + dx, lz + dz
      if nlx >= 1 and nlx <= size and nlz >= 1 and nlz <= size then
       local factor = 1 - dist / (erodeRadius + 1)
       local neighborErosion = erosionAmount * factor * 0.5
       heightmap[nlx][nlz] = math.max(
        heightmap[nlx][nlz] - neighborErosion,
        self._seaLevel - 10
       )
      end
     end
    end
   end
  end

  -- Process next nodes recursively
  if node.next then
   chunk = self:ErodeTerrain(chunk, node.next)
  end
 end

 return chunk
end

return WaterSystem
