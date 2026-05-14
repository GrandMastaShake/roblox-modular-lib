--!strict
-- test_EquipmentSystem.lua
-- Lightweight tests for EquipmentSystem module.

local EquipmentSystem = require(script.Parent.Parent.src.EquipmentSystem)

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

-- Test 1: RegisterSlot
print("TEST: RegisterSlot")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({
		id = "main_hand",
		name = "Main Hand",
		allowedTypes = { "weapon" },
	})

	-- No direct getter for slots, but we can verify via Equip behavior
	local ok = es:Equip("main_hand", "sword", nil, "weapon")
	assertTrue(ok, "Equip should succeed for registered slot")
end

-- Test 2: Equip and GetEquipped
print("TEST: Equip and GetEquipped")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({
		id = "head",
		name = "Head",
		allowedTypes = nil,
	})

	local ok = es:Equip("head", "iron_helmet", { defense = 5 })
	assertTrue(ok, "Equip should succeed")

	local equipped = es:GetEquipped("head")
	assertTrue(equipped ~= nil, "GetEquipped should return item")
	if equipped then
		assertEq(equipped.itemId, "iron_helmet", "Equipped itemId")
		assertEq(equipped.slotId, "head", "Equipped slotId")
		if equipped.stats then
			assertEq(equipped.stats.defense, 5, "Equipped stat defense")
		end
	end
end

-- Test 3: Equip with type filtering (allowedTypes)
print("TEST: Equip type filtering")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({
		id = "main_hand",
		name = "Main Hand",
		allowedTypes = { "weapon" },
	})

	local okWeapon = es:Equip("main_hand", "sword", nil, "weapon")
	assertTrue(okWeapon, "Equip should succeed with matching type")

	local okArmor = es:Equip("main_hand", "shield", nil, "armor")
	assertFalse(okArmor, "Equip should fail with non-matching type")

	local okNoType = es:Equip("main_hand", "mystery_item", nil, nil)
	assertFalse(okNoType, "Equip should fail when itemType is nil and slot has restrictions")
end

-- Test 4: Unequip returns itemId
print("TEST: Unequip")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({
		id = "chest",
		name = "Chest",
		allowedTypes = nil,
	})

	es:Equip("chest", "iron_armor", nil)
	local unequippedId = es:Unequip("chest")
	assertEq(unequippedId, "iron_armor", "Unequip should return itemId")

	local equipped = es:GetEquipped("chest")
	assertTrue(equipped == nil, "GetEquipped should return nil after unequip")
end

-- Test 5: Unequip empty slot returns nil
print("TEST: Unequip empty slot")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({ id = "feet", name = "Feet" })

	local result = es:Unequip("feet")
	assertTrue(result == nil, "Unequip empty slot should return nil")
end

-- Test 6: Equip emits ItemEquipped with previousItemId
print("TEST: Equip overwrite emits previousItemId")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({ id = "main_hand", name = "Main Hand", allowedTypes = nil })

	es:Equip("main_hand", "old_sword", nil)
	es:Equip("main_hand", "new_sword", nil)

	local events = bus._events["ItemEquipped"] or {}
	assertEq(#events, 2, "ItemEquipped event count")
	assertTrue(events[2].previousItemId ~= nil, "Second equip should have previousItemId")
	if events[2] then
		assertEq(events[2].previousItemId, "old_sword", "previousItemId should be old_sword")
	end
end

-- Test 7: Unequip emits ItemUnequipped
print("TEST: Unequip emits ItemUnequipped")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({ id = "head", name = "Head" })

	es:Equip("head", "helmet", nil)
	es:Unequip("head")

	local events = bus._events["ItemUnequipped"] or {}
	assertEq(#events, 1, "ItemUnequipped event count")
	if events[1] then
		assertEq(events[1].itemId, "helmet", "ItemUnequipped itemId")
		assertEq(events[1].slotId, "head", "ItemUnequipped slotId")
	end
end

-- Test 8: GetAllEquipped
print("TEST: GetAllEquipped")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({ id = "head", name = "Head" })
	es:RegisterSlot({ id = "chest", name = "Chest" })
	es:RegisterSlot({ id = "legs", name = "Legs" })

	es:Equip("head", "helmet", nil)
	es:Equip("chest", "armor", nil)

	local all = es:GetAllEquipped()
	assertEq(#all, 2, "GetAllEquipped count")
end

-- Test 9: GetTotalStats sums correctly
print("TEST: GetTotalStats")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({ id = "head", name = "Head" })
	es:RegisterSlot({ id = "chest", name = "Chest" })
	es:RegisterSlot({ id = "main_hand", name = "Main Hand" })

	es:Equip("head", "helmet", { defense = 5, health = 10 })
	es:Equip("chest", "armor", { defense = 10, health = 20 })
	es:Equip("main_hand", "sword", { attack = 15 })

	local totals = es:GetTotalStats()
	assertEq(totals.defense, 15, "Total defense")
	assertEq(totals.health, 30, "Total health")
	assertEq(totals.attack, 15, "Total attack")
end

-- Test 10: GetTotalStats empty
print("TEST: GetTotalStats empty")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	local totals = es:GetTotalStats()
	assertEq(next(totals), nil, "GetTotalStats should be empty")
end

-- Test 11: Equip into unregistered slot fails
print("TEST: Equip unregistered slot")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	local ok = es:Equip("unknown", "item", nil)
	assertFalse(ok, "Equip should fail for unregistered slot")
end

-- Test 12: StatsChanged event
print("TEST: StatsChanged event")
do
	local bus = createMockEventBus()
	local es = EquipmentSystem.new(bus)
	es:RegisterSlot({ id = "head", name = "Head" })

	es:Equip("head", "helmet", { defense = 5 })

	local events = bus._events["StatsChanged"] or {}
	assertTrue(#events >= 1, "StatsChanged should be emitted")
	if events[1] and events[1].stats then
		assertEq(events[1].stats.defense, 5, "StatsChanged defense value")
	end
end

print("All EquipmentSystem tests passed.")

return true
