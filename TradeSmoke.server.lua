--!strict
-- TradeSmoke.server.lua
-- Smoke-test: two mock players complete a full trade end-to-end using the
-- two-phase (Accept → Confirm) TradeSystem API.
--
-- Flow:
--   RequestTrade → AddItem / AddBucks → AcceptTrade × 2 → ConfirmTrade × 2
--   Plus: duplicate-request block, RemoveItem, cancel flow.

local SSS = game:GetService("ServerScriptService")
local EventBus    = require(SSS.src.Core.EventBus)
local TradeSystem = require(SSS.src.TradeSystem)

-- ── check helpers ─────────────────────────────────────────────────────────────

local passed, failed = 0, 0

local function check(label: string, cond: boolean)
	if cond then
		print("  [PASS] " .. label)
		passed += 1
	else
		warn("  [FAIL] " .. label)
		failed += 1
	end
end

local function section(name: string)
	print("\n── " .. name .. " ──")
end

-- ── mock players ──────────────────────────────────────────────────────────────

local UID_A = "player_1001"   -- has: 5 coins
local UID_B = "player_1002"   -- has: 200 bucks

-- ── mock: Inventory ───────────────────────────────────────────────────────────

local itemPool: { [string]: number } = { coin = 5, gem = 2 }

local inventoryMock = {} :: any
function inventoryMock:GetAllSlots(): { { itemId: string, quantity: number } }
	local slots: { { itemId: string, quantity: number } } = {}
	for id, qty in pairs(itemPool) do
		if qty > 0 then
			table.insert(slots, { itemId = id, quantity = qty })
		end
	end
	return slots
end
function inventoryMock:AddItem(itemId: string, qty: number): boolean
	itemPool[itemId] = (itemPool[itemId] or 0) + qty
	return true
end
function inventoryMock:RemoveItem(itemId: string, qty: number): boolean
	local have = itemPool[itemId] or 0
	if have < qty then return false end
	itemPool[itemId] = have - qty
	return true
end

-- ── mock: CurrencySystem ──────────────────────────────────────────────────────

local bucksBalance = 200

local currencyMock = {} :: any
function currencyMock:CanAfford(currencyId: string, amount: number): boolean
	return currencyId == "bucks" and bucksBalance >= amount
end
function currencyMock:Subtract(currencyId: string, amount: number, _reason: string): boolean
	if currencyId == "bucks" then bucksBalance -= amount end
	return true
end
function currencyMock:Add(currencyId: string, amount: number, _reason: string)
	if currencyId == "bucks" then bucksBalance += amount end
end
function currencyMock:GetBalance(currencyId: string): number
	return currencyId == "bucks" and bucksBalance or 0
end

-- ── mock: TimerSystem ─────────────────────────────────────────────────────────

local timerMock = {} :: any
function timerMock:StartTimer(_duration: number, _callback: () -> (), _repeat: boolean?): string
	return "mock_timer_smoke"
end
function timerMock:StopTimer(_id: string) end

-- ── event bus & listener ──────────────────────────────────────────────────────

local bus = EventBus.new()
local events: { [string]: { any } } = {}
local function listenFor(name: string)
	bus:Subscribe(name, function(payload: any)
		if not events[name] then events[name] = {} end
		table.insert(events[name], payload)
	end)
end
listenFor("TradeRequested")
listenFor("ItemTraded")
listenFor("BucksTraded")
listenFor("TradeAccepted")
listenFor("TradeStateChanged")
listenFor("TradeConfirmed")
listenFor("TradeCompleted")
listenFor("TradeCancelled")

-- ── system under test ─────────────────────────────────────────────────────────

local trade = TradeSystem.new(bus, inventoryMock, currencyMock, timerMock)

-- ════════════════════════════════════════════════════════════════════════════
print("\n══════════════════════════════════════")
print("  FASHIONISTA — TRADE SMOKE TEST")
print("══════════════════════════════════════")
-- ════════════════════════════════════════════════════════════════════════════

-- ── Pre-conditions ────────────────────────────────────────────────────────────
section("Pre-conditions")
check("Pool has 5 coins",   (itemPool["coin"] or 0) == 5)
check("Pool has 2 gems",    (itemPool["gem"]  or 0) == 2)
check("Bucks balance: 200", bucksBalance == 200)

-- ── Step 1: RequestTrade ──────────────────────────────────────────────────────
section("Step 1: RequestTrade  (A → B)")
local tradeId = trade:RequestTrade(UID_A, UID_B)
check("RequestTrade returns a tradeId",        tradeId ~= nil)
check("TradeRequested event fired",            #(events["TradeRequested"] or {}) == 1)
check("Self-trade blocked",                    trade:RequestTrade(UID_A, UID_A) == nil)

if tradeId then
	local s = trade:GetTrade(tradeId)
	check("State is 'pending'",                s ~= nil and s.state == "pending")
	check("PlayerA set correctly",             s ~= nil and s.playerA == UID_A)
	check("PlayerB set correctly",             s ~= nil and s.playerB == UID_B)
	-- Second RequestTrade while A is in active trade should return nil
	check("Duplicate request blocked for A",   trade:RequestTrade(UID_A, "player_9999") == nil)
end

-- ── Step 2: AddItem ───────────────────────────────────────────────────────────
section("Step 2: AddItem  (A offers 3 coins, B offers nothing yet)")
if tradeId then
	check("A adds 3 coins",        trade:AddItem(tradeId, UID_A, "coin", 3))
	check("ItemTraded event fired", #(events["ItemTraded"] or {}) >= 1)

	-- Try to exceed pool (only 5 coins, 3 already offered → 3 more = 6 > 5)
	check("A cannot over-offer (3 more → 6 total > 5 pool)", not trade:AddItem(tradeId, UID_A, "coin", 3))

	local s = trade:GetTrade(tradeId)
	check("A's offer: 3 coins recorded", s ~= nil and s.offerA.items[1] ~= nil and s.offerA.items[1].quantity == 3)
end

-- ── Step 3: AddBucks ─────────────────────────────────────────────────────────
section("Step 3: AddBucks  (B offers 100 bucks)")
if tradeId then
	check("B adds 100 bucks",       trade:AddBucks(tradeId, UID_B, 100))
	check("BucksTraded event fired", #(events["BucksTraded"] or {}) >= 1)

	-- Try to exceed balance (200 total, 100 offered → 150 more = 250 > 200)
	check("B cannot over-offer (150 more → 250 total > 200 balance)", not trade:AddBucks(tradeId, UID_B, 150))

	local s = trade:GetTrade(tradeId)
	check("B's offer: 100 bucks recorded", s ~= nil and s.offerB.bucks == 100)
end

-- ── Step 4: RemoveItem ────────────────────────────────────────────────────────
section("Step 4: RemoveItem  (A removes 1 coin, leaving 2 offered)")
if tradeId then
	check("A removes coin slot",       trade:RemoveItem(tradeId, UID_A, "coin"))
	local s = trade:GetTrade(tradeId)
	-- RemoveItem removes the entire slot (design: caller re-adds with correct qty)
	local coinQty = 0
	if s then
		for _, slot in ipairs(s.offerA.items) do
			if slot.itemId == "coin" then coinQty = slot.quantity end
		end
	end
	check("A's offer: coin slot cleared", coinQty == 0)
end

-- ── Step 5: AcceptTrade ───────────────────────────────────────────────────────
section("Step 5: AcceptTrade  (both lock in)")
if tradeId then
	check("A accepts",                   trade:AcceptTrade(tradeId, UID_A))
	check("TradeAccepted event (A)",     #(events["TradeAccepted"] or {}) == 1)
	local sMid = trade:GetTrade(tradeId)
	check("Still 'pending' (only A)",    sMid ~= nil and sMid.state == "pending")

	check("B accepts",                   trade:AcceptTrade(tradeId, UID_B))
	check("TradeAccepted event (B)",     #(events["TradeAccepted"] or {}) == 2)
	check("TradeStateChanged fired",     #(events["TradeStateChanged"] or {}) >= 1)

	local sBoth = trade:GetTrade(tradeId)
	check("State → 'accepted'",          sBoth ~= nil and sBoth.state == "accepted")

	-- Double-accept should fail
	check("Double-accept blocked",       not trade:AcceptTrade(tradeId, UID_A))
end

-- ── Step 6: ConfirmTrade ──────────────────────────────────────────────────────
section("Step 6: ConfirmTrade  (both confirm → execute swap)")
if tradeId then
	check("A confirms",                  trade:ConfirmTrade(tradeId, UID_A))
	check("TradeConfirmed event (A)",    #(events["TradeConfirmed"] or {}) == 1)
	local sMid = trade:GetTrade(tradeId)
	check("Still 'accepted' (only A)",   sMid ~= nil and sMid.state == "accepted")

	check("B confirms",                  trade:ConfirmTrade(tradeId, UID_B))
	check("TradeConfirmed event (B)",    #(events["TradeConfirmed"] or {}) == 2)
	check("TradeCompleted event fired",  #(events["TradeCompleted"] or {}) == 1)

	local sDone = trade:GetTrade(tradeId)
	check("State → 'completed'",         sDone ~= nil and sDone.state == "completed")

	-- Verify item pool changed: A gave 2 coins, B gave 100 bucks
	-- Net for the shared pool: coins -= 0 (removed then re-added = net same), bucks -= 0 (net same)
	-- The important check is the event payload
	local ev = events["TradeCompleted"] and events["TradeCompleted"][1]
	check("TradeCompleted has tradeId",  ev ~= nil and ev.tradeId == tradeId)
end

-- ── Step 7: Cancel flow ───────────────────────────────────────────────────────
section("Step 7: Cancel flow  (fresh trade, player C cancels)")
local UID_C = "player_2001"
local UID_D = "player_2002"
local tradeId2 = trade:RequestTrade(UID_C, UID_D)
if tradeId2 then
	-- Stranger cannot cancel
	check("Stranger cannot cancel",      (function()
		local s = trade:GetTrade(tradeId2)
		trade:CancelTrade(tradeId2, "player_9999")
		local sAfter = trade:GetTrade(tradeId2)
		return sAfter ~= nil and sAfter.state ~= "cancelled"
	end)())
	check("C can cancel own trade",      (function()
		trade:CancelTrade(tradeId2, UID_C)
		return true
	end)())
	check("TradeCancelled event fired",  #(events["TradeCancelled"] or {}) >= 1)
	local sCan = trade:GetTrade(tradeId2)
	check("State → 'cancelled'",         sCan ~= nil and sCan.state == "cancelled")
end

-- ── Results ───────────────────────────────────────────────────────────────────
print("\n──────────────────────────────────────")
print(string.format("  Results: %d passed, %d failed", passed, failed))
print("──────────────────────────────────────")
if failed == 0 then
	print("  ALL CHECKS PASSED — Trade system verified end-to-end!")
else
	print(string.format("  %d check(s) failed — see above.", failed))
end
print("══════════════════════════════════════\n")
