--!strict
--[[
    WeatherSystem v1.0.0
    Rain, snow, storms that interact with biomes and atmosphere.
--]]

local WeatherSystem = {}
WeatherSystem.__index = WeatherSystem

export type WeatherType = "clear" | "rain" | "snow" | "storm" | "fog" | "overcast"

export type WeatherState = {
    type: WeatherType,
    intensity: number,
    duration: number,
    windDirection: Vector3,
    windSpeed: number,
}

export type EventBus = { Emit: (any, string, any?) -> (), Subscribe: (any, string, (any?) -> ()) -> () }
export type Config = { defaultInterval: number? }

export type WeatherSystem = {
    SetWeather: (self: WeatherSystem, type: WeatherType, intensity: number, duration: number?) -> (),
    GetCurrentWeather: (self: WeatherSystem) -> WeatherState,
    Update: (self: WeatherSystem, dt: number) -> (),
    GetWeatherForBiome: (self: WeatherSystem, biomeId: string) -> { { WeatherType | number } },
    EnableRandomWeather: (self: WeatherSystem, interval: number) -> (),
    DisableRandomWeather: (self: WeatherSystem) -> (),
    SetParticleSystem: (self: WeatherSystem, weatherType: WeatherType, emitter: any) -> (),
}

local DEFAULT_BIOME_WEATHER: { [string]: { { WeatherType | number } } } = {
    Desert    = { {"clear", 0.5}, {"overcast", 0.2}, {"rain", 0.05} },
    Rainforest= { {"rain", 0.4}, {"clear", 0.2}, {"storm", 0.15} },
    Plains    = { {"clear", 0.35}, {"rain", 0.2}, {"overcast", 0.15} },
    Mountain  = { {"snow", 0.3}, {"clear", 0.2}, {"fog", 0.15} },
    Ocean     = { {"clear", 0.3}, {"storm", 0.2}, {"rain", 0.15} },
}

function WeatherSystem.new(eventBus: EventBus, config: Config?): WeatherSystem
    local self = setmetatable({}, WeatherSystem)
    self._eventBus = eventBus
    self._current = {
        type = "clear" :: WeatherType,
        intensity = 0,
        duration = 0,
        windDirection = Vector3.zero,
        windSpeed = 0,
    } :: WeatherState
    self._randomEnabled = false
    self._particleSystems = {} :: { [WeatherType]: any }
    return self :: any
end

function WeatherSystem:SetWeather(type: WeatherType, intensity: number, duration: number?): ()
    self._current.type = type
    self._current.intensity = math.clamp(intensity, 0, 1)
    self._current.duration = duration or 300
    self._eventBus:Emit("WeatherChanged", table.clone(self._current))
    if type == "storm" then
        self._eventBus:Emit("StormStarted", table.clone(self._current))
    end
end

function WeatherSystem:GetCurrentWeather(): WeatherState
    return table.clone(self._current)
end

function WeatherSystem:Update(dt: number): ()
    if self._current.duration > 0 then
        self._current.duration -= dt
        if self._current.duration <= 0 and self._current.type ~= "clear" then
            self:SetWeather("clear", 0, 0)
            self._eventBus:Emit("StormEnded", {})
        end
    end
    self._eventBus:Emit("WeatherUpdated", table.clone(self._current))
end

function WeatherSystem:GetWeatherForBiome(biomeId: string): { { WeatherType | number } }
    local entry = DEFAULT_BIOME_WEATHER[biomeId]
    if not entry then
        return { {"clear", 0.5}, {"rain", 0.25}, {"overcast", 0.15} }
    end
    local result: { { WeatherType | number } } = {}
    for _, pair in ipairs(entry) do
        table.insert(result, { pair[1] :: WeatherType, pair[2] :: number })
    end
    return result
end

function WeatherSystem:EnableRandomWeather(interval: number): ()
    self._randomEnabled = true
    task.spawn(function()
        while self._randomEnabled do
            task.wait(interval)
            if not self._randomEnabled then break end
            local types: { WeatherType } = {"clear", "rain", "snow", "storm", "fog", "overcast"}
            local randomType = types[math.random(1, #types)]
            self:SetWeather(randomType, math.random(), interval)
        end
    end)
end

function WeatherSystem:DisableRandomWeather(): ()
    self._randomEnabled = false
end

function WeatherSystem:SetParticleSystem(weatherType: WeatherType, emitter: any): ()
    self._particleSystems[weatherType] = emitter
end

return WeatherSystem
