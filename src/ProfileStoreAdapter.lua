--!strict
-- ProfileStoreAdapter.lua
-- Optional adapter to the community ProfileStore module. Falls back to
-- DataStoreSafe v2 when ProfileStore isn't available.
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
--
-- The Perplexity research treats ProfileStore (https://devforum.roblox.com/
-- t/profilestore-save-your-player-data-easy-datastore-module/3190543) as the
-- canonical session-lock library for any Roblox game with a trading economy.
-- It writes a JobId "hall pass" into each profile's DataStore key, blocking
-- the rejoin-before-save duplication exploit at the foundation.
--
-- Many studios already standardize on ProfileStore. Others roll their own.
-- This adapter:
--
--   * Tries to require ProfileStore from a configurable path (default:
--     ServerScriptService.ProfileStore). If found, every public method
--     delegates to ProfileStore.
--   * If ProfileStore isn't there, falls back to our DataStoreSafe v2
--     session locks (MemoryStoreService-based). The public API is the
--     same either way; the trade hardening above doesn't care which
--     mechanism is providing single-server-ownership guarantees.
--
-- Either implementation supports the contract TradeCoordinator needs:
--
--   :Start(userId, template) -> profile
--     Begins a session. Returns nil/throws if another server holds the lock.
--
--   :Get(userId, bypassCache?) -> profile.Data
--     Fast accessor for the current value. With bypassCache=true, refresh
--     from the DataStore (used by Phase 3 verification).
--
--   :Release(userId) -> ()
--     Releases the session lock.
--
--   :OnRelease(userId, callback) -> ()
--     Hook the moment the session is released (e.g. by a different
--     server stealing it). The composition root uses this to kick the
--     player.
--
--   :GetRawStore() -> any
--     Returns the underlying DataStore instance for direct UpdateAsync.
--     TradeCoordinator's transforms run on this store.
--
-- ============================================================================
-- CONFIGURATION
-- ============================================================================
--
--   Config keys read at construction:
--     profileStorePath: ObjectPath?  -- Where to look for ProfileStore.
--                                      Default: ServerScriptService.ProfileStore
--     profileStoreName: string       -- Store name passed to ProfileStore:New.
--                                      Default: the `name` constructor arg.

local ServerScriptService = game:GetService("ServerScriptService")

local DataStoreSafe = require(script.Parent.DataStoreSafe)
local Config        = require(script.Parent.Core.Config)
local EventBus      = require(script.Parent.Core.EventBus)

local ProfileStoreAdapter = {}
ProfileStoreAdapter.__index = ProfileStoreAdapter

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

export type ProfileStoreAdapterDeps = {
	-- Optional: explicit ProfileStore module override (mainly for testing).
	profileStoreModule: any?,
}

export type ProfileStoreAdapter = {
	Start:        (self: ProfileStoreAdapter, userId: number, template: { [string]: any }?) -> any?,
	Get:          (self: ProfileStoreAdapter, userId: number, bypassCache: boolean?) -> any?,
	Release:      (self: ProfileStoreAdapter, userId: number) -> (),
	OnRelease:    (self: ProfileStoreAdapter, userId: number, callback: () -> ()) -> (),
	GetRawStore:  (self: ProfileStoreAdapter) -> any,
	UsingProfileStore: (self: ProfileStoreAdapter) -> boolean,
	Destroy:      (self: ProfileStoreAdapter) -> (),

	-- Private
	_eventBus:    EventBus.EventBus,
	_config:      Config.Config,
	_name:        string,
	_profileStoreModule: any?,
	_profileStoreInstance: any?,
	_fallbackStore: DataStoreSafe.DataStoreSafe?,
	_fallbackProfiles: { [number]: { Data: { [string]: any }, _userId: number } },
	_releaseCallbacks: { [number]: { () -> () } },
}

-- ----------------------------------------------------------------------------
-- Constructor
-- ----------------------------------------------------------------------------

function ProfileStoreAdapter.new(
	name: string,
	eventBus: EventBus.EventBus,
	deps: ProfileStoreAdapterDeps?,
	config: Config.Config?
): ProfileStoreAdapter
	local self = setmetatable({}, ProfileStoreAdapter) :: ProfileStoreAdapter
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._name = name
	self._fallbackProfiles = {}
	self._releaseCallbacks = {}

	-- Try to locate the ProfileStore module:
	--   1. Explicitly injected via deps (testing path)
	--   2. Configurable path via Config:Get("profileStorePath", ...)
	--   3. Default location: ServerScriptService.ProfileStore
	local explicitModule = deps and deps.profileStoreModule or nil
	if explicitModule then
		self._profileStoreModule = explicitModule
	else
		local pathFromConfig = self._config:Get("profileStorePath", nil)
		local moduleScript = if pathFromConfig
			then pathFromConfig
			else ServerScriptService:FindFirstChild("ProfileStore")
		if moduleScript then
			local ok, mod = pcall(require, moduleScript)
			if ok then
				self._profileStoreModule = mod
			end
		end
	end

	if self._profileStoreModule then
		-- ProfileStore's public constructor varies slightly between v0/v1.
		-- The v1+ API is `ProfileStore.New(name, template)` returning a
		-- store object. Older variants (ProfileService) use `:GetProfileStore`.
		-- We try the modern API first, fall back to the older one.
		local store: any = nil
		local tmpl = self._config:Get("profileTemplate", {}) :: { [string]: any }
		local okNew, result = pcall(function()
			return self._profileStoreModule.New(name, tmpl)
		end)
		if okNew and result then
			store = result
		else
			local okOld, result2 = pcall(function()
				return self._profileStoreModule:GetProfileStore(name, tmpl)
			end)
			if okOld and result2 then
				store = result2
			end
		end
		self._profileStoreInstance = store
		if not store then
			-- Module exists but we couldn't construct against it; fall back.
			self._profileStoreModule = nil
		end
	end

	-- Always set up the fallback store. Even when ProfileStore is the active
	-- session-lock provider, TradeCoordinator's :GetRawStore call needs a
	-- DataStore instance \u2014 ProfileStore exposes one via :_data_store.
	local fallbackConfig: DataStoreSafe.DataStoreSafeConfig = {
		retries    = self._config:Get("dataStoreRetries", 3) :: number,
		retryDelay = self._config:Get("dataStoreRetryDelay", 1) :: number,
		useCache   = false,
	}
	self._fallbackStore = DataStoreSafe.new(name, fallbackConfig)

	return self
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

function ProfileStoreAdapter:UsingProfileStore(): boolean
	return self._profileStoreInstance ~= nil
end

function ProfileStoreAdapter:GetRawStore(): any
	-- ProfileStore-active path: dig into the underlying DataStore instance
	-- so TradeCoordinator can run UpdateAsync transforms directly. Field
	-- name varies by ProfileStore version; we try the documented public
	-- accessor first.
	if self._profileStoreInstance then
		local accessors = { "GetDataStore", "_data_store", "DataStore" }
		for _, accessor in ipairs(accessors) do
			local raw: any = nil
			local ok = pcall(function()
				local field = (self._profileStoreInstance :: any)[accessor]
				if type(field) == "function" then
					raw = field(self._profileStoreInstance)
				elseif field ~= nil then
					raw = field
				end
			end)
			if ok and raw then
				return raw
			end
		end
		-- Last resort: ProfileStore stores its DataStore as a private field.
		-- This is a documented name in the ProfileStore source.
		local privateFields = { "_data_store", "_DataStore", "Mock" }
		for _, fieldName in ipairs(privateFields) do
			local raw = (self._profileStoreInstance :: any)[fieldName]
			if raw then return raw end
		end
	end
	-- Fallback: use the DataStoreSafe v2's underlying store. We expose
	-- this via a small accessor.
	if self._fallbackStore and (self._fallbackStore :: any)._store then
		return (self._fallbackStore :: any)._store
	end
	error("[ProfileStoreAdapter] Could not locate raw DataStore instance.")
end

function ProfileStoreAdapter:Start(userId: number, template: { [string]: any }?): any?
	-- ProfileStore-active path
	if self._profileStoreInstance then
		local profileKey = tostring(userId)
		local profile: any = nil

		-- ProfileStore v1+: :StartSessionAsync; older: :LoadProfileAsync.
		local okNew, result = pcall(function()
			return self._profileStoreInstance:StartSessionAsync(profileKey, {
				Cancel = function() return false end,
			})
		end)
		if okNew and result then
			profile = result
		else
			local okOld, result2 = pcall(function()
				return self._profileStoreInstance:LoadProfileAsync(profileKey)
			end)
			if okOld and result2 then
				profile = result2
			end
		end

		if not profile then
			return nil
		end

		-- Hook OnSessionEnd / ListenToRelease to our release-callbacks map.
		local hookOk = pcall(function()
			if profile.OnSessionEnd then
				profile.OnSessionEnd:Connect(function()
					self:_fireReleaseCallbacks(userId)
				end)
			elseif profile.ListenToRelease then
				profile:ListenToRelease(function()
					self:_fireReleaseCallbacks(userId)
				end)
			end
		end)
		if not hookOk then
			-- Non-fatal: callbacks just won't fire on release.
		end

		-- ProfileStore Reconcile fills in any missing template keys.
		if template then
			pcall(function() profile:Reconcile() end)
		end

		return profile
	end

	-- Fallback path: in-memory profile backed by DataStoreSafe v2.
	if not self._fallbackStore then
		return nil
	end
	-- Acquire session lock.
	local locked = self._fallbackStore:LockSession(tostring(userId))
	if not locked then
		return nil
	end
	-- Reconcile defaults from template.
	local data = if template
		then self._fallbackStore:Reconcile(tostring(userId), template)
		else (self._fallbackStore:Load(tostring(userId)) or {})

	local profile = {
		Data    = data,
		_userId = userId,
		Release = function(p)
			self:Release(p._userId)
		end,
		Save = function(p)
			if self._fallbackStore then
				self._fallbackStore:Save(tostring(p._userId), p.Data)
			end
		end,
		Reconcile = function(_p) end,  -- already handled at Start time
		ListenToRelease = function(_p, cb)
			self:OnRelease(userId, cb)
		end,
	}
	self._fallbackProfiles[userId] = profile
	return profile
end

-- bypassCache=true forces a fresh read from the DataStore, used by
-- TradeCoordinator's Phase 3 verification (the docs require UseCache=false
-- + a 5s wait to outlast the read cache).
function ProfileStoreAdapter:Get(userId: number, bypassCache: boolean?): any?
	if self._profileStoreInstance then
		-- ProfileStore typically caches the live profile in memory. For a
		-- bypass, we read directly from the underlying DataStore.
		if bypassCache then
			local rawStore = self:GetRawStore()
			local opts: any = nil
			-- DataStoreGetOptions is a real Roblox class; in tests/mocks it
			-- might not exist. Construction is wrapped in pcall.
			local hasOpts = pcall(function()
				opts = (Instance :: any).new("DataStoreGetOptions")
				opts.UseCache = false
			end)
			local _ = hasOpts
			local ok, data = pcall(function()
				if opts then
					return rawStore:GetAsync(tostring(userId), opts)
				end
				return rawStore:GetAsync(tostring(userId))
			end)
			if ok then return data end
			return nil
		end
		-- Default path: return the live cached profile data.
		local activeProfiles: any = (self._profileStoreInstance :: any).Profiles
		if activeProfiles and activeProfiles[tostring(userId)] then
			return activeProfiles[tostring(userId)].Data
		end
		-- Some ProfileStore versions have a different accessor; try a
		-- handful before giving up.
		local candidates = { "GetActiveProfile", "GetProfile" }
		for _, accessor in ipairs(candidates) do
			local fn = (self._profileStoreInstance :: any)[accessor]
			if type(fn) == "function" then
				local ok, profile = pcall(fn, self._profileStoreInstance, tostring(userId))
				if ok and profile and profile.Data then
					return profile.Data
				end
			end
		end
		return nil
	end

	-- Fallback path
	if bypassCache and self._fallbackStore then
		self._fallbackStore:ClearCache(tostring(userId))
	end
	local profile = self._fallbackProfiles[userId]
	if profile then
		if bypassCache and self._fallbackStore then
			-- Re-read from DataStore.
			profile.Data = self._fallbackStore:Load(tostring(userId)) or profile.Data
		end
		return profile.Data
	end
	if self._fallbackStore then
		return self._fallbackStore:Load(tostring(userId))
	end
	return nil
end

function ProfileStoreAdapter:Release(userId: number)
	if self._profileStoreInstance then
		local activeProfiles: any = (self._profileStoreInstance :: any).Profiles
		if activeProfiles and activeProfiles[tostring(userId)] then
			pcall(function()
				activeProfiles[tostring(userId)]:EndSession()
			end)
			pcall(function()
				activeProfiles[tostring(userId)]:Release()
			end)
		end
	end
	if self._fallbackStore then
		self._fallbackStore:ReleaseSession(tostring(userId))
	end
	self._fallbackProfiles[userId] = nil
	self:_fireReleaseCallbacks(userId)
end

function ProfileStoreAdapter:OnRelease(userId: number, callback: () -> ())
	if not self._releaseCallbacks[userId] then
		self._releaseCallbacks[userId] = {}
	end
	table.insert(self._releaseCallbacks[userId], callback)
end

function ProfileStoreAdapter:_fireReleaseCallbacks(userId: number)
	local cbs = self._releaseCallbacks[userId]
	if not cbs then return end
	self._releaseCallbacks[userId] = nil
	for _, cb in ipairs(cbs) do
		pcall(cb)
	end
end

-- ----------------------------------------------------------------------------
-- Cleanup
-- ----------------------------------------------------------------------------

function ProfileStoreAdapter:Destroy()
	-- Release every active fallback profile.
	for userId in pairs(self._fallbackProfiles) do
		self:Release(userId)
	end
	self._fallbackProfiles = {}
	self._releaseCallbacks = {}
	if self._fallbackStore then
		self._fallbackStore:Destroy()
	end
end

return ProfileStoreAdapter
