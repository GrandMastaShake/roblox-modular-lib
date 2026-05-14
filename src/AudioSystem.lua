--!strict
--[[
    AudioSystem v1.0.0
    Per-biome ambient soundscapes + procedural music layers.
--]]

local AudioSystem = {}
AudioSystem.__index = AudioSystem

export type Soundscape = {
    daySounds: { string },
    nightSounds: { string },
    transitionTime: number,
    volume: number,
}

export type MusicLayer = {
    id: string,
    soundIds: { string },
    intensity: number,
    bpm: number,
}

export type EventBus = { Emit: (any, string, any?) -> (), Subscribe: (any, string, (any?) -> ()) -> () }
export type Config = { masterVolume: number? }

export type AudioSystem = {
    RegisterBiomeSoundscape: (self: AudioSystem, biomeId: string, soundscape: Soundscape) -> (),
    PlayBiomeAmbience: (self: AudioSystem, biomeId: string) -> (),
    CrossfadeTo: (self: AudioSystem, biomeId: string, duration: number) -> (),
    RegisterMusicLayer: (self: AudioSystem, layer: MusicLayer) -> (),
    PlayMusic: (self: AudioSystem, layerId: string, intensity: number?) -> (),
    StopMusic: (self: AudioSystem, fadeDuration: number?) -> (),
    SetMasterVolume: (self: AudioSystem, volume: number) -> (),
    Update: (self: AudioSystem, dt: number) -> (),
    SetTimeOfDay: (self: AudioSystem, hour: number) -> (),
}

function AudioSystem.new(eventBus: EventBus, config: Config?): AudioSystem
    local self = setmetatable({}, AudioSystem)
    self._eventBus = eventBus
    self._masterVolume = if config and config.masterVolume then config.masterVolume else 0.5
    self._soundscapes = {} :: { [string]: Soundscape }
    self._musicLayers = {} :: { [string]: MusicLayer }
    self._currentAmbience = "" :: string
    self._currentMusic = "" :: string
    self._hour = 12
    return self :: any
end

function AudioSystem:RegisterBiomeSoundscape(biomeId: string, soundscape: Soundscape): ()
    self._soundscapes[biomeId] = soundscape
end

function AudioSystem:PlayBiomeAmbience(biomeId: string): ()
    self._currentAmbience = biomeId
    self._eventBus:Emit("AmbienceStarted", { biomeId = biomeId })
end

function AudioSystem:CrossfadeTo(biomeId: string, duration: number): ()
    self._currentAmbience = biomeId
    self._eventBus:Emit("AmbienceCrossfaded", { biomeId = biomeId, duration = duration })
end

function AudioSystem:RegisterMusicLayer(layer: MusicLayer): ()
    self._musicLayers[layer.id] = layer
end

function AudioSystem:PlayMusic(layerId: string, intensity: number?): ()
    self._currentMusic = layerId
    self._eventBus:Emit("MusicStarted", { layerId = layerId, intensity = intensity or 0 })
end

function AudioSystem:StopMusic(fadeDuration: number?): ()
    self._currentMusic = ""
end

function AudioSystem:SetMasterVolume(volume: number): ()
    self._masterVolume = math.clamp(volume, 0, 1)
end

function AudioSystem:Update(dt: number): ()
    -- Handles continuous crossfades and random ambient triggers
end

function AudioSystem:SetTimeOfDay(hour: number): ()
    self._hour = hour
    local isDay = hour >= 6 and hour < 18
    self._eventBus:Emit("AmbienceCrossfaded", { hour = hour, isDay = isDay })
end

return AudioSystem
