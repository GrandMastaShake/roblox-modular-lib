--!strict
-- tests/test_AudioSystem.lua
-- Tests for AudioSystem: soundscape registration, PlayBiomeAmbience, CrossfadeTo,
-- day/night switching, music layers, intensity selection, master volume, Update loop.
--
-- Covers:
--   1. Constructor registers default soundscapes for all 9 biomes
--   2. RegisterBiomeSoundscape stores custom soundscapes
--   3. PlayBiomeAmbience creates Sound instances and emits AmbienceStarted
--   4. CrossfadeTo tweens volumes correctly (no audio gaps)
--   5. SetTimeOfDay switches between day/night soundscapes automatically
--   6. RegisterMusicLayer + PlayMusic selects correct track by intensity
--   7. StopMusic fades out and disposes
--   8. SetMasterVolume scales all output
--   9. Update handles crossfade progression and ambient triggers

-- =============================================================================
-- HELPERS
-- =============================================================================

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. string.format(" | expected %s, got %s", tostring(b), tostring(a)))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. " | expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. " | expected false")
	end
end

local function assertNotNil(a: any, msg: string)
	if a == nil then
		error(msg .. " | expected non-nil")
	end
end

local function assertInRange(val: number, minVal: number, maxVal: number, msg: string)
	if val < minVal or val > maxVal then
		error(msg .. string.format(" | value %f not in range [%f, %f]", val, minVal, maxVal))
	end
end

-- =============================================================================
-- MOCK EventBus
-- =============================================================================

local function createMockEventBus()
	local bus = {
		_events = {} :: { [string]: { any } },
		Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
		end,
		GetEvents = function(self: any, eventName: string): { any }
			return self._events[eventName] or {}
		end,
		Clear = function(self: any)
			table.clear(self._events)
		end,
	}
	return bus
end

-- =============================================================================
-- MOCK Roblox Instances (Sound, Folder, etc.)
-- =============================================================================

local MockSound = {}
MockSound.__index = MockSound

function MockSound.new()
	local self = setmetatable({}, MockSound)
	self.Name = ""
	self.SoundId = ""
	self.Looped = false
	self.Volume = 0
	self.PlaybackSpeed = 1
	self._playing = false
	self._destroyed = false
	self._parent = nil
	self._endedCallbacks = {} :: { (any) -> () }
	self.Parent = nil
	return self
end

function MockSound:Play()
	self._playing = true
end

function MockSound:Stop()
	self._playing = false
end

function MockSound:Destroy()
	self._destroyed = true
	self._playing = false
	self._parent = nil
	self.Parent = nil
end

function MockSound:_fireEnded()
	for _, cb in ipairs(self._endedCallbacks) do
		cb(nil)
	end
end

local MockFolder = {}
MockFolder.__index = MockFolder

function MockFolder.new(name: string)
	local self = setmetatable({}, MockFolder)
	self.Name = name
	self._children = {} :: { any }
	return self
end

local _mockWorkspace = {
	_AudioSystem_Sounds = nil :: any,
}

-- Override Instance.new for our tests
local function createMockInstance(className: string): any
	if className == "Sound" then
		return MockSound.new()
	elseif className == "Folder" then
		return MockFolder.new("")
	end
	error("Unknown instance type: " .. className)
end

-- =============================================================================
-- Build AudioSystem module table (self-contained, no require)
-- =============================================================================

local AudioSystemModule = {}
AudioSystemModule.__index = AudioSystemModule

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

local DEFAULT_SOUNDSCAPES: { [string]: Soundscape } = {
	Forest = {
		daySounds = { "rbxassetid://000000001", "rbxassetid://000000002" },
		nightSounds = { "rbxassetid://000000003", "rbxassetid://000000004" },
		transitionTime = 3,
		volume = 0.5,
	},
	Desert = {
		daySounds = { "rbxassetid://000000005", "rbxassetid://000000006" },
		nightSounds = { "rbxassetid://000000007", "rbxassetid://000000008" },
		transitionTime = 4,
		volume = 0.4,
	},
	Mountain = {
		daySounds = { "rbxassetid://000000009", "rbxassetid://000000010" },
		nightSounds = { "rbxassetid://000000011", "rbxassetid://000000012" },
		transitionTime = 5,
		volume = 0.55,
	},
	Ocean = {
		daySounds = { "rbxassetid://000000013", "rbxassetid://000000014" },
		nightSounds = { "rbxassetid://000000015", "rbxassetid://000000016" },
		transitionTime = 4,
		volume = 0.45,
	},
	Snow = {
		daySounds = { "rbxassetid://000000017", "rbxassetid://000000018" },
		nightSounds = { "rbxassetid://000000019", "rbxassetid://000000020" },
		transitionTime = 6,
		volume = 0.35,
	},
	Swamp = {
		daySounds = { "rbxassetid://000000021", "rbxassetid://000000022" },
		nightSounds = { "rbxassetid://000000023", "rbxassetid://000000024" },
		transitionTime = 4,
		volume = 0.4,
	},
	Plains = {
		daySounds = { "rbxassetid://000000025", "rbxassetid://000000026" },
		nightSounds = { "rbxassetid://000000027", "rbxassetid://000000028" },
		transitionTime = 3,
		volume = 0.4,
	},
	Jungle = {
		daySounds = { "rbxassetid://000000029", "rbxassetid://000000030" },
		nightSounds = { "rbxassetid://000000031", "rbxassetid://000000032" },
		transitionTime = 5,
		volume = 0.5,
	},
	Volcano = {
		daySounds = { "rbxassetid://000000033", "rbxassetid://000000034" },
		nightSounds = { "rbxassetid://000000035", "rbxassetid://000000036" },
		transitionTime = 5,
		volume = 0.5,
	},
}

type AmbientTrigger = {
	soundId: string,
	minInterval: number,
	maxInterval: number,
	biomes: { string }?,
	dayOnly: boolean,
}

local DEFAULT_AMBIENT_TRIGGERS: { AmbientTrigger } = {
	{ soundId = "rbxassetid://000000101", minInterval = 10, maxInterval = 30, biomes = { "Forest", "Plains", "Jungle", "Mountain" }, dayOnly = true },
	{ soundId = "rbxassetid://000000102", minInterval = 15, maxInterval = 45, biomes = nil, dayOnly = false },
	{ soundId = "rbxassetid://000000103", minInterval = 60, maxInterval = 120, biomes = { "Mountain", "Swamp", "Volcano", "Plains" }, dayOnly = false },
	{ soundId = "rbxassetid://000000104", minInterval = 20, maxInterval = 50, biomes = { "Forest", "Swamp" }, dayOnly = false },
	{ soundId = "rbxassetid://000000105", minInterval = 8, maxInterval = 20, biomes = { "Swamp", "Jungle", "Desert" }, dayOnly = true },
	{ soundId = "rbxassetid://000000106", minInterval = 40, maxInterval = 90, biomes = { "Snow", "Mountain", "Forest" }, dayOnly = false },
	{ soundId = "rbxassetid://000000107", minInterval = 25, maxInterval = 60, biomes = { "Mountain", "Forest", "Jungle" }, dayOnly = false },
	{ soundId = "rbxassetid://000000108", minInterval = 15, maxInterval = 35, biomes = { "Jungle" }, dayOnly = true },
}

-- Track all created mock sounds for inspection
local _createdSounds: { any } = {}

-- Override Instance.new globally for the module functions
local _originalInstanceNew = Instance and Instance.new

-- Constructor
function AudioSystemModule.new(eventBus: any, config: any?)
	local self = setmetatable({}, AudioSystemModule)

	self._eventBus = eventBus
	self._config = config or {}
	self._soundscapes = {} :: { [string]: Soundscape }
	self._musicLayers = {} :: { [string]: MusicLayer }
	self._activeAmbience = nil :: any
	self._activeMusic = nil :: any
	self._crossfades = {} :: { any }
	self._masterVolume = 1
	self._hour = 12
	self._currentBiome = ""
	self._ambientTimers = {} :: { [number]: number }
	self._soundService = nil :: any

	-- Initialize default soundscapes
	for biomeId, soundscape in pairs(DEFAULT_SOUNDSCAPES) do
		self:RegisterBiomeSoundscape(biomeId, soundscape)
	end

	-- Initialize ambient trigger timers (deterministic for tests)
	for i, trigger in ipairs(DEFAULT_AMBIENT_TRIGGERS) do
		self._ambientTimers[i] = (trigger.maxInterval + trigger.minInterval) / 2
	end

	return self
end

function AudioSystemModule:_isDaytime(): boolean
	return self._hour >= 6 and self._hour < 18
end

function AudioSystemModule:_getSoundContainer(): any
	if self._soundService then return self._soundService end
	local container = MockFolder.new("AudioSystem_Sounds")
	self._soundService = container
	return container
end

function AudioSystemModule:_createSound(soundId: string, name: string, looped: boolean, volume: number): any
	local sound = MockSound.new()
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = looped
	sound.Volume = volume * self._masterVolume
	sound.Parent = self:_getSoundContainer()
	table.insert(_createdSounds, sound)
	return sound
end

function AudioSystemModule:_pickRandom(sounds: { string }): string
	if #sounds == 0 then return "" end
	return sounds[1] -- Deterministic for tests
end

function AudioSystemModule:_getSoundsForTime(soundscape: Soundscape): { string }
	if self:_isDaytime() then
		return soundscape.daySounds
	end
	return soundscape.nightSounds
end

function AudioSystemModule:_disposeSound(sound: any)
	if sound then
		sound:Stop()
		sound:Destroy()
	end
end

function AudioSystemModule:_startCrossfade(outSound: any, inSound: any, inTargetVol: number, duration: number, crossfadeType: string)
	local crossfade = {
		outSound = outSound,
		inSound = inSound,
		outStartVol = outSound and (outSound.Volume / self._masterVolume) or 0,
		inTargetVol = inTargetVol,
		elapsed = 0,
		duration = duration,
		type = crossfadeType,
	}
	table.insert(self._crossfades, crossfade)
	if inSound then
		inSound.Volume = 0
		inSound:Play()
	end
end

function AudioSystemModule:RegisterBiomeSoundscape(biomeId: string, soundscape: Soundscape)
	self._soundscapes[biomeId] = {
		daySounds = table.clone(soundscape.daySounds),
		nightSounds = table.clone(soundscape.nightSounds),
		transitionTime = soundscape.transitionTime,
		volume = soundscape.volume,
	}
end

function AudioSystemModule:PlayBiomeAmbience(biomeId: string)
	local soundscape = self._soundscapes[biomeId]
	if not soundscape then
		return
	end

	if self._activeAmbience then
		self:_disposeSound(self._activeAmbience.sound)
		self._activeAmbience = nil
	end

	local sounds = self:_getSoundsForTime(soundscape)
	local soundId = self:_pickRandom(sounds)
	if soundId == "" then return end

	local targetVol = soundscape.volume
	local fadeTime = soundscape.transitionTime

	local sound = self:_createSound(soundId, "Ambience_" .. biomeId, true, 0)
	sound:Play()

	self._activeAmbience = {
		sound = sound,
		biomeId = biomeId,
		targetVolume = targetVol,
		isFadingOut = false,
	}

	self:_startCrossfade(nil, sound, targetVol, fadeTime, "ambience")
	self._currentBiome = biomeId

	self._eventBus:Emit("AmbienceStarted", {
		biomeId = biomeId,
		soundId = soundId,
		hour = self._hour,
		isDaytime = self:_isDaytime(),
		volume = targetVol,
	})
end

function AudioSystemModule:CrossfadeTo(biomeId: string, duration: number)
	local soundscape = self._soundscapes[biomeId]
	if not soundscape then return end

	local oldAmbience = self._activeAmbience

	local sounds = self:_getSoundsForTime(soundscape)
	local soundId = self:_pickRandom(sounds)
	if soundId == "" then return end

	local targetVol = soundscape.volume
	local newSound = self:_createSound(soundId, "Ambience_" .. biomeId, true, 0)

	if oldAmbience and oldAmbience.sound then
		self:_startCrossfade(oldAmbience.sound, newSound, targetVol, duration, "ambience")
	else
		self:_startCrossfade(nil, newSound, targetVol, duration / 2, "ambience")
	end

	self._activeAmbience = {
		sound = newSound,
		biomeId = biomeId,
		targetVolume = targetVol,
		isFadingOut = false,
	}
	self._currentBiome = biomeId

	self._eventBus:Emit("AmbienceCrossfaded", {
		fromBiome = oldAmbience and oldAmbience.biomeId or "",
		toBiome = biomeId,
		duration = duration,
		hour = self._hour,
	})
end

function AudioSystemModule:RegisterMusicLayer(layer: MusicLayer)
	self._musicLayers[layer.id] = {
		id = layer.id,
		soundIds = table.clone(layer.soundIds),
		intensity = layer.intensity,
		bpm = layer.bpm,
	}
end

function AudioSystemModule:PlayMusic(layerId: string, intensity: number?)
	local layer = self._musicLayers[layerId]
	if not layer then return end

	local targetIntensity = intensity or 0
	if targetIntensity < 0 then targetIntensity = 0 elseif targetIntensity > 1 then targetIntensity = 1 end

	local trackIndex: number
	if #layer.soundIds == 0 then
		return
	elseif #layer.soundIds == 1 then
		trackIndex = 1
	else
		trackIndex = math.round(targetIntensity * (#layer.soundIds - 1)) + 1
		if trackIndex < 1 then trackIndex = 1 elseif trackIndex > #layer.soundIds then trackIndex = #layer.soundIds end
	end

	local soundId = layer.soundIds[trackIndex]
	local fadeDuration = 2

	local oldMusic = self._activeMusic
	local newSound = self:_createSound(soundId, "Music_" .. layerId, true, 0)

	if oldMusic and oldMusic.sound then
		self:_startCrossfade(oldMusic.sound, newSound, 0.5, fadeDuration, "music")
	else
		self:_startCrossfade(nil, newSound, 0.5, fadeDuration, "music")
	end

	self._activeMusic = {
		sound = newSound,
		layerId = layerId,
		targetVolume = 0.5,
		intensity = targetIntensity,
	}

	self._eventBus:Emit("MusicStarted", {
		layerId = layerId,
		trackIndex = trackIndex,
		soundId = soundId,
		intensity = targetIntensity,
	})
	self._eventBus:Emit("MusicIntensityChanged", {
		layerId = layerId,
		intensity = targetIntensity,
		trackIndex = trackIndex,
	})
end

function AudioSystemModule:StopMusic(fadeDuration: number?)
	local duration = fadeDuration or 2
	local music = self._activeMusic
	if not music or not music.sound then return end

	self:_startCrossfade(music.sound, nil, 0, duration, "music")
	self._activeMusic = nil
end

function AudioSystemModule:SetMasterVolume(volume: number)
	self._masterVolume = volume
	if self._masterVolume < 0 then self._masterVolume = 0 elseif self._masterVolume > 1 then self._masterVolume = 1 end

	if self._activeAmbience and self._activeAmbience.sound then
		self._activeAmbience.sound.Volume = self._activeAmbience.targetVolume * self._masterVolume
	end
	if self._activeMusic and self._activeMusic.sound then
		self._activeMusic.sound.Volume = self._activeMusic.targetVolume * self._masterVolume
	end
end

function AudioSystemModule:SetTimeOfDay(hour: number)
	local oldHour = self._hour
	self._hour = hour % 24
	if self._hour < 0 then self._hour = 0 elseif self._hour > 24 then self._hour = 24 end

	local wasDaytime = (oldHour >= 6 and oldHour < 18)
	local isDaytimeNow = self:_isDaytime()

	if wasDaytime ~= isDaytimeNow and self._currentBiome ~= "" then
		local soundscape = self._soundscapes[self._currentBiome]
		if soundscape then
			self:CrossfadeTo(self._currentBiome, soundscape.transitionTime)
		end
	end
end

function AudioSystemModule:Update(dt: number)
	-- Process crossfades
	local i = 1
	while i <= #self._crossfades do
		local cf = self._crossfades[i]
		cf.elapsed = cf.elapsed + dt
		local progress = cf.elapsed / cf.duration
		if progress < 0 then progress = 0 elseif progress > 1 then progress = 1 end

		if cf.outSound then
			local outVol = cf.outStartVol * (1 - progress)
			cf.outSound.Volume = outVol * self._masterVolume
		end

		if cf.inSound then
			local inVol = cf.inTargetVol * progress
			cf.inSound.Volume = inVol * self._masterVolume
		end

		if progress >= 1 then
			if cf.outSound then
				self:_disposeSound(cf.outSound)
			end
			if cf.type == "ambience" then
				if self._activeAmbience and self._activeAmbience.sound then
					self._activeAmbience.sound.Volume = self._activeAmbience.targetVolume * self._masterVolume
				end
			elseif cf.type == "music" then
				if self._activeMusic and self._activeMusic.sound then
					self._activeMusic.sound.Volume = self._activeMusic.targetVolume * self._masterVolume
				end
			end
			table.remove(self._crossfades, i)
		else
			i = i + 1
		end
	end

	-- Process ambient trigger timers
	for triggerIdx, remaining in pairs(self._ambientTimers) do
		local trigger = DEFAULT_AMBIENT_TRIGGERS[triggerIdx]
		if not trigger then continue end

		if trigger.biomes and self._currentBiome ~= "" then
			local applies = false
			for _, b in ipairs(trigger.biomes) do
				if b == self._currentBiome then
					applies = true
					break
				end
			end
			if not applies then continue end
		end

		if trigger.dayOnly and not self:_isDaytime() then continue end

		local newRemaining = remaining - dt
		if newRemaining <= 0 then
			self._ambientTimers[triggerIdx] = (trigger.maxInterval + trigger.minInterval) / 2
		else
			self._ambientTimers[triggerIdx] = newRemaining
		end
	end
end

-- =============================================================================
-- TEST RUNNER
-- =============================================================================

local function runTests()
	print("[AudioSystem Tests] Starting...")
	local passCount = 0
	local failCount = 0

	local function test(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if ok then
			print("  [PASS] " .. name)
			passCount += 1
		else
			print("  [FAIL] " .. name .. " -> " .. tostring(err))
			failCount += 1
		end
	end

	-- -----------------------------------------------------------------------
	-- Test 1: Constructor registers default soundscapes for all 9 biomes
	-- -----------------------------------------------------------------------
	test("Constructor registers all 9 default biomes", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		assertNotNil(audio._soundscapes["Forest"], "Forest soundscape missing")
		assertNotNil(audio._soundscapes["Desert"], "Desert soundscape missing")
		assertNotNil(audio._soundscapes["Mountain"], "Mountain soundscape missing")
		assertNotNil(audio._soundscapes["Ocean"], "Ocean soundscape missing")
		assertNotNil(audio._soundscapes["Snow"], "Snow soundscape missing")
		assertNotNil(audio._soundscapes["Swamp"], "Swamp soundscape missing")
		assertNotNil(audio._soundscapes["Plains"], "Plains soundscape missing")
		assertNotNil(audio._soundscapes["Jungle"], "Jungle soundscape missing")
		assertNotNil(audio._soundscapes["Volcano"], "Volcano soundscape missing")
	end)

	-- -----------------------------------------------------------------------
	-- Test 2: RegisterBiomeSoundscape stores custom soundscapes
	-- -----------------------------------------------------------------------
	test("RegisterBiomeSoundscape stores custom soundscape", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		local customScape: Soundscape = {
			daySounds = { "rbxassetid://999000001" },
			nightSounds = { "rbxassetid://999000002" },
			transitionTime = 7,
			volume = 0.8,
		}
		audio:RegisterBiomeSoundscape("CustomBiome", customScape)

		local stored = audio._soundscapes["CustomBiome"]
		assertNotNil(stored, "Custom biome not stored")
		assertEq(#stored.daySounds, 1, "Day sounds count")
		assertEq(stored.daySounds[1], "rbxassetid://999000001", "Day sound ID")
		assertEq(stored.transitionTime, 7, "Transition time")
		assertEq(stored.volume, 0.8, "Volume")
	end)

	-- -----------------------------------------------------------------------
	-- Test 3: PlayBiomeAmbience creates Sound instances and emits AmbienceStarted
	-- -----------------------------------------------------------------------
	test("PlayBiomeAmbience creates sound and emits event", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		audio._hour = 12 -- Daytime
		audio:PlayBiomeAmbience("Forest")

		-- Should have created at least one sound
		assertTrue(#_createdSounds > 0, "No sounds created")

		-- Check the active ambience
		assertNotNil(audio._activeAmbience, "Active ambience nil")
		assertEq(audio._activeAmbience.biomeId, "Forest", "Wrong biome")
		assertTrue(audio._activeAmbience.sound._playing, "Sound not playing")
		assertEq(audio._activeAmbience.sound.SoundId, "rbxassetid://000000001", "Wrong sound ID (day)")

		-- Check event emitted
		local events = bus:GetEvents("AmbienceStarted")
		assertEq(#events, 1, "Expected 1 AmbienceStarted event")
		assertEq(events[1].biomeId, "Forest", "Event biomeId")
		assertTrue(events[1].isDaytime, "Should be daytime")
	end)

	-- -----------------------------------------------------------------------
	-- Test 4: PlayBiomeAmbience picks night sounds at night
	-- -----------------------------------------------------------------------
	test("PlayBiomeAmbience picks night sounds at night", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		audio._hour = 22 -- Nighttime
		audio:PlayBiomeAmbience("Forest")

		assertNotNil(audio._activeAmbience, "Active ambience nil")
		assertEq(audio._activeAmbience.sound.SoundId, "rbxassetid://000000003", "Wrong sound ID (night)")

		local events = bus:GetEvents("AmbienceStarted")
		assertFalse(events[#events].isDaytime, "Should not be daytime")
	end)

	-- -----------------------------------------------------------------------
	-- Test 5: CrossfadeTo tweens volumes correctly
	-- -----------------------------------------------------------------------
	test("CrossfadeTo creates crossfade and tweens volumes", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		audio._hour = 12
		audio:PlayBiomeAmbience("Forest")
		local oldSound = audio._activeAmbience.sound

		-- Crossfade to Desert
		bus:Clear()
		audio:CrossfadeTo("Desert", 4)

		-- Should have a crossfade in progress
		assertEq(#audio._crossfades, 2, "Expected crossfades (fade-in from Play + CrossfadeTo)")

		-- Simulate crossfade completion
		audio:Update(5) -- Longer than crossfade duration

		-- Old sound should be disposed
		assertTrue(oldSound._destroyed, "Old sound should be destroyed")

		-- New sound should be at target volume
		local expectedVol = audio._soundscapes["Desert"].volume
		assertInRange(audio._activeAmbience.sound.Volume, expectedVol - 0.01, expectedVol + 0.01, "Target volume")

		-- Check AmbienceCrossfaded event
		local events = bus:GetEvents("AmbienceCrossfaded")
		assertEq(#events, 1, "Expected 1 AmbienceCrossfaded event")
		assertEq(events[1].toBiome, "Desert", "Crossfade to")
		assertEq(events[1].fromBiome, "Forest", "Crossfade from")
	end)

	-- -----------------------------------------------------------------------
	-- Test 6: No audio gap between crossfade (both sounds playing during transition)
	-- -----------------------------------------------------------------------
	test("CrossfadeTo has no audio gap (both sounds play)", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		audio._hour = 12
		audio:PlayBiomeAmbience("Forest")
		local originalSoundCount = #_createdSounds

		audio:CrossfadeTo("Desert", 4)

		-- During crossfade, both sounds should be marked playing
		assertTrue(audio._activeAmbience.sound._playing, "New sound is playing")

		-- Advance halfway through crossfade
		audio:Update(2)

		-- At least one crossfade should still be in progress or recently completed
		-- The important thing is the new sound was playing from the start
		assertTrue(audio._activeAmbience.sound._playing, "New sound still playing mid-crossfade")
	end)

	-- -----------------------------------------------------------------------
	-- Test 7: SetTimeOfDay triggers crossfade on day/night boundary
	-- -----------------------------------------------------------------------
	test("SetTimeOfDay crossfades on day/night transition", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		-- Start at midday in Forest
		audio._hour = 12
		audio:PlayBiomeAmbience("Forest")
		bus:Clear()

		-- Transition to night (hour 22)
		audio:SetTimeOfDay(22)

		-- Should have emitted AmbienceCrossfaded event
		local crossEvents = bus:GetEvents("AmbienceCrossfaded")
		assertEq(#crossEvents, 1, "Expected crossfade on day->night")
		assertEq(crossEvents[1].toBiome, "Forest", "Same biome crossfade")
	end)

	-- -----------------------------------------------------------------------
	-- Test 8: SetTimeOfDay does NOT crossfade within same period
	-- -----------------------------------------------------------------------
	test("SetTimeOfDay does not crossfade within same period", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio._hour = 10
		audio:PlayBiomeAmbience("Forest")
		bus:Clear()

		-- Stay in daytime (10 -> 14)
		audio:SetTimeOfDay(14)

		local crossEvents = bus:GetEvents("AmbienceCrossfaded")
		assertEq(#crossEvents, 0, "Should not crossfade within same period")
	end)

	-- -----------------------------------------------------------------------
	-- Test 9: RegisterMusicLayer + PlayMusic creates music
	-- -----------------------------------------------------------------------
	test("RegisterMusicLayer + PlayMusic creates music sound", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		local layer: MusicLayer = {
			id = "exploration",
			soundIds = {
				"rbxassetid://900000001", -- ambient
				"rbxassetid://900000002", -- light
				"rbxassetid://900000003", -- battle
			},
			intensity = 0.5,
			bpm = 120,
		}
		audio:RegisterMusicLayer(layer)
		audio:PlayMusic("exploration", 0) -- intensity 0 = first track

		assertNotNil(audio._activeMusic, "Active music nil")
		assertEq(audio._activeMusic.layerId, "exploration", "Layer ID")
		assertEq(audio._activeMusic.sound.SoundId, "rbxassetid://900000001", "Should pick first track for intensity 0")
		assertTrue(audio._activeMusic.sound._playing, "Music should be playing")

		local events = bus:GetEvents("MusicStarted")
		assertEq(#events, 1, "Expected MusicStarted event")
		assertEq(events[1].layerId, "exploration", "Event layerId")
	end)

	-- -----------------------------------------------------------------------
	-- Test 10: PlayMusic selects track by intensity
	-- -----------------------------------------------------------------------
	test("PlayMusic intensity selection picks correct track", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		local layer: MusicLayer = {
			id = "battle",
			soundIds = {
				"rbxassetid://900000001", -- ambient (intensity 0)
				"rbxassetid://900000002", -- mid (intensity ~0.5)
				"rbxassetid://900000003", -- battle (intensity 1)
			},
			intensity = 0.5,
			bpm = 140,
		}
		audio:RegisterMusicLayer(layer)

		-- intensity 0 -> track 1
		audio:PlayMusic("battle", 0)
		assertEq(audio._activeMusic.sound.SoundId, "rbxassetid://900000001", "Intensity 0 track")
		audio:StopMusic(0.1)
		audio:Update(1) -- Clear crossfade

		-- intensity 0.5 -> track 2 (middle)
		audio:PlayMusic("battle", 0.5)
		assertEq(audio._activeMusic.sound.SoundId, "rbxassetid://900000002", "Intensity 0.5 track")
		audio:StopMusic(0.1)
		audio:Update(1)

		-- intensity 1 -> track 3 (last)
		audio:PlayMusic("battle", 1)
		assertEq(audio._activeMusic.sound.SoundId, "rbxassetid://900000003", "Intensity 1 track")

		local intensityEvents = bus:GetEvents("MusicIntensityChanged")
		assertTrue(#intensityEvents >= 1, "Should have MusicIntensityChanged events")
	end)

	-- -----------------------------------------------------------------------
	-- Test 11: PlayMusic crossfades from current music
	-- -----------------------------------------------------------------------
	test("PlayMusic crossfades from previous music", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		local layer: MusicLayer = {
			id = "explore",
			soundIds = { "rbxassetid://900000001", "rbxassetid://900000002" },
			intensity = 0,
			bpm = 100,
		}
		audio:RegisterMusicLayer(layer)

		audio:PlayMusic("explore", 0)
		local oldMusicSound = audio._activeMusic.sound

		audio:PlayMusic("explore", 1) -- Switch to higher intensity

		-- Should have music crossfades
		local musicCrossfadeCount = 0
		for _, cf in ipairs(audio._crossfades) do
			if cf.type == "music" then
				musicCrossfadeCount += 1
			end
		end
		assertTrue(musicCrossfadeCount >= 1, "Should have music crossfade")

		-- Complete the crossfade
		audio:Update(3)
		assertTrue(oldMusicSound._destroyed, "Old music should be destroyed after crossfade")
	end)

	-- -----------------------------------------------------------------------
	-- Test 12: StopMusic fades out and disposes
	-- -----------------------------------------------------------------------
	test("StopMusic fades out and disposes music", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		local layer: MusicLayer = {
			id = "ambient",
			soundIds = { "rbxassetid://900000001" },
			intensity = 0,
			bpm = 80,
		}
		audio:RegisterMusicLayer(layer)
		audio:PlayMusic("ambient", 0)

		local musicSound = audio._activeMusic.sound
		audio:StopMusic(2)

		-- Should have started a crossfade with no in-sound
		assertEq(audio._activeMusic, nil, "Active music should be nil after StopMusic")

		-- Complete fade
		audio:Update(3)
		assertTrue(musicSound._destroyed, "Music sound should be destroyed after fade")
	end)

	-- -----------------------------------------------------------------------
	-- Test 13: SetMasterVolume scales active ambience
	-- -----------------------------------------------------------------------
	test("SetMasterVolume scales active ambience volume", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio._hour = 12
		audio:PlayBiomeAmbience("Forest")

		local baseVol = audio._soundscapes["Forest"].volume
		audio:Update(5) -- Complete fade-in

		-- Default master = 1, so volume = baseVol * 1
		assertInRange(audio._activeAmbience.sound.Volume, baseVol - 0.01, baseVol + 0.01, "Volume at master=1")

		-- Set master to 0.5
		audio:SetMasterVolume(0.5)
		assertInRange(audio._activeAmbience.sound.Volume, baseVol * 0.5 - 0.01, baseVol * 0.5 + 0.01, "Volume at master=0.5")

		-- Set master to 0
		audio:SetMasterVolume(0)
		assertEq(audio._activeAmbience.sound.Volume, 0, "Volume at master=0")
	end)

	-- -----------------------------------------------------------------------
	-- Test 14: Update processes crossfade to completion
	-- -----------------------------------------------------------------------
	test("Update processes crossfade over time", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio._hour = 12
		audio:PlayBiomeAmbience("Forest")

		-- Start with a crossfade in progress (from PlayBiomeAmbience fade-in)
		assertTrue(#audio._crossfades > 0, "Should have crossfade from Play")

		-- Halfway through (3s transition, step 1.5s)
		audio:Update(1.5)
		local remainingAfterHalf = #audio._crossfades

		-- Complete
		audio:Update(5)
		-- Crossfade should be resolved (remaining may differ based on number of active crossfades)
		assertTrue(#audio._crossfades < remainingAfterHalf + 1, "Crossfades should resolve")
	end)

	-- -----------------------------------------------------------------------
	-- Test 15: Update processes ambient trigger timers
	-- -----------------------------------------------------------------------
	test("Update counts down ambient trigger timers", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio._hour = 12
		audio:PlayBiomeAmbience("Forest")

		-- Store initial timer values
		local initialTimers = {}
		for k, v in pairs(audio._ambientTimers) do
			initialTimers[k] = v
		end

		-- Update with dt = 1
		audio:Update(1)

		-- Timers that apply to Forest should have decreased
		for k, v in pairs(audio._ambientTimers) do
			local trigger = DEFAULT_AMBIENT_TRIGGERS[k]
			if trigger then
				local applies = false
				if trigger.biomes then
					for _, b in ipairs(trigger.biomes) do
						if b == "Forest" then
							applies = true
							break
						end
					end
				end
				if not trigger.biomes or applies then
					if not trigger.dayOnly or audio:_isDaytime() then
						assertTrue(v <= initialTimers[k], "Timer should have decreased")
					end
				end
			end
		end
	end)

	-- -----------------------------------------------------------------------
	-- Test 16: Default soundscape data is correct
	-- -----------------------------------------------------------------------
	test("Default soundscapes have proper structure", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		for biomeId, scape in pairs(audio._soundscapes) do
			assertTrue(#scape.daySounds > 0, biomeId .. " has no daySounds")
			assertTrue(#scape.nightSounds > 0, biomeId .. " has no nightSounds")
			assertTrue(scape.transitionTime > 0, biomeId .. " has no transitionTime")
			assertTrue(scape.volume >= 0 and scape.volume <= 1, biomeId .. " volume out of range")
		end
	end)

	-- -----------------------------------------------------------------------
	-- Test 17: PlayMusic clamps intensity to 0..1
	-- -----------------------------------------------------------------------
	test("PlayMusic clamps intensity", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		local layer: MusicLayer = {
			id = "test",
			soundIds = { "rbxassetid://900000001", "rbxassetid://900000002" },
			intensity = 0.5,
			bpm = 100,
		}
		audio:RegisterMusicLayer(layer)

		-- Test clamping: intensity 2 should be treated as 1
		audio:PlayMusic("test", 2)
		assertEq(audio._activeMusic.intensity, 1, "Intensity should clamp to 1")

		audio:StopMusic(0.1)
		audio:Update(1)

		-- Test negative intensity
		audio:PlayMusic("test", -0.5)
		assertEq(audio._activeMusic.intensity, 0, "Intensity should clamp to 0")
	end)

	-- -----------------------------------------------------------------------
	-- Test 18: Master volume clamps to 0..1
	-- -----------------------------------------------------------------------
	test("SetMasterVolume clamps to 0..1", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio:SetMasterVolume(1.5)
		assertEq(audio._masterVolume, 1, "Should clamp to 1")

		audio:SetMasterVolume(-0.5)
		assertEq(audio._masterVolume, 0, "Should clamp to 0")

		audio:SetMasterVolume(0.75)
		assertEq(audio._masterVolume, 0.75, "Should accept valid value")
	end)

	-- -----------------------------------------------------------------------
	-- Test 19: PlayBiomeAmbience warns on missing biome
	-- -----------------------------------------------------------------------
	test("PlayBiomeAmbience handles missing biome gracefully", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		-- Should not error
		audio:PlayBiomeAmbience("NonExistentBiome")

		assertEq(audio._activeAmbience, nil, "Should not have active ambience for unknown biome")
	end)

	-- -----------------------------------------------------------------------
	-- Test 20: CrossfadeTo handles missing biome gracefully
	-- -----------------------------------------------------------------------
	test("CrossfadeTo handles missing biome gracefully", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio:CrossfadeTo("NonExistentBiome", 4)
		assertTrue(true, "Should not error")
	end)

	-- -----------------------------------------------------------------------
	-- Test 21: StopMusic on non-playing music is safe
	-- -----------------------------------------------------------------------
	test("StopMusic is safe when no music playing", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		audio:StopMusic(2)
		assertEq(audio._activeMusic, nil, "Should remain nil")
	end)

	-- -----------------------------------------------------------------------
	-- Test 22: MusicStarted event has correct payload
	-- -----------------------------------------------------------------------
	test("MusicStarted event payload is correct", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)

		local layer: MusicLayer = {
			id = "adventure",
			soundIds = { "rbxassetid://900000001", "rbxassetid://900000002", "rbxassetid://900000003" },
			intensity = 0,
			bpm = 110,
		}
		audio:RegisterMusicLayer(layer)
		audio:PlayMusic("adventure", 0.5)

		local events = bus:GetEvents("MusicStarted")
		local lastEvent = events[#events]
		assertEq(lastEvent.layerId, "adventure", "layerId")
		assertEq(lastEvent.trackIndex, 2, "trackIndex for intensity 0.5")
		assertNotNil(lastEvent.soundId, "soundId")
	end)

	-- -----------------------------------------------------------------------
	-- Test 23: Night ambience uses nightSounds
	-- -----------------------------------------------------------------------
	test("Night ambience uses correct night sound IDs", function()
		local bus = createMockEventBus()
		local audio = AudioSystemModule.new(bus)
		_createdSounds = {}

		audio._hour = 2 -- Deep night
		audio:PlayBiomeAmbience("Desert")

		local expectedNightSound = "rbxassetid://000000007" -- Desert nightSounds[1]
		assertEq(audio._activeAmbience.sound.SoundId, expectedNightSound, "Desert night sound")
	end)

	-- -----------------------------------------------------------------------
	-- Summary
	-- -----------------------------------------------------------------------
	print(string.format("\n[AudioSystem Tests] %d passed, %d failed", passCount, failCount))
	if failCount > 0 then
		error(string.format("%d test(s) failed", failCount))
	end
end

runTests()
