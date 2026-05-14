--!strict
-- test_TradeSystem.lua
-- Tests for TradeSystem — focus is on the security invariants:
--   * State machine transitions in the right order
--   * Ownership re-validation at edit AND at finalize
--   * Ready-flag reset on offer mutation
--   * Tradeable-flag enforcement
--   * Players locked into one trade at a time
--   * Atomic transfer (all-or-nothing on finalize)
--   * Cross-side dupe prevention

local TradeSystem = require(script.Parent.Parent.src.TradeSystem)

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

local function createMockEventBus()
	return {
		_events = {} :: { [string]: { any } },
		Subscribe = function(_self: any, _eventName: string, _callback: (any) -> ()): () -> ()
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
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
		Set = function(_self: any, key: string, value: any) store[key] = value end,
		Reset = function(_self: any) end,
		All = function(_self: any) return store end,
	}
end

-- Mock Inventory: per-uid item bags. Distinguishes tradeable vs soul-bound.
local function createMockInventory()
	local inv = {
		_bags = {} :: { [number]: { [string]: number } },
		_tradeable = {} :: { [string]: boolean },  -- false = soul-bound
		Define = function(self: any, itemId: string, tradeable: boolean)
			self._tradeable[itemId] = tradeable
		end,
		Give = function(self: any, uid: number, itemId: string, qty: number)
			if not self._bags[uid] then self._bags[uid] = {} end
			self._bags[uid][itemId] = (self._bags[uid][itemId] or 0) + qty
		end,
		-- TradeSystem-facing API: operates on the "active" uid, set via SetActive
		_active = 0,
		SetActive = function(self: any, uid: number) self._active = uid end,
		GetItemQuantity = function(self: any, itemId: string): number
			local bag = self._bags[self._active]
			if not bag then return 0 end
			return bag[itemId] or 0
		end,
		IsItemTradeable = function(self: any, itemId: string): boolean
			-- Default true unless explicitly false
			local t = self._tradeable[itemId]
			return t ~= false
		end,
		AddItem = function(self: any, itemId: string, qty: number?): boolean
			local q = qty or 1
			if not self._bags[self._active] then self._bags[self._active] = {} end
			self._bags[self._active][itemId] = (self._bags[self._active][itemId] or 0) + q
			return true
		end,
		RemoveItem = function(self: any, itemId: string, qty: number?): boolean
			local q = qty or 1
			local bag = self._bags[self._active]
			if not bag or (bag[itemId] or 0) < q then return false end
			bag[itemId] -= q
			if bag[itemId] <= 0 then bag[itemId] = nil end
			return true
		end,
	}
	return inv
end

-- Mock PetSystem: simple ownership table.
local function createMockPets()
	return {
		_pets = {} :: { [string]: { id: string, ownerId: number, isFollowing: boolean, inPen: boolean } },
		Give = function(self: any, ownerId: number, petId: string)
			self._pets[petId] = { id = petId, ownerId = ownerId, isFollowing = false, inPen = false }
		end,
		OwnsPet = function(self: any, ownerId: number, petId: string): boolean
			local p = self._pets[petId]
			return p ~= nil and p.ownerId == ownerId
		end,
		GetPet = function(self: any, petId: string): any
			return self._pets[petId]
		end,
	}
end

-- Mock TimerSystem: synchronous, can manually trigger.
local function createMockTimers()
	return {
		_timers = {} :: { [string]: { duration: number, callback: any, fired: boolean } },
		_seq = 0,
		StartTimer = function(self: any, duration: number, callback: any, _loop: boolean?): string
			self._seq += 1
			local id = "t_" .. self._seq
			self._timers[id] = { duration = duration, callback = callback, fired = false }
			return id
		end,
		StopTimer = function(self: any, id: string)
			self._timers[id] = nil
		end,
		Fire = function(self: any, id: string)  -- test helper
			local t = self._timers[id]
			if t and not t.fired then
				t.fired = true
				if t.callback then t.callback(id) end
				self._timers[id] = nil
			end
		end,
	}
end

-- Convenience: build a fresh trio of trade dependencies.
local function buildDeps()
	local inv = createMockInventory()
	local pets = createMockPets()
	local timers = createMockTimers()
	return inv, pets, timers, { inventory = inv, pets = pets, timers = timers }
end

-- ============================================================================
-- Tests
-- ============================================================================

print("TEST: Propose returns id and emits event")
do
	local bus = createMockEventBus()
	local _, _, _, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2)
	assertNotNil(id, "Propose returns id")
	assertEq(#(bus._events["TradeProposed"] or {}), 1, "TradeProposed emitted")

	trade:Destroy()
end

print("TEST: Cannot propose to self")
do
	local bus = createMockEventBus()
	local _, _, _, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 1)
	assertEq(id, nil, "Self-trade returns nil")

	trade:Destroy()
end

print("TEST: Player locked into one trade at a time")
do
	local bus = createMockEventBus()
	local _, _, _, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id1 = trade:Propose(1, 2)
	assertNotNil(id1, "First trade ok")
	-- Player 1 tries to start a second trade while still in first
	local id2 = trade:Propose(1, 3)
	assertEq(id2, nil, "Second trade for player 1 blocked")
	-- Player 2 also blocked
	local id3 = trade:Propose(2, 4)
	assertEq(id3, nil, "Player 2 also locked")

	trade:Destroy()
end

print("TEST: Only invitee can accept")
do
	local bus = createMockEventBus()
	local _, _, _, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	assertFalse(trade:Accept(id, 1), "Proposer cannot accept")
	assertFalse(trade:Accept(id, 99), "Stranger cannot accept")
	assertTrue(trade:Accept(id, 2), "Invitee can accept")

	local t = trade:GetTrade(id)
	if t then assertEq(t.state, "offering", "State after accept") end

	trade:Destroy()
end

print("TEST: AddPet blocks if not owned by adder")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	pets:Give(2, "pet_b")  -- belongs to player 2
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)

	-- Player 1 tries to add a pet they don't own
	assertFalse(trade:AddPet(id, 1, "pet_b"), "AddPet blocks unowned pet")

	trade:Destroy()
end

print("TEST: AddItem blocks soul-bound items")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	inv:Define("soulbound", false)  -- explicit false = NOT tradeable
	inv:SetActive(1)
	inv:Give(1, "soulbound", 5)
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)

	inv:SetActive(1)
	assertFalse(trade:AddItem(id, 1, "soulbound", 1), "Soul-bound item rejected")

	trade:Destroy()
end

print("TEST: AddItem blocks if quantity exceeds inventory")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	inv:Give(1, "potion", 3)
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)

	inv:SetActive(1)
	assertTrue(trade:AddItem(id, 1, "potion", 3), "Add up to inventory ok")
	-- Try to add a 4th — should fail (only 3 in inventory)
	assertFalse(trade:AddItem(id, 1, "potion", 1), "Cannot offer more than owned")

	trade:Destroy()
end

print("TEST: Mutation after Ready resets both ready flags")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	pets:Give(1, "pet_a")
	pets:Give(2, "pet_b")
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)
	trade:AddPet(id, 1, "pet_a")
	trade:AddPet(id, 2, "pet_b")
	trade:SetReady(id, 1, true)
	trade:SetReady(id, 2, true)

	local t = trade:GetTrade(id)
	if t then
		assertEq(t.state, "ready", "Both ready -> ready state")
		assertTrue(t.offers.a.ready, "A ready")
		assertTrue(t.offers.b.ready, "B ready")
	end

	-- Player 1 sneaks in another pet — both ready flags should reset
	pets:Give(1, "pet_a2")
	trade:AddPet(id, 1, "pet_a2")

	t = trade:GetTrade(id)
	if t then
		assertEq(t.state, "offering", "Mutation kicks back to offering")
		assertFalse(t.offers.a.ready, "A ready cleared")
		assertFalse(t.offers.b.ready, "B ready cleared (anti-swap invariant)")
	end

	trade:Destroy()
end

print("TEST: Confirm only allowed after both ready")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	pets:Give(1, "pet_a")
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)
	trade:AddPet(id, 1, "pet_a")

	-- Try to confirm while only one side is ready
	trade:SetReady(id, 1, true)
	assertFalse(trade:Confirm(id, 1, true), "Confirm blocked when only one ready")

	trade:SetReady(id, 2, true)
	assertTrue(trade:Confirm(id, 1, true), "Confirm ok when both ready")

	trade:Destroy()
end

print("TEST: Both confirm finalizes; ownership transfers")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	pets:Give(1, "pet_a")
	pets:Give(2, "pet_b")
	inv:Give(1, "egg_starter", 2)
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)
	trade:AddPet(id, 1, "pet_a")
	trade:AddPet(id, 2, "pet_b")
	inv:SetActive(1)
	trade:AddItem(id, 1, "egg_starter", 1)
	trade:SetReady(id, 1, true)
	trade:SetReady(id, 2, true)
	trade:Confirm(id, 1, true)
	trade:Confirm(id, 2, true)

	-- Verify finalized state
	local t = trade:GetTrade(id)
	if t then assertEq(t.state, "finalized", "State finalized") end

	-- Verify ownership transferred
	assertTrue(pets:OwnsPet(2, "pet_a"), "pet_a now owned by 2")
	assertTrue(pets:OwnsPet(1, "pet_b"), "pet_b now owned by 1")

	-- Verify TradeFinalized fired with correct transfers
	local finals = bus._events["TradeFinalized"]
	assertNotNil(finals, "TradeFinalized fired")
	if finals then
		assertEq(#finals, 1, "Exactly one finalize event")
		local payload = finals[1]
		assertEq(payload.tradeId, id, "Correct trade id in finalize event")
	end

	-- Verify players are released and can start new trades
	assertEq(trade:GetActiveTradeFor(1), nil, "Player 1 freed")
	assertEq(trade:GetActiveTradeFor(2), nil, "Player 2 freed")

	trade:Destroy()
end

print("TEST: Cancel works from any state")
do
	local bus = createMockEventBus()
	local _, _, _, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	assertTrue(trade:Cancel(id, 1), "Cancel from proposed ok")

	local t = trade:GetTrade(id)
	if t then assertEq(t.state, "cancelled", "State cancelled") end

	-- Cannot cancel a cancelled trade
	assertFalse(trade:Cancel(id, 1), "Cannot cancel twice")

	-- Players freed
	assertEq(trade:GetActiveTradeFor(1), nil, "Player 1 freed")
	assertEq(trade:GetActiveTradeFor(2), nil, "Player 2 freed")

	trade:Destroy()
end

print("TEST: Stranger cannot cancel")
do
	local bus = createMockEventBus()
	local _, _, _, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	assertFalse(trade:Cancel(id, 99), "Stranger cancel rejected")

	trade:Destroy()
end

print("TEST: Timer auto-cancel fires after timeout")
do
	local bus = createMockEventBus()
	local inv, pets, timers, deps = buildDeps()
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	local t = trade:GetTrade(id)
	assertNotNil(t, "Trade exists")
	if t then
		assertNotNil(t.timeoutTimerId, "Timer started on propose")
		-- Manually fire the timer to simulate timeout
		timers:Fire(t.timeoutTimerId :: string)
	end

	t = trade:GetTrade(id)
	if t then assertEq(t.state, "cancelled", "Timeout cancels") end

	trade:Destroy()
end

print("TEST: Same pet cannot be in both offers")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	-- This shouldn't happen via legitimate API since AddPet requires
	-- ownership, but the dupe check is belt-and-suspenders.
	pets:Give(1, "pet_x")
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)
	assertTrue(trade:AddPet(id, 1, "pet_x"), "1 adds pet_x")
	-- Now imagine pet_x somehow got transferred to 2 (it didn't, but if it did)
	pets._pets["pet_x"].ownerId = 2
	-- Player 2 tries to also add it — blocked because already in side a
	assertFalse(trade:AddPet(id, 2, "pet_x"), "Cannot add same pet to both sides")

	trade:Destroy()
end

print("TEST: Finalize bails if pet ownership lost mid-trade")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	pets:Give(1, "pet_a")
	pets:Give(2, "pet_b")
	local trade = TradeSystem.new(bus, deps)

	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)
	trade:AddPet(id, 1, "pet_a")
	trade:AddPet(id, 2, "pet_b")
	trade:SetReady(id, 1, true)
	trade:SetReady(id, 2, true)
	trade:Confirm(id, 1, true)

	-- Simulate a cheater transferring pet_a away via a side channel between
	-- their confirm and the partner's confirm.
	pets._pets["pet_a"].ownerId = 999

	-- Partner confirms — finalize should detect and cancel.
	trade:Confirm(id, 2, true)

	local t = trade:GetTrade(id)
	if t then assertEq(t.state, "cancelled", "Finalize aborted on lost ownership") end

	-- pet_b should NOT have moved (atomic all-or-nothing)
	assertTrue(pets:OwnsPet(2, "pet_b"), "pet_b stays with original owner")

	trade:Destroy()
end

print("TEST: Soul-bound flag enforced")
do
	local bus = createMockEventBus()
	local inv, pets, _, deps = buildDeps()
	inv:Define("trophy", false)        -- soul-bound
	inv:Define("regular", true)        -- explicit tradeable
	-- An undefined item should default tradeable (nil tradeable)
	inv:Give(1, "trophy", 1)
	inv:Give(1, "regular", 1)
	inv:Give(1, "undefined", 1)
	inv:SetActive(1)

	local trade = TradeSystem.new(bus, deps)
	local id = trade:Propose(1, 2) :: string
	trade:Accept(id, 2)

	assertFalse(trade:AddItem(id, 1, "trophy", 1), "trophy soul-bound")
	assertTrue(trade:AddItem(id, 1, "regular", 1), "regular tradeable")
	assertTrue(trade:AddItem(id, 1, "undefined", 1), "undefined tradeable by default")

	trade:Destroy()
end

print("All TradeSystem tests passed!")

return true
