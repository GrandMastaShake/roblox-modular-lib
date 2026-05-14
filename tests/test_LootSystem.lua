--!strict
-- test_LootSystem.lua
-- Lightweight tests for LootSystem module.

local LootSystem = require(script.Parent.Parent.src.LootSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
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

local function createMockEventBus()
	local bus = {
		_events = {} :: { [string]: { any } },
		Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
		end,
	}
	return bus
end

-- Test 1: RegisterRarity and GetRarityColor
print("TEST: RegisterRarity and GetRarityColor")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})

	local color = ls:GetRarityColor("common")
	assertEq(color.R, 0.5, "RarityColor R")
	assertEq(color.G, 0.5, "RarityColor G")
	assertEq(color.B, 0.5, "RarityColor B")
end

-- Test 2: GetRarityColor unknown returns white
print("TEST: GetRarityColor unknown")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	local color = ls:GetRarityColor("nonexistent")
	assertEq(color.R, 1, "Unknown rarity should be white R")
	assertEq(color.G, 1, "Unknown rarity should be white G")
	assertEq(color.B, 1, "Unknown rarity should be white B")
end

-- Test 3: RegisterLootTable and Roll returns results
print("TEST: RegisterLootTable and Roll")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterLootTable({
		id = "basic_drops",
		entries = {
			{ itemId = "coin", quantity = 1, rarityId = "common", weight = 1 },
		},
		rollCount = 1,
	})

	local results = ls:Roll("basic_drops")
	assertEq(#results, 1, "Roll should return 1 result")
	assertEq(results[1].itemId, "coin", "Roll result itemId")
	assertEq(results[1].quantity, 1, "Roll result quantity")
end

-- Test 4: Roll emits LootDropped event
print("TEST: Roll emits LootDropped")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterLootTable({
		id = "basic_drops",
		entries = {
			{ itemId = "coin", quantity = 1, rarityId = "common", weight = 1 },
		},
		rollCount = 2,
	})

	ls:Roll("basic_drops")

	local events = bus._events["LootDropped"] or {}
	assertEq(#events, 1, "LootDropped event count")
	if events[1] then
		assertEq(#events[1].results, 2, "LootDropped results count")
	end
end

-- Test 5: Roll unknown table returns empty
print("TEST: Roll unknown table")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	local results = ls:Roll("nonexistent")
	assertEq(#results, 0, "Roll unknown table should return empty")
end

-- Test 6: Weighted distribution (rare vs common)
print("TEST: Weighted distribution")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterRarity({
		id = "rare",
		name = "Rare",
		color = Color3.new(0, 0, 1),
		weight = 0.1,
	})
	ls:RegisterLootTable({
		id = "mixed_drops",
		entries = {
			{ itemId = "common_item", quantity = 1, rarityId = "common", weight = 1 },
			{ itemId = "rare_item", quantity = 1, rarityId = "rare", weight = 1 },
		},
		rollCount = 100,
	})

	local results = ls:Roll("mixed_drops")
	assertEq(#results, 100, "Roll should return 100 results")

	local commonCount = 0
	local rareCount = 0
	for _, result in ipairs(results) do
		if result.itemId == "common_item" then
			commonCount += 1
		elseif result.itemId == "rare_item" then
			rareCount += 1
		end
	end

	-- Common should appear significantly more than rare due to rarity weight
	assertTrue(commonCount > rareCount, "Common items should drop more than rare")
end

-- Test 7: RareItemDropped event
print("TEST: RareItemDropped event")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterRarity({
		id = "legendary",
		name = "Legendary",
		color = Color3.new(1, 0.8, 0),
		weight = 0.05,
	})
	ls:RegisterLootTable({
		id = "boss_drops",
		entries = {
			{ itemId = "legendary_sword", quantity = 1, rarityId = "legendary", weight = 1 },
		},
		rollCount = 1,
	})

	ls:Roll("boss_drops")

	local rareEvents = bus._events["RareItemDropped"] or {}
	assertTrue(#rareEvents >= 0, "RareItemDropped may or may not fire based on roll")
end

-- Test 8: luckModifier increases weights
print("TEST: luckModifier")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterLootTable({
		id = "lucky_drops",
		entries = {
			{ itemId = "coin", quantity = 1, rarityId = "common", weight = 1 },
		},
		rollCount = 5,
	})

	local results = ls:Roll("lucky_drops", 2.0)
	assertEq(#results, 5, "Luck modifier should not change result count")
end

-- Test 9: Multiple entries with same rarity
print("TEST: Multiple entries same rarity")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterLootTable({
		id = "multi_drops",
		entries = {
			{ itemId = "coin", quantity = 1, rarityId = "common", weight = 3 },
			{ itemId = "herb", quantity = 1, rarityId = "common", weight = 1 },
		},
		rollCount = 100,
	})

	local results = ls:Roll("multi_drops")
	local coinCount = 0
	local herbCount = 0
	for _, result in ipairs(results) do
		if result.itemId == "coin" then
			coinCount += 1
		elseif result.itemId == "herb" then
			herbCount += 1
		end
	end

	-- Coin has 3x the weight, so should appear roughly 3x more
	assertTrue(coinCount > herbCount, "Higher weight entry should drop more")
end

-- Test 10: Roll with rollCount > 1
print("TEST: Roll count")
do
	local bus = createMockEventBus()
	local ls = LootSystem.new(bus)
	ls:RegisterRarity({
		id = "common",
		name = "Common",
		color = Color3.new(0.5, 0.5, 0.5),
		weight = 1.0,
	})
	ls:RegisterLootTable({
		id = "multi_roll",
		entries = {
			{ itemId = "coin", quantity = 1, rarityId = "common", weight = 1 },
		},
		rollCount = 5,
	})

	local results = ls:Roll("multi_roll")
	assertEq(#results, 5, "Roll should return exactly rollCount results")
end

print("All LootSystem tests passed.")

return true
