--!strict
-- tests/test_CurrencySystem.lua
-- Lightweight assert-based tests for CurrencySystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local Config = require(script.Parent.Parent.src.Core.Config)
local CurrencySystem = require(script.Parent.Parent.src.CurrencySystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. ": expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. ": expected false")
	end
end

local function runTests()
	print("[test_CurrencySystem] Starting tests...")

	-- Test 1: RegisterCurrency and GetBalance
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins",
			name = "Gold Coins",
			symbol = "G",
			defaultBalance = 100,
		})

		assertEq(currency:GetBalance("coins"), 100, "Default balance should be 100")
		print("  [PASS] RegisterCurrency and GetBalance")
	end

	-- Test 2: Add
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		local ok = currency:Add("coins", 50, "quest_reward")
		assertTrue(ok, "Add should succeed")
		assertEq(currency:GetBalance("coins"), 50, "Balance after add")
		print("  [PASS] Add")
	end

	-- Test 3: Add event emission
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		local addedFired = false
		local changedFired = false
		bus:Subscribe("CurrencyAdded", function(payload: any)
			addedFired = true
			assertEq(payload.currencyId, "coins", "CurrencyAdded currencyId")
			assertEq(payload.amount, 30, "CurrencyAdded amount")
			assertEq(payload.newBalance, 30, "CurrencyAdded newBalance")
		end)
		bus:Subscribe("CurrencyBalanceChanged", function(payload: any)
			changedFired = true
			assertEq(payload.oldBalance, 0, "CurrencyBalanceChanged oldBalance")
			assertEq(payload.newBalance, 30, "CurrencyBalanceChanged newBalance")
		end)

		currency:Add("coins", 30)
		assertTrue(addedFired, "CurrencyAdded should fire")
		assertTrue(changedFired, "CurrencyBalanceChanged should fire")
		print("  [PASS] Add event emission")
	end

	-- Test 4: Subtract success
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 100,
		})

		local ok = currency:Subtract("coins", 40, "purchase")
		assertTrue(ok, "Subtract should succeed")
		assertEq(currency:GetBalance("coins"), 60, "Balance after subtract")
		print("  [PASS] Subtract success")
	end

	-- Test 5: Subtract fail (would go negative)
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 10,
		})

		local ok = currency:Subtract("coins", 20)
		assertFalse(ok, "Subtract should fail when balance insufficient")
		assertEq(currency:GetBalance("coins"), 10, "Balance should remain unchanged")
		print("  [PASS] Subtract fail")
	end

	-- Test 6: Subtract with allowDebt
	do
		local bus = EventBus.new()
		local cfg = Config.new({ allowDebt = true })
		local currency = CurrencySystem.new(bus, cfg)
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 10,
		})

		local ok = currency:Subtract("coins", 20)
		assertTrue(ok, "Subtract should succeed with allowDebt")
		assertEq(currency:GetBalance("coins"), -10, "Balance should be negative with debt")
		print("  [PASS] Subtract with allowDebt")
	end

	-- Test 7: CanAfford
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 50,
		})

		assertTrue(currency:CanAfford("coins", 50), "CanAfford exact amount")
		assertTrue(currency:CanAfford("coins", 30), "CanAfford less than balance")
		assertFalse(currency:CanAfford("coins", 51), "CanAfford more than balance")
		print("  [PASS] CanAfford")
	end

	-- Test 8: Transfer
	do
		local bus = EventBus.new()
		local currencyA = CurrencySystem.new(bus, Config.new())
		local currencyB = CurrencySystem.new(bus, Config.new())

		currencyA:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 100,
		})
		currencyB:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		local ok = currencyA:Transfer("coins", 30, currencyB)
		assertTrue(ok, "Transfer should succeed")
		assertEq(currencyA:GetBalance("coins"), 70, "A balance after transfer")
		assertEq(currencyB:GetBalance("coins"), 30, "B balance after transfer")
		print("  [PASS] Transfer")
	end

	-- Test 9: Transfer fail (insufficient funds)
	do
		local bus = EventBus.new()
		local currencyA = CurrencySystem.new(bus, Config.new())
		local currencyB = CurrencySystem.new(bus, Config.new())

		currencyA:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 10,
		})
		currencyB:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		local ok = currencyA:Transfer("coins", 30, currencyB)
		assertFalse(ok, "Transfer should fail with insufficient funds")
		assertEq(currencyA:GetBalance("coins"), 10, "A balance unchanged")
		assertEq(currencyB:GetBalance("coins"), 0, "B balance unchanged")
		print("  [PASS] Transfer fail")
	end

	-- Test 10: Transfer to nil target
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 100,
		})

		local ok = currency:Transfer("coins", 30, nil :: any)
		assertFalse(ok, "Transfer to nil should fail")
		print("  [PASS] Transfer to nil")
	end

	-- Test 11: GetHistory
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		currency:Add("coins", 10, "reward1")
		currency:Add("coins", 20, "reward2")
		currency:Subtract("coins", 5, "fee")

		local history = currency:GetHistory("coins")
		assertEq(#history, 3, "History should have 3 entries")
		assertEq(history[1].amount, 10, "History[1] amount")
		assertEq(history[1].reason, "reward1", "History[1] reason")
		assertEq(history[3].amount, -5, "History[3] amount (subtract)")
		print("  [PASS] GetHistory")
	end

	-- Test 12: GetHistory with limit
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		currency:Add("coins", 1, "t1")
		currency:Add("coins", 2, "t2")
		currency:Add("coins", 3, "t3")
		currency:Add("coins", 4, "t4")

		local history = currency:GetHistory("coins", 2)
		assertEq(#history, 2, "History with limit should return 2 entries")
		assertEq(history[1].amount, 3, "History[1] should be the 3rd transaction")
		assertEq(history[2].amount, 4, "History[2] should be the 4th transaction")
		print("  [PASS] GetHistory with limit")
	end

	-- Test 13: TransactionLogged event
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 0,
		})

		local logged = false
		bus:Subscribe("TransactionLogged", function(payload: any)
			logged = true
			assertEq(payload.currencyId, "coins", "TransactionLogged currencyId")
			assertEq(payload.amount, 25, "TransactionLogged amount")
			assertEq(payload.reason, "test", "TransactionLogged reason")
		end)

		currency:Add("coins", 25, "test")
		assertTrue(logged, "TransactionLogged should fire")
		print("  [PASS] TransactionLogged event")
	end

	-- Test 14: Subtract event emission
	do
		local bus = EventBus.new()
		local currency = CurrencySystem.new(bus, Config.new())
		currency:RegisterCurrency({
			id = "coins", name = "Gold Coins", symbol = "G", defaultBalance = 50,
		})

		local subtractFired = false
		bus:Subscribe("CurrencySubtracted", function(payload: any)
			subtractFired = true
			assertEq(payload.currencyId, "coins", "CurrencySubtracted currencyId")
			assertEq(payload.amount, 20, "CurrencySubtracted amount")
			assertEq(payload.newBalance, 30, "CurrencySubtracted newBalance")
		end)

		currency:Subtract("coins", 20)
		assertTrue(subtractFired, "CurrencySubtracted should fire")
		print("  [PASS] Subtract event emission")
	end

	print("[test_CurrencySystem] All tests passed!")
end

runTests()

return true
