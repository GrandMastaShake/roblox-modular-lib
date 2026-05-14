--!strict
-- NoiseLib.lua
-- Classic Perlin noise with fractional Brownian motion (fBm).
-- Deterministic: same seed + coordinates always produce the same output.

local NoiseLib = {}
NoiseLib.__index = NoiseLib

export type NoiseConfig = {
	seed: number,
	octaves: number,
	persistence: number,
	lacunarity: number,
	scale: number,
}

export type NoiseLib = {
	Get2D: (self: NoiseLib, x: number, z: number) -> number,
	Get3D: (self: NoiseLib, x: number, y: number, z: number) -> number,
	Get2DRange: (self: NoiseLib, x: number, z: number, min: number, max: number) -> number,
	SetSeed: (self: NoiseLib, seed: number) -> (),
	GetConfig: (self: NoiseLib) -> NoiseConfig,
}

local DEFAULT_CONFIG: NoiseConfig = {
	seed = 12345,
	octaves = 6,
	persistence = 0.5,
	lacunarity = 2.0,
	scale = 100,
}

-- Standard Perlin permutation table (0-255, duplicated to 512 for safe indexing)
local PERM = {
	151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
	140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
	247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
	57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
	74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
	60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
	65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
	200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
	52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
	207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
	119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
	129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
	218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
	81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
	184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
	222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
}

-- Build 512-entry permutation lookup
local _perm512: { number } = {}
for i = 0, 511 do
	_perm512[i] = PERM[(i % 256) + 1]
end

-- Gradient vectors for 2D (12 gradient directions)
local GRAD2 = {
	{ 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 },
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 },
}

-- Gradient vectors for 3D
local GRAD3 = {
	{ 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 },
	{ 1, 0, 1 }, { -1, 0, 1 }, { 1, 0, -1 }, { -1, 0, -1 },
	{ 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 },
}

-- Fade function: 6t^5 - 15t^4 + 10t^3
local function _fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

-- Linear interpolation
local function _lerp(a: number, b: number, t: number): number
	return a + t * (b - a)
end

-- Hash function: deterministic based on seed + coordinates
local function _hash(seed: number, x: number, y: number, z: number?): number
	local h = seed
	h = bit32.bxor(h * 374761393 + bit32.lround(x * 1271), bit32.lround(y * 2819))
	if z then
		h = bit32.bxor(h, bit32.lround(z * 4513))
	end
	h = bit32.band(h * 668265263 + 2147483647, 0x7FFFFFFF)
	return h
end

-- Get gradient index from hash
local function _gradIndex(hash: number): number
	return (hash % 12) + 1
end

-- 2D dot product with gradient
local function _dot2(gx: number, gy: number, x: number, y: number): number
	return gx * x + gy * y
end

-- 3D dot product with gradient
local function _dot3(gx: number, gy: number, gz: number, x: number, y: number, z: number): number
	return gx * x + gy * y + gz * z
end

-- Classic Perlin noise 2D
local function _perlin2D(seed: number, x: number, y: number): number
	-- Offset by seed-derived value to make different seeds produce different patterns
	local sx = x + seed * 0.001
	local sy = y + seed * 0.002

	local xi = math.floor(sx) % 256
	local yi = math.floor(sy) % 256

	local xf = sx - math.floor(sx)
	local yf = sy - math.floor(sy)

	local u = _fade(xf)
	local v = _fade(yf)

	-- Get permutation values for corners
	local aa = _perm512[_perm512[xi] + yi]
	local ab = _perm512[_perm512[xi] + yi + 1]
	local ba = _perm512[_perm512[xi + 1] + yi]
	local bb = _perm512[_perm512[xi + 1] + yi + 1]

	-- Gradient vectors for each corner
	local g1 = GRAD2[_gradIndex(aa)]
	local g2 = GRAD2[_gradIndex(ab)]
	local g3 = GRAD2[_gradIndex(ba)]
	local g4 = GRAD2[_gradIndex(bb)]

	-- Dot products
	local d1 = _dot2(g1[1], g1[2], xf, yf)
	local d2 = _dot2(g2[1], g2[2], xf, yf - 1)
	local d3 = _dot2(g3[1], g3[2], xf - 1, yf)
	local d4 = _dot2(g4[1], g4[2], xf - 1, yf - 1)

	-- Interpolate
	local x1 = _lerp(d1, d3, u)
	local x2 = _lerp(d2, d4, u)
	local result = _lerp(x1, x2, v)

	-- Normalize from approximately -1..1 to exactly -1..1
	return math.clamp(result, -1, 1)
end

-- Classic Perlin noise 3D
local function _perlin3D(seed: number, x: number, y: number, z: number): number
	local sx = x + seed * 0.001
	local sy = y + seed * 0.002
	local sz = z + seed * 0.003

	local xi = math.floor(sx) % 256
	local yi = math.floor(sy) % 256
	local zi = math.floor(sz) % 256

	local xf = sx - math.floor(sx)
	local yf = sy - math.floor(sy)
	local zf = sz - math.floor(sz)

	local u = _fade(xf)
	local v = _fade(yf)
	local w = _fade(zf)

	-- Permutation values for all 8 corners
	local aaa = _perm512[_perm512[_perm512[xi] + yi] + zi]
	local aba = _perm512[_perm512[_perm512[xi] + yi + 1] + zi]
	local aab = _perm512[_perm512[_perm512[xi] + yi] + zi + 1]
	local abb = _perm512[_perm512[_perm512[xi] + yi + 1] + zi + 1]
	local baa = _perm512[_perm512[_perm512[xi + 1] + yi] + zi]
	local bba = _perm512[_perm512[_perm512[xi + 1] + yi + 1] + zi]
	local bab = _perm512[_perm512[_perm512[xi + 1] + yi] + zi + 1]
	local bbb = _perm512[_perm512[_perm512[xi + 1] + yi + 1] + zi + 1]

	-- Gradients
	local g1 = GRAD3[_gradIndex(aaa)]
	local g2 = GRAD3[_gradIndex(aba)]
	local g3 = GRAD3[_gradIndex(aab)]
	local g4 = GRAD3[_gradIndex(abb)]
	local g5 = GRAD3[_gradIndex(baa)]
	local g6 = GRAD3[_gradIndex(bba)]
	local g7 = GRAD3[_gradIndex(bab)]
	local g8 = GRAD3[_gradIndex(bbb)]

	-- Dot products
	local d1 = _dot3(g1[1], g1[2], g1[3], xf, yf, zf)
	local d2 = _dot3(g2[1], g2[2], g2[3], xf, yf - 1, zf)
	local d3 = _dot3(g3[1], g3[2], g3[3], xf, yf, zf - 1)
	local d4 = _dot3(g4[1], g4[2], g4[3], xf, yf - 1, zf - 1)
	local d5 = _dot3(g5[1], g5[2], g5[3], xf - 1, yf, zf)
	local d6 = _dot3(g6[1], g6[2], g6[3], xf - 1, yf - 1, zf)
	local d7 = _dot3(g7[1], g7[2], g7[3], xf - 1, yf, zf - 1)
	local d8 = _dot3(g8[1], g8[2], g8[3], xf - 1, yf - 1, zf - 1)

	-- Trilinear interpolation
	local x1 = _lerp(d1, d5, u)
	local x2 = _lerp(d2, d6, u)
	local x3 = _lerp(d3, d7, u)
	local x4 = _lerp(d4, d8, u)

	local y1 = _lerp(x1, x2, v)
	local y2 = _lerp(x3, x4, v)

	return math.clamp(_lerp(y1, y2, w), -1, 1)
end

-- Fractional Brownian Motion: sum multiple octaves of noise
local function _fbm2D(
	seed: number,
	x: number,
	z: number,
	octaves: number,
	persistence: number,
	lacunarity: number
): number
	local total = 0
	local amplitude = 1
	local frequency = 1
	local maxValue = 0 -- Normalization factor

	for _ = 1, octaves do
		total += _perlin2D(seed, x * frequency, z * frequency) * amplitude
		maxValue += amplitude
		amplitude *= persistence
		frequency *= lacunarity
	end

	if maxValue > 0 then
		total /= maxValue
	end

	return math.clamp(total, -1, 1)
end

local function _fbm3D(
	seed: number,
	x: number,
	y: number,
	z: number,
	octaves: number,
	persistence: number,
	lacunarity: number
): number
	local total = 0
	local amplitude = 1
	local frequency = 1
	local maxValue = 0

	for _ = 1, octaves do
		total += _perlin3D(seed, x * frequency, y * frequency, z * frequency) * amplitude
		maxValue += amplitude
		amplitude *= persistence
		frequency *= lacunarity
	end

	if maxValue > 0 then
		total /= maxValue
	end

	return math.clamp(total, -1, 1)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function NoiseLib.new(config: NoiseConfig?): NoiseLib
	local self = setmetatable({}, NoiseLib)
	local cfg = config or table.clone(DEFAULT_CONFIG)
	self._config = {
		seed = cfg.seed or DEFAULT_CONFIG.seed,
		octaves = cfg.octaves or DEFAULT_CONFIG.octaves,
		persistence = cfg.persistence or DEFAULT_CONFIG.persistence,
		lacunarity = cfg.lacunarity or DEFAULT_CONFIG.lacunarity,
		scale = cfg.scale or DEFAULT_CONFIG.scale,
	}
	return self
end

function NoiseLib:Get2D(x: number, z: number): number
	local cfg = self._config
	local nx = x / cfg.scale
	local nz = z / cfg.scale
	return _fbm2D(cfg.seed, nx, nz, cfg.octaves, cfg.persistence, cfg.lacunarity)
end

function NoiseLib:Get3D(x: number, y: number, z: number): number
	local cfg = self._config
	local nx = x / cfg.scale
	local ny = y / cfg.scale
	local nz = z / cfg.scale
	return _fbm3D(cfg.seed, nx, ny, nz, cfg.octaves, cfg.persistence, cfg.lacunarity)
end

function NoiseLib:Get2DRange(x: number, z: number, min: number, max: number): number
	local n = self:Get2D(x, z)
	-- Map -1..1 to min..max
	local t = (n + 1) / 2 -- 0..1
	return min + t * (max - min)
end

function NoiseLib:SetSeed(seed: number): ()
	self._config.seed = seed
end

function NoiseLib:GetConfig(): NoiseConfig
	return table.clone(self._config)
end

return NoiseLib
