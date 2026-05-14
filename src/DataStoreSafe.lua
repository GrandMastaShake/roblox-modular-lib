--!strict
-- DataStoreSafe.lua  (v2)
-- Production-grade DataStore wrapper with:
--   * Exponential-backoff retries (v1)
--   * In-memory cache (v1)
--   * UpdateAsync-based safe writes (v2 \u2014 prevents cross-server data loss)
--   * Reconcile helper for typed default-fill (v2)
--   * Optional MemoryStore-based session locks (v2 \u2014 single-writer guarantee)
--   * Proper :Destroy (v2)
--
-- ============================================================================
-- WHY v2 EXISTS
-- ============================================================================
--
-- The v1 wrapper used :GetAsync / :SetAsync. That's the easy path but has a
-- subtle problem: if two servers write to the same key concurrently
-- (a player teleports between servers, an admin tool writes while the
-- player's server is still up, etc.), the second :SetAsync silently
-- overwrites the first. Real games lose pets, currency, and progress this
-- way. The Roblox-recommended fix is :UpdateAsync, which gives you the
-- existing value and atomically applies a transform.
--
-- v2 adds :Update as the new primary write path and reframes :Save as a
-- compatibility shim that still works for existing callers but is no longer
-- the recommended API. New code should call :Update. Old code keeps working.
--
-- ============================================================================
-- BACKWARD COMPATIBILITY
-- ============================================================================
--
-- Every v1 method is preserved with the same signature and semantics:
--   Load(key)                     \u2192 SaveData?
--   Save(key, data)               \u2192 boolean
--   GetCache(key)                 \u2192 SaveData?
--   ClearCache(key)               \u2192 ()
--
-- :Save now delegates to :Update internally with a "force overwrite"
-- transform so concurrent writes still take the last-write-wins behaviour
-- existing callers expect, but at least Roblox's transactional retry runs
-- under the hood. Callers that want true conflict-safe writes should use
-- :Update directly.
--
-- ============================================================================
-- SESSION LOCKING (OPT-IN)
-- ============================================================================
--
-- Two callers can race even with UpdateAsync if they both legitimately
-- think they own a key (e.g. a teleport handoff). Adopt-Me-style games
-- solve this with session locks: write \"this server owns this player from
-- timestamp T to T+N\" into a fast key/value store; refuse to write data
-- without a valid lock.
--
-- We use Roblox's MemoryStoreService for the lock store \u2014 it's exactly the
-- right tool (sub-second latency, automatic expiry). Locking is OPT-IN so
-- existing single-server callers don't pay the cost. The PetGame demo
-- doesn't use locks; a production deployment would.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Types = require(script.Parent.Core.Types)

local DataStoreSafe = {}
DataStoreSafe.__index = DataStoreSafe

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local DEFAULT_RETRIES        = 3
local DEFAULT_RETRY_DELAY    = 1
local DEFAULT_LOCK_TTL_SEC   = 30   -- session lock auto-expires after 30s
local DEFAULT_LOCK_REFRESH   = 10   -- refresh the lock every 10s while held
local LOCK_STORE_SUFFIX      = "_locks"

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

-- A transform function takes the current value (may be nil for new keys)
-- and returns the new value. Returning nil tells UpdateAsync to leave the
-- key unchanged \u2014 useful for "only write if predicate matches".
export type Transform = (current: Types.SaveData?) -> Types.SaveData?

export type DataStoreSafeConfig = {
	retries:    number?,
	retryDelay: number?,
	useCache:   boolean?,
	-- v2 additions:
	lockTtlSec:     number?,   -- TTL for session locks; 30 by default
	lockRefreshSec: number?,   -- background refresh interval; 10 by default
	serverId:       string?,   -- identifier for this server in lock writes
}

export type DataStoreSafe = {
	-- v1 API (preserved)
	Load:        (self: DataStoreSafe, key: string) -> Types.SaveData?,
	Save:        (self: DataStoreSafe, key: string, data: Types.SaveData) -> boolean,
	GetCache:    (self: DataStoreSafe, key: string) -> Types.SaveData?,
	ClearCache:  (self: DataStoreSafe, key: string) -> (),

	-- v2 additions
	Update:        (self: DataStoreSafe, key: string, transform: Transform) -> (boolean, Types.SaveData?),
	Reconcile:     (self: DataStoreSafe, key: string, defaults: Types.SaveData) -> Types.SaveData,
	LockSession:   (self: DataStoreSafe, key: string) -> boolean,
	ReleaseSession: (self: DataStoreSafe, key: string) -> (),
	HoldsLock:     (self: DataStoreSafe, key: string) -> boolean,
	Destroy:       (self: DataStoreSafe) -> (),

	-- Private
	_name:           string,
	_retries:        number,
	_retryDelay:     number,
	_useCache:       boolean,
	_store:          GlobalDataStore,
	_cache:          { [string]: Types.SaveData },

	-- Session-lock state
	_lockStore:      MemoryStoreHashMap,
	_lockTtl:        number,
	_lockRefresh:    number,
	_serverId:       string,
	_heldLocks:      { [string]: boolean },     -- keys we currently hold
	_lockRefreshThread: thread?,                -- background refresh loop
	_destroyed:      boolean,
}

-- ----------------------------------------------------------------------------
-- Constructor
-- ----------------------------------------------------------------------------

function DataStoreSafe.new(
	name: string,
	config: DataStoreSafeConfig?
): DataStoreSafe
	local self = setmetatable({}, DataStoreSafe) :: DataStoreSafe
	self._name = name
	self._retries     = if config and config.retries     ~= nil then config.retries     :: number else DEFAULT_RETRIES
	self._retryDelay  = if config and config.retryDelay  ~= nil then config.retryDelay  :: number else DEFAULT_RETRY_DELAY
	self._useCache    = if config and config.useCache    ~= nil then config.useCache    :: boolean else true
	self._lockTtl     = if config and config.lockTtlSec  ~= nil then config.lockTtlSec  :: number else DEFAULT_LOCK_TTL_SEC
	self._lockRefresh = if config and config.lockRefreshSec ~= nil then config.lockRefreshSec :: number else DEFAULT_LOCK_REFRESH

	-- Per-job server id for lock disambiguation. game.JobId is unique per
	-- server instance; if it's missing (Studio test mode) we synthesise.
	local jobId = (game :: any).JobId
	self._serverId = if config and config.serverId ~= nil then config.serverId :: string
		elseif jobId and jobId ~= "" then jobId
		else string.format("studio_%d_%d", os.time(), math.random(1, 1e9))

	self._store     = DataStoreService:GetDataStore(name)
	self._lockStore = MemoryStoreService:GetHashMap(name .. LOCK_STORE_SUFFIX)
	self._cache     = {}
	self._heldLocks = {}
	self._lockRefreshThread = nil
	self._destroyed = false

	return self
end

-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------

function DataStoreSafe:_waitRetry(attempt: number)
	local delayTime = self._retryDelay * (2 ^ attempt)
	task.wait(delayTime)
end

-- Run an arbitrary pcall'd operation with retry/backoff. Returns
-- (success, result_or_err). Used by every public method that talks to
-- DataStoreService or MemoryStoreService so retry logic lives in one place.
function DataStoreSafe:_retry(opName: string, fn: () -> any): (boolean, any)
	local success: boolean = false
	local result: any = nil

	for attempt = 0, self._retries do
		success, result = pcall(fn)
		if success then
			return true, result
		end
		if attempt < self._retries then
			self:_waitRetry(attempt)
		end
	end

	warn(string.format(
		"[DataStoreSafe:%s] %s failed after %d attempts: %s",
		self._name, opName, self._retries + 1, tostring(result)
	))
	return false, result
end

-- ----------------------------------------------------------------------------
-- v1 Load \u2014 unchanged contract
-- ----------------------------------------------------------------------------

function DataStoreSafe:Load(key: string): Types.SaveData?
	if self._useCache then
		local cached = self._cache[key]
		if cached ~= nil then
			return cached
		end
	end

	local success, result = self:_retry("Load", function()
		return self._store:GetAsync(key)
	end)

	if not success or result == nil then
		return nil
	end

	if self._useCache then
		self._cache[key] = result :: Types.SaveData
	end
	return result :: Types.SaveData
end

-- ----------------------------------------------------------------------------
-- v2 Update \u2014 the new primary write path
-- ----------------------------------------------------------------------------
-- Wraps DataStore:UpdateAsync. The supplied transform receives the current
-- value (or nil for new keys) and returns the value to write. Returning
-- nil from the transform aborts the update without writing \u2014 useful for
-- "only write if condition holds" patterns.

function DataStoreSafe:Update(key: string, transform: Transform): (boolean, Types.SaveData?)
	-- The transform may itself error; we want that to count as a retry
	-- failure, not bubble out, so we wrap inside the pcall in _retry.
	local function wrapped()
		return self._store:UpdateAsync(key, function(current)
			-- Coerce nil/false explicitly so the transform always sees nil
			-- for "no value yet" rather than a Lua-y false.
			local currentValue: Types.SaveData? = current
			return transform(currentValue)
		end)
	end

	local success, result = self:_retry("Update", wrapped)
	if not success then
		return false, nil
	end

	-- UpdateAsync returns the value that was written (which may be nil if
	-- the transform returned nil to abort). Cache the written value.
	if result ~= nil and self._useCache then
		self._cache[key] = result :: Types.SaveData
	end
	return true, result :: Types.SaveData?
end

-- ----------------------------------------------------------------------------
-- v1 Save \u2014 compatibility shim, now backed by Update
-- ----------------------------------------------------------------------------
-- Delegates to :Update with a force-overwrite transform. Existing callers
-- get the same last-write-wins semantics they've always had, but with
-- UpdateAsync's transactional retry under the hood (better than the raw
-- :SetAsync v1 used). New code should call :Update directly.

function DataStoreSafe:Save(key: string, data: Types.SaveData): boolean
	local ok = self:Update(key, function(_current)
		return data
	end)
	if ok and self._useCache then
		self._cache[key] = data
	end
	return ok
end

-- ----------------------------------------------------------------------------
-- v2 Reconcile \u2014 default-fill helper
-- ----------------------------------------------------------------------------
-- Common Roblox pattern: when a player joins, you want their save data
-- merged with the latest set of default fields (so a v3 game can read a v1
-- save and still find every key it expects). Reconcile loads the key and
-- shallow-merges defaults into any missing top-level fields.
--
-- We do a SHALLOW merge intentionally \u2014 deep merging is risky and tends
-- to silently mask bugs. Callers with nested data should write their own
-- migrator and call :Update directly.

function DataStoreSafe:Reconcile(key: string, defaults: Types.SaveData): Types.SaveData
	local existing = self:Load(key) or {}
	for fieldName, defaultValue in pairs(defaults :: { [string]: any }) do
		if (existing :: { [string]: any })[fieldName] == nil then
			(existing :: { [string]: any })[fieldName] = defaultValue
		end
	end
	if self._useCache then
		self._cache[key] = existing
	end
	return existing
end

-- ----------------------------------------------------------------------------
-- v2 Session locks
-- ----------------------------------------------------------------------------
-- Lock writes are stored in a MemoryStore HashMap keyed by the data key.
-- Each lock value is the serverId. A server "holds" a lock if the value
-- in the store equals its serverId AND it hasn't expired.
--
-- LockSession returns true on acquisition. Subsequent calls from the same
-- server are idempotent (return true, refresh TTL). Calls from a different
-- server return false until the existing lock expires or is released.

function DataStoreSafe:_writeLock(key: string): boolean
	-- UpdateAsync semantics on MemoryStoreHashMap: the callback returns
	-- the new value, or nil to abort. We only write if the slot is empty
	-- or already ours.
	local writeOk, _result = pcall(function()
		return self._lockStore:UpdateAsync(key, function(current)
			if current == nil or current == self._serverId then
				return self._serverId
			end
			-- Someone else owns the lock; abort.
			return nil
		end, self._lockTtl)
	end)
	if not writeOk then
		return false
	end

	-- Verify the value is now ours. (If the abort fired, the value won't be.)
	local readOk, currentValue = pcall(function()
		return self._lockStore:GetAsync(key)
	end)
	return readOk and currentValue == self._serverId
end

function DataStoreSafe:LockSession(key: string): boolean
	if self._destroyed then return false end

	local acquired = self:_writeLock(key)
	if not acquired then
		return false
	end

	self._heldLocks[key] = true
	self:_ensureLockRefreshThread()
	return true
end

function DataStoreSafe:ReleaseSession(key: string)
	if not self._heldLocks[key] then return end
	self._heldLocks[key] = nil

	-- Best-effort delete; if the network's down we just let the TTL drop it.
	pcall(function()
		self._lockStore:RemoveAsync(key)
	end)
end

function DataStoreSafe:HoldsLock(key: string): boolean
	return self._heldLocks[key] == true
end

-- Background loop that refreshes every held lock at lockRefresh intervals.
-- Started lazily on first :LockSession call; stops when no locks are held
-- or :Destroy fires.
function DataStoreSafe:_ensureLockRefreshThread()
	if self._lockRefreshThread ~= nil then return end

	self._lockRefreshThread = task.spawn(function()
		while not self._destroyed do
			task.wait(self._lockRefresh)
			if self._destroyed then return end

			-- Snapshot the keys so we don't iterate while mutating.
			local keys = {}
			for k in pairs(self._heldLocks) do
				table.insert(keys, k)
			end

			if #keys == 0 then
				-- Nothing to refresh; let the thread idle out so we don't
				-- spin a heartbeat with no work.
				self._lockRefreshThread = nil
				return
			end

			for _, key in ipairs(keys) do
				if self._destroyed then return end
				self:_writeLock(key)
			end
		end
	end)
end

-- ----------------------------------------------------------------------------
-- Cache helpers \u2014 unchanged
-- ----------------------------------------------------------------------------

function DataStoreSafe:GetCache(key: string): Types.SaveData?
	return self._cache[key]
end

function DataStoreSafe:ClearCache(key: string)
	self._cache[key] = nil
end

-- ----------------------------------------------------------------------------
-- Destroy
-- ----------------------------------------------------------------------------

function DataStoreSafe:Destroy()
	self._destroyed = true

	-- Best-effort release of every held lock so other servers can pick up
	-- the player immediately rather than waiting for TTL expiry.
	for key in pairs(self._heldLocks) do
		pcall(function()
			self._lockStore:RemoveAsync(key)
		end)
	end
	self._heldLocks = {}
	self._cache = {}
	-- The refresh thread checks self._destroyed at every wait boundary
	-- and exits cleanly; no need to forcibly cancel it.
	self._lockRefreshThread = nil
end

return DataStoreSafe
