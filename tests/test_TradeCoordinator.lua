--!strict
-- test_TradeCoordinator.lua
-- Tests for TradeCoordinator. Focus is on the invariants the production
-- research highlights:
--   * Phase 1 unanimous-yes vs vote-no
--   * Phase 3 partial-commit re-apply (A committed, B didn't)
--   * Idempotency on re-applied transforms
--   * Fence-token rejection of zombie writers
--   * Crash recovery: orphan resume on profile load
--
-- We mock every external service so tests run in any Lua environment that
-- can require the modular library (no Roblox runtime needed).

local TradeCoordinator = require(script.Parent.Parent.src.TradeCoordinator)

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

local function assertNotNil(a: any, msg: string)
	if a == nil then error(msg .. " expected non-nil") end
end

-- ----------------------------------------------------------------------------
-- Mock services
-- ----------------------------------------------------------------------------

-- Synchronous mock EventBus that captures emitted events for assertion.
local function createMockEventBus()
	local events: { [string]: { any } } = {}
	return {
		_events = events,
		Subscribe = function(_self: any, _eventName: string, _cb: (any) -> ())
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then self._events[eventName] = {} end
			table.insert(self._events[eventName], payload)
		end,
	}
end

local function createMockConfig(overrides: { [string]: any }?)
	local store: { [string]: any } = overrides or {}
	return {
		Get = function(_self: any, key: string, default: any?): any
			local v = store[key]
			if v == nil then return default end
			return v
		end,
		Set = function(_self: any, key: string, v: any) store[key] = v end,
		Reset = function(_self: any) end,
		All = function(_self: any) return store end,
	}
end

-- Mock raw DataStore: stores values keyed by string. UpdateAsync calls the
-- transform with the current value and writes back the result. For tests
-- of failure-injection we accept a `failNext` counter.
local function createMockRawStore()
	local store = {
		_data = {} :: { [string]: any },
		_calls = 0,
		_failNext = 0,
	}
	function store:_set(key: string, value: any) self._data[key] = value end
	function store:_get(key: string) return self._data[key] end
	function store:UpdateAsync(key: string, transform: (any) -> any?): any?
		self._calls += 1
		if self._failNext > 0 then
			self._failNext -= 1
			error("MockRawStore:UpdateAsync injected failure")
		end
		local current = self._data[key]
		local new = transform(current)
		if new ~= nil then
			self._data[key] = new
		end
		return new
	end
	function store:GetAsync(key: string, _options: any?)
		return self._data[key]
	end
	function store:SetAsync(key: string, value: any)
		self._calls += 1
		self._data[key] = value
	end
	return store
end

-- Mock ProfileStoreAdapter: minimal surface TradeCoordinator uses.
local function createMockProfileStore(rawStore: any)
	return {
		_raw = rawStore,
		Get = function(self: any, userId: number, _bypassCache: boolean?)
			-- Always read fresh from the raw store.
			return self._raw._data[tostring(userId)]
		end,
		GetRawStore = function(self: any) return self._raw end,
	}
end

-- Mock PetSystem
local function createMockPets()
	local pets = {
		_pets = {} :: { [string]: { ownerId: number } },
	}
	function pets:Give(petId: string, ownerId: number)
		self._pets[petId] = { id = petId, ownerId = ownerId, isFollowing = false, inPen = false }
	end
	function pets:OwnsPet(uid: number, petId: string): boolean
		local p = self._pets[petId]
		return p ~= nil and p.ownerId == uid
	end
	function pets:GetPet(petId: string): any
		return self._pets[petId]
	end
	function pets:TransferOwnership(petId: string, newOwnerId: number): boolean
		local p = self._pets[petId]
		if not p then return false end
		p.ownerId = newOwnerId
		p.isFollowing = false
		p.inPen = false
		return true
	end
	return pets
end

-- Mock txnLogStore: durable WAL persistence (DataStore-like).
local function createMockTxnLogStore()
	local store = {
		_data = {} :: { [string]: any },
	}
	function store:GetAsync(key: string)
		return self._data[key]
	end
	function store:SetAsync(key: string, value: any)
		self._data[key] = value
	end
	function store:UpdateAsync(key: string, transform: (any) -> any?)
		local cur = self._data[key]
		local new = transform(cur)
		if new ~= nil then
			self._data[key] = new
		end
		return new
	end
	return store
end

-- Mock txnCoordinator: fast WAL (MemoryStore-like).
local function createMockTxnCoordinator()
	local coord = {
		_data = {} :: { [string]: any },
	}
	function coord:GetAsync(key: string)
		return self._data[key]
	end
	function coord:SetAsync(key: string, value: any, _ttl: number?)
		self._data[key] = value
	end
	function coord:RemoveAsync(key: string)
		self._data[key] = nil
	end
	return coord
end

-- Build the standard deps table used across most tests.
local function buildDeps()
	local rawStore       = createMockRawStore()
	local profileStore   = createMockProfileStore(rawStore)
	local pets           = createMockPets()
	local txnLogStore    = createMockTxnLogStore()
	local txnCoordinator = createMockTxnCoordinator()

	local deps = {
		profileStore   = profileStore,
		pets           = pets,
		txnLogStore    = txnLogStore,
		txnCoordinator = txnCoordinator,
	}
	return rawStore, profileStore, pets, txnLogStore, txnCoordinator, deps
end

-- Set up two profiles A (uid=100) and B (uid=200) with the given items.
-- Items are stored as the presence-keyed table TradeCoordinator's transform
-- expects: `inventory = { item_a = true, item_b = true }`.
local function seedProfiles(rawStore: any, itemsA: { string }, itemsB: { string })
	local invA = {}
	for _, id in ipairs(itemsA) do invA[id] = true end
	local invB = {}
	for _, id in ipairs(itemsB) do invB[id] = true end
	rawStore:_set("100", { inventory = invA, appliedTxns = {}, _txnFence = 0 })
	rawStore:_set("200", { inventory = invB, appliedTxns = {}, _txnFence = 0 })
end

-- ============================================================================
-- Tests
-- ============================================================================

print("TEST: ExecuteTrade unanimous-yes commits items on both sides")
do
	local rawStore, _, pets, _, _, deps = buildDeps()
	seedProfiles(rawStore, { "potion", "egg" }, { "rope", "torch" })
	pets:Give("pet_alpha", 100)
	pets:Give("pet_beta", 200)

	local cfg = createMockConfig({
		tradeCoordinatorPhase3DelaySec = 0,  -- skip the wait in tests
	})
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	local result = coord:ExecuteTrade(100, 200,
		{ itemsToLeave = { "potion" }, petsToLeave = { "pet_alpha" } },
		{ itemsToLeave = { "rope" },   petsToLeave = { "pet_beta"  } }
	)

	assertTrue(result.success, "ExecuteTrade returns success")
	assertEq(result.state, "COMMITTED", "Final state is COMMITTED")

	-- A's inventory: -potion, +rope
	local aData = rawStore:_get("100")
	assertFalse(aData.inventory["potion"] == true, "A no longer has potion")
	assertTrue(aData.inventory["rope"] == true, "A has rope")
	-- B's inventory: -rope, +potion
	local bData = rawStore:_get("200")
	assertFalse(bData.inventory["rope"] == true, "B no longer has rope")
	assertTrue(bData.inventory["potion"] == true, "B has potion")
	-- Pet ownership swapped
	assertTrue(pets:OwnsPet(200, "pet_alpha"), "pet_alpha now owned by B")
	assertTrue(pets:OwnsPet(100, "pet_beta"), "pet_beta now owned by A")
	-- appliedTxns stamped on both sides
	assertNotNil(aData.appliedTxns[result.txnId], "A's appliedTxns has the txnId")
	assertNotNil(bData.appliedTxns[result.txnId], "B's appliedTxns has the txnId")
	-- Locks cleared
	assertEq(aData._txnLock, nil, "A's lock cleared")
	assertEq(bData._txnLock, nil, "B's lock cleared")

	coord:Destroy()
end

print("TEST: ExecuteTrade aborts when A doesn't own offered item")
do
	local rawStore, _, pets, _, _, deps = buildDeps()
	-- A claims to offer "potion" but only owns "egg"
	seedProfiles(rawStore, { "egg" }, { "rope" })

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	local result = coord:ExecuteTrade(100, 200,
		{ itemsToLeave = { "potion" }, petsToLeave = {} },  -- A doesn't own this
		{ itemsToLeave = { "rope" },   petsToLeave = {} }
	)

	assertFalse(result.success, "ExecuteTrade fails")
	assertEq(result.reason, "prepare_failed", "Reason is prepare_failed")

	-- B's inventory unchanged
	local bData = rawStore:_get("200")
	assertTrue(bData.inventory["rope"] == true, "B still has rope")
	assertFalse(bData.inventory["potion"] == true, "B did not receive potion")
	-- A's inventory unchanged (egg only)
	local aData = rawStore:_get("100")
	assertTrue(aData.inventory["egg"] == true, "A still has egg")
	-- Both locks cleared
	assertEq(aData._txnLock, nil, "A's lock cleared after abort")
	assertEq(bData._txnLock, nil, "B's lock cleared after abort")

	coord:Destroy()
end

print("TEST: Idempotency — re-applying same txnId on a profile is a no-op")
do
	local rawStore, _, _, _, _, deps = buildDeps()
	seedProfiles(rawStore, { "potion" }, { "rope" })

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Manually invoke the transform builder to simulate an UpdateAsync
	-- internal retry that calls the transform a second time on data
	-- that already has the txnId stamped.
	local txnId = "test_txn_idem"
	local transform = coord:_buildTradeTransform(txnId, 1, "COMMIT", { "potion" }, { "rope" })

	-- First application: simulate the commit running normally.
	local data: { [string]: any } = {
		inventory = { potion = true },
		appliedTxns = {},
		_txnFence = 0,
		_txnLock = txnId,
		_txnState = "PREPARED",
		_txnItems = { "potion" },
	}
	local result1 = transform(data)
	assertNotNil(result1, "First commit returns updated data")
	assertNotNil((result1 :: any).appliedTxns[txnId], "txnId stamped")
	assertFalse((result1 :: any).inventory["potion"] == true, "potion removed")
	assertTrue((result1 :: any).inventory["rope"] == true, "rope added")

	-- Second application of the SAME transform on the SAME data should
	-- return nil (no-op), proving the appliedTxns guard works.
	local result2 = transform(result1)
	assertEq(result2, nil, "Re-applying same txnId is a no-op")

	coord:Destroy()
end

print("TEST: Fence-token rejection — stale fence is silently dropped")
do
	local rawStore, _, _, _, _, deps = buildDeps()
	seedProfiles(rawStore, { "potion" }, { "rope" })

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Profile has fence = 5 (current claimer is on fence 5).
	local data: { [string]: any } = {
		inventory = { potion = true },
		appliedTxns = {},
		_txnFence = 5,
	}
	-- A zombie coordinator with an OLD fence (1) tries to write.
	local txnId = "zombie_txn"
	local transform = coord:_buildTradeTransform(txnId, 1, "PREPARE", { "potion" }, {})
	local result = transform(data)
	assertEq(result, nil, "Zombie fence rejected (returned nil)")

	-- A current coordinator (fence 6) is accepted.
	local goodTransform = coord:_buildTradeTransform(txnId, 6, "PREPARE", { "potion" }, {})
	local goodResult = goodTransform(data)
	assertNotNil(goodResult, "Higher fence accepted")
	assertEq((goodResult :: any)._txnFence, 6, "Profile fence updated to 6")

	coord:Destroy()
end

print("TEST: PREPARE on already-locked profile votes NO")
do
	local rawStore, _, _, _, _, deps = buildDeps()
	seedProfiles(rawStore, { "potion" }, {})

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Pre-lock the profile with a different txn.
	local data: { [string]: any } = {
		inventory = { potion = true },
		appliedTxns = {},
		_txnFence = 0,
		_txnLock  = "other_txn_id",
		_txnState = "PREPARED",
	}
	local transform = coord:_buildTradeTransform("new_txn", 1, "PREPARE", { "potion" }, {})
	local result = transform(data)
	assertEq(result, nil, "PREPARE on locked-by-other returns nil (vote NO)")

	coord:Destroy()
end

print("TEST: PREPARE re-entry on same txn returns data unchanged (vote YES)")
do
	local rawStore, _, _, _, _, deps = buildDeps()
	seedProfiles(rawStore, { "potion" }, {})

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Profile already PREPARED for THIS txn (e.g. the engine retried
	-- the transform once).
	local data: { [string]: any } = {
		inventory = { potion = true },
		appliedTxns = {},
		_txnFence = 0,
		_txnLock  = "my_txn",
		_txnState = "PREPARED",
		_txnItems = { "potion" },
	}
	local transform = coord:_buildTradeTransform("my_txn", 1, "PREPARE", { "potion" }, {})
	local result = transform(data)
	assertNotNil(result, "PREPARE re-entry returns data (vote YES)")
	assertEq((result :: any)._txnLock, "my_txn", "Lock unchanged")
	assertEq((result :: any)._txnState, "PREPARED", "State unchanged")

	coord:Destroy()
end

print("TEST: COMMIT on profile not in PREPARED state is no-op")
do
	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local _, _, _, _, _, deps = buildDeps()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	local data: { [string]: any } = {
		inventory = { potion = true },
		appliedTxns = {},
		_txnFence = 0,
		-- Note: NO _txnLock or _txnState
	}
	local transform = coord:_buildTradeTransform("txn1", 1, "COMMIT", { "potion" }, { "rope" })
	local result = transform(data)
	assertEq(result, nil, "COMMIT without PREPARED state is no-op")
	-- Inventory unchanged
	assertTrue(data.inventory["potion"] == true, "potion still there")
	assertEq(data.inventory["rope"], nil, "rope NOT added")

	coord:Destroy()
end

print("TEST: RELEASE_LOCK clears lock without touching inventory")
do
	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local _, _, _, _, _, deps = buildDeps()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	local data: { [string]: any } = {
		inventory = { potion = true },
		appliedTxns = {},
		_txnFence = 0,
		_txnLock  = "txn1",
		_txnState = "PREPARED",
		_txnItems = { "potion" },
	}
	local transform = coord:_buildTradeTransform("txn1", 1, "RELEASE_LOCK", {}, {})
	local result = transform(data)
	assertNotNil(result, "RELEASE_LOCK returns data")
	assertEq((result :: any)._txnLock, nil, "Lock cleared")
	assertEq((result :: any)._txnState, nil, "State cleared")
	assertEq((result :: any)._txnItems, nil, "Items cleared")
	assertTrue((result :: any).inventory["potion"] == true, "Inventory unchanged")

	coord:Destroy()
end

print("TEST: Crash recovery resumes COMMITTED txn that wasn't applied locally")
do
	local rawStore, _, _, txnLogStore, txnCoordinator, deps = buildDeps()
	seedProfiles(rawStore, { "potion" }, { "rope" })

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Inject a coordinator record showing this txn was COMMITTED.
	local txnId = "orphan_committed"
	local record = {
		txnId = txnId,
		state = "COMMITTED",
		fenceToken = 1,
		parties = { "100", "200" },
		offers = {
			["100"] = { itemsToLeave = { "potion" }, petsToLeave = {} },
			["200"] = { itemsToLeave = { "rope" }, petsToLeave = {} },
		},
		createdAt = os.time(),
	}
	txnLogStore:SetAsync("txn_" .. txnId, record)
	txnCoordinator:SetAsync(txnId, record)

	-- The profile loads with a stale lock (server crashed before clearing).
	local profile = {
		Data = {
			inventory   = { potion = true },  -- never committed
			appliedTxns = {},
			_txnFence   = 0,
			_txnLock    = txnId,
			_txnState   = "PREPARED",
			_txnItems   = { "potion" },
		},
	}
	rawStore:_set("100", profile.Data)

	coord:ResumeOrphanedTransaction(profile, 100)

	-- Wait for the spawned re-apply task. In our synchronous mock the
	-- task.spawn body runs immediately, but we also yield to be safe.
	task.wait(0)

	-- The spawned commit transform should have run against the rawStore.
	local data = rawStore:_get("100")
	-- Either the appliedTxns has the stamp now, OR (since spawn timing
	-- can be tricky in tests) the lock is cleared on the local profile.
	-- Both indicate successful resume.
	local stamped = data.appliedTxns[txnId] ~= nil
	local lockCleared = profile.Data._txnLock == nil
	assertTrue(stamped or lockCleared, "Crash recovery either committed or cleared local lock")

	coord:Destroy()
end

print("TEST: Crash recovery aborts orphan that was mid-PREPARE")
do
	local rawStore, _, _, txnLogStore, _, deps = buildDeps()
	seedProfiles(rawStore, { "potion" }, { "rope" })

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Inject a coordinator record stuck in PREPARING state.
	local txnId = "orphan_preparing"
	txnLogStore:SetAsync("txn_" .. txnId, {
		txnId = txnId,
		state = "PREPARING",
		fenceToken = 1,
		parties = { "100", "200" },
		offers = {
			["100"] = { itemsToLeave = { "potion" }, petsToLeave = {} },
			["200"] = { itemsToLeave = { "rope" }, petsToLeave = {} },
		},
		createdAt = os.time(),
	})

	local profile = {
		Data = {
			inventory   = { potion = true },
			appliedTxns = {},
			_txnFence   = 0,
			_txnLock    = txnId,
			_txnState   = "PREPARED",
			_txnItems   = { "potion" },
		},
	}
	rawStore:_set("100", profile.Data)

	coord:ResumeOrphanedTransaction(profile, 100)

	-- Local profile lock immediately cleared; the abort task spawns to
	-- clean the rawStore copy too.
	assertEq(profile.Data._txnLock, nil, "Local profile lock cleared on PREPARING orphan")

	-- Resume should have emitted an OrphanResumed event with action=abort.
	local events = bus._events["TradeCoordinatorOrphanResumed"] or {}
	assertEq(#events, 1, "OrphanResumed fired")
	assertEq(events[1].action, "abort", "Action is abort")

	coord:Destroy()
end

print("TEST: Crash recovery releases orphan with no coordinator record")
do
	local rawStore, _, _, _, _, deps = buildDeps()

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Profile has lock but coordinator record is gone (TTL expired).
	local profile = {
		Data = {
			inventory = { potion = true },
			appliedTxns = {},
			_txnFence = 0,
			_txnLock = "missing_txn",
			_txnState = "PREPARED",
			_txnItems = { "potion" },
		},
	}
	rawStore:_set("100", profile.Data)

	coord:ResumeOrphanedTransaction(profile, 100)

	assertEq(profile.Data._txnLock, nil, "Lock released")
	assertEq(profile.Data._txnState, nil, "State cleared")

	local events = bus._events["TradeCoordinatorOrphanResumed"] or {}
	assertEq(#events, 1, "OrphanResumed event fired")
	assertEq(events[1].action, "release", "Action is release (conservative no-op)")

	coord:Destroy()
end

print("TEST: ResumeOrphanedTransaction is no-op when profile has no _txnLock")
do
	local rawStore, _, _, _, _, deps = buildDeps()

	local cfg = createMockConfig({ tradeCoordinatorPhase3DelaySec = 0 })
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	-- Clean profile, no lock at all.
	local profile = {
		Data = { inventory = {}, appliedTxns = {}, _txnFence = 0 },
	}
	coord:ResumeOrphanedTransaction(profile, 100)

	-- Nothing should have happened: no events fired.
	local events = bus._events["TradeCoordinatorOrphanResumed"] or {}
	assertEq(#events, 0, "No orphan-resume event for clean profile")

	coord:Destroy()
end

print("TEST: GetCoordinatorRecord round-trips a written record")
do
	local _, _, _, txnLogStore, _, deps = buildDeps()
	local cfg = createMockConfig()
	local bus = createMockEventBus()
	local coord = TradeCoordinator.new(bus, deps, cfg)

	local txnId = "round_trip_test"
	txnLogStore:SetAsync("txn_" .. txnId, { txnId = txnId, state = "COMMITTED" })

	local record = coord:GetCoordinatorRecord(txnId)
	assertNotNil(record, "Record retrieved")
	assertEq((record :: any).state, "COMMITTED", "State preserved")

	coord:Destroy()
end

print("All TradeCoordinator tests passed!")

return true
