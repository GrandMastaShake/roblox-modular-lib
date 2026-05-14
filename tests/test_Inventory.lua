--!strict
-- test_Inventory.lua
-- Lightweight tests for Inventory module.

local Inventory = require(script.Parent.Parent.src.Inventory)

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

-- Test 1: AddItem and GetSlot
print("TEST: AddItem and GetSlot")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "sword", name = "Iron Sword", maxStack = 1, equippable = true })

	local ok = inv:AddItem("sword", 1)
	assertTrue(ok, "AddItem should succeed")

	local slot = inv:GetSlot(1)
	assertTrue(slot ~= nil, "Slot 1 should not be nil")
	if slot then
		assertEq(slot.itemId, "sword", "Slot itemId")
		assertEq(slot.quantity, 1, "Slot quantity")
		assertEq(slot.equipped, false, "Slot equipped default")
	end

	assertEq(#(bus._events["ItemAdded"] or {}), 1, "ItemAdded event count")
end

-- Test 2: Stacking
print("TEST: Stacking")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "potion", name = "Health Potion", maxStack = 5, equippable = false })

	inv:AddItem("potion", 3)
	inv:AddItem("potion", 2)

	local slot = inv:GetSlot(1)
	assertTrue(slot ~= nil, "Stack slot should exist")
	if slot then
		assertEq(slot.quantity, 5, "Stack quantity should be 5")
	end

	assertEq(#(bus._events["ItemAdded"] or {}), 2, "Two ItemAdded events")
end

-- Test 3: Overflow to next slot
print("TEST: Overflow to next slot")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "potion", name = "Health Potion", maxStack = 5, equippable = false })

	inv:AddItem("potion", 5)
	inv:AddItem("potion", 3)

	local slot1 = inv:GetSlot(1)
	local slot2 = inv:GetSlot(2)
	assertTrue(slot1 ~= nil, "Slot 1 should exist")
	assertTrue(slot2 ~= nil, "Slot 2 should exist")
	if slot1 then assertEq(slot1.quantity, 5, "Slot 1 quantity") end
	if slot2 then assertEq(slot2.quantity, 3, "Slot 2 quantity") end
end

-- Test 4: InventoryFull
print("TEST: InventoryFull")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 2)
	inv:DefineItem({ id = "gem", name = "Gem", maxStack = 1, equippable = false })

	local ok1 = inv:AddItem("gem", 1)
	local ok2 = inv:AddItem("gem", 1)
	local ok3 = inv:AddItem("gem", 1)

	assertTrue(ok1, "First add should succeed")
	assertTrue(ok2, "Second add should succeed")
	assertFalse(ok3, "Third add should fail (full)")

	local fullEvents = bus._events["InventoryFull"] or {}
	assertEq(#fullEvents, 1, "InventoryFull event count")
	if fullEvents[1] then
		assertEq(fullEvents[1].itemId, "gem", "InventoryFull itemId")
		assertEq(fullEvents[1].remaining, 1, "InventoryFull remaining")
	end
end

-- Test 5: RemoveItem
print("TEST: RemoveItem")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "arrow", name = "Arrow", maxStack = 10, equippable = false })

	inv:AddItem("arrow", 8)
	local ok = inv:RemoveItem("arrow", 3)
	assertTrue(ok, "RemoveItem should succeed")

	local slot = inv:GetSlot(1)
	assertTrue(slot ~= nil, "Slot should exist after partial remove")
	if slot then
		assertEq(slot.quantity, 5, "Remaining quantity")
	end

	local ok2 = inv:RemoveItem("arrow", 5)
	assertTrue(ok2, "RemoveItem remaining should succeed")
	local slot2 = inv:GetSlot(1)
	assertTrue(slot2 == nil, "Slot should be empty after full remove")
end

-- Test 6: EquipItem / UnequipItem
print("TEST: EquipItem / UnequipItem")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "sword", name = "Iron Sword", maxStack = 1, equippable = true })
	inv:DefineItem({ id = "potion", name = "Health Potion", maxStack = 5, equippable = false })

	inv:AddItem("sword", 1)
	inv:AddItem("potion", 1)

	local eqOk = inv:EquipItem(1)
	assertTrue(eqOk, "EquipItem should succeed for equippable item")

	local slot = inv:GetSlot(1)
	assertTrue(slot ~= nil, "Slot 1 should exist")
	if slot then
		assertEq(slot.equipped, true, "Slot should be equipped")
	end

	local eqFail = inv:EquipItem(2)
	assertFalse(eqFail, "EquipItem should fail for non-equippable item")

	local ueqOk = inv:UnequipItem(1)
	assertTrue(ueqOk, "UnequipItem should succeed")

	local slotAfter = inv:GetSlot(1)
	assertTrue(slotAfter ~= nil, "Slot 1 should still exist")
	if slotAfter then
		assertEq(slotAfter.equipped, false, "Slot should be unequipped")
	end
end

-- Test 7: RemoveItem not enough
print("TEST: RemoveItem not enough")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "coin", name = "Coin", maxStack = 99, equippable = false })

	inv:AddItem("coin", 2)
	local ok = inv:RemoveItem("coin", 5)
	assertFalse(ok, "RemoveItem should fail when not enough items")
end

-- Test 8: GetAllSlots
print("TEST: GetAllSlots")
do
	local bus = createMockEventBus()
	local inv = Inventory.new(bus, 5)
	inv:DefineItem({ id = "berry", name = "Berry", maxStack = 5, equippable = false })

	inv:AddItem("berry", 2)
	inv:AddItem("berry", 2)

	local all = inv:GetAllSlots()
	assertEq(#all, 1, "GetAllSlots should return 1 slot (stacked)")
	if all[1] then
		assertEq(all[1].quantity, 4, "Total stacked quantity")
	end
end

print("All Inventory tests passed.")

return true
