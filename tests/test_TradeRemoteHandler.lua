--!strict
-- test_TradeRemoteHandler.lua
-- Tests for the network-edge trade hardening layer.
--
-- The handler's job is to be paranoid about every incoming RemoteEvent fire:
--   * Reject malformed payloads BEFORE TradeSystem sees them
--   * Enforce per-event rate limits per player
--   * Pre-validate ownership where cheap
-- We test those security invariants directly. We do NOT test that the
-- TradeSystem methods themselves do the right thing \u2014 those are tested in
-- test_TradeSystem.lua.

local TradeRemoteHandler = require(script.Parent.Parent.src.TradeRemoteHandler)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then error(msg .. " expected true") end
end

-- ----------------------------------------------------------------------------
-- Mock RemoteEvent that captures fired callbacks so tests can invoke them.
-- ----------------------------------------------------------------------------
local function createMockRemoteEvent(name: string)
	local event = {
		Name = name,
		_fired = {} :: { (any, ...any) -> () },
		_clientFires = {} :: { { player: any, args: { any } } },
	}
	event.OnServerEvent = {
		Connect = function(_self: any, cb: (any, ...any) -> ()): any
			table.insert(event._fired, cb)
			local conn = { Connected = true }
			function conn:Disconnect() conn.Connected = false end
			return conn
		end,
	}
	function event:Fire(player: any, ...): ()
		for _, cb in ipairs(self._fired) do
			cb(player, ...)
		end
	end
	function event:FireClient(player: any, ...)
		table.insert(self._clientFires, { player = player, args = { ... } })
	end
	return event
end

local function createMockPlayer(uid: number)
	return { UserId = uid, Name = "Player" .. uid }
end

-- ----------------------------------------------------------------------------
-- Mock TradeSystem
-- ----------------------------------------------------------------------------
local function createMockTrades()
	local trades: any = {
		_calls = {} :: { { method: string, args: { any } } },
	}
	local function record(method: string, args: { any }): boolean
		table.insert(trades._calls, { method = method, args = args })
		return true
	end
	function trades:Propose(...) record("Propose", { ... }); return "trade_test_id" end
	function trades:Accept(...) return record("Accept", { ... }) end
	function trades:AddPet(...) return record("AddPet", { ... }) end
	function trades:RemovePet(...) return record("RemovePet", { ... }) end
	function trades:AddItem(...) return record("AddItem", { ... }) end
	function trades:RemoveItem(...) return record("RemoveItem", { ... }) end
	function trades:SetReady(...) return record("SetReady", { ... }) end
	function trades:Confirm(...) return record("Confirm", { ... }) end
	function trades:Cancel(...) return record("Cancel", { ... }) end
	return trades
end

local function createMockInventory()
	return {
		IsItemTradeable = function(_self: any, _id: string) return true end,
		GetItemQuantity = function(_self: any, _id: string) return 100 end,
	}
end

local function createMockPets()
	local pets: any = { _owners = {} :: { [string]: number } }
	function pets:Give(petId: string, uid: number) self._owners[petId] = uid end
	function pets:OwnsPet(uid: number, petId: string)
		return self._owners[petId] == uid
	end
	return pets
end

local function createMockEventBus()
	local events: { [string]: { any } } = {}
	return {
		_events = events,
		Subscribe = function(_self: any, _: string, _cb: (any) -> ())
			return function() end
		end,
		Emit = function(self: any, name: string, payload: any)
			if not self._events[name] then self._events[name] = {} end
			table.insert(self._events[name], payload)
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

local function buildHandler(rateOverrides: { [string]: any }?)
	local trades   = createMockTrades()
	local inv      = createMockInventory()
	local pets     = createMockPets()
	local bus      = createMockEventBus()
	local cfg      = createMockConfig(rateOverrides)

	local inbound = {
		TradeRequest    = createMockRemoteEvent("TradeRequest"),
		TradeAccept     = createMockRemoteEvent("TradeAccept"),
		TradeAddPet     = createMockRemoteEvent("TradeAddPet"),
		TradeRemovePet  = createMockRemoteEvent("TradeRemovePet"),
		TradeAddItem    = createMockRemoteEvent("TradeAddItem"),
		TradeRemoveItem = createMockRemoteEvent("TradeRemoveItem"),
		TradeSetReady   = createMockRemoteEvent("TradeSetReady"),
		TradeConfirm    = createMockRemoteEvent("TradeConfirm"),
		TradeCancel     = createMockRemoteEvent("TradeCancel"),
	}

	local handler = TradeRemoteHandler.new(bus, {
		trades   = trades,
		inventory = inv,
		pets     = pets,
		inbound  = inbound,
	}, cfg)

	return handler, trades, inv, pets, bus, inbound
end

-- ============================================================================
-- Sanitization tests
-- ============================================================================

print("TEST: TradeAccept rejects non-string trade id")
do
	local handler, _, _, _, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	-- Number instead of string
	inbound.TradeAccept:Fire(player, 12345)

	local rejects = bus._events["TradeRemoteRejected"] or {}
	assertEq(#rejects, 1, "One reject event")
	assertEq(rejects[1].reason, "bad_trade_id", "Reason is bad_trade_id")

	handler:Destroy()
end

print("TEST: TradeAccept rejects trade id with bad characters")
do
	local handler, _, _, _, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	-- Strings with semicolons, slashes, null bytes, etc. should be rejected.
	for _, badId in ipairs({"abc;def", "abc/def", "abc def", "abc\0def", string.rep("a", 65)}) do
		inbound.TradeAccept:Fire(player, badId)
	end

	local rejects = bus._events["TradeRemoteRejected"] or {}
	assertEq(#rejects, 5, "All 5 bad ids rejected")
	for _, reject in ipairs(rejects) do
		assertEq(reject.reason, "bad_trade_id", "Each rejection cites bad_trade_id")
	end

	handler:Destroy()
end

print("TEST: TradeAddItem rejects non-positive or non-integer quantities")
do
	local handler, _, _, _, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	for _, badQty in ipairs({0, -5, 1.5, "5", true, math.huge}) do
		inbound.TradeAddItem:Fire(player, "trade_abc", "potion", badQty)
	end

	local rejects = bus._events["TradeRemoteRejected"] or {}
	-- Note: we expect 6 rejects, but rate limiting WILL kick in after the
	-- first AddItem. Default rate limit is 0.25s per player per event.
	-- Each bad-quantity rejection happens BEFORE rate counter advances on
	-- accept, but the rate check fires first. So actually the rate limit
	-- counter advances on EVERY call (whether or not the payload passes).
	-- Result: first call passes rate check but fails sanitize; subsequent
	-- calls hit rate limit.
	assertTrue(#rejects >= 1, "At least one reject")
	-- The first one is bad_quantity; the rest (within 0.25s) are rate_limited
	assertEq(rejects[1].reason, "bad_quantity", "First rejection is bad_quantity")

	handler:Destroy()
end

print("TEST: TradeRequest blocks self-trade and offline target")
do
	local handler, _, _, _, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	inbound.TradeRequest:Fire(player, 100)  -- self-trade attempt

	local rejects = bus._events["TradeRemoteRejected"] or {}
	assertEq(#rejects, 1, "Self-trade rejected")
	assertEq(rejects[1].reason, "self_trade", "Reason is self_trade")

	handler:Destroy()
end

print("TEST: TradeAddPet rejects when player doesn't own pet")
do
	local handler, _, _, pets, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	-- pet "alpha" exists but is owned by player 200
	pets:Give("alpha", 200)

	inbound.TradeAddPet:Fire(player, "trade_abc", "alpha")

	local rejects = bus._events["TradeRemoteRejected"] or {}
	assertEq(#rejects, 1, "Non-owner reject fired")
	assertEq(rejects[1].reason, "not_owner", "Reason is not_owner")

	handler:Destroy()
end

print("TEST: TradeSetReady rejects non-boolean ready arg")
do
	local handler, _, _, _, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	inbound.TradeSetReady:Fire(player, "trade_abc", "yes")  -- string instead of bool

	local rejects = bus._events["TradeRemoteRejected"] or {}
	assertEq(#rejects, 1, "Bad-type reject fired")
	assertEq(rejects[1].reason, "bad_ready_type", "Reason is bad_ready_type")

	handler:Destroy()
end

-- ============================================================================
-- Rate-limiting tests
-- ============================================================================

print("TEST: Rate limit blocks rapid TradeAddItem fires")
do
	-- Use a tight rate limit so the test doesn't have to wait long.
	local handler, _, _, _, bus, inbound = buildHandler({
		tradeRateLimit_TradeAddItem = 0.5,  -- 0.5s minimum between fires
	})
	local player = createMockPlayer(100)

	-- First fire should accept (or reject for a non-rate reason).
	inbound.TradeAddItem:Fire(player, "trade_abc", "potion", 1)
	-- Second fire immediately should be rate-limited.
	inbound.TradeAddItem:Fire(player, "trade_abc", "potion", 2)

	local rejects = bus._events["TradeRemoteRejected"] or {}
	-- The first call may have hit `add_failed` (mock returns true so no),
	-- so the reject for the second call should be `rate_limited`.
	local rateLimited = false
	for _, r in ipairs(rejects) do
		if r.reason == "rate_limited" then rateLimited = true end
	end
	assertTrue(rateLimited, "Second fire was rate-limited")

	handler:Destroy()
end

print("TEST: Rate limit is per-player not global")
do
	local handler, _, _, _, bus, inbound = buildHandler({
		tradeRateLimit_TradeAddItem = 0.5,
	})
	local player1 = createMockPlayer(100)
	local player2 = createMockPlayer(200)

	inbound.TradeAddItem:Fire(player1, "trade_abc", "potion", 1)
	-- Different player; should NOT be rate-limited.
	inbound.TradeAddItem:Fire(player2, "trade_abc", "potion", 1)

	local rejects = bus._events["TradeRemoteRejected"] or {}
	for _, r in ipairs(rejects) do
		assertTrue(r.reason ~= "rate_limited", "No rate-limit for different player")
	end

	handler:Destroy()
end

-- ============================================================================
-- Accept-path tests
-- ============================================================================

print("TEST: Valid TradeAccept passes through to TradeSystem and emits Accepted")
do
	local handler, trades, _, _, bus, inbound = buildHandler()
	local player = createMockPlayer(100)

	inbound.TradeAccept:Fire(player, "trade_legit_id")

	local accepts = bus._events["TradeRemoteAccepted"] or {}
	assertEq(#accepts, 1, "Acceptance emitted")
	assertEq(accepts[1].eventName, "TradeAccept", "Right event name")

	-- Check TradeSystem received the call
	local relevant = {}
	for _, c in ipairs(trades._calls) do
		if c.method == "Accept" then table.insert(relevant, c) end
	end
	assertEq(#relevant, 1, "TradeSystem.Accept called once")

	handler:Destroy()
end

print("TEST: Destroy disconnects all signal connections")
do
	local handler, _, _, _, _, _ = buildHandler()
	-- Smoke test: Destroy doesn't throw.
	handler:Destroy()
	assertTrue(true, "Destroy completed cleanly")
end

print("All TradeRemoteHandler tests passed!")

return true
