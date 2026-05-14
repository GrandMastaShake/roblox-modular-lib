--!strict
-- CaveSystem.lua
-- 3D noise cave tunnel networks for procedural terrain.

local EventBus = require(script.Parent.Core.EventBus)

local CaveSystem = {}
CaveSystem.__index = CaveSystem

export type CaveConfig = {
 frequency: number,
 threshold: number,
 minY: number,
 maxY: number,
 tunnelWidth: number,
}

export type CaveSystem = {
 CarveChunk: (self: CaveSystem, chunk: any) -> any,
 IsCaveAt: (self: CaveSystem, x: number, y: number, z: number) -> boolean,
 SetConfig: (self: CaveSystem, config: CaveConfig) -> (),

 _eventBus: EventBus.EventBus,
 _seed: number,
 _config: CaveConfig,
 _noisePerm: { number },
}

-- Permutation table for Perlin noise
local function makePermutation(seed: number): { number }
 local perm: { number } = {}
 for i = 0, 255 do
  perm[i + 1] = i
 end

 -- Shuffle with seed
 local rng = Random.new(seed)
 for i = 256, 2, -1 do
  local j = rng:NextInteger(1, i)
  perm[i], perm[j] = perm[j], perm[i]
 end

 -- Duplicate for overflow wrapping
 for i = 1, 256 do
  perm[256 + i] = perm[i]
 end

 return perm
end

-- Gradient vectors for 3D
local grad3: { { number } } = {
 { 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 },
 { 1, 0, 1 }, { -1, 0, 1 }, { 1, 0, -1 }, { -1, 0, -1 },
 { 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 },
}

-- Dot product helper
local function dot(g: { number }, x: number, y: number, z: number): number
 return g[1] * x + g[2] * y + g[3] * z
end

-- Fade function: 6t^5 - 15t^4 + 10t^3
local function fade(t: number): number
 return t * t * t * (t * (t * 6 - 15) + 10)
end

-- Linear interpolation
local function lerp(a: number, b: number, t: number): number
 return a + t * (b - a)
end

-- 3D Perlin noise: returns value in range [-1, 1]
local function perlin3D(
 x: number,
 y: number,
 z: number,
 perm: { number }
): number
 local xi = math.floor(x) % 256
 local yi = math.floor(y) % 256
 local zi = math.floor(z) % 256

 local xf = x - math.floor(x)
 local yf = y - math.floor(y)
 local zf = z - math.floor(z)

 local u = fade(xf)
 local v = fade(yf)
 local w = fade(zf)

 -- Hash coordinates of the 8 cube corners
 local p = perm
 local function hash(ix: number, iy: number, iz: number): number
  return p[p[p[ix + 1] + 1 + iy] + 1 + iz] % 12 + 1
 end

 -- Gradient values at each corner
 local aaa = dot(grad3[hash(xi, yi, zi)], xf, yf, zf)
 local aba = dot(grad3[hash(xi, yi + 1, zi)], xf, yf - 1, zf)
 local aab = dot(grad3[hash(xi, yi, zi + 1)], xf, yf, zf - 1)
 local abb = dot(grad3[hash(xi, yi + 1, zi + 1)], xf, yf - 1, zf - 1)
 local baa = dot(grad3[hash(xi + 1, yi, zi)], xf - 1, yf, zf)
 local bba = dot(grad3[hash(xi + 1, yi + 1, zi)], xf - 1, yf - 1, zf)
 local bab = dot(grad3[hash(xi + 1, yi, zi + 1)], xf - 1, yf, zf - 1)
 local bbb = dot(grad3[hash(xi + 1, yi + 1, zi + 1)], xf - 1, yf - 1, zf - 1)

 -- Interpolate along x
 local x1 = lerp(aaa, baa, u)
 local x2 = lerp(aba, bba, u)
 local x3 = lerp(aab, bab, u)
 local x4 = lerp(abb, bbb, u)

 -- Interpolate along y
 local y1 = lerp(x1, x2, v)
 local y2 = lerp(x3, x4, v)

 -- Interpolate along z
 return lerp(y1, y2, w)
end

-- Fractal Brownian Motion for 3D noise
local function fbm3D(
 x: number,
 y: number,
 z: number,
 perm: { number },
 octaves: number,
 persistence: number,
 lacunarity: number
): number
 local total = 0
 local amplitude = 1
 local frequency = 1
 local maxValue = 0

 for _ = 1, octaves do
  total += perlin3D(x * frequency, y * frequency, z * frequency, perm) * amplitude
  maxValue += amplitude
  amplitude *= persistence
  frequency *= lacunarity
 end

 return total / maxValue
end

function CaveSystem.new(eventBus: EventBus.EventBus, seed: number?): CaveSystem
 local self = setmetatable({}, CaveSystem) :: CaveSystem
 self._eventBus = eventBus
 self._seed = seed or math.random(1, 100000)
 self._config = {
  frequency = 0.03,
  threshold = 0.35,
  minY = -50,
  maxY = 100,
  tunnelWidth = 3,
 }
 self._noisePerm = makePermutation(self._seed)
 return self
end

function CaveSystem:SetConfig(config: CaveConfig): ()
 self._config = {
  frequency = config.frequency or self._config.frequency,
  threshold = config.threshold or self._config.threshold,
  minY = config.minY or self._config.minY,
  maxY = config.maxY or self._config.maxY,
  tunnelWidth = config.tunnelWidth or self._config.tunnelWidth,
 }
end

-- Compute 3D noise value at a point (normalized to 0..1 range)
function CaveSystem:_noise3D(x: number, y: number, z: number): number
 local f = self._config.frequency
 local raw = fbm3D(
  x * f, y * f, z * f,
  self._noisePerm,
  3,    -- octaves
  0.5,  -- persistence
  2.0   -- lacunarity
 )

 -- Normalize from [-1, 1] to [0, 1]
 return (raw + 1) * 0.5
end

-- Check if a world point is inside a cave tunnel
function CaveSystem:IsCaveAt(x: number, y: number, z: number): boolean
 -- Only check within cave Y range
 if y < self._config.minY or y > self._config.maxY then
  return false
 end

 local noiseValue = self:_noise3D(x, y, z)
 return noiseValue < self._config.threshold
end

--[[
 CarveChunk(chunk):
 1. Iterate all underground voxels in the chunk (y from minY to surfaceY at each x,z)
 2. Apply 3D noise threshold test
 3. Carve valid tunnel voxels
 4. Detect cave entrances where caves intersect the surface
 5. Emit CaveEntranceFound for each entrance found
 6. Return modified chunk
--]]
function CaveSystem:CarveChunk(chunk: any): any
 if not chunk then
  warn("[CaveSystem] CarveChunk: nil chunk")
  return chunk
 end

 local cx = chunk.cx or 0
 local cz = chunk.cz or 0
 local size = chunk.size or 64
 local surfaceY = chunk.surfaceY
 local heightmap = chunk.heightmap

 -- Build surfaceY from heightmap if not provided
 if not surfaceY and heightmap then
  surfaceY = {}
  for x = 1, size do
   surfaceY[x] = {}
   for z = 1, size do
    surfaceY[x][z] = heightmap[x][z]
   end
  end
 end

 if not surfaceY then
  warn("[CaveSystem] CarveChunk: no surfaceY or heightmap in chunk")
  return chunk
 end

 -- Track carved voxels and entrances
 local carvedCount = 0
 local entrances: { { x: number, y: number, z: number } } = {}
 local chunkOriginX = cx * size
 local chunkOriginZ = cz * size

 -- 1. Iterate underground voxels
 for lx = 1, size do
  for lz = 1, size do
   local surfY = surfaceY[lx] and surfaceY[lx][lz]
   if not surfY then
    continue
   end

   local worldX = chunkOriginX + lx
   local worldZ = chunkOriginZ + lz

   -- Check from minY up to surface for this column
   local checkMinY = math.max(self._config.minY, surfY - 80)
   local checkMaxY = math.min(self._config.maxY, surfY - 2)

   for y = math.floor(checkMinY), math.floor(checkMaxY) do
    -- 2. Apply 3D noise threshold test
    local noiseValue = self:_noise3D(worldX, y, worldZ)

    if noiseValue < self._config.threshold then
     -- 3. Carve valid tunnel voxels
     carvedCount += 1

     -- Mark in heightmap if present (set to "air" sentinel)
     if heightmap and heightmap[lx] then
      -- Store cave carve info in a caves table on the chunk
      if not chunk.caves then
       chunk.caves = {}
      end
      if not chunk.caves[lx] then
       chunk.caves[lx] = {}
      end
      if not chunk.caves[lx][lz] then
       chunk.caves[lx][lz] = {}
      end
      table.insert(chunk.caves[lx][lz], y)
     end
    end
   end

   -- 4. Detect cave entrances: check if cave intersects surface
   local surfaceNoise = self:_noise3D(worldX, surfY, worldZ)
   local justBelowNoise = self:_noise3D(worldX, surfY - 2, worldZ)

   if surfaceNoise >= self._config.threshold and justBelowNoise < self._config.threshold then
    -- Cave entrance found at surface
    table.insert(entrances, {
     x = worldX,
     y = surfY,
     z = worldZ,
    })
   end
  end
 end

 -- 5. Emit entrance events
 for _, entrance in ipairs(entrances) do
  self._eventBus:Emit("CaveEntranceFound", {
   chunk = { cx = cx, cz = cz },
   entrance = entrance,
  })
 end

 -- 6. Emit completion and return modified chunk
 self._eventBus:Emit("CavesCarved", {
  chunk = { cx = cx, cz = cz },
  carvedCount = carvedCount,
  entranceCount = #entrances,
 })

 return chunk
end

return CaveSystem
