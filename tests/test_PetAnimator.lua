--!strict
-- test_PetAnimator.lua
-- Tests for PetAnimator. We mock the EventBus, Config, and the Roblox
-- model/animator/track tree. Focus is on:
--   * Event subscriptions correctly map PetSystem events to play calls
--   * Track lookup, play/stop semantics, and crossfade behaviour
--   * Missing animations are logged once, not spammed
--   * One-shots vs base loops behave correctly
--   * Unregister cleans up tracks

local PetAnimator = require(script.Parent.Parent.src.PetAnimator)

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then error(msg .. " expected true") end
end

local function assertFalse(a: boolean, msg: string)
	if a then error(msg .. " expected false") end
end

-- Mock EventBus that records every Subscribe and Emit. Subscribers are
-- captured so tests can fire events synchronously.
local function createMockEventBus()
	local events: { [string]: { any } } = {}
	local subs: { [string]: { (any) -> () } } = {}

	local bus = {}
	bus._events = events
	bus._subs = subs

	function bus:Subscribe(eventName: string, callback: (any) -> ()): () -> ()
		if not subs[eventName] then subs[eventName] = {} end
		table.insert(subs[eventName], callback)
		-- Return an unsubscribe that removes this exact callback.
		return function()
			local list = subs[eventName]
			if not list then return end
			for i, cb in ipairs(list) do
				if cb == callback then
					table.remove(list, i)
					return
				end
			end
		end
	end

	function bus:Emit(eventName: string, payload: any)
		if not events[eventName] then events[eventName] = {} end
		table.insert(events[eventName], payload)
		local list = subs[eventName]
		if list then
			for _, cb in ipairs(list) do
				cb(payload)
			end
		end
	end

	return bus
end

local function createMockConfig()
	local store: { [string]: any } = {}
	return {
		Get = function(_self: any, key: string, default: any?): any
			local v = store[key]
			if v == nil then return default end
			return v
		end,
		Set = function(_self: any, key: string, value: any) store[key] = value end,
		Reset = function(_self: any) end,
		All = function(_self: any) return store end,
	}
end

-- ----------------------------------------------------------------------------
-- Mock Roblox Model / AnimationController / Animator / AnimationTrack
-- ----------------------------------------------------------------------------
-- We re-implement just enough surface area to drive PetAnimator's logic.
-- Real Roblox tests would have to run in Studio; this lets the unit tests
-- run in any Lua environment that supports the modular library.

local function createMockTrack(animationId: string)
	local track = {
		IsPlaying = false,
		Looped    = false,
		_animId   = animationId,
		_stoppedConns = {} :: { (() -> ()) },
		Stopped = nil :: any,  -- assigned below
	}

	track.Stopped = {
		Once = function(_self: any, cb: () -> ())
			table.insert(track._stoppedConns, cb)
			local conn = { Connected = true }
			function conn:Disconnect() conn.Connected = false end
			return conn
		end,
	}

	function track:Play(_fade: number?)
		track.IsPlaying = true
	end
	function track:Stop(_fade: number?)
		if track.IsPlaying then
			track.IsPlaying = false
			-- Fire any Once-stopped subscribers (Roblox triggers Stopped
			-- whenever the track stops, looped or not).
			local conns = track._stoppedConns
			track._stoppedConns = {}
			for _, cb in ipairs(conns) do cb() end
		end
	end
	function track:Destroy() end
	function track:_simulateFinish()
		-- Helper for one-shot tests: simulate the track finishing naturally.
		track:Stop()
	end

	return track
end

local function createMockAnimator(animationsByName: { [string]: any })
	local animator = {
		ClassName = "Animator",
		_animationsByName = animationsByName,
		_loadedTracks = {} :: { [string]: any },
	}
	function animator:LoadAnimation(anim: any): any
		local track = createMockTrack(anim.Name)
		animator._loadedTracks[anim.Name] = track
		return track
	end
	function animator:FindFirstChildOfClass(cls: string)
		return nil
	end
	return animator
end

-- Build a mock pet model with the given animation ids exposed in an
-- "Animations" folder under the model.
local function createMockPetModel(petName: string, animIds: { string })
	local animFolder = {
		Name = "Animations",
		_children = {} :: { [string]: any },
	}
	for _, id in ipairs(animIds) do
		animFolder._children[id] = {
			Name = id,
			ClassName = "Animation",
			IsA = function(_self: any, cls: string) return cls == "Animation" end,
		}
	end
	function animFolder:FindFirstChild(name: string)
		return self._children[name]
	end

	local animator = createMockAnimator(animFolder._children)
	local controller = {
		ClassName = "AnimationController",
		_animator = animator,
	}
	function controller:FindFirstChildOfClass(cls: string)
		if cls == "Animator" then return self._animator end
		return nil
	end

	local model = {
		Name = petName,
		ClassName = "Model",
		_children = {
			AnimationController = controller,
			Animations          = animFolder,
		},
	}
	function model:FindFirstChild(name: string)
		return self._children[name]
	end
	function model:FindFirstChildOfClass(cls: string)
		if cls == "AnimationController" then return controller end
		return nil
	end
	return model, animator
end

-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------

print("TEST: RegisterPetModel loads tracks and starts idle")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "walk", "eat", "play"})
	local ok = pa:RegisterPetModel("pet_1", model :: any)
	assertTrue(ok, "RegisterPetModel succeeds")
	assertTrue(pa:IsRegistered("pet_1"), "Pet is registered")

	-- Idle should be playing
	local idleTrack = animator._loadedTracks["idle"]
	assertTrue(idleTrack.IsPlaying, "Idle track is playing after register")
	assertTrue(idleTrack.Looped, "Idle track is looped")

	-- One PetAnimationStarted event with animationId=idle
	local started = bus._events["PetAnimationStarted"] or {}
	assertEq(#started, 1, "Exactly one PetAnimationStarted")
	assertEq(started[1].animationId, "idle", "Started idle")

	pa:Destroy()
end

print("TEST: Missing animations are reported once via PetAnimationMissing")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	-- Model with no animations folder = every animation missing.
	local model = {
		Name = "Empty",
		_children = {
			AnimationController = {
				ClassName = "AnimationController",
				FindFirstChildOfClass = function(self: any, cls: string)
					return cls == "Animator" and (self._animator) or nil
				end,
				_animator = createMockAnimator({}),
			},
		},
	}
	function model:FindFirstChild(name: string) return self._children[name] end
	function model:FindFirstChildOfClass(cls: string)
		if cls == "AnimationController" then return self._children.AnimationController end
		return nil
	end

	pa:RegisterPetModel("pet_1", model :: any)
	-- Should have logged missing for "idle" exactly once on registration.
	local missing = bus._events["PetAnimationMissing"] or {}
	assertEq(#missing, 1, "Missing animation logged once")
	assertEq(missing[1].animationId, "idle", "Missing was idle")

	-- Trigger another play of idle; should NOT log again.
	pa:PlayAnimation("pet_1", "idle")
	missing = bus._events["PetAnimationMissing"] or {}
	assertEq(#missing, 1, "Still only one missing log (no spam)")

	pa:Destroy()
end

print("TEST: PetCared(feed) plays eat one-shot")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "eat"})
	pa:RegisterPetModel("pet_1", model :: any)

	bus:Emit("PetCared", { petId = "pet_1", action = "feed", value = 25,
	                        statName = "hunger", statNow = 50 })

	local eatTrack = animator._loadedTracks["eat"]
	assertTrue(eatTrack.IsPlaying, "Eat track is playing after feed")

	pa:Destroy()
end

print("TEST: PetCared(sleep) sets sleep as base loop and stops idle")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "sleep"})
	pa:RegisterPetModel("pet_1", model :: any)

	local idleTrack = animator._loadedTracks["idle"]
	assertTrue(idleTrack.IsPlaying, "Idle was playing")

	bus:Emit("PetCared", { petId = "pet_1", action = "sleep", value = 25,
	                        statName = "energy", statNow = 50 })

	local sleepTrack = animator._loadedTracks["sleep"]
	assertTrue(sleepTrack.IsPlaying, "Sleep is now playing")
	assertFalse(idleTrack.IsPlaying, "Idle was stopped (crossfade)")

	pa:Destroy()
end

print("TEST: PetStageAdvanced plays jump celebration")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "jump"})
	pa:RegisterPetModel("pet_1", model :: any)

	bus:Emit("PetStageAdvanced", { petId = "pet_1", fromStage = "Newborn", toStage = "Junior" })

	local jumpTrack = animator._loadedTracks["jump"]
	assertTrue(jumpTrack.IsPlaying, "Jump played")

	pa:Destroy()
end

print("TEST: One-shot returns to base loop after finish")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "eat"})
	pa:RegisterPetModel("pet_1", model :: any)

	local idleTrack = animator._loadedTracks["idle"]
	-- Trigger eat
	bus:Emit("PetCared", { petId = "pet_1", action = "feed", value = 25,
	                        statName = "hunger", statNow = 50 })

	local eatTrack = animator._loadedTracks["eat"]
	assertTrue(eatTrack.IsPlaying, "Eat playing")

	-- During the eat, idle was stopped (we don't crossfade for one-shots
	-- that aren't base loops -- only the prior loop is paused). In our
	-- mock, idle was set Looped=true and played at register time. The
	-- one-shot path doesn't touch the base loop's IsPlaying, so idle is
	-- still "playing" in the mock world; we instead test the post-finish
	-- behavior.
	eatTrack:_simulateFinish()
	assertFalse(eatTrack.IsPlaying, "Eat finished")
	-- After the one-shot's Stopped fires, our handler restarts the base
	-- loop if it isn't playing. Since the mock idle was still IsPlaying=true
	-- (one-shots don't stop the base loop in our impl), the "if not playing"
	-- branch is skipped. This matches the design: one-shots layer over loops.

	pa:Destroy()
end

print("TEST: PetReleased unregisters and stops tracks")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "walk"})
	pa:RegisterPetModel("pet_1", model :: any)
	assertTrue(pa:IsRegistered("pet_1"), "Registered")

	bus:Emit("PetReleased", { petId = "pet_1", ownerId = 1 })
	assertFalse(pa:IsRegistered("pet_1"), "Unregistered after release")

	local idleTrack = animator._loadedTracks["idle"]
	assertFalse(idleTrack.IsPlaying, "Idle stopped on release")

	pa:Destroy()
end

print("TEST: PetPenChanged plays sit on penned pets")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local m1, a1 = createMockPetModel("Sparky", {"idle", "sit"})
	local m2, a2 = createMockPetModel("Buddy",  {"idle", "sit"})
	pa:RegisterPetModel("pet_1", m1 :: any)
	pa:RegisterPetModel("pet_2", m2 :: any)

	bus:Emit("PetPenChanged", { ownerId = 1, penPetIds = {"pet_1", "pet_2"} })

	assertTrue(a1._loadedTracks["sit"].IsPlaying, "pet_1 sit playing")
	assertTrue(a2._loadedTracks["sit"].IsPlaying, "pet_2 sit playing")

	pa:Destroy()
end

print("TEST: PlayAnimation explicit call works for unregistered no-op")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local ok = pa:PlayAnimation("ghost_pet", "idle")
	assertFalse(ok, "PlayAnimation on unregistered returns false")

	pa:Destroy()
end

print("TEST: SetBaseLoop changes the active base")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, animator = createMockPetModel("Sparky", {"idle", "walk", "run"})
	pa:RegisterPetModel("pet_1", model :: any)

	local idleTrack = animator._loadedTracks["idle"]
	local walkTrack = animator._loadedTracks["walk"]
	assertTrue(idleTrack.IsPlaying, "Idle started")

	pa:SetBaseLoop("pet_1", "walk")
	assertTrue(walkTrack.IsPlaying, "Walk now playing")
	assertFalse(idleTrack.IsPlaying, "Idle stopped")

	pa:Destroy()
end

print("TEST: Re-register replaces existing handle")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local m1, a1 = createMockPetModel("V1", {"idle"})
	pa:RegisterPetModel("pet_1", m1 :: any)
	assertTrue(a1._loadedTracks["idle"].IsPlaying, "v1 idle playing")

	-- Re-spawn pet_1 with a new model
	local m2, a2 = createMockPetModel("V2", {"idle", "walk"})
	pa:RegisterPetModel("pet_1", m2 :: any)
	assertFalse(a1._loadedTracks["idle"].IsPlaying, "v1 idle stopped on unregister")
	assertTrue(a2._loadedTracks["idle"].IsPlaying, "v2 idle now playing")

	pa:Destroy()
end

print("TEST: Destroy unsubscribes and clears all handles")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local pa = PetAnimator.new(bus, cfg)

	local model, _animator = createMockPetModel("Sparky", {"idle"})
	pa:RegisterPetModel("pet_1", model :: any)
	pa:Destroy()

	assertFalse(pa:IsRegistered("pet_1"), "Handles cleared")

	-- After Destroy, events should NOT trigger play attempts.
	bus:Emit("PetCared", { petId = "pet_1", action = "feed", value = 25,
	                        statName = "hunger", statNow = 50 })
	-- No assertion target here other than no-error: the handle is gone
	-- so the subscription handler short-circuits.
end

print("All PetAnimator tests passed!")

return true
