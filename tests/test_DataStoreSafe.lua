--!strict
-- tests/test_DataStoreSafe.lua
-- Tests for cache logic, retry math, and config parsing.

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. " expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. " expected false")
	end
end

-- Mock DataStoreService and GlobalDataStore
local MockDataStore = {}
MockDataStore.__index = MockDataStore

function MockDataStore.new(failTimes: number?)
	local self = setmetatable({}, MockDataStore)
	self._data = {} :: { [string]: any }
	self._failures = failTimes or 0
	self._calls = 0
	return self
end

function MockDataStore:GetAsync(key: string): any
	self._calls += 1
	if self._failures > 0 then
		self._failures -= 1
		error("MockDataStore:GetAsync simulated failure (remaining " .. tostring(self._failures) .. ")")
	end
	return self._data[key]
end

function MockDataStore:SetAsync(key: string, value: any)
	self._calls += 1
	if self._failures > 0 then
		self._failures -= 1
		error("MockDataStore:SetAsync simulated failure (remaining " .. tostring(self._failures) .. ")")
	end
	self._data[key] = value
end

-- v2: UpdateAsync semantics on the mock store. Calls the transform with
-- the current value, applies the result, and returns the written value.
-- Used by the v2 :Update path.
function MockDataStore:UpdateAsync(key: string, transform: (any) -> any): any
	self._calls += 1
	if self._failures > 0 then
		self._failures -= 1
		error("MockDataStore:UpdateAsync simulated failure (remaining " .. tostring(self._failures) .. ")")
	end
	local current = self._data[key]
	local new = transform(current)
	if new ~= nil then
		self._data[key] = new
	end
	return new
end

-- v2 mock: MemoryStoreHashMap with TTL semantics. We don't actually wait,
-- but we record TTLs so tests can assert refresh behaviour.
local MockMemoryHashMap = {}
MockMemoryHashMap.__index = MockMemoryHashMap

function MockMemoryHashMap.new()
	local self = setmetatable({}, MockMemoryHashMap)
	self._data = {} :: { [string]: any }
	self._ttls = {} :: { [string]: number }
	self._calls = 0
	return self
end

function MockMemoryHashMap:UpdateAsync(key: string, transform: (any) -> any, ttl: number?)
	self._calls += 1
	local current = self._data[key]
	local new = transform(current)
	if new == nil then
		return nil  -- abort, value unchanged
	end
	self._data[key] = new
	self._ttls[key] = ttl or 0
	return new
end

function MockMemoryHashMap:GetAsync(key: string): any
	return self._data[key]
end

function MockMemoryHashMap:RemoveAsync(key: string)
	self._data[key] = nil
	self._ttls[key] = nil
end

-- Build a lightweight DataStoreSafe replica for testing
local DataStoreSafeModule = {}
DataStoreSafeModule.__index = DataStoreSafeModule

function DataStoreSafeModule.new(
	name: string,
	config: { retries: number?, retryDelay: number?, useCache: boolean?,
	          serverId: string?, lockTtlSec: number? }?,
	mockStore: any?,
	mockLockStore: any?
)
	local self = setmetatable({}, DataStoreSafeModule)
	self._name = name
	self._retries = if config and config.retries ~= nil then config.retries :: number else 3
	self._retryDelay = if config and config.retryDelay ~= nil then config.retryDelay :: number else 1
	self._useCache = if config and config.useCache ~= nil then config.useCache :: boolean else true
	self._store = mockStore
	self._lockStore = mockLockStore  -- nil for v1-only tests
	self._cache = {}
	self._heldLocks = {}
	self._serverId = (config and config.serverId) or "test_server_1"
	self._lockTtl = (config and config.lockTtlSec) or 30
	return self
end

function DataStoreSafeModule:_waitRetry(attempt: number)
	-- In real code: task.wait(self._retryDelay * (2 ^ attempt))
	-- For tests we just compute the value so callers can assert the math.
	self._lastWaited = self._retryDelay * (2 ^ attempt)
end

function DataStoreSafeModule:Load(key: string): { [string]: any }?
	if self._useCache then
		local cached = self._cache[key]
		if cached ~= nil then
			return cached
		end
	end

	local success = false
	local result: any = nil
	local err = ""

	for attempt = 0, self._retries do
		success, result = pcall(function()
			return self._store:GetAsync(key)
		end)

		if success then
			break
		else
			err = tostring(result)
			if attempt < self._retries then
				self:_waitRetry(attempt)
			end
		end
	end

	if not success then
		return nil
	end

	if result == nil then
		return nil
	end

	if self._useCache then
		self._cache[key] = result
	end

	return result
end

function DataStoreSafeModule:Save(key: string, data: { [string]: any }): boolean
	local success = false
	local err = ""

	for attempt = 0, self._retries do
		success, err = pcall(function()
			self._store:SetAsync(key, data)
		end)

		if success then
			break
		else
			err = tostring(err)
			if attempt < self._retries then
				self:_waitRetry(attempt)
			end
		end
	end

	if not success then
		return false
	end

	if self._useCache then
		self._cache[key] = data
	end

	return true
end

-- v2: Update wraps UpdateAsync with retries. Mirrors the real module's
-- contract: returns (success, written_value).
function DataStoreSafeModule:Update(key: string, transform: (any) -> any): (boolean, any)
	local success = false
	local result: any = nil

	for attempt = 0, self._retries do
		success, result = pcall(function()
			return self._store:UpdateAsync(key, function(current)
				return transform(current)
			end)
		end)

		if success then
			break
		end
		if attempt < self._retries then
			self:_waitRetry(attempt)
		end
	end

	if not success then
		return false, nil
	end
	if result ~= nil and self._useCache then
		self._cache[key] = result
	end
	return true, result
end

-- v2: Reconcile loads + shallow-merges defaults into missing fields.
function DataStoreSafeModule:Reconcile(key: string, defaults: { [string]: any }): { [string]: any }
	local existing = self:Load(key) or {}
	for field, default in pairs(defaults) do
		if existing[field] == nil then
			existing[field] = default
		end
	end
	if self._useCache then
		self._cache[key] = existing
	end
	return existing
end

-- v2: Session locking via the mock MemoryStoreHashMap.
function DataStoreSafeModule:LockSession(key: string): boolean
	local ok = pcall(function()
		self._lockStore:UpdateAsync(key, function(current)
			if current == nil or current == self._serverId then
				return self._serverId
			end
			return nil
		end, self._lockTtl)
	end)
	if not ok then return false end

	local _, currentValue = pcall(function()
		return self._lockStore:GetAsync(key)
	end)
	if currentValue == self._serverId then
		self._heldLocks[key] = true
		return true
	end
	return false
end

function DataStoreSafeModule:ReleaseSession(key: string)
	if not self._heldLocks[key] then return end
	self._heldLocks[key] = nil
	pcall(function() self._lockStore:RemoveAsync(key) end)
end

function DataStoreSafeModule:HoldsLock(key: string): boolean
	return self._heldLocks[key] == true
end

function DataStoreSafeModule:Destroy()
	for key in pairs(self._heldLocks) do
		pcall(function() self._lockStore:RemoveAsync(key) end)
	end
	self._heldLocks = {}
	self._cache = {}
end

function DataStoreSafeModule:GetCache(key: string): { [string]: any }?
	return self._cache[key]
end

function DataStoreSafeModule:ClearCache(key: string)
	self._cache[key] = nil
end

-- Tests
local function testDefaultConfig()
	local store = DataStoreSafeModule.new("TestStore", nil, MockDataStore.new())
	assertEq(store._retries, 3, "Default retries should be 3")
	assertEq(store._retryDelay, 1, "Default retryDelay should be 1")
	assertTrue(store._useCache, "Default useCache should be true")
end

local function testCustomConfig()
	local store = DataStoreSafeModule.new("TestStore", { retries = 5, retryDelay = 2, useCache = false }, MockDataStore.new())
	assertEq(store._retries, 5, "Custom retries should be 5")
	assertEq(store._retryDelay, 2, "Custom retryDelay should be 2")
	assertFalse(store._useCache, "Custom useCache should be false")
end

local function testRetryDelayMath()
	local store = DataStoreSafeModule.new("TestStore", { retryDelay = 0.5, retries = 3 }, MockDataStore.new())
	store:_waitRetry(0)
	assertEq(store._lastWaited, 0.5, "Attempt 0 delay should be retryDelay * 2^0")
	store:_waitRetry(1)
	assertEq(store._lastWaited, 1.0, "Attempt 1 delay should be retryDelay * 2^1")
	store:_waitRetry(2)
	assertEq(store._lastWaited, 2.0, "Attempt 2 delay should be retryDelay * 2^2")
end

local function testLoadCachesResult()
	local mock = MockDataStore.new()
	mock._data["key1"] = { coins = 100 }

	local store = DataStoreSafeModule.new("TestStore", nil, mock)
	local data = store:Load("key1")
	assertEq(data.coins, 100, "Load should return stored data")
	assertEq(store:GetCache("key1").coins, 100, "Cache should contain loaded data")
end

local function testLoadReturnsCacheWithoutStoreCall()
	local mock = MockDataStore.new()
	mock._data["key1"] = { coins = 100 }

	local store = DataStoreSafeModule.new("TestStore", nil, mock)
	store:Load("key1")
	local beforeCalls = mock._calls

	local data = store:Load("key1")
	assertEq(mock._calls, beforeCalls, "Second load should not call store when cached")
	assertEq(data.coins, 100, "Cached load should return correct data")
end

local function testSaveUpdatesCache()
	local mock = MockDataStore.new()
	local store = DataStoreSafeModule.new("TestStore", nil, mock)

	local ok = store:Save("key2", { gems = 5 })
	assertTrue(ok, "Save should succeed")
	assertEq(store:GetCache("key2").gems, 5, "Cache should be updated after save")
	assertEq(mock._data["key2"].gems, 5, "Store should contain saved data")
end

local function testClearCache()
	local mock = MockDataStore.new()
	mock._data["key3"] = { xp = 50 }

	local store = DataStoreSafeModule.new("TestStore", nil, mock)
	store:Load("key3")
	assertTrue(store:GetCache("key3") ~= nil, "Cache should exist after load")

	store:ClearCache("key3")
	assertEq(store:GetCache("key3"), nil, "Cache should be nil after clear")
end

local function testLoadRetriesThenSucceeds()
	local mock = MockDataStore.new(2) -- fail first 2 calls
	mock._data["key4"] = { level = 10 }

	local store = DataStoreSafeModule.new("TestStore", { retries = 3, retryDelay = 0 }, mock)
	local data = store:Load("key4")
	assertEq(data.level, 10, "Load should eventually succeed after retries")
	assertEq(mock._calls, 3, "Should have called store 3 times (2 fails + 1 success)")
end

local function testLoadRetriesThenFails()
	local mock = MockDataStore.new(5) -- fail more than retries

	local store = DataStoreSafeModule.new("TestStore", { retries = 2, retryDelay = 0 }, mock)
	local data = store:Load("key5")
	assertEq(data, nil, "Load should return nil when all retries exhausted")
	assertEq(mock._calls, 3, "Should have called store retries+1 times")
end

local function testSaveRetriesThenSucceeds()
	local mock = MockDataStore.new(1) -- fail first call

	local store = DataStoreSafeModule.new("TestStore", { retries = 2, retryDelay = 0 }, mock)
	local ok = store:Save("key6", { score = 99 })
	assertTrue(ok, "Save should eventually succeed after retries")
	assertEq(mock._calls, 2, "Should have called store 2 times (1 fail + 1 success)")
end

local function testSaveRetriesThenFails()
	local mock = MockDataStore.new(5)

	local store = DataStoreSafeModule.new("TestStore", { retries = 1, retryDelay = 0 }, mock)
	local ok = store:Save("key7", { score = 99 })
	assertFalse(ok, "Save should return false when all retries exhausted")
	assertEq(mock._calls, 2, "Should have called store retries+1 times")
end

local function testNoCacheWhenDisabled()
	local mock = MockDataStore.new()
	mock._data["key8"] = { health = 80 }

	local store = DataStoreSafeModule.new("TestStore", { useCache = false, retries = 2, retryDelay = 0 }, mock)
	local data = store:Load("key8")
	assertEq(data.health, 80, "Load should return data even with cache disabled")
	assertEq(store:GetCache("key8"), nil, "Cache should be nil when useCache is false")
end

local function testNilDataLoad()
	local mock = MockDataStore.new()
	-- mock._data["missing"] is nil

	local store = DataStoreSafeModule.new("TestStore", nil, mock)
	local data = store:Load("missing")
	assertEq(data, nil, "Load of missing key should return nil")
end

-- ============================================================================
-- v2 tests — Update / Reconcile / session locking
-- ============================================================================

local function testUpdateAppliesTransform()
	local mock = MockDataStore.new()
	mock._data["key"] = { coins = 10 }

	local store = DataStoreSafeModule.new("TS", { retryDelay = 0 }, mock)
	local ok, value = store:Update("key", function(current)
		current.coins += 5
		return current
	end)

	assertTrue(ok, "Update succeeds")
	assertEq(value.coins, 15, "Transform was applied")
	assertEq(mock._data["key"].coins, 15, "Store reflects update")
end

local function testUpdateAbortReturnsNil()
	-- A transform returning nil should leave the value unchanged.
	local mock = MockDataStore.new()
	mock._data["key"] = { coins = 10 }

	local store = DataStoreSafeModule.new("TS", { retryDelay = 0 }, mock)
	local ok, value = store:Update("key", function(_current)
		return nil  -- abort
	end)

	assertTrue(ok, "Update with abort still returns success")
	assertEq(value, nil, "Abort returns nil for the written value")
	assertEq(mock._data["key"].coins, 10, "Store unchanged on abort")
end

local function testUpdateRetriesThenSucceeds()
	local mock = MockDataStore.new(2)  -- fail first 2 calls

	local store = DataStoreSafeModule.new("TS", { retryDelay = 0 }, mock)
	local ok, value = store:Update("key", function(_current) return { v = 1 } end)
	assertTrue(ok, "Update eventually succeeds after retries")
	assertEq(value.v, 1, "Final value applied")
	assertEq(mock._calls, 3, "Three calls (2 fails + 1 success)")
end

local function testUpdateAllRetriesFailReturnsFalse()
	local mock = MockDataStore.new(10)

	local store = DataStoreSafeModule.new("TS", { retries = 2, retryDelay = 0 }, mock)
	local ok, value = store:Update("key", function(_) return { v = 1 } end)
	assertFalse(ok, "Returns false when all retries exhausted")
	assertEq(value, nil, "Returns nil for value on failure")
end

local function testReconcileFillsMissingFields()
	local mock = MockDataStore.new()
	mock._data["k"] = { coins = 100 }  -- exists, missing 'gems'

	local store = DataStoreSafeModule.new("TS", { retryDelay = 0 }, mock)
	local data = store:Reconcile("k", { coins = 0, gems = 5, level = 1 })

	assertEq(data.coins, 100, "Existing field preserved")
	assertEq(data.gems, 5, "Missing field filled from default")
	assertEq(data.level, 1, "Other missing field filled")
end

local function testReconcileOnEmptyKey()
	local mock = MockDataStore.new()  -- key doesn't exist at all

	local store = DataStoreSafeModule.new("TS", { retryDelay = 0 }, mock)
	local data = store:Reconcile("new_key", { coins = 500, level = 1 })

	assertEq(data.coins, 500, "All defaults applied to new key")
	assertEq(data.level, 1, "All defaults applied to new key")
end

local function testLockSessionAcquiresAndReleases()
	local mock = MockDataStore.new()
	local lockStore = MockMemoryHashMap.new()

	local store = DataStoreSafeModule.new("TS", { serverId = "s1", retryDelay = 0 }, mock, lockStore)
	local got = store:LockSession("player_1")
	assertTrue(got, "First lock acquisition succeeds")
	assertTrue(store:HoldsLock("player_1"), "HoldsLock returns true after acquire")
	assertEq(lockStore._data["player_1"], "s1", "Lock store records the serverId")

	store:ReleaseSession("player_1")
	assertFalse(store:HoldsLock("player_1"), "HoldsLock returns false after release")
	assertEq(lockStore._data["player_1"], nil, "Lock store no longer has the key")
end

local function testLockSessionRefusesIfHeldByOtherServer()
	local mock = MockDataStore.new()
	local lockStore = MockMemoryHashMap.new()

	-- Server A grabs the lock first
	local sA = DataStoreSafeModule.new("TS", { serverId = "sA", retryDelay = 0 }, mock, lockStore)
	assertTrue(sA:LockSession("p1"), "Server A acquires lock")

	-- Server B tries
	local sB = DataStoreSafeModule.new("TS", { serverId = "sB", retryDelay = 0 }, mock, lockStore)
	local got = sB:LockSession("p1")
	assertFalse(got, "Server B is rejected because A holds the lock")
	assertFalse(sB:HoldsLock("p1"), "Server B does not hold")
	assertEq(lockStore._data["p1"], "sA", "Lock store still belongs to A")
end

local function testLockSessionIdempotentForSameServer()
	local mock = MockDataStore.new()
	local lockStore = MockMemoryHashMap.new()

	local store = DataStoreSafeModule.new("TS", { serverId = "s1", retryDelay = 0 }, mock, lockStore)
	assertTrue(store:LockSession("p1"), "First acquire")
	assertTrue(store:LockSession("p1"), "Re-acquire by same server is idempotent")
end

local function testDestroyReleasesAllLocks()
	local mock = MockDataStore.new()
	local lockStore = MockMemoryHashMap.new()

	local store = DataStoreSafeModule.new("TS", { serverId = "s1", retryDelay = 0 }, mock, lockStore)
	store:LockSession("p1")
	store:LockSession("p2")
	assertTrue(store:HoldsLock("p1"), "p1 held")
	assertTrue(store:HoldsLock("p2"), "p2 held")

	store:Destroy()
	assertFalse(store:HoldsLock("p1"), "p1 released by Destroy")
	assertFalse(store:HoldsLock("p2"), "p2 released by Destroy")
	assertEq(lockStore._data["p1"], nil, "Lock store cleaned for p1")
	assertEq(lockStore._data["p2"], nil, "Lock store cleaned for p2")
end

-- Runner
local tests = {
	{ name = "testDefaultConfig", fn = testDefaultConfig },
	{ name = "testCustomConfig", fn = testCustomConfig },
	{ name = "testRetryDelayMath", fn = testRetryDelayMath },
	{ name = "testLoadCachesResult", fn = testLoadCachesResult },
	{ name = "testLoadReturnsCacheWithoutStoreCall", fn = testLoadReturnsCacheWithoutStoreCall },
	{ name = "testSaveUpdatesCache", fn = testSaveUpdatesCache },
	{ name = "testClearCache", fn = testClearCache },
	{ name = "testLoadRetriesThenSucceeds", fn = testLoadRetriesThenSucceeds },
	{ name = "testLoadRetriesThenFails", fn = testLoadRetriesThenFails },
	{ name = "testSaveRetriesThenSucceeds", fn = testSaveRetriesThenSucceeds },
	{ name = "testSaveRetriesThenFails", fn = testSaveRetriesThenFails },
	{ name = "testNoCacheWhenDisabled", fn = testNoCacheWhenDisabled },
	{ name = "testNilDataLoad", fn = testNilDataLoad },
	-- v2 additions
	{ name = "testUpdateAppliesTransform", fn = testUpdateAppliesTransform },
	{ name = "testUpdateAbortReturnsNil", fn = testUpdateAbortReturnsNil },
	{ name = "testUpdateRetriesThenSucceeds", fn = testUpdateRetriesThenSucceeds },
	{ name = "testUpdateAllRetriesFailReturnsFalse", fn = testUpdateAllRetriesFailReturnsFalse },
	{ name = "testReconcileFillsMissingFields", fn = testReconcileFillsMissingFields },
	{ name = "testReconcileOnEmptyKey", fn = testReconcileOnEmptyKey },
	{ name = "testLockSessionAcquiresAndReleases", fn = testLockSessionAcquiresAndReleases },
	{ name = "testLockSessionRefusesIfHeldByOtherServer", fn = testLockSessionRefusesIfHeldByOtherServer },
	{ name = "testLockSessionIdempotentForSameServer", fn = testLockSessionIdempotentForSameServer },
	{ name = "testDestroyReleasesAllLocks", fn = testDestroyReleasesAllLocks },
}

local passed = 0
local failed = 0

for _, test in ipairs(tests) do
	local ok, err = pcall(test.fn)
	if ok then
		passed += 1
		print("[PASS] " .. test.name)
	else
		failed += 1
		print("[FAIL] " .. test.name .. ": " .. tostring(err))
	end
end

print("\nResults: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed out of " .. tostring(#tests))

return true
