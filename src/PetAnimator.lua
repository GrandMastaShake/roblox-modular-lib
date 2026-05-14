--!strict
-- PetAnimator.lua
-- Server-side pet animation playback. Closes the loop between PetSystem
-- state changes (feed / play / sleep / following / pen / stage advance)
-- and the visual animation tracks playing on each pet's in-world model.
--
-- ============================================================================
-- DESIGN OVERVIEW
-- ============================================================================
--
-- PetSystem owns gameplay state. PetAnimator is a thin "view layer" that
-- subscribes to the relevant events and translates them into AnimationTrack
-- play/stop calls on the pet's model. PetSystem never knows PetAnimator
-- exists; PetAnimator never mutates pet state.
--
-- The flow:
--   PetSystem:Feed(petId, ...)
--     -> emits "PetCared" { action="feed" }
--     -> PetAnimator subscriber maps "feed" -> "eat" animation
--     -> AnimationTrack.Play() on the registered model's Animator
--
-- ============================================================================
-- MODEL REGISTRATION
-- ============================================================================
--
-- The composition root (PetGame.lua, or a per-server "spawn pet model"
-- handler) is responsible for:
--   1. Spawning the pet's Model in the workspace
--   2. Loading the 8 Animation instances under
--      Model/AnimationFolder/<animation_id> (e.g. "idle", "walk", "run", etc.)
--   3. Calling :RegisterPetModel(petId, model)
--
-- This module DOES NOT spawn models or load Animation assets itself. That's
-- a deliberate seam \u2014 a real game has a streaming layer that decides when
-- a pet is in render range, when to stream out, etc. PetAnimator just
-- accepts the Model when it appears and forgets it when told.
--
-- ============================================================================
-- ANIMATION RESOLUTION
-- ============================================================================
--
-- Pet models are NOT Humanoid \u2014 they use a custom quadruped skeleton from
-- pet_skeleton.py. We therefore drive animations via AnimationController +
-- Animator (the non-Humanoid path), looking up Animation instances by name
-- inside an AnimationFolder ObjectValue or Folder under the model.
--
-- Naming contract: each Animation instance is named exactly the same as the
-- animation_id from pet_animator.py: "idle", "walk", "run", "sit", "sleep",
-- "jump", "eat", "play". If a name isn't found, the request is silently
-- skipped and a debug print logs once per missing animation per pet.
--
-- ============================================================================
-- EVENT MAPPING
-- ============================================================================
--
--   PetHatched           -> nothing (pet is still an Egg, no model yet)
--   PetCared(feed)       -> play "eat", then return to base loop
--   PetCared(play)       -> play "play", then return to base loop
--   PetCared(sleep)      -> play "sleep" (loops)
--   PetStageAdvanced     -> one-shot "jump" celebration, then base loop
--   PetFollowingChanged  -> set base loop to "walk" while moving, "idle" otherwise
--                            (we default to "idle"; PetGame.lua can drive
--                             "walk" from a humanoid-state listener)
--   PetReleased          -> stop all tracks, unregister
--
-- "Base loop" = whatever animation should be running when the pet isn't
-- doing a one-shot. By default: "idle".
--
-- ============================================================================
-- EMITTED EVENTS
-- ============================================================================
--
-- PetAnimationStarted  { petId, animationId, source: "event"|"explicit" }
-- PetAnimationStopped  { petId, animationId }
-- PetAnimationMissing  { petId, animationId }  -- debug aid

local RunService = game:GetService("RunService")

local EventBus = require(script.Parent.Core.EventBus)
local Config   = require(script.Parent.Core.Config)

local PetAnimator = {}
PetAnimator.__index = PetAnimator

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local DEFAULT_FADE_TIME = 0.3   -- Crossfade between animations, seconds.
local DEFAULT_BASE_LOOP = "idle"

-- Animation ids the Blender side produces. Mirrors pet_animator.ANIMATION_IDS.
local KNOWN_ANIMATIONS: { string } = {
	"idle", "walk", "run", "sit", "sleep", "jump", "eat", "play",
}

-- One-shot animations: play once, then return to base loop.
local ONE_SHOTS: { [string]: boolean } = {
	jump = true,
	eat  = true,
	play = true,
	sit  = true,  -- pet sits, holds; PetAnimator returns to idle after duration
}

-- Mapping from PetCared.action to animation id.
-- "feed" -> "eat" because the gameplay action and animation id differ.
local CARE_TO_ANIM: { [string]: string } = {
	feed  = "eat",
	play  = "play",
	sleep = "sleep",
}

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

export type PetModelHandle = {
	petId: string,
	model: Model,
	animator: Animator,
	tracks: { [string]: AnimationTrack },     -- animation_id -> loaded track
	currentLoop: string,                       -- which loop is the "base"
	currentOneShot: string?,                   -- one-shot currently playing
	missingLogged: { [string]: boolean },      -- avoid spamming missing-anim warnings
}

export type PetAnimator = {
	RegisterPetModel:    (self: PetAnimator, petId: string, model: Model) -> boolean,
	UnregisterPetModel:  (self: PetAnimator, petId: string) -> (),
	PlayAnimation:       (self: PetAnimator, petId: string, animationId: string) -> boolean,
	SetBaseLoop:         (self: PetAnimator, petId: string, animationId: string) -> (),
	StopAll:             (self: PetAnimator, petId: string) -> (),
	IsRegistered:        (self: PetAnimator, petId: string) -> boolean,
	Destroy:             (self: PetAnimator) -> (),

	-- Private
	_eventBus:        EventBus.EventBus,
	_config:          Config.Config,
	_handles:         { [string]: PetModelHandle },
	_subscriptions:   { () -> () },
	_fadeTime:        number,
}

-- ----------------------------------------------------------------------------
-- Constructor
-- ----------------------------------------------------------------------------

function PetAnimator.new(eventBus: EventBus.EventBus, config: Config.Config?): PetAnimator
	local self = setmetatable({}, PetAnimator) :: PetAnimator
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._handles = {}
	self._subscriptions = {}
	self._fadeTime = self._config:Get("petAnimatorFadeTime", DEFAULT_FADE_TIME) :: number

	self:_subscribeToPetEvents()
	return self
end

-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------

-- Find the AnimationController + Animator on a pet model. Returns nil if
-- the model isn't a pet rig (no AnimationController). We accept both
-- AnimationController (non-Humanoid) and Humanoid (just in case a pet was
-- imported as a Humanoid by mistake) to be friendly.
local function findAnimator(model: Model): Animator?
	local controller = model:FindFirstChildOfClass("AnimationController")
		or model:FindFirstChildOfClass("Humanoid")
	if controller == nil then
		return nil
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if animator == nil then
		-- Roblox auto-creates an Animator when an AnimationTrack is loaded,
		-- but we'd rather have it explicit so :LoadAnimation works the
		-- moment the model spawns.
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	return animator
end

-- Find the folder of Animation instances on the model. We look for either:
--   model.Animations (Folder)
--   model.AnimationFolder (Folder or ObjectValue)
-- This matches the convention the rest of the toolkit uses.
local function findAnimationFolder(model: Model): Instance?
	return model:FindFirstChild("Animations")
		or model:FindFirstChild("AnimationFolder")
end

-- Pre-load every known animation as an AnimationTrack. Tracks are cached
-- per pet. Missing animations are recorded in missingLogged so we only
-- complain about each one once.
local function loadTracks(handle: PetModelHandle): ()
	local folder = findAnimationFolder(handle.model)
	if folder == nil then
		return
	end

	for _, animId in ipairs(KNOWN_ANIMATIONS) do
		local animInstance = folder:FindFirstChild(animId)
		if animInstance and animInstance:IsA("Animation") then
			local ok, track = pcall(function()
				return handle.animator:LoadAnimation(animInstance)
			end)
			if ok and track then
				handle.tracks[animId] = track
			end
		end
	end
end

-- ----------------------------------------------------------------------------
-- Track playback
-- ----------------------------------------------------------------------------

function PetAnimator:_logMissingOnce(handle: PetModelHandle, animationId: string)
	if handle.missingLogged[animationId] then
		return
	end
	handle.missingLogged[animationId] = true
	self._eventBus:Emit("PetAnimationMissing", {
		petId       = handle.petId,
		animationId = animationId,
	})
end

-- Play a track on the handle. Stops any current one-shot first; for loops,
-- we crossfade. Returns whether the play actually happened.
function PetAnimator:_playTrack(handle: PetModelHandle, animationId: string, isOneShot: boolean): boolean
	local track = handle.tracks[animationId]
	if not track then
		self:_logMissingOnce(handle, animationId)
		return false
	end

	-- Stop the current one-shot if any (we don't want jumps stomping eats).
	if handle.currentOneShot and handle.currentOneShot ~= animationId then
		local prevTrack = handle.tracks[handle.currentOneShot]
		if prevTrack and prevTrack.IsPlaying then
			prevTrack:Stop(self._fadeTime)
		end
		handle.currentOneShot = nil
	end

	-- For loops, only re-trigger if it's not the current loop already.
	if not isOneShot and handle.currentLoop == animationId and track.IsPlaying then
		return true  -- already running, nothing to do
	end

	-- Stop the prior loop if it's a different one (crossfade).
	if not isOneShot and handle.currentLoop ~= animationId then
		local prevLoop = handle.tracks[handle.currentLoop]
		if prevLoop and prevLoop.IsPlaying then
			prevLoop:Stop(self._fadeTime)
		end
		handle.currentLoop = animationId
	end

	-- Configure looping on the track based on our knowledge.
	-- Loops in pet_animator: idle, walk, run, sleep
	local shouldLoop = (animationId == "idle" or animationId == "walk"
		or animationId == "run" or animationId == "sleep")
	track.Looped = shouldLoop

	track:Play(self._fadeTime)

	if isOneShot then
		handle.currentOneShot = animationId
		-- Schedule return-to-base when the one-shot finishes.
		local connection: RBXScriptConnection? = nil
		connection = track.Stopped:Once(function()
			-- IsRegistered check guards against the pet being released
			-- mid-animation.
			if self._handles[handle.petId] == handle and handle.currentOneShot == animationId then
				handle.currentOneShot = nil
				-- Re-trigger the base loop (it'll be idempotent).
				local base = handle.tracks[handle.currentLoop]
				if base and not base.IsPlaying then
					base:Play(self._fadeTime)
				end
			end
			if connection then
				connection:Disconnect()
			end
		end)
	end

	self._eventBus:Emit("PetAnimationStarted", {
		petId       = handle.petId,
		animationId = animationId,
		source      = "explicit",
	})
	return true
end

-- ----------------------------------------------------------------------------
-- PetSystem event subscriptions
-- ----------------------------------------------------------------------------

function PetAnimator:_subscribeToPetEvents()
	-- PetCared: map action to animation, play as one-shot.
	-- "sleep" is a special case \u2014 it's a loop that lasts until the next
	-- gameplay action interrupts it. We treat sleep as a base-loop change.
	table.insert(self._subscriptions, self._eventBus:Subscribe("PetCared", function(data)
		local handle = self._handles[data.petId]
		if not handle then return end

		local animId = CARE_TO_ANIM[data.action]
		if not animId then return end

		if data.action == "sleep" then
			self:SetBaseLoop(data.petId, "sleep")
		else
			self:_playTrack(handle, animId, true)
		end
	end))

	-- Stage advance: celebrate with a jump.
	table.insert(self._subscriptions, self._eventBus:Subscribe("PetStageAdvanced", function(data)
		local handle = self._handles[data.petId]
		if not handle then return end
		self:_playTrack(handle, "jump", true)
	end))

	-- Following changed: a pet that just started following gets the idle
	-- loop; a pet that stopped following has its tracks stopped (model
	-- usually de-spawns shortly after but we don't want it to keep
	-- animating off-screen).
	table.insert(self._subscriptions, self._eventBus:Subscribe("PetFollowingChanged", function(data)
		-- data.followingPetIds is the new set; we don't know individual
		-- transitions, so we just ensure every following pet is on idle.
		for _, petId in ipairs(data.followingPetIds) do
			local handle = self._handles[petId]
			if handle and handle.currentLoop ~= "walk" and handle.currentLoop ~= "run" then
				self:SetBaseLoop(petId, DEFAULT_BASE_LOOP)
			end
		end
	end))

	-- Pen change: pets in the pen sit (Adopt-Me-style).
	table.insert(self._subscriptions, self._eventBus:Subscribe("PetPenChanged", function(data)
		for _, petId in ipairs(data.penPetIds) do
			local handle = self._handles[petId]
			if handle then
				self:_playTrack(handle, "sit", true)
			end
		end
	end))

	-- Released: stop everything and forget.
	table.insert(self._subscriptions, self._eventBus:Subscribe("PetReleased", function(data)
		self:UnregisterPetModel(data.petId)
	end))

	-- Hatched: do nothing visually here. The model spawn flow lives in the
	-- composition root; it should call :RegisterPetModel after spawning.
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

function PetAnimator:RegisterPetModel(petId: string, model: Model): boolean
	if self._handles[petId] then
		-- Already registered \u2014 unregister first so a re-spawn picks up
		-- the new model cleanly.
		self:UnregisterPetModel(petId)
	end

	local animator = findAnimator(model)
	if animator == nil then
		warn(("[PetAnimator] Pet '%s' model has no AnimationController/Humanoid; skipping."):format(petId))
		return false
	end

	local handle: PetModelHandle = {
		petId          = petId,
		model          = model,
		animator       = animator,
		tracks         = {},
		currentLoop    = DEFAULT_BASE_LOOP,
		currentOneShot = nil,
		missingLogged  = {},
	}

	loadTracks(handle)
	self._handles[petId] = handle

	-- Kick off the base loop if it's available.
	local baseTrack = handle.tracks[DEFAULT_BASE_LOOP]
	if baseTrack then
		baseTrack.Looped = true
		baseTrack:Play(self._fadeTime)
		self._eventBus:Emit("PetAnimationStarted", {
			petId       = petId,
			animationId = DEFAULT_BASE_LOOP,
			source      = "event",
		})
	else
		self:_logMissingOnce(handle, DEFAULT_BASE_LOOP)
	end
	return true
end

function PetAnimator:UnregisterPetModel(petId: string)
	local handle = self._handles[petId]
	if not handle then return end

	for animId, track in pairs(handle.tracks) do
		if track.IsPlaying then
			track:Stop(0)
		end
		track:Destroy()
		self._eventBus:Emit("PetAnimationStopped", {
			petId       = petId,
			animationId = animId,
		})
	end
	self._handles[petId] = nil
end

function PetAnimator:PlayAnimation(petId: string, animationId: string): boolean
	local handle = self._handles[petId]
	if not handle then return false end
	local isOneShot = ONE_SHOTS[animationId] == true
	return self:_playTrack(handle, animationId, isOneShot)
end

function PetAnimator:SetBaseLoop(petId: string, animationId: string)
	local handle = self._handles[petId]
	if not handle then return end
	-- Treat as a non-one-shot so _playTrack handles the crossfade correctly.
	self:_playTrack(handle, animationId, false)
end

function PetAnimator:StopAll(petId: string)
	local handle = self._handles[petId]
	if not handle then return end
	for _, track in pairs(handle.tracks) do
		if track.IsPlaying then
			track:Stop(self._fadeTime)
		end
	end
	handle.currentOneShot = nil
end

function PetAnimator:IsRegistered(petId: string): boolean
	return self._handles[petId] ~= nil
end

-- ----------------------------------------------------------------------------
-- Cleanup
-- ----------------------------------------------------------------------------

function PetAnimator:Destroy()
	for _, unsubscribe in ipairs(self._subscriptions) do
		pcall(unsubscribe)
	end
	self._subscriptions = {}

	for petId, _ in pairs(self._handles) do
		self:UnregisterPetModel(petId)
	end
	self._handles = {}
end

return PetAnimator
