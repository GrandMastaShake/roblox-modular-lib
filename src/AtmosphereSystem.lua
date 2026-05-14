--!strict
-- AtmosphereSystem.lua
-- Per-biome lighting, fog, sky, and atmospheric transitions.

local EventBus = require(script.Parent.Core.EventBus)

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local AtmosphereSystem = {}
AtmosphereSystem.__index = AtmosphereSystem

export type LightingConfig = {
 ambient: Color3,
 outdoorAmbient: Color3,
 brightness: number,
 clockTime: number,
}

export type FogConfig = {
 start: number,
 ["end"]: number,
 color: Color3,
}

export type SkyConfig = {
 skyboxId: string?,
 celestialBodiesShown: boolean,
}

export type SoundscapeConfig = {
 daySounds: { string },
 nightSounds: { string },
}

export type AtmosphereConfig = {
 lighting: LightingConfig,
 fog: FogConfig,
 sky: SkyConfig,
 soundscape: SoundscapeConfig,
}

export type AtmosphereSystem = {
 RegisterBiomeAtmosphere: (self: AtmosphereSystem, biomeId: string, config: AtmosphereConfig) -> (),
 ApplyToRegion: (self: AtmosphereSystem, biomeId: string, region: Region3) -> (),
 ApplyToChunk: (self: AtmosphereSystem, chunk: any) -> (),
 TransitionAtmosphere: (self: AtmosphereSystem, fromBiome: string, toBiome: string, duration: number) -> (),

 _eventBus: EventBus.EventBus,
 _biomeAtmospheres: { [string]: AtmosphereConfig },
 _activeTweens: { Tween },
 _soundscapes: { [string]: Sound },
}

-- Default atmosphere configurations for 9 biomes
local DEFAULT_BIOME_ATMOSPHERES: { [string]: AtmosphereConfig } = {
 Tundra = {
  lighting = {
   ambient = Color3.fromRGB(200, 210, 225),
   outdoorAmbient = Color3.fromRGB(180, 195, 215),
   brightness = 1.8,
   clockTime = 10,
  },
  fog = {
   start = 80,
   ["end"] = 300,
   color = Color3.fromRGB(220, 230, 240),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 Taiga = {
  lighting = {
   ambient = Color3.fromRGB(160, 180, 160),
   outdoorAmbient = Color3.fromRGB(140, 165, 140),
   brightness = 1.4,
   clockTime = 10,
  },
  fog = {
   start = 60,
   ["end"] = 250,
   color = Color3.fromRGB(200, 215, 205),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 ["Temperate Forest"] = {
  lighting = {
   ambient = Color3.fromRGB(120, 150, 100),
   outdoorAmbient = Color3.fromRGB(100, 135, 85),
   brightness = 1.2,
   clockTime = 11,
  },
  fog = {
   start = 40,
   ["end"] = 200,
   color = Color3.fromRGB(170, 190, 155),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 Grassland = {
  lighting = {
   ambient = Color3.fromRGB(180, 175, 140),
   outdoorAmbient = Color3.fromRGB(170, 165, 130),
   brightness = 1.6,
   clockTime = 12,
  },
  fog = {
   start = 100,
   ["end"] = 350,
   color = Color3.fromRGB(210, 205, 175),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 Desert = {
  lighting = {
   ambient = Color3.fromRGB(255, 220, 170),
   outdoorAmbient = Color3.fromRGB(250, 210, 150),
   brightness = 2.2,
   clockTime = 13,
  },
  fog = {
   start = 150,
   ["end"] = 500,
   color = Color3.fromRGB(235, 210, 170),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 ["Tropical Rainforest"] = {
  lighting = {
   ambient = Color3.fromRGB(80, 120, 70),
   outdoorAmbient = Color3.fromRGB(65, 105, 55),
   brightness = 0.9,
   clockTime = 11,
  },
  fog = {
   start = 20,
   ["end"] = 120,
   color = Color3.fromRGB(130, 160, 120),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = false,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 Savanna = {
  lighting = {
   ambient = Color3.fromRGB(200, 185, 145),
   outdoorAmbient = Color3.fromRGB(190, 175, 130),
   brightness = 1.7,
   clockTime = 12,
  },
  fog = {
   start = 80,
   ["end"] = 350,
   color = Color3.fromRGB(215, 200, 165),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 Mountains = {
  lighting = {
   ambient = Color3.fromRGB(170, 185, 200),
   outdoorAmbient = Color3.fromRGB(155, 175, 195),
   brightness = 1.9,
   clockTime = 10,
  },
  fog = {
   start = 30,
   ["end"] = 180,
   color = Color3.fromRGB(190, 200, 215),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
 Ocean = {
  lighting = {
   ambient = Color3.fromRGB(80, 130, 180),
   outdoorAmbient = Color3.fromRGB(65, 115, 170),
   brightness = 1.3,
   clockTime = 11,
  },
  fog = {
   start = 10,
   ["end"] = 150,
   color = Color3.fromRGB(100, 150, 195),
  },
  sky = {
   skyboxId = nil,
   celestialBodiesShown = true,
  },
  soundscape = {
   daySounds = {},
   nightSounds = {},
  },
 },
}

function AtmosphereSystem.new(eventBus: EventBus.EventBus): AtmosphereSystem
 local self = setmetatable({}, AtmosphereSystem) :: AtmosphereSystem
 self._eventBus = eventBus
 self._biomeAtmospheres = {}
 self._activeTweens = {}
 self._soundscapes = {}

 -- Register default atmospheres for all 9 biomes
 for biomeId, config in pairs(DEFAULT_BIOME_ATMOSPHERES) do
  self:RegisterBiomeAtmosphere(biomeId, config)
 end

 return self
end

function AtmosphereSystem:RegisterBiomeAtmosphere(
 biomeId: string,
 config: AtmosphereConfig
): ()
 self._biomeAtmospheres[biomeId] = config

 self._eventBus:Emit("BiomeAtmosphereRegistered", {
  biomeId = biomeId,
  config = config,
 })
end

-- Get or create the Atmosphere object in Lighting
function AtmosphereSystem:_getAtmosphereObject(): Atmosphere
 local atm = Lighting:FindFirstChildOfClass("Atmosphere")
 if not atm then
  atm = Instance.new("Atmosphere")
  atm.Name = "WorldAtmosphere"
  atm.Parent = Lighting
 end
 return atm
end

--[[
 ApplyToRegion(biomeId, region): apply the biome's atmosphere settings to a Region3.
 Uses Roblox Lighting service properties and creates/updates Atmosphere object.
--]]
function AtmosphereSystem:ApplyToRegion(biomeId: string, region: Region3): ()
 local config = self._biomeAtmospheres[biomeId]
 if not config then
  warn("[AtmosphereSystem] No atmosphere config for biome: " .. biomeId)
  return
 end

 -- Cancel any active tweens
 for _, tween in ipairs(self._activeTweens) do
  if tween.PlaybackState ~= Enum.PlaybackState.Completed then
   pcall(function()
    tween:Cancel()
   end)
  end
 end
 table.clear(self._activeTweens)

 -- Apply lighting settings
 Lighting.Ambient = config.lighting.ambient
 Lighting.OutdoorAmbient = config.lighting.outdoorAmbient
 Lighting.Brightness = config.lighting.brightness
 Lighting.ClockTime = config.lighting.clockTime

 -- Apply fog via Atmosphere object
 local atm = self:_getAtmosphereObject()
 atm.Density = 1 / math.max(config.fog["end"] - config.fog.start, 1)
 atm.Offset = config.fog.start / math.max(config.fog["end"], 1)
 atm.Color = config.fog.color
 atm.Haze = 0
 atm.Glare = 0

 -- Configure sky
 if config.sky.celestialBodiesShown ~= nil then
  Lighting.GlobalShadows = config.sky.celestialBodiesShown
 end

 self._eventBus:Emit("AtmosphereApplied", {
  biomeId = biomeId,
  region = region,
  config = config,
 })
end

--[[
 ApplyToChunk(chunk): read biome from chunk, apply appropriate atmosphere.
--]]
function AtmosphereSystem:ApplyToChunk(chunk: any): ()
 if not chunk then
  warn("[AtmosphereSystem] ApplyToChunk: nil chunk")
  return
 end

 -- Determine dominant biome from chunk's biomeMap
 local biomeMap = chunk.biomeMap
 local biomeCounts: { [string]: number } = {}

 if biomeMap then
  local size = #biomeMap
  for x = 1, size do
   for z = 1, size do
    local biomeId = biomeMap[x] and biomeMap[x][z]
    if biomeId then
     biomeCounts[biomeId] = (biomeCounts[biomeId] or 0) + 1
    end
   end
  end
 end

 -- Find dominant biome
 local dominantBiome = "Grassland" -- default
 local maxCount = 0
 for biomeId, count in pairs(biomeCounts) do
  if count > maxCount then
   maxCount = count
   dominantBiome = biomeId
  end
 end

 -- Create a Region3 from chunk coordinates
 local cx = chunk.cx or 0
 local cz = chunk.cz or 0
 local chunkSize = chunk.size or 64
 local worldX = cx * chunkSize
 local worldZ = cz * chunkSize
 local minCorner = Vector3.new(worldX - chunkSize / 2, -50, worldZ - chunkSize / 2)
 local maxCorner = Vector3.new(worldX + chunkSize / 2, 200, worldZ + chunkSize / 2)
 local region = Region3.new(minCorner, maxCorner)

 self:ApplyToRegion(dominantBiome, region)
end

--[[
 TransitionAtmosphere(fromBiome, toBiome, duration):
 Smoothly transition between two biome atmospheres using TweenService.
--]]
function AtmosphereSystem:TransitionAtmosphere(
 fromBiome: string,
 toBiome: string,
 duration: number
): ()
 local fromConfig = self._biomeAtmospheres[fromBiome]
 local toConfig = self._biomeAtmospheres[toBiome]

 if not fromConfig then
  warn("[AtmosphereSystem] No atmosphere config for fromBiome: " .. fromBiome)
  return
 end
 if not toConfig then
  warn("[AtmosphereSystem] No atmosphere config for toBiome: " .. toBiome)
  return
 end

 -- Cancel previous tweens
 for _, tween in ipairs(self._activeTweens) do
  pcall(function()
   tween:Cancel()
  end)
 end
 table.clear(self._activeTweens)

 -- Create transition info
 local tweenInfo = TweenInfo.new(
  duration,
  Enum.EasingStyle.Quad,
  Enum.EasingDirection.InOut
 )

 -- Tween Lighting properties via a proxy value object
 local lightingProxy = Instance.new("NumberValue")
 lightingProxy.Name = "AtmosphereTransition"
 lightingProxy.Value = 0
 lightingProxy.Parent = script

 -- Tween the proxy from 0 to 1
 local tween = TweenService:Create(lightingProxy, tweenInfo, { Value = 1 })

 -- Sample start values
 local startAmbient = Lighting.Ambient
 local startOutdoorAmbient = Lighting.OutdoorAmbient
 local startBrightness = Lighting.Brightness
 local startClockTime = Lighting.ClockTime

 local atm = self:_getAtmosphereObject()
 local startAtmColor = atm.Color
 local startAtmDensity = atm.Density
 local startAtmOffset = atm.Offset

 -- Interpolate values each frame
 local connection: RBXScriptConnection? = nil
 connection = lightingProxy:GetPropertyChangedSignal("Value"):Connect(function()
  local t = lightingProxy.Value

  -- Lerp Color3 values
  local function lerpColor3(a: Color3, b: Color3, t: number): Color3
   return Color3.new(
    a.R + (b.R - a.R) * t,
    a.G + (b.G - a.G) * t,
    a.B + (b.B - a.B) * t
   )
  end

  -- Apply interpolated lighting
  Lighting.Ambient = lerpColor3(startAmbient, toConfig.lighting.ambient, t)
  Lighting.OutdoorAmbient = lerpColor3(
   startOutdoorAmbient,
   toConfig.lighting.outdoorAmbient,
   t
  )
  Lighting.Brightness = startBrightness
   + (toConfig.lighting.brightness - startBrightness) * t
  Lighting.ClockTime = startClockTime
   + (toConfig.lighting.clockTime - startClockTime) * t

  -- Apply interpolated atmosphere
  local targetDensity = 1
   / math.max(toConfig.fog["end"] - toConfig.fog.start, 1)
  local targetOffset = toConfig.fog.start / math.max(toConfig.fog["end"], 1)

  atm.Color = lerpColor3(startAtmColor, toConfig.fog.color, t)
  atm.Density = startAtmDensity + (targetDensity - startAtmDensity) * t
  atm.Offset = startAtmOffset + (targetOffset - startAtmOffset) * t
 end)

 -- Cleanup on completion
 local function onComplete()
  if connection then
   connection:Disconnect()
  end
  lightingProxy:Destroy()

  -- Ensure final values are exact
  Lighting.Ambient = toConfig.lighting.ambient
  Lighting.OutdoorAmbient = toConfig.lighting.outdoorAmbient
  Lighting.Brightness = toConfig.lighting.brightness
  Lighting.ClockTime = toConfig.lighting.clockTime

  local targetDensity = 1
   / math.max(toConfig.fog["end"] - toConfig.fog.start, 1)
  local targetOffset = toConfig.fog.start / math.max(toConfig.fog["end"], 1)
  atm.Color = toConfig.fog.color
  atm.Density = targetDensity
  atm.Offset = targetOffset
 end

 tween.Completed:Connect(function()
  onComplete()
  self._eventBus:Emit("AtmosphereTransitioned", {
   fromBiome = fromBiome,
   toBiome = toBiome,
   duration = duration,
  })
 end)

 table.insert(self._activeTweens, tween)
 tween:Play()
end

return AtmosphereSystem
